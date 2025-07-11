# DockPiler

A Linux-based Docker container for cloning GitHub repositories containing Windows-targeted C#, C, or C++ source code, compiling them, and delivering the resulting Windows binaries (x64 or x86).

## Overview

This Docker image automates the process of cross-compiling Windows executables from GitHub repositories on Linux or macOS hosts. It supports:

- C# projects (.csproj): Both .NET Framework (v4.0, v4.7.2, v4.8) and modern .NET, producing self-contained executables.
- Visual Studio C++ projects (.vcxproj): Basic cross-compilation using MinGW, with common patches for includes.
- CMake-based C/C++ projects (CMakeLists.txt).
- Makefile-based C/C++ projects (Makefile).
- Simple C/C++ files (no build system): Compiles individual .c/.cpp files recursively.

The image uses Ubuntu 24.04 as the base, MinGW-w64 for C/C++ cross-compilation, and .NET SDK for C# builds. Architecture (x64 or x86) is configurable at runtime.

## Features

- **Automatic Project Detection**: Scans the repository recursively for build files and compiles accordingly.
- **Windows Cross-Compilation**: Produces .exe binaries runnable on Windows (x64 or x86).
- **Architecture Selection**: Default x64; specify x86 as a runtime argument.
- **Output Volume Mounting**: Mount a host directory to retrieve compiled binaries.
- **Error Handling**: Basic detection and messages for unsupported projects or compilation failures.

## Prerequisites

- Docker installed on your Linux or macOS machine.
- A public GitHub repository URL with compilable source code.

## Usage

Run the container with a GitHub URL and optional architecture:

```bash
docker run -v $(pwd)/output:/output dockpiler <github_repo_url> [x64|x86]
```

- `<github_repo_url>`: The URL of the GitHub repository (e.g., https://github.com/GhostPack/Rubeus.git).
- `[x64|x86]`: Optional; defaults to x64.
- The compiled binaries will be placed in `./output` on your host (create the directory if needed).

### Examples

1. Compile a C# project (default x64):

   ```bash
   docker run -v $(pwd)/output:/output dockpiler https://github.com/GhostPack/Rubeus.git
   ```

2. Compile a Visual Studio C++ project for x86:

   ```bash
   docker run -v $(pwd)/output:/output dockpiler https://github.com/decoder-it/LocalPotato.git x86
   ```

3. Compile a CMake-based C++ project:

   ```bash
   docker run -v $(pwd)/output:/output dockpiler https://github.com/example/cmake-project.git
   ```

Binaries will appear in subdirectories under `./output` (e.g., `./output/Rubeus/Rubeus.exe`).

## Limitations

- **Public Repositories Only**: No authentication for private repos.
- **Simple Projects**: May fail on complex dependencies, external libraries, or custom build steps. For C++ projects, additional libraries/flags might be needed.
- **.NET Framework Versions**: Limited to v4.0, v4.7.2, v4.8; add more reference assemblies in the Dockerfile if required.
- **x86 Builds**: Some .NET Framework projects with COM references may still fail on Linux; test on Windows if needed.
- **No Runtime Testing**: Compiles binaries but does not run or test them.
- **Error Handling**: If compilation fails, check container logs for details.

## Contributing

Feel free to fork this repository, add support for more project types or frameworks, and submit a pull request.