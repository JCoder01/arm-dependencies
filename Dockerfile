###########################################################
# base image, used for build stages and final images
FROM phusion/baseimage:resolute-1.0.16 AS base
RUN mkdir /opt/arm
WORKDIR /opt/arm

# start by updating and upgrading the OS
RUN \
    apt clean && \
    apt update && \
    apt upgrade -y -o Dpkg::Options::="--force-confold"
# newer Ubuntu base images ship a default "ubuntu" user/group at 1000; remove it
# so we can use that id for our own arm user/group instead, same as before
RUN userdel -r ubuntu 2>/dev/null || true

# create an arm group(gid 1000) and an arm user(uid 1000), with password logon disabled
RUN groupadd -g 1000 arm \
    && useradd -rm -d /home/arm -s /bin/bash -g arm -G video,cdrom -u 1000 arm

# enable support for Arch Linux and derivatives, who use a different user group for optical drive permissions
RUN groupadd -g 990 optical \
    && usermod -aG optical arm

# Enable support for Fedora derivatives, which uses GID 11 for the cdrom group for optical drive permissions, whereas Ubuntu uses GID 24 for the same group name.
RUN groupadd -g 11 cdrom_Fedora \
   && usermod -aG cdrom_Fedora arm


# set the default environment variables
# UID and GID are not settable as of https://github.com/phusion/baseimage-docker/pull/86, as doing so would
# break multi-account containers
ENV ARM_UID=1000
ENV ARM_GID=1000

# setup gnupg/wget for add-ppa.sh
RUN install_clean \
        git \
        wget \
        build-essential \
        libcurl4-openssl-dev \
        libssl-dev \
        gnupg \
        libudev-dev \
        udev \
        python3 \
        python3-dev \
        python3-pip \
        nano \
        vim \
        # arm extra requirements
        scons swig libzbar-dev libzbar0

###########################################################
# install deps specific to the docker deployment
FROM base AS deps-docker
RUN install_clean gosu


###########################################################
# install deps for ripper
FROM deps-docker AS deps-ripper
RUN install_clean \
        abcde \
        eyed3 \
        atomicparsley \
        cdparanoia \
        eject \
        ffmpeg \
        flac \
        glyrc \
        default-jre-headless \
        id3 \
        id3v2 \
        lame \
        libavcodec-extra \
        lsdvd \
        mkcue \
        vorbis-tools \
        opus-tools \
        fdkaac

# install libdvd-pkg
RUN \
    install_clean libdvd-pkg && \
    dpkg-reconfigure libdvd-pkg

# install python reqs
COPY requirements.txt ./requirements.txt
RUN pip3 install --break-system-packages --ignore-installed --upgrade pip wheel setuptools psutil pyudev
RUN pip3 install --break-system-packages --ignore-installed --prefer-binary -r ./requirements.txt

###########################################################
# install makemkv and handbrake
FROM deps-ripper AS install-makemkv-handbrake

# Intel QuickSync (QSV) support: Ubuntu's own libva-dev is too old for FFmpeg's
# QSV code, which gates VAAPI device-info support behind a *compile-time*
# `#if VA_CHECK_VERSION(1, 15, 0)` check - so HandBrake must be built against a
# newer libva-dev than the distro ships, or QSV silently no-ops at runtime.
# Pull both the runtime driver and dev headers from Intel's own repo instead
# (noble is the newest Ubuntu release Intel currently publishes for; these
# userspace libs are compatible with newer bases):
# https://dgpu-docs.intel.com/driver/client/overview.html
RUN apt-get update && \
    apt-get install -y --no-install-recommends gnupg wget ca-certificates && \
    wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
        gpg --dearmor --output /usr/share/keyrings/intel-graphics.gpg && \
    echo "deb [arch=amd64,i386 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu noble client" \
        > /etc/apt/sources.list.d/intel-gpu.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        intel-media-va-driver-non-free \
        libmfx-gen1 \
        libvpl2 \
        libva2 \
        libva-dev \
        libva-drm2 \
        vainfo \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# HandBrake's statically-linked oneVPL dispatcher only reports QSV as
# available if the legacy MSDK-compat runtime (libmfx1) is present too -
# libmfx-gen1 alone isn't enough, confirmed by testing on real Intel hardware.
# libmfx1 has no successor package in Intel's newer (noble) repo at all, so
# pull it from their older jammy repo instead - it's still published there.
RUN echo "deb [arch=amd64,i386 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu jammy client" \
        > /etc/apt/sources.list.d/intel-gpu-jammy.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends libmfx1 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# The arm user is already in the video group; render is also needed for
# /dev/dri/renderD128 access.
RUN groupadd -f render && usermod -aG video,render arm

COPY ./scripts/install_mkv_hb_deps.sh /install_mkv_hb_deps.sh
RUN chmod +x /install_mkv_hb_deps.sh && sleep 1 && \
    /install_mkv_hb_deps.sh

COPY ./scripts/install_handbrake.sh /install_handbrake.sh
RUN chmod +x /install_handbrake.sh && sleep 1 && \
    /install_handbrake.sh

# MakeMKV setup by https://github.com/tianon
COPY ./scripts/install_makemkv.sh /install_makemkv.sh
RUN chmod +x /install_makemkv.sh && sleep 1 && \
    /install_makemkv.sh

# clean up apt
RUN apt clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Container healthcheck
COPY scripts/healthcheck.sh /healthcheck.sh
RUN chmod +x /healthcheck.sh
HEALTHCHECK --interval=5m --timeout=15s --start-period=30s CMD /healthcheck.sh

# Set Timezone data
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC
RUN install_clean tzdata && \
    ln -sf /usr/share/zoneinfo/$TZ /etc/localtime && \
    dpkg-reconfigure --frontend noninteractive tzdata

ARG VERSION
ARG BUILD_DATE
# set metadata
LABEL org.opencontainers.image.source=https://github.com/automatic-ripping-machine/arm-dependencies.git
LABEL org.opencontainers.image.url=https://github.com/automatic-ripping-machine/arm-dependencies
LABEL org.opencontainers.image.description="Dependencies for Automatic Ripping Machine"
LABEL org.opencontainers.image.documentation=https://raw.githubusercontent.com/automatic-ripping-machine/arm-dependencies/main/README.md
LABEL org.opencontainers.image.license=MIT
LABEL org.opencontainers.image.version=$VERSION
LABEL org.opencontainers.image.created=$BUILD_DATE
