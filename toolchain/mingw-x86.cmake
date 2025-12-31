# CMake toolchain file for cross-compiling to Windows x86 (32-bit) using MinGW-w64
# Usage: cmake -DCMAKE_TOOLCHAIN_FILE=/path/to/mingw-x86.cmake ..

set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR i686)

# Toolchain prefix
set(TOOLCHAIN_PREFIX i686-w64-mingw32)

# Cross compilers
set(CMAKE_C_COMPILER ${TOOLCHAIN_PREFIX}-gcc)
set(CMAKE_CXX_COMPILER ${TOOLCHAIN_PREFIX}-g++)
set(CMAKE_RC_COMPILER ${TOOLCHAIN_PREFIX}-windres)
set(CMAKE_AR ${TOOLCHAIN_PREFIX}-ar)
set(CMAKE_RANLIB ${TOOLCHAIN_PREFIX}-ranlib)
set(CMAKE_STRIP ${TOOLCHAIN_PREFIX}-strip)

# Target environment
set(CMAKE_FIND_ROOT_PATH /usr/${TOOLCHAIN_PREFIX})

# Search paths for programs, libraries, and headers
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Default compiler flags for Windows cross-compilation
# Use -static to link all libraries statically (no DLL dependencies)
# -DINITGUID: Instantiate COM GUIDs (required for many Windows COM projects)
# -fpermissive: Allow MSVC-style code to compile (relaxes strict C++ checking)
set(CMAKE_C_FLAGS_INIT "-DWIN32 -D_WIN32 -D_WINDOWS -DUNICODE -D_UNICODE -DINITGUID -static")
set(CMAKE_CXX_FLAGS_INIT "-DWIN32 -D_WIN32 -D_WINDOWS -DUNICODE -D_UNICODE -DINITGUID -fpermissive -static")

# Static linking for GCC runtime libraries (libgcc, libstdc++)
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static -static-libgcc -static-libstdc++")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-static-libgcc -static-libstdc++")

# Ensure .exe suffix
set(CMAKE_EXECUTABLE_SUFFIX ".exe")
set(CMAKE_SHARED_LIBRARY_SUFFIX ".dll")
set(CMAKE_STATIC_LIBRARY_SUFFIX ".a")

# Resource compiler flags
set(CMAKE_RC_FLAGS "-O coff")

# Disable RPATH (not applicable for Windows)
set(CMAKE_SKIP_RPATH TRUE)

# Additional search paths for libraries
list(APPEND CMAKE_LIBRARY_PATH /usr/${TOOLCHAIN_PREFIX}/lib)
list(APPEND CMAKE_INCLUDE_PATH /usr/${TOOLCHAIN_PREFIX}/include)
