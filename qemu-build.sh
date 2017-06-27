#!/bin/bash
###############################################################################
#
# This build script is for running the QEMU build as a container with the
# option of launching the container with Docker or Kubernetes.
#
###############################################################################
#
# Variables used for in the build:
#  WORKSPACE    = Path of the workspace directory where some intermediate files
#                 and the images will be saved to.
#  qemudir      = Path of the QEMU directory where the build will be done, if
#                 none exists will clone in the OpenBMC/QEMU repo to WORKSPACE.
#
# Optional Variables:
#  launch       = job|pod
#                 Can be left blank to launch via Docker if not using
#                 Kubernetes to launch the container.
#                 Job lets you keep a copy of job and container logs on the
#                 api, can be useful if not using Jenkins as you can run the
#                 job again via the api without needing this script.
#                 Pod launches a container which runs to completion without
#                 saving anything to the api when it completes.
#  imgname      = Defaults to qemu-build with the arch as its tag, can be
#                 changed or passed to give a specific name to created image.
#  http_proxy   = The HTTP address for the proxy server you wish to connect to.
#
###############################################################################

# Trace bash processing
set -x

# Default variables
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
http_proxy=${http_proxy:-}
launch=${launch:-}
qemudir=${qemudir:-${WORKSPACE}/qemu}
ARCH=$(uname -m)
imgname=${imgname:-qemu-build:${ARCH}}

# Timestamp for job
echo "Build started, $(date)"

# Setup Proxy
if [[ -n "${http_proxy}" ]]; then
PROXY="RUN echo \"Acquire::http::Proxy \\"\"${http_proxy}/\\"\";\" > /etc/apt/apt.conf.d/000apt-cacher-ng-proxy"
fi

# Determine the prefix of the Dockerfile's base image
case ${ARCH} in
  "ppc64le")
    DOCKER_BASE="ppc64le/"
    ;;
  "x86_64")
    DOCKER_BASE=""
    ;;
  *)
    echo "Unsupported system architecture(${ARCH}) found for docker image"
    exit 1
esac

# If there is no qemu directory, git clone in the openbmc mirror
if [ ! -d ${qemudir} ]; then
  echo "Clone in openbmc master to ${qemudir}"
  git clone https://github.com/openbmc/qemu ${qemudir}
fi

# Create the docker run script
export PROXY_HOST=${http_proxy/#http*:\/\/}
export PROXY_HOST=${PROXY_HOST/%:[0-9]*}
export PROXY_PORT=${http_proxy/#http*:\/\/*:}

mkdir -p ${WORKSPACE}

cat > "${WORKSPACE}"/build.sh << EOF_SCRIPT
#!/bin/bash

set -x

# create a copy of the qemudir in /qemu to use as the build directory
cp -r ${qemudir}/* /qemu

# Go into the source directory (the script will put us in a build subdir)
cd /qemu

gcc --version
git submodule update --init dtc
# disable anything that requires us to pull in X
./configure \
    --target-list=arm-softmmu \
    --disable-spice \
    --disable-docs \
    --disable-gtk \
    --disable-smartcard \
    --disable-usb-redir \
    --disable-libusb \
    --disable-sdl \
    --disable-gnutls \
    --disable-vte \
    --disable-vnc \
    --disable-vnc-png
make -j4

cp -r /qemu/arm-softmmu ${WORKSPACE}/arm-softmmu
EOF_SCRIPT

chmod a+x ${WORKSPACE}/build.sh

# Configure docker build
Dockerfile=$(cat << EOF
FROM ${DOCKER_BASE}ubuntu:16.04

${PROXY}

ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update && apt-get install -yy --no-install-recommends \
    bison \
    flex \
    gcc \
    git \
    libc6-dev \
    libfdt-dev \
    libglib2.0-dev \
    libpixman-1-dev \
    make \
    python-yaml \
    python3-yaml

RUN grep -q ${GROUPS} /etc/group || groupadd -g ${GROUPS} ${USER}
RUN grep -q ${UID} /etc/passwd || useradd -d ${HOME} -m -u ${UID} -g ${GROUPS} ${USER}
RUN mkdir /qemu \
    chown -r 10000:10000 /qemu
USER ${USER}
ENV HOME ${HOME}
EOF
)

# If Launch is left empty will create a docker container
if [[ "${launch}" == "" ]]; then

  docker build -t ${imgname} - <<< "${Dockerfile}"
  if [[ "$?" -ne 0 ]]; then
    echo "Failed to build docker container."
    exit 1
  fi
  mountqemu="-v ""${qemudir}"":""${qemudir}"" "
  if [[ "${qemudir}" = "${HOME}/"* || "${qemudir}" = "${HOME}" ]]; then
    mountqemu=""
  fi
  docker run \
      --rm=true \
      -e WORKSPACE=${WORKSPACE} \
      -w "${HOME}" \
      -v "${HOME}":"${HOME}" \
      ${mountqemu} \
      -t ${imgname} \
      ${WORKSPACE}/build.sh
elif [[ "${launch}" == "pod" || "${launch}" == "job" ]]; then
  . ./kubernetes/kubernetes-launch.sh QEMU-build true true
else
  echo "Launch Parameter is invalid"
fi


