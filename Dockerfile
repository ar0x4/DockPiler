FROM ubuntu:24.04

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        wget \
        apt-transport-https \
        software-properties-common \
        ca-certificates \
        cmake \
        make \
        mingw-w64 \
        unzip && \
    wget https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb && \
    dpkg -i packages-microsoft-prod.deb && \
    rm packages-microsoft-prod.deb && \
    apt-get update && \
    apt-get install -y dotnet-sdk-8.0 && \
    mkdir -p /reference-assemblies && \
    cd /reference-assemblies && \
    wget https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net40/1.0.3 -O net40.nupkg && \
    unzip net40.nupkg -d net40 && \
    rm net40.nupkg && \
    wget https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net472/1.0.3 -O net472.nupkg && \
    unzip net472.nupkg -d net472 && \
    rm net472.nupkg && \
    wget https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net48/1.0.3 -O net48.nupkg && \
    unzip net48.nupkg -d net48 && \
    rm net48.nupkg && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN echo '#!/bin/bash\n\
set -e\n\
\n\
URL="$1"\n\
ARCH="${2:-x64}"\n\
if [ "$ARCH" != "x64" ] && [ "$ARCH" != "x86" ]; then\n\
  echo "Error: Invalid architecture. Use x64 or x86."\n\
  exit 1\n\
fi\n\
if [ "$ARCH" = "x86" ]; then\n\
  PLATFORM="x86"\n\
  TOOLCHAIN_PREFIX="i686-w64-mingw32"\n\
else\n\
  PLATFORM="x64"\n\
  TOOLCHAIN_PREFIX="x86_64-w64-mingw32"\n\
fi\n\
OUTPUT_DIR="/output"\n\
REPO_DIR="/repo"\n\
REPO_NAME=$(basename "$URL" .git)\n\
\n\
if [ -z "$URL" ]; then\n\
  echo "Error: No GitHub URL provided. Usage: docker run -v /path/to/output:/output image_name <github_url> [x64|x86]"\n\
  exit 1\n\
fi\n\
\n\
# Clone the repository\n\
git clone "$URL" "$REPO_DIR"\n\
cd "$REPO_DIR"\n\
\n\
# Detect and build recursively\n\
CSPROJS=$(find . -type f -name "*.csproj")\n\
if [ -n "$CSPROJS" ]; then\n\
  echo "Detected C# project(s). Building for Windows $ARCH..."\n\
  for proj in $CSPROJS; do\n\
    proj_dir=$(dirname "$proj")\n\
    proj_name=$(basename "$proj_dir")\n\
    cd "$proj_dir"\n\
    proj_file=$(basename "$proj")\n\
    if grep -qi "<TargetFrameworkVersion>v" "$proj_file"; then\n\
      echo "Building .NET Framework project with dotnet build..."\n\
      mkdir -p "$OUTPUT_DIR/$proj_name"\n\
      tfv=$(grep -i "<TargetFrameworkVersion>" "$proj_file" | sed -E "s/.*>(v[0-9.]+)<.*/\\1/")\n\
      case "$tfv" in\n\
        v4.0) net_dir="net40" ;;\n\
        v4.7.2) net_dir="net472" ;;\n\
        v4.8) net_dir="net48" ;;\n\
        *) echo "Unsupported .NET Framework version: $tfv. Add reference assemblies for this version." ; exit 1 ;;\n\
      esac\n\
      ref_path="/reference-assemblies/$net_dir/build/.NETFramework/$tfv"\n\
      dotnet restore "$proj_file"\n\
      dotnet build "$proj_file" -c Release -p:Platform=$PLATFORM -p:PlatformTarget=$ARCH -p:OutputPath="$OUTPUT_DIR/$proj_name" -p:FrameworkPathOverride="$ref_path" -p:AllowUnsafeBlocks=true -p:DisableOutOfProcTaskHost=true\n\
    else\n\
      echo "Building .NET project with dotnet publish..."\n\
      mkdir -p "$OUTPUT_DIR/$proj_name"\n\
      dotnet publish "$proj_file" -c Release -r win-$ARCH --self-contained true -p:PublishSingleFile=true -o "$OUTPUT_DIR/$proj_name" -p:AllowUnsafeBlocks=true\n\
    fi\n\
    cd - >/dev/null\n\
  done\n\
elif VCXPROJS=$(find . -type f -name "*.vcxproj"); [ -n "$VCXPROJS" ]; then\n\
  echo "Detected Visual Studio C++ project(s). Cross-compiling for Windows $ARCH..."\n\
  for vcx in $VCXPROJS; do\n\
    proj_dir=$(dirname "$vcx")\n\
    proj_name=$(basename "$proj_dir")\n\
    if [ -z "$proj_name" ]; then proj_name="$REPO_NAME"; fi\n\
    cd "$proj_dir"\n\
    # Patch common case-sensitive includes\n\
    sed -i '\''s/#include "Windows.h"/#include <windows.h>/g'\'' *.cpp *.h 2>/dev/null || true\n\
    sed -i '\''s/#include "windows.h"/#include <windows.h>/g'\'' *.cpp *.h 2>/dev/null || true\n\
    mkdir -p "$OUTPUT_DIR/$proj_name"\n\
    $TOOLCHAIN_PREFIX-g++ $(find . -name "*.cpp") -o "$OUTPUT_DIR/$proj_name/$proj_name.exe" -lws2_32 -lsecur32 -DSECURITY_WIN32 -D_UNICODE -DUNICODE -std=c++11 -Wno-deprecated-declarations\n\
    cd - >/dev/null\n\
  done\n\
elif CMAKE=$(find . -type f -name "CMakeLists.txt"); [ -n "$CMAKE" ]; then\n\
  echo "Detected CMake project(s). Cross-compiling for Windows $ARCH..."\n\
  cat <<EOF > /toolchain-mingw.cmake\n\
set(CMAKE_SYSTEM_NAME Windows)\n\
set(TOOLCHAIN_PREFIX $TOOLCHAIN_PREFIX)\n\
set(CMAKE_C_COMPILER \${TOOLCHAIN_PREFIX}-gcc)\n\
set(CMAKE_CXX_COMPILER \${TOOLCHAIN_PREFIX}-g++)\n\
set(CMAKE_RC_COMPILER \${TOOLCHAIN_PREFIX}-windres)\n\
set(CMAKE_FIND_ROOT_PATH /usr/\${TOOLCHAIN_PREFIX} /usr/lib/gcc/\${TOOLCHAIN_PREFIX})\n\
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)\n\
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)\n\
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)\n\
EOF\n\
  for cmakelists in $CMAKE; do\n\
    proj_dir=$(dirname "$cmakelists")\n\
    proj_name=$(basename "$proj_dir")\n\
    mkdir -p "$proj_dir/build"\n\
    cd "$proj_dir/build"\n\
    cmake .. -DCMAKE_TOOLCHAIN_FILE=/toolchain-mingw.cmake\n\
    make\n\
    mkdir -p "$OUTPUT_DIR/$proj_name"\n\
    find . -name "*.exe" -exec cp {} "$OUTPUT_DIR/$proj_name/" \\;\n\
    cd - >/dev/null\n\
  done\n\
elif MAKEFILES=$(find . -type f -name "Makefile"); [ -n "$MAKEFILES" ]; then\n\
  echo "Detected Makefile project(s). Cross-compiling for Windows $ARCH..."\n\
  for makefile in $MAKEFILES; do\n\
    proj_dir=$(dirname "$makefile")\n\
    proj_name=$(basename "$proj_dir")\n\
    cd "$proj_dir"\n\
    make CC=$TOOLCHAIN_PREFIX-gcc CXX=$TOOLCHAIN_PREFIX-g++\n\
    mkdir -p "$OUTPUT_DIR/$proj_name"\n\
    find . -name "*.exe" -exec cp {} "$OUTPUT_DIR/$proj_name/" \\;\n\
    cd - >/dev/null\n\
  done\n\
else\n\
  echo "No build system detected. Attempting simple C/C++ compilation recursively for Windows $ARCH..."\n\
  COMPILED=false\n\
  while IFS= read -r file; do\n\
    if [[ "$file" == *.c ]]; then\n\
      base=$(basename "$file" .c)\n\
      $TOOLCHAIN_PREFIX-gcc "$file" -o "$OUTPUT_DIR/$base.exe"\n\
      COMPILED=true\n\
    elif [[ "$file" == *.cpp ]]; then\n\
      base=$(basename "$file" .cpp)\n\
      $TOOLCHAIN_PREFIX-g++ "$file" -o "$OUTPUT_DIR/$base.exe"\n\
      COMPILED=true\n\
    fi\n\
  done < <(find . -type f \\( -name "*.c" -o -name "*.cpp" \\) -not -path "*/build/*" -not -path "*/bin/*" -not -path "*/.git/*" )\n\
  if [ "$COMPILED" = false ]; then\n\
    echo "Error: No compilable files or build system found."\n\
    exit 1\n\
  fi\n\
fi\n\
\n\
echo "Build complete. Binaries are in $OUTPUT_DIR"' > /entrypoint.sh && \
    chmod +x /entrypoint.sh

# Set entrypoint
ENTRYPOINT ["/entrypoint.sh"]