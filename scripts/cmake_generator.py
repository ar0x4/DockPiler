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
            'rpcrt4', 'ntdll', 'shlwapi', 'version', 'psapi'
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
        essential = ['WIN32', '_WINDOWS', 'UNICODE', '_UNICODE', 'SECURITY_WIN32']

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

    def _get_link_options(self) -> List[str]:
        """Get linker options."""
        options = []

        # Unicode support (for wmain entry point)
        options.append('-municode')

        # Subsystem
        subsystem = self.data.get('subsystem', 'Console').lower()
        if 'console' in subsystem:
            options.append('-mconsole')
        elif 'windows' in subsystem:
            options.append('-mwindows')

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

    def generate(self) -> str:
        """Generate CMakeLists.txt content."""
        lines = []

        # Header
        lines.append('# Auto-generated CMakeLists.txt by DockPiler')
        lines.append('# Project: ' + self.project_name)
        lines.append('')
        lines.append('cmake_minimum_required(VERSION 3.10)')
        lines.append(f'project({self.project_name})')
        lines.append('')

        # C++ standard
        cpp_std = self.data.get('cpp_standard', 'c++11')
        cpp_std_num = cpp_std.replace('c++', '')
        lines.append(f'set(CMAKE_CXX_STANDARD {cpp_std_num})')
        lines.append('set(CMAKE_CXX_STANDARD_REQUIRED ON)')
        lines.append('')

        # Source files
        sources = self._get_source_files()
        if sources:
            lines.append('# Source files')
            lines.append('set(SOURCES')
            for src in sources:
                lines.append(f'    {src}')
            lines.append(')')
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

        # Executable
        lines.append('# Create executable')
        if resources:
            lines.append(f'add_executable({self.project_name} ${{SOURCES}} ${{RESOURCES}})')
        elif sources:
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

        # Compile definitions
        definitions = self._get_compile_definitions()
        if definitions:
            lines.append('# Preprocessor definitions')
            lines.append(f'target_compile_definitions({self.project_name} PRIVATE')
            for defn in definitions:
                # Handle definitions with values
                if '=' in defn:
                    lines.append(f'    {defn}')
                else:
                    lines.append(f'    {defn}')
            lines.append(')')
            lines.append('')

        # Compile options
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

        # Output name (ensure .exe suffix)
        lines.append('# Output settings')
        lines.append(f'set_target_properties({self.project_name} PROPERTIES')
        lines.append(f'    OUTPUT_NAME "{self.project_name}"')
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
