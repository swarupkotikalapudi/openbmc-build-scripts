#!/bin/bash -xe
#
# Purpose:
#  Added by Swarup to test Jenkin testing..
#  This script is responsible for building all platform
#  on master branch.
#
# This script assumes openbmc-build-scripts has been cloned into
# the WORKSPACE directory.
#
# Required Inputs:
#  WORKSPACE:      Directory to run the builds out of

export LANG=en_US.UTF8

cd "${WORKSPACE}"
if [ -d openbmc ]; then
    git -C openbmc fetch
    git -C openbmc rebase
else
    git clone https://github.com/openbmc/openbmc.git
fi

# Ensure everything is built on same filesystem
export build_dir="${WORKSPACE}/build"

PLATFORM_MACHINES=(
    romed8hm3,
    romulus,
    zaius,
    e3c246d4i,
    gbs,
    p10bmc,
    yosemite4,
    bletchley,
    witherspoon,
    ahe50dc,
    palmetto
)

for m in "${PLATFORM_MACHINES[@]}"; do
    echo "Building $m"
    export target=$m
    "${WORKSPACE}/openbmc-build-scripts/build-setup.sh" || \
        echo "Build failed for $m; continuing."
    rm -rf "${WORKSPACE}/openbmc/build"
    rm -rf "${build_dir}"
done