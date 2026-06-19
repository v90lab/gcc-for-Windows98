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

WORKDIR /work

CMD ["bash"]
