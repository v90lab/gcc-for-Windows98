ARG UBUNTU_IMAGE=ubuntu:22.04
FROM ${UBUNTU_IMAGE} AS builder

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /work

COPY ./docker/scripts/apt-mirror-selector.sh ./apt-mirror-selector.sh

RUN chmod a+x ./apt-mirror-selector.sh

RUN dpkg --add-architecture i386

RUN ./apt-mirror-selector.sh -y --no-install-recommends \
      autoconf \
      automake \
      autopoint \
      bash \
      build-essential \
      bison \
      ca-certificates \
      ccache \
      cmake \
      curl \
      file \
      flex \
      g++ \
      gawk \
      git \
      gperf \
      help2man \
      libgmp-dev \
      libisl-dev \
      libmpc-dev \
      libmpfr-dev \
      libtool \
      binutils-mingw-w64-i686 \
      gcc-mingw-w64-i686-win32 \
      g++-mingw-w64-i686-win32 \
      m4 \
      make \
      ninja-build \
      patch \
      perl \
      pkg-config \
      python3 \
      python3-pip \
      texinfo \
      jq \
      wine \
      wine32 \
      zip \
      unzip \
      wget \
      xz-utils && \
    rm -rf /var/lib/apt/lists/*

# Ubuntu 22.04's apt-meson is 0.61.x (April 2022). muon's meson.build uses
# dict-form project() default_options which requires meson >= 1.1 (April 2023).
# Pip-install on top of the system Python — lands at /usr/local/bin/meson
# which precedes /usr/bin/meson on PATH.
RUN pip3 install --no-cache-dir meson

# ccache integration:
#   * Ubuntu's `ccache` package ships /usr/lib/ccache/{gcc,g++,cc,c++} symlinks
#     that wrap host gcc/g++ — putting /usr/lib/ccache in PATH (below) lets
#     build-cross-*.sh transparently pick up ccache when compiling the
#     cross-toolchain itself.
#   * For build-native-*.sh / extras, every script does
#       `export PATH="$CROSS_BIN_DIR:$PATH"`
#     which puts /work/out/toolchain/bin (the real cross gcc) ahead of any
#     ccache shim dir we'd add to PATH. So PATH-shim alone won't catch the
#     native-build calls — common.sh sets CC/CXX to "ccache <cross-gcc>"
#     directly when sourced from a build-native-*.sh.
#   * Cache dir is the external `gcc-win98-ccache` docker volume (declared
#     in docker-compose.yml). External lifecycle so `clean-rebuild.sh`'s
#     `docker compose down -v` leaves it intact; nuke at will with
#     `docker volume rm gcc-win98-ccache` or `ccache -C` inside the container.
ENV PATH="/usr/lib/ccache:${PATH}"
ENV CCACHE_DIR=/root/.ccache
ENV CCACHE_MAXSIZE=10G
ENV CCACHE_COMPRESS=1

WORKDIR /work

CMD ["bash"]
