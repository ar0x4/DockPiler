FROM ubuntu:24.04

# Install required packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        wget \
        apt-transport-https \
        software-properties-common \
        ca-certificates \
        cmake \
        make \
        gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 \
        gcc-mingw-w64-i686 g++-mingw-w64-i686 \
        unzip && \
    # Install .NET SDK 8.0
    wget https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb && \
    dpkg -i packages-microsoft-prod.deb && \
    rm packages-microsoft-prod.deb && \
    apt-get update && \
    apt-get install -y dotnet-sdk-8.0 && \
    # Download and extract .NET Framework reference assemblies (only 4.8)
    mkdir -p /reference-assemblies && \
    cd /reference-assemblies && \
    wget https://www.nuget.org/api/v2/package/Microsoft.NETFramework.ReferenceAssemblies.net48/1.0.3 -O net48.nupkg && \
    unzip net48.nupkg -d net48 && \
    rm net48.nupkg && \
    # Clean up
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create entrypoint script
RUN echo '#!/bin/bash\n\
set -e\n\
\n\
URL="$1"\n\
ARCH="${2:-x64}"\n\
EXTRA_FLAGS="${3}"\n\
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
  echo "Error: No GitHub URL provided. Usage: docker run -v /path/to/output:/output image_name <github_url> [x64|x86] [extra_flags]"\n\
  exit 1\n\
fi\n\
\n\
# Clone the repository\n\
git clone "$URL" "$REPO_DIR"\n\
cd "$REPO_DIR"\n\
\n\
find . -type f \( -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" \) -exec sed -i '1s/^\xEF\xBB\xBF//' {} + -exec sed -i 's/\r$//' {} +\n\
\n\
# Create MinGW toolchain file\n\
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
      # Update to v4.8 if lower\n\
      sed -i '\''s/<TargetFrameworkVersion>v[0-9.]*/<TargetFrameworkVersion>v4.8/'\'' "$proj_file"\n\
      ref_path="/reference-assemblies/net48/build/.NETFramework/v4.8"\n\
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
    if [ "$proj_name" = "." ] || [ -z "$proj_name" ]; then proj_name="$REPO_NAME"; fi\n\
    cd "$proj_dir"\n\
    # Lowercase all source and header filenames if not already lowercase\n\
    for file in $(find . -type f \\( -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" \\)); do\n\
      lower=$(basename "$file" | tr '\''A-Z'\'' '\''a-z'\'')\n\
      if [ "$(basename "$file")" != "$lower" ]; then\n\
        mv "$file" "$(dirname "$file")/$lower"\n\
      fi\n\
    done\n\
    # Patch quoted includes: lowercase filename, keep quoted\n\
    sed -i '\''s/#include "\\([^"]*\\.h\\)"/#include "\\L\\1"/g'\'' *.cpp *.c *.h *.hpp 2>/dev/null || true\n\
    sed -i '\''s/#include "\\([^"]*\\.hpp\\)"/#include "\\L\\1"/g'\'' *.cpp *.c *.h *.hpp 2>/dev/null || true\n\
    # Patch angled includes: lowercase filename\n\
    sed -i '\''s/#include <\\([^>]*\\.h\\)>/#include <\\L\\1>/g'\'' *.cpp *.c *.h *.hpp 2>/dev/null || true\n\
    sed -i '\''s/#include <\\([^>]*\\.hpp\\)>/#include <\\L\\1>/g'\'' *.cpp *.c *.h *.hpp 2>/dev/null || true\n\
    # Add C++11 threading includes at the top of all files\n\
    sed -i '\''1i #include <condition_variable>\n#include <mutex>\n#include <thread>'\'' *.cpp *.c *.h *.hpp 2>/dev/null || true\n\
    # Add #define INITGUID for COM GUID definitions to stdafx.h if exists\n\
    if [ -f stdafx.h ]; then\n\
      sed -i '\''1i #define INITGUID'\'' stdafx.h\n\
    fi\n\
    # Generate CMakeLists.txt\n\
    SOURCES=$(find . -type f \\( -name "*.cpp" -o -name "*.c" \\) | tr '\''\n'\'' '\'' '\'') \n\
    echo "cmake_minimum_required(VERSION 3.10)\n\
project($proj_name)\n\
add_executable($proj_name $SOURCES)\n\
target_compile_definitions($proj_name PRIVATE SECURITY_WIN32 _UNICODE UNICODE INITGUID)\n\
target_compile_options($proj_name PRIVATE -Wno-deprecated-declarations -municode -Wno-write-strings -pthread $EXTRA_FLAGS)\n\
target_link_options($proj_name PRIVATE -mconsole)\n\
target_link_libraries($proj_name ws2_32 secur32 advapi32 ole32 oleaut32 user32 rpcrt4 ntdll crypt32 uuid)\n\
set_property(TARGET $proj_name PROPERTY CXX_STANDARD 11)\n\
" > CMakeLists.txt\n\
    mkdir -p build\n\
    cd build\n\
    cmake .. -DCMAKE_TOOLCHAIN_FILE=/toolchain-mingw.cmake\n\
    make\n\
    mkdir -p "$OUTPUT_DIR/$proj_name"\n\
    cp $proj_name.exe "$OUTPUT_DIR/$proj_name/"\n\
    cd ..\n\
    cd - >/dev/null\n\
  done\n\
elif CMAKE=$(find . -type f -name "CMakeLists.txt"); [ -n "$CMAKE" ]; then\n\
  echo "Detected CMake project(s). Cross-compiling for Windows $ARCH..."\n\
  for cmakelists in $CMAKE; do\n\
    proj_dir=$(dirname "$cmakelists")\n\
    proj_name=$(basename "$proj_dir")\n\
    if [ "$proj_name" = "." ] || [ -z "$proj_name" ]; then proj_name="$REPO_NAME"; fi\n\
    mkdir -p "$proj_dir/build"\n\
    cd "$proj_dir/build"\n\
    cmake .. -DCMAKE_TOOLCHAIN_FILE=/toolchain-mingw.cmake -DCMAKE_CXX_FLAGS="-std=c++11 -Wno-deprecated-declarations -municode -Wno-write-strings -pthread $EXTRA_FLAGS"\n\
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
    if [ "$proj_name" = "." ] || [ -z "$proj_name" ]; then proj_name="$REPO_NAME"; fi\n\
    cd "$proj_dir"\n\
    make CC=$TOOLCHAIN_PREFIX-gcc CXX=$TOOLCHAIN_PREFIX-g++ CXXFLAGS="-std=c++11 -Wno-deprecated-declarations -municode -Wno-write-strings -pthread $EXTRA_FLAGS"\n\
    mkdir -p "$OUTPUT_DIR/$proj_name"\n\
    find . -name "*.exe" -exec cp {} "$OUTPUT_DIR/$proj_name/" \\;\n\
    cd - >/dev/null\n\
  done\n\
else\n\
  echo "No build system detected. Attempting simple C/C++ compilation recursively for Windows $ARCH..."\n\
  COMPILED=false\n\
  if [ -n "$(find . -type f \\( -name "*.c" -o -name "*.cpp" \\))" ]; then\n\
    # Lowercase all source and header filenames if not already lowercase\n\
    for file in $(find . -type f \\( -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" \\)); do\n\
      lower=$(basename "$file" | tr '\''A-Z'\'' '\''a-z'\'')\n\
      if [ "$(basename "$file")" != "$lower" ]; then\n\
        mv "$file" "$(dirname "$file")/$lower"\n\
      fi\n\
    done\n\
    # Patch quoted includes: lowercase filename, keep quoted\n\
    sed -i '\''s/#include "\\([^"]*\\.h\\)"/#include "\\L\\1"/g'\'' *.cpp *.c *.h *.hpp 2>/dev/null || true\n\
    sed -i '\''s/#include "\\([^"]*\\.hpp\\)"/#include "\\L\\1"/g'\'' *.cpp *.c *.h *.hpp 2>/dev/null || true\n\
    # Patch angled includes: lowercase filename\n\
    sed -i '\''s/#include <\\([^>]*\\.h\\)>/#include <\\L\\1>/g'\'' *.cpp *.c *.h *.hpp 2>/dev/null || true\n\
    sed -i '\''s/#include <\\([^>]*\\.hpp\\)>/#include <\\L\\1>/g'\'' *.cpp *.c *.h *.hpp 2>/dev/null || true\n\
    # Add C++11 threading includes at the top of all files\n\
    sed -i '\''1i #include <condition_variable>\n#include <mutex>\n#include <thread>'\'' *.cpp *.c *.h *.hpp 2>/dev/null || true\n\
    # Add #define INITGUID for COM GUID definitions to stdafx.h if exists\n\
    if [ -f stdafx.h ]; then\n\
      sed -i '\''1i #define INITGUID'\'' stdafx.h\n\
    fi\n\
    # Generate CMakeLists.txt\n\
    SOURCES=$(find . -type f \\( -name "*.cpp" -o -name "*.c" \\) | tr '\''\n'\'' '\'' '\'') \n\
    echo "cmake_minimum_required(VERSION 3.10)\n\
project($REPO_NAME)\n\
add_executable($REPO_NAME $SOURCES)\n\
target_compile_definitions($REPO_NAME PRIVATE SECURITY_WIN32 _UNICODE UNICODE INITGUID)\n\
target_compile_options($REPO_NAME PRIVATE -Wno-deprecated-declarations -municode -Wno-write-strings -pthread $EXTRA_FLAGS)\n\
target_link_options($REPO_NAME PRIVATE -mconsole)\n\
target_link_libraries($REPO_NAME ws2_32 secur32 advapi32 ole32 oleaut32 user32 rpcrt4 ntdll crypt32 uuid)\n\
set_property(TARGET $REPO_NAME PROPERTY CXX_STANDARD 11)\n\
" > CMakeLists.txt\n\
    mkdir -p build\n\
    cd build\n\
    cmake .. -DCMAKE_TOOLCHAIN_FILE=/toolchain-mingw.cmake\n\
    make\n\
    mkdir -p "$OUTPUT_DIR/$REPO_NAME"\n\
    find . -name "*.exe" -exec cp {} "$OUTPUT_DIR/$REPO_NAME/" \\;\n\
    cd - >/dev/null\n\
    COMPILED=true\n\
  fi\n\
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