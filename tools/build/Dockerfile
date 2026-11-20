# Build environment for the kernel modules and the camera userland.
# The modules in this repository were built with Debian 12's gcc 12.2.0 cross compiler (gcc-12-arm-linux-gnueabi
# 12.2.0-14cross1). A newer Debian point release may carry a different compiler build and then produce different
# (but equivalent) binaries; tools/build.sh reports whether the hashes match the shipped ones.
FROM debian:12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      gcc gcc-arm-linux-gnueabi libc6-dev-armel-cross make bc bison flex libssl-dev libelf-dev \
      git curl ca-certificates python3 squashfs-tools \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /repo
