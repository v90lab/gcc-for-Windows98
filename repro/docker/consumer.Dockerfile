ARG UBUNTU_IMAGE=ubuntu:22.04
FROM ${UBUNTU_IMAGE} AS base

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /work

COPY ./docker/scripts/*.sh ./

RUN chmod a+x ./*.sh

RUN dpkg --add-architecture i386

RUN ./apt-mirror-selector.sh -y --no-install-recommends \
      bash \
      build-essential \
      cmake \
      make \
      ninja-build \
      python3 \
      python3-pip \
      file \
      binutils \
      git \
      patch \
      xz-utils \
      unzip \
      ca-certificates \
      libisl23 \
      libmpc3 \
      libmpfr6 \
      libgmp10 \
      wine \
      wine32 \
      xvfb \
      xauth && \
    rm -rf /var/lib/apt/lists/*

FROM base AS extractor

WORKDIR /work

# Copy and extract all three toolchain packages. Native + extras ship as
# .zip so Win98 SE / 7zip 9.20 can extract them in one pass; the cross
# toolchain stays as .tar.xz since it's only consumed here in Linux. The
# extras archive is optional — the build pipeline may skip it via
# BUILD_EXTRAS=0. We accept an empty placeholder via a COPY trick: copying
# a glob that matches zero files is an error, so we always copy the
# package directory and pick the extras archive at install time only if
# it exists.
COPY ./out/package/gcc-win98-cross-toolchain.tar.xz /tmp/gcc-win98-cross-toolchain.tar.xz
COPY ./out/package/gcc-win98-native-toolchain.zip /tmp/gcc-win98-native-toolchain.zip
COPY ./out/package/ /tmp/package/

RUN mkdir -p /opt/cross-toolset /opt/native-toolset /opt/extras && \
    ./install-toolchain-artifact.sh /tmp/gcc-win98-cross-toolchain.tar.xz /opt/cross-toolset && \
    ./install-toolchain-artifact.sh /tmp/gcc-win98-native-toolchain.zip /opt/native-toolset && \
    if [ -f /tmp/package/gcc-win98-native-toolchain-extras.zip ]; then \
        ./install-toolchain-artifact.sh /tmp/package/gcc-win98-native-toolchain-extras.zip /opt/extras; \
    else \
        echo "[*] extras archive not present; /opt/extras will be empty"; \
    fi && \
    rm -rf /tmp/*.tar.xz /tmp/*.zip /tmp/package && \
    mkdir -p /opt/cmake-toolchain && \
    mkdir -p /opt/.wine

FROM base AS final

COPY --from=extractor /opt /opt

# Set up environment
ENV TARGET=i686-w64-mingw32
ENV CROSS_PREFIX=/opt/cross-toolset
ENV NATIVE_PREFIX=/opt/native-toolset
ENV EXTRAS_PREFIX=/opt/extras
ENV WINEPREFIX=/opt/.wine
ENV PATH="${CROSS_PREFIX}/bin:${NATIVE_PREFIX}/bin:${EXTRAS_PREFIX}/bin:${PATH}"

COPY ./docker/cmake/cross-toolchain.cmake /opt/cmake-toolchain/cross-toolchain.cmake
COPY ./docker/cmake/native-toolchain.cmake /opt/cmake-toolchain/native-toolchain.cmake
COPY ./docker/cmake/*.sh /opt/cmake-toolchain/

RUN chmod a+x /opt/cmake-toolchain/*.sh

ENV CMAKE_TOOLCHAIN_FILE=/opt/cmake-toolchain/cross-toolchain.cmake

WORKDIR /workspace
