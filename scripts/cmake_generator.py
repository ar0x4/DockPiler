#!/usr/bin/env python3
"""
cmake_generator.py - Generate CMakeLists.txt from parsed Visual Studio project data

Creates CMake build files optimized for MinGW cross-compilation.
"""

import os
import json
import argparse
from pathlib import Path
from typing import Dict, List, Optional, Set

# Import the library mapper
try:
    from library_mapper import LibraryMapper
except ImportError:
    LibraryMapper = None


class CMakeGenerator:
    """Generate CMakeLists.txt from parsed project data."""

    # MSVC to GCC flag mapping
    MSVC_TO_GCC_FLAGS = {
        '/W0': '-w',
        '/W1': '-Wall',
        '/W2': '-Wall',
        '/W3': '-Wall',
        '/W4': '-Wall -Wextra',
        '/WX': '-Werror',
        '/Od': '-O0',
        '/O1': '-O1',
        '/O2': '-O2',
        '/Ox': '-O3',
        '/GS-': '',  # No stack protector equivalent (MinGW default)
        '/GS': '-fstack-protector',
        '/Gy': '-ffunction-sections',
        '/GL': '-flto',
        '/MT': '-static',
        '/MTd': '-static',
        '/MD': '',  # Dynamic linking (default)
        '/MDd': '',
        '/EHsc': '-fexceptions',
        '/EHa': '-fexceptions',
        '/Zi': '-g',
        '/ZI': '-g',
        '/RTC1': '',  # No direct equivalent
        '/fp:fast': '-ffast-math',
        '/fp:precise': '',
        '/fp:strict': '-frounding-math',
        '/Gd': '',  # __cdecl is default
        '/Gr': '-mrtd',  # __fastcall
        '/Gz': '-mstackrealign',  # __stdcall
        '/permissive-': '-fpermissive',
        '/std:c++14': '-std=c++14',
        '/std:c++17': '-std=c++17',
        '/std:c++20': '-std=c++20',
        '/std:c++latest': '-std=c++20',
        '/Zc:wchar_t': '',  # Default behavior
        '/Zc:forScope': '',  # Default behavior
        '/Zc:inline': '',  # Default behavior
    }

    # Definitions to skip (MSVC-specific or problematic)
    SKIP_DEFINITIONS = {
        '_MBCS', '_AFXDLL', '_ATL_DLL', 'VC_EXTRALEAN',
        '_CRT_SECURE_NO_WARNINGS', '_SCL_SECURE_NO_WARNINGS',
        '_CRT_NONSTDC_NO_DEPRECATE', '_CRT_SECURE_NO_DEPRECATE',
    }

    def __init__(self, project_data: Dict, library_mapper: Optional['LibraryMapper'] = None):
        self.data = project_data
        self.project_name = project_data.get('project_name', 'project')
        self.library_mapper = library_mapper

    def _convert_msvc_flag(self, flag: str) -> Optional[str]:
        """Convert MSVC compiler flag to GCC equivalent."""
        flag = flag.strip()

        # Direct mapping
        if flag in self.MSVC_TO_GCC_FLAGS:
            return self.MSVC_TO_GCC_FLAGS[flag]

        # Handle /D definitions
        if flag.startswith('/D'):
            return f'-D{flag[2:]}'
        if flag.startswith('-D'):
            return flag

        # Handle /I include paths
        if flag.startswith('/I'):
            return f'-I{flag[2:]}'
        if flag.startswith('-I'):
            return flag

        # Handle warning disable
        if flag.startswith('/wd'):
            # Can't easily map specific MSVC warnings to GCC
            return None

        # Ignore unknown MSVC flags
        if flag.startswith('/'):
            return None

        return flag

    def _filter_definitions(self, definitions: List[str]) -> List[str]:
        """Filter out problematic or MSVC-specific definitions."""
        result = []
        for defn in definitions:
            # Skip certain definitions
            if defn in self.SKIP_DEFINITIONS:
                continue

            # Keep the definition
            result.append(defn)

        return result

    def _get_libraries(self) -> List[str]:
        """Get library list, mapping Windows names to MinGW."""
        libs = set()

        # From project data
        for lib in self.data.get('additional_libraries', []):
            if self.library_mapper:
                mapped = self.library_mapper.map_library(lib)
                if mapped:
                    libs.add(mapped)
            else:
                # Simple mapping: remove .lib extension
                lib_name = lib.replace('.lib', '').replace('.Lib', '').replace('.LIB', '')
                libs.add(lib_name)

        # Add default Windows libraries
        default_libs = [
            'kernel32', 'user32', 'gdi32', 'winspool', 'comdlg32',
            'advapi32', 'shell32', 'ole32', 'oleaut32', 'uuid',
            'odbc32', 'odbccp32', 'ws2_32', 'crypt32', 'secur32',
            'rpcrt4', 'ntdll', 'shlwapi', 'version', 'psapi',
            'userenv', 'wtsapi32', 'netapi32'
        ]

        for lib in default_libs:
            libs.add(lib)

        return sorted(list(libs))

    def _get_compile_definitions(self) -> List[str]:
        """Get preprocessor definitions."""
        definitions = self._filter_definitions(
            self.data.get('preprocessor_definitions', [])
        )

        # Ensure essential Windows definitions
        essential = ['WIN32', '_WINDOWS', 'UNICODE', '_UNICODE', 'SECURITY_WIN32', 'GUID_NULL=IID_NULL']

        config = self.data.get('config', 'Release')
        if config == 'Debug':
            essential.extend(['_DEBUG', 'DEBUG'])
        else:
            essential.append('NDEBUG')

        for defn in essential:
            if defn not in definitions:
                definitions.append(defn)

        return definitions

    def _get_compile_options(self) -> List[str]:
        """Get compiler options/flags."""
        options = []

        # Convert MSVC flags from project
        for flag in self.data.get('additional_options', []):
            converted = self._convert_msvc_flag(flag)
            if converted:
                options.append(converted)

        # Add standard MinGW flags for Windows cross-compilation
        standard_flags = [
            '-Wno-deprecated-declarations',
            '-Wno-write-strings',
            '-municode',
            '-fno-strict-aliasing',
            '-fms-extensions',  # MSVC compatibility
            '-Wno-expansion-to-defined',
        ]

        for flag in standard_flags:
            if flag not in options:
                options.append(flag)

        # Add optimization from project
        optimization = self.data.get('optimization', '-O2')
        if optimization and optimization not in options:
            options.append(optimization)

        # Debug symbols
        config = self.data.get('config', 'Release')
        if config == 'Debug' and '-g' not in options:
            options.append('-g')

        return options

    def _detect_wide_entry_point(self) -> bool:
        """Detect if source files use wide-character entry point (wmain/wWinMain)."""
        import re
        source_files = self.data.get('source_files', [])
        project_dir = self.data.get('project_dir', '.')

        for src in source_files:
            src_path = Path(project_dir) / src.replace('\\', '/')
            # Try lowercase version too
            if not src_path.exists():
                src_path = Path(project_dir) / src.replace('\\', '/').lower()
            if src_path.exists():
                try:
                    content = src_path.read_text(errors='ignore')
                    # Look for wmain or wWinMain function definitions
                    # Match patterns like: int wmain(, wmain(int, wWinMain(HINSTANCE, etc.
                    if re.search(r'\bwmain\s*\(', content) or re.search(r'\bwWinMain\s*\(', content):
                        return True
                except Exception:
                    pass
        return False

    def _get_link_options(self) -> List[str]:
        """Get linker options."""
        options = []

        # Subsystem
        subsystem = self.data.get('subsystem', 'Console').lower()
        if 'console' in subsystem:
            options.append('-mconsole')
        elif 'windows' in subsystem:
            options.append('-mwindows')

        # Add -municode only if wide-character entry point is detected
        if self._detect_wide_entry_point():
            options.append('-municode')

        # Static linking option
        runtime = self.data.get('runtime_library', '')
        if 'MultiThreaded' in runtime and 'DLL' not in runtime:
            options.append('-static')
            options.append('-static-libgcc')
            options.append('-static-libstdc++')

        return options

    def _get_include_directories(self) -> List[str]:
        """Get include directories."""
        includes = self.data.get('include_directories', [])

        # Add current directory
        if '.' not in includes:
            includes = ['.'] + includes

        # Add mingw_stubs directory if it exists (for stub headers)
        if 'mingw_stubs' not in includes:
            includes.append('mingw_stubs')

        return includes

    def _get_source_files(self) -> List[str]:
        """Get source files, converting paths to lowercase for case-insensitive matching."""
        sources = []

        for src in self.data.get('source_files', []):
            # Convert backslashes to forward slashes
            src = src.replace('\\', '/')
            # Lowercase the filename (since we lowercase source files during preprocessing)
            parts = src.rsplit('/', 1)
            if len(parts) == 2:
                src = parts[0] + '/' + parts[1].lower()
            else:
                src = src.lower()
            sources.append(src)

        return sources

    def _get_c_source_files(self) -> List[str]:
        """Get C source files (.c) only."""
        sources = []

        # First try explicit c_source_files from parser
        c_files = self.data.get('c_source_files', [])
        if c_files:
            for src in c_files:
                src = src.replace('\\', '/')
                parts = src.rsplit('/', 1)
                if len(parts) == 2:
                    src = parts[0] + '/' + parts[1].lower()
                else:
                    src = src.lower()
                sources.append(src)
        else:
            # Fallback: filter from all source files
            for src in self.data.get('source_files', []):
                src = src.replace('\\', '/')
                if src.lower().endswith('.c'):
                    parts = src.rsplit('/', 1)
                    if len(parts) == 2:
                        src = parts[0] + '/' + parts[1].lower()
                    else:
                        src = src.lower()
                    sources.append(src)

        return sources

    def _get_cpp_source_files(self) -> List[str]:
        """Get C++ source files (.cpp, .cxx, .cc) only."""
        sources = []
        cpp_extensions = ('.cpp', '.cxx', '.cc', '.c++')

        # First try explicit cpp_source_files from parser
        cpp_files = self.data.get('cpp_source_files', [])
        if cpp_files:
            for src in cpp_files:
                src = src.replace('\\', '/')
                parts = src.rsplit('/', 1)
                if len(parts) == 2:
                    src = parts[0] + '/' + parts[1].lower()
                else:
                    src = src.lower()
                sources.append(src)
        else:
            # Fallback: filter from all source files
            for src in self.data.get('source_files', []):
                src = src.replace('\\', '/')
                if src.lower().endswith(cpp_extensions):
                    parts = src.rsplit('/', 1)
                    if len(parts) == 2:
                        src = parts[0] + '/' + parts[1].lower()
                    else:
                        src = src.lower()
                    sources.append(src)

        return sources

    def _has_mixed_sources(self) -> bool:
        """Check if project has both C and C++ source files."""
        c_sources = self._get_c_source_files()
        cpp_sources = self._get_cpp_source_files()
        return len(c_sources) > 0 and len(cpp_sources) > 0

    def _get_resource_files(self) -> List[str]:
        """Get resource files."""
        resources = []

        for rc in self.data.get('resource_files', []):
            rc = rc.replace('\\', '/')
            # Lowercase the filename
            parts = rc.rsplit('/', 1)
            if len(parts) == 2:
                rc = parts[0] + '/' + parts[1].lower()
            else:
                rc = rc.lower()
            resources.append(rc)

        return resources

    def _get_c_compile_options(self) -> List[str]:
        """Get compiler options specific to C files."""
        options = []

        # Add standard MinGW flags for Windows cross-compilation (C compatible)
        standard_flags = [
            '-Wno-deprecated-declarations',
            '-fno-strict-aliasing',
            '-fms-extensions',  # MSVC compatibility
        ]

        for flag in standard_flags:
            if flag not in options:
                options.append(flag)

        # Add optimization from project
        optimization = self.data.get('optimization', '-O2')
        if optimization and optimization not in options:
            options.append(optimization)

        # Debug symbols
        config = self.data.get('config', 'Release')
        if config == 'Debug' and '-g' not in options:
            options.append('-g')

        return options

    def _get_cpp_compile_options(self) -> List[str]:
        """Get compiler options specific to C++ files."""
        options = []

        # Convert MSVC flags from project
        for flag in self.data.get('additional_options', []):
            converted = self._convert_msvc_flag(flag)
            if converted:
                options.append(converted)

        # Add standard MinGW flags for Windows cross-compilation
        standard_flags = [
            '-Wno-deprecated-declarations',
            '-Wno-write-strings',
            '-fno-strict-aliasing',
            '-fms-extensions',  # MSVC compatibility
            '-Wno-expansion-to-defined',
        ]

        for flag in standard_flags:
            if flag not in options:
                options.append(flag)

        # Add optimization from project
        optimization = self.data.get('optimization', '-O2')
        if optimization and optimization not in options:
            options.append(optimization)

        # Debug symbols
        config = self.data.get('config', 'Release')
        if config == 'Debug' and '-g' not in options:
            options.append('-g')

        return options

    def generate(self) -> str:
        """Generate CMakeLists.txt content."""
        lines = []

        # Check if this is a mixed C/C++ project
        c_sources = self._get_c_source_files()
        cpp_sources = self._get_cpp_source_files()
        has_c = len(c_sources) > 0
        has_cpp = len(cpp_sources) > 0
        is_mixed = has_c and has_cpp

        # Header
        lines.append('# Auto-generated CMakeLists.txt by DockPiler')
        lines.append('# Project: ' + self.project_name)
        if is_mixed:
            lines.append('# Mixed C/C++ project detected')
        lines.append('')
        lines.append('cmake_minimum_required(VERSION 3.10)')

        # Enable both C and C++ languages for mixed projects
        if is_mixed:
            lines.append(f'project({self.project_name} LANGUAGES C CXX)')
        elif has_c and not has_cpp:
            lines.append(f'project({self.project_name} LANGUAGES C)')
        else:
            lines.append(f'project({self.project_name})')
        lines.append('')

        # Language standards
        if has_cpp:
            cpp_std = self.data.get('cpp_standard', 'c++11')
            cpp_std_num = cpp_std.replace('c++', '')
            lines.append(f'set(CMAKE_CXX_STANDARD {cpp_std_num})')
            lines.append('set(CMAKE_CXX_STANDARD_REQUIRED ON)')

        if has_c:
            lines.append('set(CMAKE_C_STANDARD 11)')
            lines.append('set(CMAKE_C_STANDARD_REQUIRED ON)')

        lines.append('')

        # Source files - handle mixed projects differently
        if is_mixed:
            # Separate C and C++ sources
            lines.append('# C source files')
            lines.append('set(SOURCES_C')
            for src in c_sources:
                lines.append(f'    {src}')
            lines.append(')')
            lines.append('')

            lines.append('# C++ source files')
            lines.append('set(SOURCES_CXX')
            for src in cpp_sources:
                lines.append(f'    {src}')
            lines.append(')')
            lines.append('')

            # Combined sources for target
            lines.append('# All source files')
            lines.append('set(SOURCES ${SOURCES_C} ${SOURCES_CXX})')
            lines.append('')

            # Add any generated IID definition files (for MIDL-generated COM interfaces)
            lines.append('# Auto-generated IID definition files')
            lines.append('file(GLOB IID_SOURCES "*_iid.c")')
            lines.append('list(APPEND SOURCES ${IID_SOURCES})')
            lines.append('list(APPEND SOURCES_C ${IID_SOURCES})')
            lines.append('')
        else:
            # Single language project
            sources = self._get_source_files()
            if sources:
                lines.append('# Source files')
                lines.append('set(SOURCES')
                for src in sources:
                    lines.append(f'    {src}')
                lines.append(')')
                lines.append('')
                # Add any generated IID definition files (for MIDL-generated COM interfaces)
                lines.append('# Auto-generated IID definition files')
                lines.append('file(GLOB IID_SOURCES "*_iid.c")')
                lines.append('list(APPEND SOURCES ${IID_SOURCES})')
                lines.append('')

        # Resource files
        resources = self._get_resource_files()
        if resources:
            lines.append('# Resource files')
            lines.append('set(RESOURCES')
            for rc in resources:
                lines.append(f'    {rc}')
            lines.append(')')
            lines.append('')

        # Determine output type (Application, DynamicLibrary, StaticLibrary)
        config_type = self.data.get('configuration_type', 'Application')
        is_dll = config_type == 'DynamicLibrary'
        is_static_lib = config_type == 'StaticLibrary'

        # Create target based on type
        sources_exist = (c_sources or cpp_sources) if is_mixed else self._get_source_files()
        if is_dll:
            lines.append('# Create shared library (DLL)')
            if resources and sources_exist:
                lines.append(f'add_library({self.project_name} SHARED ${{SOURCES}} ${{RESOURCES}})')
            elif sources_exist:
                lines.append(f'add_library({self.project_name} SHARED ${{SOURCES}})')
            else:
                lines.append('file(GLOB_RECURSE SOURCES "*.cpp" "*.c")')
                lines.append('file(GLOB_RECURSE RESOURCES "*.rc")')
                lines.append(f'add_library({self.project_name} SHARED ${{SOURCES}} ${{RESOURCES}})')
        elif is_static_lib:
            lines.append('# Create static library')
            if sources_exist:
                lines.append(f'add_library({self.project_name} STATIC ${{SOURCES}})')
            else:
                lines.append('file(GLOB_RECURSE SOURCES "*.cpp" "*.c")')
                lines.append(f'add_library({self.project_name} STATIC ${{SOURCES}})')
        else:
            lines.append('# Create executable')
            if resources and sources_exist:
                lines.append(f'add_executable({self.project_name} ${{SOURCES}} ${{RESOURCES}})')
            elif sources_exist:
                lines.append(f'add_executable({self.project_name} ${{SOURCES}})')
            else:
                # Fallback: glob for sources
                lines.append('file(GLOB_RECURSE SOURCES "*.cpp" "*.c")')
                lines.append('file(GLOB_RECURSE RESOURCES "*.rc")')
                lines.append(f'add_executable({self.project_name} ${{SOURCES}} ${{RESOURCES}})')
        lines.append('')

        # Include directories
        includes = self._get_include_directories()
        if includes:
            lines.append('# Include directories')
            lines.append(f'target_include_directories({self.project_name} PRIVATE')
            for inc in includes:
                lines.append(f'    {inc}')
            lines.append(')')
            lines.append('')

        # Compile definitions (apply to all sources)
        definitions = self._get_compile_definitions()
        if definitions:
            lines.append('# Preprocessor definitions')
            lines.append(f'target_compile_definitions({self.project_name} PRIVATE')
            for defn in definitions:
                lines.append(f'    {defn}')
            lines.append(')')
            lines.append('')

        # Compile options - handle mixed projects with language-specific flags
        if is_mixed:
            # C-specific compile options
            c_options = self._get_c_compile_options()
            if c_options:
                lines.append('# C compiler options')
                lines.append(f'set_source_files_properties(${{SOURCES_C}} PROPERTIES COMPILE_OPTIONS')
                lines.append(f'    "{";".join(c_options)}"')
                lines.append(')')
                lines.append('')

            # C++-specific compile options
            cpp_options = self._get_cpp_compile_options()
            if cpp_options:
                lines.append('# C++ compiler options')
                lines.append(f'set_source_files_properties(${{SOURCES_CXX}} PROPERTIES COMPILE_OPTIONS')
                lines.append(f'    "{";".join(cpp_options)}"')
                lines.append(')')
                lines.append('')

            # Add -municode only to C++ files if wide entry point detected
            if self._detect_wide_entry_point():
                lines.append('# Unicode entry point (C++ only)')
                lines.append('set_source_files_properties(${SOURCES_CXX} PROPERTIES')
                lines.append('    COMPILE_FLAGS "-municode"')
                lines.append(')')
                lines.append('')
        else:
            # Single language project - apply options to target
            options = self._get_compile_options()
            if options:
                lines.append('# Compiler options')
                lines.append(f'target_compile_options({self.project_name} PRIVATE')
                for opt in options:
                    lines.append(f'    {opt}')
                lines.append(')')
                lines.append('')

        # Link options
        link_options = self._get_link_options()
        if link_options:
            lines.append('# Linker options')
            lines.append(f'target_link_options({self.project_name} PRIVATE')
            for opt in link_options:
                lines.append(f'    {opt}')
            lines.append(')')
            lines.append('')

        # Libraries
        libraries = self._get_libraries()
        if libraries:
            lines.append('# Link libraries')
            lines.append(f'target_link_libraries({self.project_name}')
            for lib in libraries:
                lines.append(f'    {lib}')
            lines.append(')')
            lines.append('')

        # Output name (set appropriate suffix based on type)
        lines.append('# Output settings')
        lines.append(f'set_target_properties({self.project_name} PROPERTIES')
        lines.append(f'    OUTPUT_NAME "{self.project_name}"')
        if is_dll:
            lines.append('    SUFFIX ".dll"')
            lines.append('    PREFIX ""')  # No 'lib' prefix for DLLs
        elif is_static_lib:
            lines.append('    SUFFIX ".lib"')
            lines.append('    PREFIX ""')  # No 'lib' prefix
        else:
            lines.append('    SUFFIX ".exe"')
        lines.append(')')
        lines.append('')

        return '\n'.join(lines)


def generate_from_vcxproj(vcxproj_path: str, config: str = 'Release',
                          platform: str = 'x64') -> str:
    """Generate CMakeLists.txt from a .vcxproj file."""
    from vcxproj_parser import VcxprojParser

    parser = VcxprojParser(vcxproj_path)
    data = parser.parse_all(config, platform)

    # Try to use library mapper
    mapper = None
    if LibraryMapper:
        mapper = LibraryMapper()

    generator = CMakeGenerator(data, mapper)
    return generator.generate()


def generate_from_json(json_data: Dict) -> str:
    """Generate CMakeLists.txt from JSON project data."""
    mapper = None
    if LibraryMapper:
        mapper = LibraryMapper()

    generator = CMakeGenerator(json_data, mapper)
    return generator.generate()


def generate_fallback(project_name: str, project_dir: str,
                      config: str = 'Release') -> str:
    """Generate fallback CMakeLists.txt for projects without vcxproj."""
    data = {
        'project_name': project_name,
        'project_dir': project_dir,
        'config': config,
        'platform': 'x64',
        'cpp_standard': 'c++11',
        'source_files': [],  # Will use GLOB
        'preprocessor_definitions': [],
        'include_directories': ['.'],
        'additional_libraries': [],
        'subsystem': 'Console',
    }

    generator = CMakeGenerator(data)
    return generator.generate()


def main():
    parser = argparse.ArgumentParser(description='Generate CMakeLists.txt from Visual Studio project')
    parser.add_argument('input', nargs='?', help='Path to .vcxproj file or JSON data file')
    parser.add_argument('-c', '--config', default='Release', help='Build configuration')
    parser.add_argument('-p', '--platform', default='x64', help='Target platform')
    parser.add_argument('-o', '--output', help='Output CMakeLists.txt path (default: stdout)')
    parser.add_argument('-n', '--name', help='Project name (for fallback generation)')
    parser.add_argument('-d', '--directory', default='.', help='Project directory (for fallback)')
    parser.add_argument('--json', action='store_true', help='Input is JSON file')

    args = parser.parse_args()

    try:
        if args.input:
            if args.json or args.input.endswith('.json'):
                with open(args.input, 'r') as f:
                    data = json.load(f)
                cmake_content = generate_from_json(data)
            else:
                cmake_content = generate_from_vcxproj(args.input, args.config, args.platform)
        else:
            # Fallback generation
            name = args.name or os.path.basename(os.path.abspath(args.directory))
            cmake_content = generate_fallback(name, args.directory, args.config)

        if args.output:
            with open(args.output, 'w') as f:
                f.write(cmake_content)
            print(f"Generated: {args.output}")
        else:
            print(cmake_content)

    except Exception as e:
        print(f"Error: {e}", file=__import__('sys').stderr)
        __import__('sys').exit(1)


if __name__ == '__main__':
    main()
