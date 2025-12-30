# =============================================================================
# DockPiler - Windows Cross-Compilation Docker Image
# =============================================================================
#
# A Docker image for cross-compiling Windows executables from GitHub repositories.
# Supports C#, C++, and C projects with various build systems.
#
# Build Options:
#   docker build -t dockpiler .                                    # Minimal (MinGW only)
#   docker build -t dockpiler --build-arg INCLUDE_VCPKG=true .     # With vcpkg
#   docker build -t dockpiler --build-arg INCLUDE_MSVC=true .      # With MSVC via Wine
#   docker build -t dockpiler --build-arg INCLUDE_VCPKG=true --build-arg INCLUDE_MSVC=true .  # Full
#
# Usage:
#   docker run -v $(pwd)/output:/output dockpiler <github_url> [arch] [config] [git_ref] [extra_flags]
#
# =============================================================================

FROM ubuntu:24.04 AS base

# Build arguments for optional features
ARG INCLUDE_VCPKG=false
ARG INCLUDE_MSVC=false

# Environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
ENV DOTNET_NOLOGO=1

# =============================================================================
# Stage 1: Base packages and MinGW toolchain
# =============================================================================

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Build essentials
    build-essential \
    cmake \
    make \
    ninja-build \
    # MinGW-w64 cross-compilers (both 64-bit and 32-bit)
    gcc-mingw-w64-x86-64 \
    g++-mingw-w64-x86-64 \
    gcc-mingw-w64-i686 \
    g++-mingw-w64-i686 \
    mingw-w64-tools \
    # Version control
    git \
    # Utilities
    wget \
    curl \
    unzip \
    zip \
    ca-certificates \
    apt-transport-https \
    software-properties-common \
    # Python for build scripts
    python3 \
    python3-pip \
    # Text processing
    dos2unix \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Stage 2: .NET SDK and Framework Reference Assemblies
# =============================================================================

# Install .NET SDK 8.0
RUN wget https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb && \
    dpkg -i packages-microsoft-prod.deb && \
    rm packages-microsoft-prod.deb && \
    apt-get update && \
    apt-get install -y dotnet-sdk-8.0 && \
    rm -rf /var/lib/apt/lists/*

# Download all .NET Framework reference assemblies (4.0 through 4.8.1)
RUN mkdir -p /reference-assemblies && cd /reference-assemblies && \
    # .NET Framework 4.0
    wget -q https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net40/1.0.3 -O net40.nupkg && \
    unzip -q net40.nupkg -d net40 && rm net40.nupkg && \
    # .NET Framework 4.5
    wget -q https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net45/1.0.3 -O net45.nupkg && \
    unzip -q net45.nupkg -d net45 && rm net45.nupkg && \
    # .NET Framework 4.5.1
    wget -q https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net451/1.0.3 -O net451.nupkg && \
    unzip -q net451.nupkg -d net451 && rm net451.nupkg && \
    # .NET Framework 4.5.2
    wget -q https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net452/1.0.3 -O net452.nupkg && \
    unzip -q net452.nupkg -d net452 && rm net452.nupkg && \
    # .NET Framework 4.6
    wget -q https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net46/1.0.3 -O net46.nupkg && \
    unzip -q net46.nupkg -d net46 && rm net46.nupkg && \
    # .NET Framework 4.6.1
    wget -q https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net461/1.0.3 -O net461.nupkg && \
    unzip -q net461.nupkg -d net461 && rm net461.nupkg && \
    # .NET Framework 4.6.2
    wget -q https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net462/1.0.3 -O net462.nupkg && \
    unzip -q net462.nupkg -d net462 && rm net462.nupkg && \
    # .NET Framework 4.7
    wget -q https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net47/1.0.3 -O net47.nupkg && \
    unzip -q net47.nupkg -d net47 && rm net47.nupkg && \
    # .NET Framework 4.7.1
    wget -q https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net471/1.0.3 -O net471.nupkg && \
    unzip -q net471.nupkg -d net471 && rm net471.nupkg && \
    # .NET Framework 4.7.2
    wget -q https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net472/1.0.3 -O net472.nupkg && \
    unzip -q net472.nupkg -d net472 && rm net472.nupkg && \
    # .NET Framework 4.8
    wget -q https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net48/1.0.3 -O net48.nupkg && \
    unzip -q net48.nupkg -d net48 && rm net48.nupkg && \
    # .NET Framework 4.8.1
    wget -q https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net481/1.0.3 -O net481.nupkg && \
    unzip -q net481.nupkg -d net481 && rm net481.nupkg && \
    echo "All .NET Framework reference assemblies installed"

# =============================================================================
# Stage 3: Optional vcpkg installation
# =============================================================================

RUN if [ "$INCLUDE_VCPKG" = "true" ]; then \
        echo "Installing vcpkg..." && \
        git clone https://github.com/microsoft/vcpkg.git /opt/vcpkg && \
        /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics && \
        # Create MinGW triplets for cross-compilation
        echo 'set(VCPKG_TARGET_ARCHITECTURE x64)' > /opt/vcpkg/triplets/community/x64-mingw-static.cmake && \
        echo 'set(VCPKG_CRT_LINKAGE static)' >> /opt/vcpkg/triplets/community/x64-mingw-static.cmake && \
        echo 'set(VCPKG_LIBRARY_LINKAGE static)' >> /opt/vcpkg/triplets/community/x64-mingw-static.cmake && \
        echo 'set(VCPKG_CMAKE_SYSTEM_NAME MinGW)' >> /opt/vcpkg/triplets/community/x64-mingw-static.cmake && \
        echo 'set(VCPKG_TARGET_ARCHITECTURE x86)' > /opt/vcpkg/triplets/community/x86-mingw-static.cmake && \
        echo 'set(VCPKG_CRT_LINKAGE static)' >> /opt/vcpkg/triplets/community/x86-mingw-static.cmake && \
        echo 'set(VCPKG_LIBRARY_LINKAGE static)' >> /opt/vcpkg/triplets/community/x86-mingw-static.cmake && \
        echo 'set(VCPKG_CMAKE_SYSTEM_NAME MinGW)' >> /opt/vcpkg/triplets/community/x86-mingw-static.cmake && \
        ln -s /opt/vcpkg/vcpkg /usr/local/bin/vcpkg && \
        echo "vcpkg installed successfully"; \
    else \
        echo "Skipping vcpkg installation"; \
    fi

# =============================================================================
# Stage 4: Optional MSVC via Wine installation
# =============================================================================
# NOTE: MSVC via Wine requires x86_64 architecture. It will not work on ARM.

RUN if [ "$INCLUDE_MSVC" = "true" ]; then \
        ARCH=$(uname -m) && \
        if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then \
            echo ""; \
            echo "============================================================"; \
            echo "  WARNING: MSVC installation skipped (ARM architecture)"; \
            echo "============================================================"; \
            echo ""; \
            echo "  MSVC via Wine requires x86_64 architecture."; \
            echo "  Your system: $ARCH"; \
            echo ""; \
            echo "  To use MSVC, build on an x86_64 machine (Intel/AMD)."; \
            echo "  MinGW cross-compilation will still work on ARM."; \
            echo ""; \
            echo "============================================================"; \
            echo ""; \
        else \
            echo "Installing Wine and MSVC on $ARCH..." && \
            dpkg --add-architecture i386 && \
            mkdir -pm755 /etc/apt/keyrings && \
            wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key && \
            wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources && \
            apt-get update && \
            apt-get install -y --install-recommends winehq-stable && \
            apt-get install -y msitools python3-simplejson python3-six cabextract && \
            git clone https://github.com/mstorsjo/msvc-wine.git /opt/msvc-wine && \
            cd /opt/msvc-wine && \
            PYTHONDONTWRITEBYTECODE=1 python3 ./vsdownload.py --dest /opt/msvc --accept-license && \
            ./install.sh /opt/msvc && \
            echo '#!/bin/bash' > /usr/local/bin/msvc-cl && \
            echo 'wine /opt/msvc/bin/x64/cl.exe "$@"' >> /usr/local/bin/msvc-cl && \
            chmod +x /usr/local/bin/msvc-cl && \
            echo '#!/bin/bash' > /usr/local/bin/msvc-link && \
            echo 'wine /opt/msvc/bin/x64/link.exe "$@"' >> /usr/local/bin/msvc-link && \
            chmod +x /usr/local/bin/msvc-link && \
            rm -rf /var/lib/apt/lists/* && \
            echo "MSVC installed successfully"; \
        fi; \
    else \
        echo "Skipping MSVC installation"; \
    fi

# =============================================================================
# Stage 5: Copy scripts and toolchain files
# =============================================================================

# Create directories
RUN mkdir -p /scripts /toolchain /output /repo /build

# Copy Python scripts
COPY scripts/*.py /scripts/

# Copy shell scripts
COPY scripts/*.sh /scripts/
RUN chmod +x /scripts/*.sh

# Copy CMake toolchain files
COPY toolchain/*.cmake /toolchain/

# Set environment for scripts
ENV SCRIPTS_DIR=/scripts
ENV TOOLCHAIN_DIR=/toolchain
ENV PATH="/scripts:${PATH}"

# =============================================================================
# Stage 6: Final configuration
# =============================================================================

# Create output and repo directories
VOLUME ["/output"]
WORKDIR /repo

# Set entrypoint
ENTRYPOINT ["/scripts/entrypoint.sh"]

# Default command (show help)
CMD ["--help"]

# =============================================================================
# Labels
# =============================================================================

LABEL maintainer="DockPiler"
LABEL description="Cross-compile Windows executables from GitHub repositories"
LABEL version="2.0"
