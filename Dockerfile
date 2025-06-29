FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    WINEPREFIX=/wine \
    WINEARCH=win64 \
    WINEDLLOVERRIDES="mscoree,mshtml=" \
    DISPLAY=:0

# Install base dependencies
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    ca-certificates \
    gnupg2 \
    software-properties-common \
    wget \
    git \
    unzip \
    xvfb \
    && rm -rf /var/lib/apt/lists/*

# Add Mono repository
RUN apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF && \
    apt-add-repository 'deb https://download.mono-project.com/repo/ubuntu stable-focal main' && \
    apt-get update

# Install Mono and .NET SDK separately
RUN apt-get install -y --no-install-recommends \
    mono-complete \
    nuget \
    && rm -rf /var/lib/apt/lists/*
    
# Install .NET 7.0 SDK
RUN wget https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb && \
    dpkg -i packages-microsoft-prod.deb && \
    rm packages-microsoft-prod.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    dotnet-sdk-7.0 \
    && rm -rf /var/lib/apt/lists/*

# Install build tools and Wine dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    libgl1 \
    libx11-dev \
    gcc-mingw-w64-x86-64 \
    g++-mingw-w64-x86-64 \
    binutils-mingw-w64-x86-64 \
    && rm -rf /var/lib/apt/lists/*

# Install Wine 8.0 with proper dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    lsb-release \
    cabextract \
    winbind \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/apt/keyrings && \
    wget -nc -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key && \
    echo "deb [signed-by=/etc/apt/keyrings/winehq-archive.key] https://dl.winehq.org/wine-builds/ubuntu/ jammy main" > /etc/apt/sources.list.d/winehq-jammy.list && \
    apt-get update && \
    apt-get install -y --install-recommends winehq-stable && \
    rm -rf /var/lib/apt/lists/*

# Configure Wine with Xvfb and install requirements
# Configure Wine with Xvfb and install requirements
RUN Xvfb :0 -screen 0 1024x768x24 >/dev/null 2>&1 & \
    sleep 5 && \
    wine wineboot --init && \
    wget https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks && \
    chmod +x winetricks && \
    mv winetricks /usr/local/bin && \
    winetricks --unattended dotnet35sp1 && \
    winetricks --unattended vcrun2019 && \
    winetricks --unattended --force dotnet48 && \
    wineserver -w

# Create build environment
RUN mkdir /build /output
WORKDIR /build

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
