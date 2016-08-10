#!/bin/bash -xe

# This script is for starting QEMU against the input build and running
#  the robot CI test suite against it.
#
#  Parameters:
#   UPSTREAM_WORKSPACE = <required, base dir of QEMU image>
#   WORKSPACE =          <optional, temp dir for robot script>

set -uo pipefail

QEMU_RUN_TIMER=300
WORKSPACE=${WORKSPACE:-${HOME}/${RANDOM}${RANDOM}}
DOCKER_IMG_NAME="openbmc/ubuntu-robot-qemu"
ROBOT_CODE_HOME=/tmp/obmc-test

# Get base directory of our repo so we can find the scripts later
DIR="${BASH_SOURCE%/*}"
if [[ ! -d "$DIR" || "$DIR" == "." ]]; then DIR="$PWD"; fi

cd ${UPSTREAM_WORKSPACE}

# Determine our architecture, ppc64le or the other one
if [ $(uname -m) == "ppc64le" ]; then
    DOCKER_BASE="ppc64le/"
    QEMU_ARCH="ppc64le-linux"
else
    DOCKER_BASE=""
    QEMU_ARCH="x86_64-linux"
fi

# Create the docker image that QEMU and Robot will run in
. "$DIR/scripts/build-qemu-robot-docker.sh" "$DOCKER_IMG_NAME"

# Copy the scripts to start and verify QEMU in the workspace
cp $DIR/scripts/boot-qemu* ${UPSTREAM_WORKSPACE}

# Start QEMU docker instance
# root in docker required to open up the https/ssh ports
obmc_qemu_docker=$(docker run --detach \
                              --user root \
                              --env HOME=${HOME} \
                              --env QEMU_RUN_TIMER=${QEMU_RUN_TIMER} \
                              --env QEMU_ARCH=${QEMU_ARCH} \
                              --workdir "${HOME}"           \
                              --volume "${UPSTREAM_WORKSPACE}":"${HOME}" \
                              --tty \
                              ${DOCKER_IMG_NAME} ${HOME}/boot-qemu-test.sh)

# We can use default ports because we're going to have the 2
# docker instances talk over their private network
DOCKER_SSH_PORT=22
DOCKER_HTTPS_PORT=443
DOCKER_QEMU_IP_ADDR="$(docker inspect $obmc_qemu_docker |  \
                      grep -m 1 "IPAddress\":" | cut -d '"' -f 4)"

# Now wait for the openbmc qemu docker instance to get to standby
attempt=60
while [ $attempt -gt 0 ]; do
    attempt=$(( $attempt - 1 ))
    echo "Waiting for qemu to get to standby (attempt: $attempt)..."
    result=$(docker logs $obmc_qemu_docker)
    if grep -q 'OPENBMC-READY' <<< $result ; then
        echo "QEMU is ready!"
        # Give QEMU a few secs to stablize
        sleep 5
        break
    fi
    sleep 2
done

if [ "$attempt" -eq 0 ]; then
    echo "Timed out waiting for QEMU, exiting"
    exit 1
fi

# Now run the robot test

# Timestamp for job
echo "Robot Test started, $(date)"

DOCKER_ROBOT_SCRIPT=robot.sh

mkdir -p ${WORKSPACE}
cd ${WORKSPACE}

################################ robot.sh ######################################
# Create script to run within the docker image #
cat > "${DOCKER_ROBOT_SCRIPT}" << EOF_SCRIPT
#!/bin/bash

# we don't want to fail on bad rc since robot tests may fail

git clone https://github.com/openbmc/openbmc-test-automation.git \
    ${ROBOT_CODE_HOME}

cd ${ROBOT_CODE_HOME}

chmod ugo+rw -R ${ROBOT_CODE_HOME}/*

# Execute the CI tests
export OPENBMC_HOST=${DOCKER_QEMU_IP_ADDR}
export SSH_PORT=${DOCKER_SSH_PORT}
export HTTPS_PORT=${DOCKER_HTTPS_PORT}

tox -e qemu -- --include CI tests

cp ${ROBOT_CODE_HOME}/*.xml ${HOME}/
cp ${ROBOT_CODE_HOME}/*.html ${HOME}/

EOF_SCRIPT

################################ robot.sh ######################################
chmod a+x ${DOCKER_ROBOT_SCRIPT}

# Run the docker container to execute the robot test cases
docker run --user root \
           --workdir ${HOME} \
           --volume ${WORKSPACE}:${HOME} \
           --tty \
           ${DOCKER_IMG_NAME} ${HOME}/${DOCKER_ROBOT_SCRIPT}

# Now stop the QEMU docker image
docker stop $obmc_qemu_docker
