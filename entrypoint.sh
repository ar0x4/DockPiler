#!/bin/bash

# Check for required environment variables
if [ -z "$GIT_REPO" ]; then
    echo "Error: GIT_REPO environment variable must be set"
    exit 1
fi

# Set default branch if not specified
BRANCH=${GIT_BRANCH:-main}

# Set up Wine environment
export WINEPREFIX=/wine
export WINEARCH=win64

# Path to Windows msbuild.exe in Wine
MSBUILD_PATH="/wine/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/msbuild.exe"

# Clone the repository
echo "Cloning repository $GIT_REPO (branch: $BRANCH)"
git clone --branch "$BRANCH" --depth 1 "$GIT_REPO" /build/source
cd /build/source || exit 1

# Restore NuGet packages using Windows msbuild.exe via Wine
echo "Restoring NuGet packages..."
find . -name "*.sln" -exec wine "$MSBUILD_PATH" -t:Restore {} \;

# Build .NET projects using Windows msbuild.exe via Wine
echo "Building .NET projects..."
find . -name "*.sln" -exec wine "$MSBUILD_PATH" /p:Configuration=Release /p:Platform="Any CPU" /p:OutputPath=/output {} \;

# Build C projects (32-bit Windows)
echo "Building C projects..."
find . -name "*.c" -exec i686-w64-mingw32-gcc -static -o /output/{}.exe {} \;

# Build C++ projects (32-bit Windows)
echo "Building C++ projects..."
find . -name "*.cpp" -exec i686-w64-mingw32-g++ -static -o /output/{}.exe {} \;

# Display build output
echo "Build completed. Output files:"
ls -lh /output