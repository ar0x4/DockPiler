#!/bin/bash
#
# DockPiler Entrypoint Script
# Cross-compile Windows executables from GitHub repositories
#
# Usage: entrypoint.sh <github_url> [arch] [config] [git_ref] [extra_flags]
#

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPTS_DIR="/scripts"
TOOLCHAIN_DIR="/toolchain"
OUTPUT_DIR="/output"
REPO_DIR="/repo"
BUILD_DIR="/build"

# ============================================================================
# Logging Functions
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO $(date +%H:%M:%S)]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS $(date +%H:%M:%S)]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING $(date +%H:%M:%S)]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR $(date +%H:%M:%S)]${NC} $1"
}

log_step() {
    local current=$1
    local total=$2
    local message=$3
    echo -e "${CYAN}[$current/$total]${NC} $message"
}

# ============================================================================
# Error Handling
# ============================================================================

cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Build failed with exit code $exit_code"

        # Save build logs if available
        if [ -d "$REPO_DIR" ]; then
            log_info "Saving build logs to output directory..."
            mkdir -p "$OUTPUT_DIR/logs"

            # Copy CMake logs
            find "$REPO_DIR" -name "CMakeError.log" -exec cp {} "$OUTPUT_DIR/logs/" \; 2>/dev/null || true
            find "$REPO_DIR" -name "CMakeOutput.log" -exec cp {} "$OUTPUT_DIR/logs/" \; 2>/dev/null || true

            # Save last 100 lines of any build output
            if [ -f /tmp/build.log ]; then
                tail -100 /tmp/build.log > "$OUTPUT_DIR/logs/build.log" 2>/dev/null || true
            fi
        fi

        # Collect diagnostics
        collect_diagnostics
    fi
}

trap cleanup EXIT

collect_diagnostics() {
    mkdir -p "$OUTPUT_DIR/logs"
    {
        echo "=== DockPiler Build Diagnostics ==="
        echo "Date: $(date)"
        echo "Architecture: ${ARCH:-unknown}"
        echo "Configuration: ${CONFIG:-unknown}"
        echo "Git Ref: ${GIT_REF:-default}"
        echo ""
        echo "=== Compiler Versions ==="
        x86_64-w64-mingw32-gcc --version 2>/dev/null || echo "x64 compiler not found"
        i686-w64-mingw32-gcc --version 2>/dev/null || echo "x86 compiler not found"
        echo ""
        echo "=== CMake Version ==="
        cmake --version 2>/dev/null || echo "CMake not found"
        echo ""
        echo "=== .NET Version ==="
        dotnet --version 2>/dev/null || echo ".NET not found"
        echo ""
        echo "=== Python Version ==="
        python3 --version 2>/dev/null || echo "Python not found"
    } > "$OUTPUT_DIR/logs/diagnostics.txt" 2>&1
}

# ============================================================================
# Parameter Parsing
# ============================================================================

URL="${1:-}"
ARCH="${2:-x64}"
CONFIG="${3:-Release}"
GIT_REF="${4:-}"
EXTRA_FLAGS="${5:-}"

# Validate URL
if [ -z "$URL" ]; then
    log_error "No GitHub URL provided"
    echo ""
    echo "Usage: docker run -v \$(pwd)/output:/output dockpiler <github_url> [arch] [config] [git_ref] [extra_flags]"
    echo ""
    echo "Arguments:"
    echo "  github_url   - URL of the GitHub repository"
    echo "  arch         - Target architecture: x64 (default) or x86"
    echo "  config       - Build configuration: Release (default) or Debug"
    echo "  git_ref      - Branch, tag, or commit hash (optional)"
    echo "  extra_flags  - Additional compiler flags (optional)"
    echo ""
    echo "Examples:"
    echo "  docker run -v \$(pwd)/output:/output dockpiler https://github.com/GhostPack/Rubeus.git"
    echo "  docker run -v \$(pwd)/output:/output dockpiler https://github.com/example/project.git x86 Debug"
    echo "  docker run -v \$(pwd)/output:/output dockpiler https://github.com/example/project.git x64 Release v1.0.0"
    exit 1
fi

# Validate architecture
if [ "$ARCH" != "x64" ] && [ "$ARCH" != "x86" ]; then
    log_error "Invalid architecture '$ARCH'. Use 'x64' or 'x86'."
    exit 1
fi

# Validate configuration
if [ "$CONFIG" != "Release" ] && [ "$CONFIG" != "Debug" ]; then
    log_error "Invalid configuration '$CONFIG'. Use 'Release' or 'Debug'."
    exit 1
fi

# Set toolchain variables
if [ "$ARCH" = "x86" ]; then
    PLATFORM="x86"
    TOOLCHAIN_PREFIX="i686-w64-mingw32"
    TOOLCHAIN_FILE="$TOOLCHAIN_DIR/mingw-x86.cmake"
    DOTNET_RID="win-x86"
else
    PLATFORM="x64"
    TOOLCHAIN_PREFIX="x86_64-w64-mingw32"
    TOOLCHAIN_FILE="$TOOLCHAIN_DIR/mingw-x64.cmake"
    DOTNET_RID="win-x64"
fi

# Set build type flags
if [ "$CONFIG" = "Debug" ]; then
    CMAKE_BUILD_TYPE="Debug"
    CFLAGS_CONFIG="-g -O0 -DDEBUG -D_DEBUG"
else
    CMAKE_BUILD_TYPE="Release"
    CFLAGS_CONFIG="-O2 -DNDEBUG"
fi

REPO_NAME=$(basename "$URL" .git)

# ============================================================================
# Display Configuration
# ============================================================================

echo ""
echo "=============================================="
echo "  DockPiler - Windows Cross-Compiler"
echo "=============================================="
echo ""
log_info "Repository: $URL"
log_info "Architecture: $ARCH ($TOOLCHAIN_PREFIX)"
log_info "Configuration: $CONFIG"
[ -n "$GIT_REF" ] && log_info "Git Reference: $GIT_REF"
[ -n "$EXTRA_FLAGS" ] && log_info "Extra Flags: $EXTRA_FLAGS"
echo ""

# ============================================================================
# Clone Repository
# ============================================================================

log_step 1 5 "Cloning repository..."

mkdir -p "$REPO_DIR"

if [ -n "$GIT_REF" ]; then
    # Try to clone specific branch/tag first
    if git clone --branch "$GIT_REF" --depth 1 --recurse-submodules "$URL" "$REPO_DIR" 2>/dev/null; then
        log_success "Cloned branch/tag: $GIT_REF"
    else
        # Fall back to full clone and checkout
        log_info "Branch/tag not found, trying as commit hash..."
        git clone --recurse-submodules "$URL" "$REPO_DIR"
        cd "$REPO_DIR"
        git checkout "$GIT_REF"
        log_success "Checked out: $GIT_REF"
    fi
else
    git clone --depth 1 --recurse-submodules "$URL" "$REPO_DIR"
    log_success "Cloned default branch"
fi

cd "$REPO_DIR"

# Initialize submodules if not already done
if [ -f .gitmodules ]; then
    log_info "Initializing git submodules..."
    git submodule update --init --recursive
fi

# ============================================================================
# Preprocessing
# ============================================================================

log_step 2 5 "Preprocessing source files..."

# Remove BOM and convert line endings for all source files
find . -type f \( -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" -o -name "*.cc" -o -name "*.cxx" \) \
    -exec sed -i '1s/^\xEF\xBB\xBF//' {} + \
    -exec sed -i 's/\r$//' {} + 2>/dev/null || true

# Fix MSVC variadic macro issue: replace ", __VA_ARGS__)" with ", ##__VA_ARGS__)"
# This allows GCC to handle macros with optional variadic arguments like MSVC does
find . -type f \( -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" \) \
    -exec sed -i 's/, *__VA_ARGS__ *)/, ##__VA_ARGS__ )/g' {} + 2>/dev/null || true

log_success "Preprocessed source files"

# ============================================================================
# Detect and Build
# ============================================================================

log_step 3 5 "Detecting project type..."

# Helper function to lowercase filenames
lowercase_sources() {
    local dir="${1:-.}"
    find "$dir" -type f \( -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" \) | while read -r file; do
        local dir_name=$(dirname "$file")
        local base_name=$(basename "$file")
        local lower_name=$(echo "$base_name" | tr 'A-Z' 'a-z')
        if [ "$base_name" != "$lower_name" ]; then
            mv "$file" "$dir_name/$lower_name" 2>/dev/null || true
        fi
    done
}

# Helper function to patch includes to lowercase
patch_includes() {
    local dir="${1:-.}"
    find "$dir" -type f \( -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" \) -exec sed -i \
        -e 's/#include "\([^"]*\.[hH]\)"/#include "\L\1"/g' \
        -e 's/#include "\([^"]*\.[hH][pP][pP]\)"/#include "\L\1"/g' \
        -e 's/#include <\([^>]*\.[hH]\)>/#include <\L\1>/g' \
        {} + 2>/dev/null || true
}

# Helper function to build C# project
build_csharp_project() {
    local proj_file="$1"
    local proj_dir=$(dirname "$proj_file")
    local proj_name=$(basename "$proj_dir")

    if [ "$proj_name" = "." ]; then
        proj_name=$(basename "$proj_file" .csproj)
    fi

    log_info "Building C# project: $proj_name"

    cd "$proj_dir"
    local proj_basename=$(basename "$proj_file")

    # Check if it's .NET Framework or modern .NET
    if grep -qi "<TargetFrameworkVersion>v" "$proj_basename"; then
        log_info "Detected .NET Framework project"

        # Extract target framework version
        local target_fw=$(grep -oP '<TargetFrameworkVersion>v\K[0-9.]+' "$proj_basename" | head -1)
        log_info "Target Framework: v$target_fw"

        # Map to reference assembly path
        local ref_path=""
        case "$target_fw" in
            4.0*)   ref_path="/reference-assemblies/net40/build/.NETFramework/v4.0" ;;
            4.5)    ref_path="/reference-assemblies/net45/build/.NETFramework/v4.5" ;;
            4.5.1)  ref_path="/reference-assemblies/net451/build/.NETFramework/v4.5.1" ;;
            4.5.2)  ref_path="/reference-assemblies/net452/build/.NETFramework/v4.5.2" ;;
            4.6)    ref_path="/reference-assemblies/net46/build/.NETFramework/v4.6" ;;
            4.6.1)  ref_path="/reference-assemblies/net461/build/.NETFramework/v4.6.1" ;;
            4.6.2)  ref_path="/reference-assemblies/net462/build/.NETFramework/v4.6.2" ;;
            4.7)    ref_path="/reference-assemblies/net47/build/.NETFramework/v4.7" ;;
            4.7.1)  ref_path="/reference-assemblies/net471/build/.NETFramework/v4.7.1" ;;
            4.7.2)  ref_path="/reference-assemblies/net472/build/.NETFramework/v4.7.2" ;;
            4.8*)   ref_path="/reference-assemblies/net48/build/.NETFramework/v4.8" ;;
            *)
                log_warning "Unsupported framework version $target_fw, using 4.8"
                ref_path="/reference-assemblies/net48/build/.NETFramework/v4.8"
                sed -i "s/<TargetFrameworkVersion>v[0-9.]*/<TargetFrameworkVersion>v4.8/" "$proj_basename"
                ;;
        esac

        mkdir -p "$OUTPUT_DIR/$proj_name"
        dotnet restore "$proj_basename" || true
        dotnet build "$proj_basename" -c "$CONFIG" \
            -p:Platform="$PLATFORM" \
            -p:PlatformTarget="$ARCH" \
            -p:OutputPath="$OUTPUT_DIR/$proj_name" \
            -p:FrameworkPathOverride="$ref_path" \
            -p:AllowUnsafeBlocks=true \
            -p:DisableOutOfProcTaskHost=true \
            -p:GenerateFullPaths=true 2>&1 | tee -a /tmp/build.log
    else
        log_info "Detected modern .NET project"

        mkdir -p "$OUTPUT_DIR/$proj_name"
        dotnet publish "$proj_basename" -c "$CONFIG" \
            -r "$DOTNET_RID" \
            --self-contained true \
            -p:PublishSingleFile=true \
            -p:AllowUnsafeBlocks=true \
            -o "$OUTPUT_DIR/$proj_name" 2>&1 | tee -a /tmp/build.log
    fi

    cd - >/dev/null
    log_success "Built C# project: $proj_name"
}

# Helper function to build C++ project with vcxproj
build_vcxproj() {
    local vcxproj_file="$1"
    local proj_dir=$(dirname "$vcxproj_file")
    local proj_name=$(basename "$proj_dir")

    if [ "$proj_name" = "." ]; then
        proj_name=$(basename "$vcxproj_file" .vcxproj)
    fi

    log_info "Building C++ project: $proj_name"

    cd "$proj_dir"

    # Lowercase source files for case-sensitivity
    lowercase_sources .
    patch_includes .

    # Parse vcxproj and generate CMakeLists.txt using Python
    log_info "Parsing vcxproj file..."
    python3 "$SCRIPTS_DIR/vcxproj_parser.py" "$(basename "$vcxproj_file")" \
        -c "$CONFIG" -p "$PLATFORM" -o /tmp/project_data.json

    python3 "$SCRIPTS_DIR/cmake_generator.py" --json /tmp/project_data.json -o CMakeLists.txt

    # Build with CMake
    mkdir -p build
    cd build

    cmake .. \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
        -DCMAKE_CXX_FLAGS="$CFLAGS_CONFIG $EXTRA_FLAGS" \
        -DCMAKE_C_FLAGS="$CFLAGS_CONFIG $EXTRA_FLAGS" 2>&1 | tee -a /tmp/build.log

    make -j$(nproc) 2>&1 | tee -a /tmp/build.log

    # Copy output
    mkdir -p "$OUTPUT_DIR/$proj_name"
    find . -name "*.exe" -exec cp {} "$OUTPUT_DIR/$proj_name/" \;

    cd ..  # Back to project dir from build/
    cd - >/dev/null
    log_success "Built C++ project: $proj_name"
}

# Helper function to build CMake project
build_cmake_project() {
    local cmake_dir="$1"
    local proj_name=$(basename "$cmake_dir")

    if [ "$proj_name" = "." ]; then
        proj_name="$REPO_NAME"
    fi

    log_info "Building CMake project: $proj_name"

    cd "$cmake_dir"

    # Preprocessing
    lowercase_sources .
    patch_includes .

    mkdir -p build
    cd build

    cmake .. \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
        -DCMAKE_CXX_FLAGS="-std=c++11 -Wno-deprecated-declarations -municode -Wno-write-strings -pthread $CFLAGS_CONFIG $EXTRA_FLAGS" \
        -DCMAKE_C_FLAGS="-Wno-deprecated-declarations -municode $CFLAGS_CONFIG $EXTRA_FLAGS" 2>&1 | tee -a /tmp/build.log

    make -j$(nproc) 2>&1 | tee -a /tmp/build.log

    mkdir -p "$OUTPUT_DIR/$proj_name"
    find . -name "*.exe" -exec cp {} "$OUTPUT_DIR/$proj_name/" \;

    cd - >/dev/null
    log_success "Built CMake project: $proj_name"
}

# Helper function to build Makefile project
build_makefile_project() {
    local makefile_dir="$1"
    local proj_name=$(basename "$makefile_dir")

    if [ "$proj_name" = "." ]; then
        proj_name="$REPO_NAME"
    fi

    log_info "Building Makefile project: $proj_name"

    cd "$makefile_dir"

    lowercase_sources .
    patch_includes .

    make -j$(nproc) \
        CC="$TOOLCHAIN_PREFIX-gcc" \
        CXX="$TOOLCHAIN_PREFIX-g++" \
        CFLAGS="$CFLAGS_CONFIG $EXTRA_FLAGS" \
        CXXFLAGS="-std=c++11 -Wno-deprecated-declarations -municode -Wno-write-strings -pthread $CFLAGS_CONFIG $EXTRA_FLAGS" 2>&1 | tee -a /tmp/build.log

    mkdir -p "$OUTPUT_DIR/$proj_name"
    find . -name "*.exe" -exec cp {} "$OUTPUT_DIR/$proj_name/" \;

    cd - >/dev/null
    log_success "Built Makefile project: $proj_name"
}

# Helper function for fallback C/C++ compilation
build_fallback() {
    local src_dir="$1"
    local proj_name="$REPO_NAME"

    log_info "Building with fallback method: $proj_name"

    cd "$src_dir"

    lowercase_sources .
    patch_includes .

    # Add common includes
    find . -type f \( -name "*.cpp" -o -name "*.c" \) -exec sed -i \
        '1i #include <condition_variable>\n#include <mutex>\n#include <thread>' {} + 2>/dev/null || true

    # Add INITGUID if stdafx.h exists
    if [ -f stdafx.h ]; then
        sed -i '1i #define INITGUID' stdafx.h
    fi

    # Generate CMakeLists.txt using Python
    python3 "$SCRIPTS_DIR/cmake_generator.py" -n "$proj_name" -d . -c "$CONFIG" -o CMakeLists.txt

    mkdir -p build
    cd build

    cmake .. \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
        -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
        -DCMAKE_CXX_FLAGS="$CFLAGS_CONFIG $EXTRA_FLAGS" \
        -DCMAKE_C_FLAGS="$CFLAGS_CONFIG $EXTRA_FLAGS" 2>&1 | tee -a /tmp/build.log

    make -j$(nproc) 2>&1 | tee -a /tmp/build.log

    mkdir -p "$OUTPUT_DIR/$proj_name"
    find . -name "*.exe" -exec cp {} "$OUTPUT_DIR/$proj_name/" \;

    cd - >/dev/null
    log_success "Built fallback project: $proj_name"
}

# ============================================================================
# Main Build Logic
# ============================================================================

BUILT=false

# Check for .sln file first (solution file)
SLN_FILES=$(find . -maxdepth 2 -type f -name "*.sln" | head -5)
if [ -n "$SLN_FILES" ]; then
    log_info "Detected Visual Studio Solution file(s)"

    for sln in $SLN_FILES; do
        log_info "Processing solution: $sln"

        # Parse solution and get build order
        sln_dir=$(dirname "$sln")

        # Get C# projects in build order
        CSPROJ_LIST=$(python3 "$SCRIPTS_DIR/sln_parser.py" "$sln" --csharp-only --build-order 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join([p['full_path'] for p in d.get('build_order',[])]))" 2>/dev/null || echo "")

        if [ -n "$CSPROJ_LIST" ]; then
            for csproj in $CSPROJ_LIST; do
                if [ -f "$csproj" ]; then
                    build_csharp_project "$csproj"
                    BUILT=true
                fi
            done
        fi

        # Get C++ projects in build order
        VCXPROJ_LIST=$(python3 "$SCRIPTS_DIR/sln_parser.py" "$sln" --cpp-only --build-order 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join([p['full_path'] for p in d.get('build_order',[])]))" 2>/dev/null || echo "")

        if [ -n "$VCXPROJ_LIST" ]; then
            for vcxproj in $VCXPROJ_LIST; do
                if [ -f "$vcxproj" ]; then
                    build_vcxproj "$vcxproj"
                    BUILT=true
                fi
            done
        fi
    done
fi

# If no solution file or no projects in solution, try individual project files
if [ "$BUILT" = false ]; then
    # Check for C# projects
    CSPROJ_FILES=$(find . -type f -name "*.csproj" | head -10)
    if [ -n "$CSPROJ_FILES" ]; then
        log_info "Detected C# project file(s)"
        for csproj in $CSPROJ_FILES; do
            build_csharp_project "$csproj"
            BUILT=true
        done
    fi
fi

if [ "$BUILT" = false ]; then
    # Check for vcxproj files
    VCXPROJ_FILES=$(find . -type f -name "*.vcxproj" | head -10)
    if [ -n "$VCXPROJ_FILES" ]; then
        log_info "Detected Visual Studio C++ project file(s)"
        for vcxproj in $VCXPROJ_FILES; do
            build_vcxproj "$vcxproj"
            BUILT=true
        done
    fi
fi

if [ "$BUILT" = false ]; then
    # Check for CMakeLists.txt
    CMAKE_FILES=$(find . -maxdepth 2 -type f -name "CMakeLists.txt" | head -5)
    if [ -n "$CMAKE_FILES" ]; then
        log_info "Detected CMake project(s)"
        for cmake_file in $CMAKE_FILES; do
            cmake_dir=$(dirname "$cmake_file")
            build_cmake_project "$cmake_dir"
            BUILT=true
        done
    fi
fi

if [ "$BUILT" = false ]; then
    # Check for Makefile
    MAKEFILES=$(find . -maxdepth 2 -type f -name "Makefile" | head -5)
    if [ -n "$MAKEFILES" ]; then
        log_info "Detected Makefile project(s)"
        for makefile in $MAKEFILES; do
            makefile_dir=$(dirname "$makefile")
            build_makefile_project "$makefile_dir"
            BUILT=true
        done
    fi
fi

if [ "$BUILT" = false ]; then
    # Fallback: look for C/C++ source files
    SOURCE_FILES=$(find . -type f \( -name "*.c" -o -name "*.cpp" -o -name "*.cc" -o -name "*.cxx" \) | head -1)
    if [ -n "$SOURCE_FILES" ]; then
        log_info "No build system detected, using fallback compilation"
        build_fallback "."
        BUILT=true
    fi
fi

if [ "$BUILT" = false ]; then
    log_error "No compilable files or build system found"
    exit 1
fi

# ============================================================================
# Summary
# ============================================================================

log_step 5 5 "Build complete!"

echo ""
echo "=============================================="
echo "  Build Summary"
echo "=============================================="
echo ""

# List output files
if [ -d "$OUTPUT_DIR" ]; then
    OUTPUT_COUNT=$(find "$OUTPUT_DIR" -type f \( -name "*.exe" -o -name "*.dll" \) | wc -l)

    if [ "$OUTPUT_COUNT" -gt 0 ]; then
        log_success "Generated $OUTPUT_COUNT binary file(s):"
        echo ""
        find "$OUTPUT_DIR" -type f \( -name "*.exe" -o -name "*.dll" \) -exec ls -lh {} \;
    else
        log_warning "No binary files were generated"
    fi
fi

echo ""
log_success "Output directory: $OUTPUT_DIR"
echo ""
