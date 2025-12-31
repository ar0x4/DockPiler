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
ARTIFACTS_DIR="/artifacts"  # Shared directory for built binaries (DLLs/EXEs) between projects

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

# ============================================================================
# Generate MIDL headers from IDL files
# ============================================================================
# MIDL generates *_c.c (client stubs), *_s.c (server stubs), and *_h.h (header)
# If IDL file exists but header doesn't, generate it using our Python generator

process_idl_files() {
    local target_arch="$1"  # x64 or x86

    find . -name "*.idl" -type f 2>/dev/null | while read -r idl_file; do
        local idl_dir=$(dirname "$idl_file")
        local idl_basename=$(basename "$idl_file" .idl)
        local header_file="${idl_dir}/${idl_basename}_h.h"

        # Check if the header file is missing but stub files exist
        if [ ! -f "$header_file" ]; then
            # Check if this IDL has associated stub files (indicating it was MIDL-compiled)
            if [ -f "${idl_dir}/${idl_basename}_c.c" ] || [ -f "${idl_dir}/${idl_basename}_s.c" ]; then
                log_info "Generating MIDL header from IDL: $idl_file"

                # Use the Python MIDL header generator
                if python3 "$SCRIPTS_DIR/midl_header_generator.py" "$idl_file" -o "$header_file" -a "$target_arch" 2>/dev/null; then
                    log_success "Generated header: $header_file"
                else
                    log_warning "Python generator failed, using fallback..."
                    generate_fallback_midl_header "$idl_file" "$header_file"
                fi
            fi
        fi
    done
}

# Fallback MIDL header generator (simple bash version)
generate_fallback_midl_header() {
    local idl_file="$1"
    local header_file="$2"
    local idl_basename=$(basename "$idl_file" .idl)

    # Extract basic interface info
    local uuid=$(grep -oP 'uuid\s*\(\s*\K[0-9a-fA-F-]+' "$idl_file" 2>/dev/null | head -1)
    local iface_name=$(grep -oP 'interface\s+\K\w+' "$idl_file" 2>/dev/null | head -1)
    local version=$(grep -oP 'version\s*\(\s*\K[0-9.]+' "$idl_file" 2>/dev/null | head -1 || echo "1.0")
    local version_str=$(echo "$version" | tr '.' '_')

    cat > "$header_file" << MIDL_HEADER_EOF
/* MIDL header - auto-generated by DockPiler from $(basename "$idl_file") */
#ifndef __${idl_basename^^}_H__
#define __${idl_basename^^}_H__

#ifndef __REQUIRED_RPCNDR_H_VERSION__
#define __REQUIRED_RPCNDR_H_VERSION__ 475
#endif

#include <rpc.h>
#include <rpcndr.h>

#ifndef COM_NO_WINDOWS_H
#include <windows.h>
#include <ole2.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Interface: ${iface_name:-unknown} */
/* UUID: ${uuid:-unknown} */

extern RPC_IF_HANDLE ${iface_name:-unknown}_v${version_str}_c_ifspec;
extern RPC_IF_HANDLE ${iface_name:-unknown}_v${version_str}_s_ifspec;

/* Context handle type */
typedef void* PCONTEXT_HANDLE_TYPE;

#ifdef __cplusplus
}
#endif

#endif /* __${idl_basename^^}_H__ */
MIDL_HEADER_EOF

    log_success "Generated fallback header: $header_file"
}

# Process IDL files for the target architecture
process_idl_files "$ARCH"

# Convert UTF-16 encoded files to UTF-8 (common for Windows resource files)
# UTF-16 LE BOM is FF FE, UTF-16 BE BOM is FE FF
find . -type f \( -name "*.rc" -o -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" \) 2>/dev/null | while read -r file; do
    # Check for UTF-16 LE BOM (FF FE)
    if head -c 2 "$file" 2>/dev/null | od -An -tx1 | grep -q "ff fe"; then
        log_info "Converting UTF-16 LE to UTF-8: $file"
        iconv -f UTF-16LE -t UTF-8 "$file" > "${file}.tmp" 2>/dev/null && mv "${file}.tmp" "$file" || rm -f "${file}.tmp"
    # Check for UTF-16 BE BOM (FE FF)
    elif head -c 2 "$file" 2>/dev/null | od -An -tx1 | grep -q "fe ff"; then
        log_info "Converting UTF-16 BE to UTF-8: $file"
        iconv -f UTF-16BE -t UTF-8 "$file" > "${file}.tmp" 2>/dev/null && mv "${file}.tmp" "$file" || rm -f "${file}.tmp"
    fi
done

# Remove BOM and convert line endings for all source files
find . -type f \( -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" -o -name "*.cc" -o -name "*.cxx" -o -name "*.rc" \) \
    -exec sed -i '1s/^\xEF\xBB\xBF//' {} + \
    -exec sed -i 's/\r$//' {} + 2>/dev/null || true

# Convert Windows header includes to lowercase for MinGW (Linux is case-sensitive)
find . -type f \( -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" \) \
    -exec sed -i 's/#include <Windows\.h>/#include <windows.h>/g' {} + \
    -exec sed -i 's/#include <Shlwapi\.h>/#include <shlwapi.h>/g' {} + \
    -exec sed -i 's/#include <Strsafe\.h>/#include <strsafe.h>/g' {} + \
    -exec sed -i 's/#include <Sddl\.h>/#include <sddl.h>/g' {} + \
    -exec sed -i 's/#include <Lmcons\.h>/#include <lmcons.h>/g' {} + \
    -exec sed -i 's/#include <WinSock2\.h>/#include <winsock2.h>/g' {} + \
    -exec sed -i 's/#include <WS2tcpip\.h>/#include <ws2tcpip.h>/g' {} + 2>/dev/null || true

# Fix MSVC variadic macro issue: replace ", __VA_ARGS__)" with ", ##__VA_ARGS__)"
# This allows GCC to handle macros with optional variadic arguments like MSVC does
find . -type f \( -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" \) \
    -exec sed -i 's/, *__VA_ARGS__ *)/, ##__VA_ARGS__ )/g' {} + 2>/dev/null || true

# Fix MinGW header compatibility: Ensure Windows.h is included first with proper defines
# This fixes shlwapi.h, strsafe.h, and other problematic headers
find . -type f \( -name "*.cpp" -o -name "*.c" \) 2>/dev/null | while read -r file; do
    # Check if file includes problematic headers that need Windows.h first
    if grep -q '#include.*<shlwapi\.h>\|#include.*<strsafe\.h>\|#include.*<sddl\.h>\|#include.*<Lmcons\.h>' "$file" 2>/dev/null; then
        # Check if file starts with C++ standard library includes (before Windows.h)
        first_include=$(grep -n '#include' "$file" 2>/dev/null | head -1)
        if echo "$first_include" | grep -q '<iostream>\|<fstream>\|<string>\|<vector>\|<map>'; then
            log_info "Prepending Windows.h before C++ headers in: $file"
            # Insert Windows.h with version defines at the very beginning
            sed -i '1i\
// MinGW compatibility: Windows headers must come before C++ standard library\
#ifndef _WIN32_WINNT\
#define _WIN32_WINNT 0x0600\
#endif\
#ifndef WINVER\
#define WINVER 0x0600\
#endif\
#include <windows.h>\
' "$file" 2>/dev/null || true
        fi
    fi
done

# Fix MSVC Structured Exception Handling (SEH) for GCC compatibility
# Both RpcTryExcept/RpcExcept/RpcEndExcept and raw __try/__except are not supported by GCC
# Convert to simple if(1)/else pattern to compile (exceptions won't be caught properly but code compiles)
find . -type f \( -name "*.cpp" -o -name "*.c" \) 2>/dev/null | while read -r file; do
    if grep -q "RpcTryExcept\|RpcExcept\|RpcEndExcept" "$file" 2>/dev/null; then
        log_info "Patching RPC SEH in: $file"
        # Replace RpcTryExcept with if(1) {
        sed -i 's/RpcTryExcept/if(1) {/g' "$file"
        # Replace RpcExcept(...) with } else if(0) {
        sed -i 's/RpcExcept([^)]*)/} else if(0) {/g' "$file"
        # Replace RpcEndExcept with }
        sed -i 's/RpcEndExcept/}/g' "$file"
    fi

    # Also handle raw __try/__except blocks (MSVC SEH)
    if grep -q "__try\|__except" "$file" 2>/dev/null; then
        log_info "Patching raw SEH (__try/__except) in: $file"
        # Replace __try with try (for C++) or if(1) { (for C)
        if [[ "$file" == *.cpp ]]; then
            sed -i 's/__try/try/g' "$file"
            # Replace __except(...) with catch(...)
            sed -i 's/__except\s*([^)]*)/catch(...)/g' "$file"
        else
            sed -i 's/__try/if(1) {/g' "$file"
            sed -i 's/__except\s*([^)]*)/} else if(0) {/g' "$file"
        fi
    fi
done

# Create stub headers for missing Windows SDK headers
# Some headers are Windows SDK-only and not in MinGW
create_stub_headers() {
    # Check for includes of missing headers and create stubs
    local missing_headers=(
        "minidumpapiset.h"
        "processsnapshot.h"
    )

    for header in "${missing_headers[@]}"; do
        # Find directories that contain files using this header
        find . -type f \( -name "*.cpp" -o -name "*.c" -o -name "*.h" \) -exec grep -l "#include.*<${header}>" {} \; 2>/dev/null | while read -r src_file; do
            local src_dir=$(dirname "$src_file")
            local stub_dir="${src_dir}/mingw_stubs"
            mkdir -p "$stub_dir"
            local stub_file="$stub_dir/$header"

            if [ ! -f "$stub_file" ]; then
                log_info "Creating stub header for missing: $header in $stub_dir"
                local guard_name=$(echo "${header}" | tr '[:lower:].' '[:upper:]_')
                cat > "$stub_file" << STUB_HEADER_EOF
/* Stub header for $header - auto-generated by DockPiler */
/* This header provides minimal definitions for MinGW cross-compilation */
#ifndef _${guard_name}_STUB_
#define _${guard_name}_STUB_

#include <windows.h>

/* Minidump types - minimal definitions for compilation */
#ifndef _MINIDUMP_TYPE_DEFINED
#define _MINIDUMP_TYPE_DEFINED
typedef enum _MINIDUMP_TYPE {
    MiniDumpNormal = 0x00000000,
    MiniDumpWithDataSegs = 0x00000001,
    MiniDumpWithFullMemory = 0x00000002,
    MiniDumpWithHandleData = 0x00000004,
    MiniDumpFilterMemory = 0x00000008,
    MiniDumpScanMemory = 0x00000010,
    MiniDumpWithUnloadedModules = 0x00000020,
    MiniDumpWithIndirectlyReferencedMemory = 0x00000040,
    MiniDumpFilterModulePaths = 0x00000080,
    MiniDumpWithProcessThreadData = 0x00000100,
    MiniDumpWithPrivateReadWriteMemory = 0x00000200,
    MiniDumpWithoutOptionalData = 0x00000400,
    MiniDumpWithFullMemoryInfo = 0x00000800,
    MiniDumpWithThreadInfo = 0x00001000,
    MiniDumpWithCodeSegs = 0x00002000,
    MiniDumpWithoutAuxiliaryState = 0x00004000,
    MiniDumpWithFullAuxiliaryState = 0x00008000,
    MiniDumpWithPrivateWriteCopyMemory = 0x00010000,
    MiniDumpIgnoreInaccessibleMemory = 0x00020000,
    MiniDumpWithTokenInformation = 0x00040000,
    MiniDumpWithModuleHeaders = 0x00080000,
    MiniDumpFilterTriage = 0x00100000,
    MiniDumpWithAvxXStateContext = 0x00200000,
    MiniDumpWithIptTrace = 0x00400000,
    MiniDumpValidTypeFlags = 0x007fffff
} MINIDUMP_TYPE;
#endif

/* MiniDumpWriteDump function - stub declaration */
typedef BOOL (WINAPI *MINIDUMPWRITEDUMP)(
    HANDLE hProcess,
    DWORD ProcessId,
    HANDLE hFile,
    MINIDUMP_TYPE DumpType,
    PVOID ExceptionParam,
    PVOID UserStreamParam,
    PVOID CallbackParam
);

#endif /* _${guard_name}_STUB_ */
STUB_HEADER_EOF
            fi

            # Replace angle bracket include with quoted include for local stub in this file
            sed -i "s|#include *<${header}>|#include \"mingw_stubs/${header}\"|g" "$src_file"
        done
    done
}

create_stub_headers

# Add missing COM interface definitions for MinGW
# IPrincipal2 is a Task Scheduler interface not in MinGW headers
find . -type f \( -name "*.cpp" -o -name "*.c" \) 2>/dev/null | while read -r file; do
    if grep -q "IPrincipal2" "$file" 2>/dev/null; then
        log_info "Adding IPrincipal2 interface definition to: $file"
        # Insert IPrincipal2 definition after #include <taskschd.h>
        sed -i '/#include.*taskschd\.h/a \
\
#ifndef __IPrincipal2_INTERFACE_DEFINED__\
#define __IPrincipal2_INTERFACE_DEFINED__\
typedef enum _TASK_PROC_TOKEN_SID_TYPE { TASK_PROC_TOKEN_SID_TYPE_NONE = 0, TASK_PROC_TOKEN_SID_TYPE_UNRESTRICTED = 1, TASK_PROC_TOKEN_SID_TYPE_DEFAULT = 2 } TASK_PROC_TOKEN_SID_TYPE;\
DEFINE_GUID(IID_IPrincipal2, 0x248919AE, 0xE345, 0x4A6D, 0x8A, 0xEB, 0xE0, 0xD3, 0x16, 0x5C, 0x90, 0x4E);\
MIDL_INTERFACE("248919AE-E345-4A6D-8AEB-E0D3165C904E")\
IPrincipal2 : public IDispatch {\
public:\
    virtual HRESULT STDMETHODCALLTYPE get_ProcessTokenSidType(TASK_PROC_TOKEN_SID_TYPE *pProcessTokenSidType) = 0;\
    virtual HRESULT STDMETHODCALLTYPE put_ProcessTokenSidType(TASK_PROC_TOKEN_SID_TYPE processTokenSidType) = 0;\
    virtual HRESULT STDMETHODCALLTYPE get_RequiredPrivilegeCount(long *pCount) = 0;\
    virtual HRESULT STDMETHODCALLTYPE get_RequiredPrivilege(long index, BSTR *pPrivilege) = 0;\
    virtual HRESULT STDMETHODCALLTYPE AddRequiredPrivilege(BSTR privilege) = 0;\
};\
#endif
' "$file"
    fi
done

# Fix MSVC architecture macros for MinGW compatibility
# MIDL-generated code uses _M_AMD64 (MSVC) but MinGW uses __x86_64__
# Similarly _M_IX86 (MSVC) vs __i386__ (GCC/MinGW)
find . -type f \( -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" \) \
    -exec sed -i 's/#if defined(_M_AMD64)/#if defined(_M_AMD64) || defined(__x86_64__)/g' {} + \
    -exec sed -i 's/#if defined(_M_IX86)/#if defined(_M_IX86) || defined(__i386__)/g' {} + \
    -exec sed -i 's/#elif defined(_M_AMD64)/#elif defined(_M_AMD64) || defined(__x86_64__)/g' {} + \
    -exec sed -i 's/#elif defined(_M_IX86)/#elif defined(_M_IX86) || defined(__i386__)/g' {} + \
    -exec sed -i 's/#ifdef _M_AMD64/#if defined(_M_AMD64) || defined(__x86_64__)/g' {} + \
    -exec sed -i 's/#ifdef _M_IX86/#if defined(_M_IX86) || defined(__i386__)/g' {} + 2>/dev/null || true

# Fix MIDL-generated RPC stub and header compatibility issues
# 1. Remove RPCNDR version check that fails with MinGW headers
# 2. Fix extern/static declaration conflicts (MSVC allows this, GCC doesn't)

# First, patch header files (remove RPCNDR version check)
find . -type f -name "*_h.h" 2>/dev/null | while read -r midl_file; do
    if grep -q "__REQUIRED_RPCNDR_H_VERSION__" "$midl_file" 2>/dev/null; then
        log_info "Patching MIDL header: $midl_file"
        sed -i 's/#ifndef __REQUIRED_RPCNDR_H_VERSION__/#if 0 \/* RPCNDR version check disabled for MinGW *\//g' "$midl_file"
    fi
done

# Then, patch stub files (fix static/extern conflicts and RPCNDR check)
find . -type f \( -name "*_s.c" -o -name "*_c.c" \) 2>/dev/null | while read -r midl_file; do
    log_info "Patching MIDL stub: $midl_file"

    # Remove RPCNDR version check
    sed -i 's/#ifndef __REQUIRED_RPCNDR_H_VERSION__/#if 0 \/* RPCNDR version check disabled for MinGW *\//g' "$midl_file"

    # Fix static/extern conflicts: replace all "static const" at start of line with just "const"
    # This is safe for MIDL stubs as all the static const declarations should be const
    sed -i 's/^static const /const /g' "$midl_file"
done

# Generate COM IID definitions for MIDL-generated headers
# MIDL generates headers with EXTERN_C const IID declarations but the _i.c files
# that define them are often not included in the repository.
# We generate IID definitions from MIDL_INTERFACE() declarations.
generate_iid_definitions() {
    local header_file="$1"
    local output_file="${header_file%.h}_iid.c"

    # Extract MIDL_INTERFACE declarations and generate IID definitions
    # Pattern: MIDL_INTERFACE("XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX")
    # Following line should have interface name like: InterfaceName : public IUnknown

    local found_interfaces=false
    local iid_content="#include <windows.h>\n#include <initguid.h>\n\n"

    while IFS= read -r line; do
        if [[ "$line" =~ MIDL_INTERFACE\(\"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\"\) ]]; then
            local guid="${BASH_REMATCH[1]}"
            # Read next line to get interface name
            read -r next_line
            if [[ "$next_line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*: ]]; then
                local iface_name="${BASH_REMATCH[1]}"
                # Parse GUID components
                local g1="${guid:0:8}"
                local g2="${guid:9:4}"
                local g3="${guid:14:4}"
                local g4="${guid:19:4}"
                local g5="${guid:24:12}"
                # Format: DEFINE_GUID(IID_InterfaceName, 0xXXXXXXXX, 0xXXXX, 0xXXXX, 0xXX, 0xXX, 0xXX, 0xXX, 0xXX, 0xXX, 0xXX, 0xXX);
                local b1="${g4:0:2}" b2="${g4:2:2}"
                local b3="${g5:0:2}" b4="${g5:2:2}" b5="${g5:4:2}" b6="${g5:6:2}" b7="${g5:8:2}" b8="${g5:10:2}"
                iid_content+="DEFINE_GUID(IID_${iface_name}, 0x${g1}, 0x${g2}, 0x${g3}, 0x${b1}, 0x${b2}, 0x${b3}, 0x${b4}, 0x${b5}, 0x${b6}, 0x${b7}, 0x${b8});\n"
                found_interfaces=true
            fi
        fi
    done < "$header_file"

    if [ "$found_interfaces" = true ]; then
        echo -e "$iid_content" > "$output_file"
        log_info "Generated IID definitions: $output_file"
    fi
}

# Find and process MIDL-generated headers (files with MIDL_INTERFACE)
for header in $(grep -l "MIDL_INTERFACE" *.h */*.h 2>/dev/null || true); do
    # Check if this header has unresolved IID references
    if grep -q "EXTERN_C const IID IID_" "$header" 2>/dev/null; then
        generate_iid_definitions "$header"
    fi
done

log_success "Preprocessed source files"

# ============================================================================
# Detect and Build
# ============================================================================

log_step 3 5 "Detecting project type..."

# Initialize shared artifacts directory
mkdir -p "$ARTIFACTS_DIR"

# Helper function to patch resource files (.rc) that reference external binaries
# This handles cases where projects embed DLLs from sibling projects
patch_resource_files() {
    local dir="${1:-.}"

    find "$dir" -type f -name "*.rc" 2>/dev/null | while read -r rc_file; do
        # Look for binary references in resource files (RCDATA, etc.)
        # Common patterns: "..\Release\Something.dll", "$(OutDir)Something.dll", relative paths to DLLs/EXEs

        # Extract referenced binary files from the .rc file
        grep -oE '[^"[:space:]]+\.(dll|exe|bin)' "$rc_file" 2>/dev/null | sort -u | while read -r binary_ref; do
            # Get just the filename
            binary_name=$(basename "$binary_ref")

            # Check if this binary exists in our artifacts directory
            if [ -f "$ARTIFACTS_DIR/$binary_name" ]; then
                log_info "Patching resource reference: $binary_ref -> $ARTIFACTS_DIR/$binary_name"
                # Escape special characters for sed
                escaped_ref=$(echo "$binary_ref" | sed 's/[.[\*^$/]/\\&/g')
                sed -i "s|$escaped_ref|$ARTIFACTS_DIR/$binary_name|g" "$rc_file"
            else
                # Binary not found - check if it's a relative path we can resolve
                # Also create a symlink/copy spot in artifacts so it can be found
                log_info "Resource file references missing binary: $binary_name (will retry after dependencies build)"
            fi
        done
    done
}

# Helper function to copy build outputs to shared artifacts directory
copy_to_artifacts() {
    local build_dir="${1:-.}"
    local copied=0

    # Copy all DLLs and EXEs to artifacts directory
    find "$build_dir" -type f \( -name "*.dll" -o -name "*.exe" \) 2>/dev/null | while read -r binary; do
        local binary_name=$(basename "$binary")
        cp "$binary" "$ARTIFACTS_DIR/$binary_name" 2>/dev/null && \
            log_info "Copied to artifacts: $binary_name"
    done
}

# Helper function to lowercase filenames
lowercase_sources() {
    local dir="${1:-.}"
    find "$dir" -type f \( -name "*.cpp" -o -name "*.c" -o -name "*.h" -o -name "*.hpp" -o -name "*.rc" \) | while read -r file; do
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

    # Patch resource files to use artifacts from previously built dependencies
    patch_resource_files .

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
        -DCMAKE_CXX_FLAGS="-DINITGUID -fpermissive $CFLAGS_CONFIG $EXTRA_FLAGS" \
        -DCMAKE_C_FLAGS="-DINITGUID $CFLAGS_CONFIG $EXTRA_FLAGS" 2>&1 | tee -a /tmp/build.log

    make -j$(nproc) 2>&1 | tee -a /tmp/build.log

    # Copy outputs to shared artifacts directory (for dependent projects)
    copy_to_artifacts .

    # Copy output to final output directory
    mkdir -p "$OUTPUT_DIR/$proj_name"
    find . -name "*.exe" -exec cp {} "$OUTPUT_DIR/$proj_name/" \;
    find . -name "*.dll" -exec cp {} "$OUTPUT_DIR/$proj_name/" \;

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
        -DCMAKE_CXX_FLAGS="-DINITGUID -fpermissive -std=c++11 -Wno-deprecated-declarations -municode -Wno-write-strings -pthread $CFLAGS_CONFIG $EXTRA_FLAGS" \
        -DCMAKE_C_FLAGS="-DINITGUID -Wno-deprecated-declarations -municode $CFLAGS_CONFIG $EXTRA_FLAGS" 2>&1 | tee -a /tmp/build.log

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
        CFLAGS="-DINITGUID $CFLAGS_CONFIG $EXTRA_FLAGS" \
        CXXFLAGS="-DINITGUID -fpermissive -std=c++11 -Wno-deprecated-declarations -municode -Wno-write-strings -pthread $CFLAGS_CONFIG $EXTRA_FLAGS" 2>&1 | tee -a /tmp/build.log

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
        -DCMAKE_CXX_FLAGS="-DINITGUID -fpermissive $CFLAGS_CONFIG $EXTRA_FLAGS" \
        -DCMAKE_C_FLAGS="-DINITGUID $CFLAGS_CONFIG $EXTRA_FLAGS" 2>&1 | tee -a /tmp/build.log

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

        # Get C++ projects in build order (DLLs first, then EXEs)
        VCXPROJ_LIST=$(python3 "$SCRIPTS_DIR/sln_parser.py" "$sln" --cpp-only --build-order --dlls-first 2>/dev/null | \
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

        # Sort projects: DLLs first, then EXEs
        # Use Python to determine project types and sort them
        SORTED_VCXPROJ=$(python3 -c "
import sys
import xml.etree.ElementTree as ET

def get_config_type(path):
    try:
        tree = ET.parse(path)
        root = tree.getroot()
        for elem in root.iter():
            if '}' in elem.tag:
                elem.tag = elem.tag.split('}', 1)[1]
        for elem in root.findall('.//ConfigurationType'):
            if elem.text:
                return elem.text
    except:
        pass
    return 'Application'

projects = '''$VCXPROJ_FILES'''.strip().split()
dll_projects = []
other_projects = []

for proj in projects:
    config_type = get_config_type(proj)
    if config_type == 'DynamicLibrary':
        dll_projects.append(proj)
    else:
        other_projects.append(proj)

# DLLs first, then others
for p in dll_projects + other_projects:
    print(p)
" 2>/dev/null || echo "$VCXPROJ_FILES")

        for vcxproj in $SORTED_VCXPROJ; do
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
