#!/usr/bin/env python3
"""
vcxproj_parser.py - Parse Visual Studio C++ project files (.vcxproj)

Extracts compiler settings, preprocessor definitions, include directories,
source files, resource files, and library dependencies.
"""

import xml.etree.ElementTree as ET
import os
import re
import json
import argparse
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple


class VcxprojParser:
    """Parser for Visual Studio .vcxproj files."""

    MSBUILD_NS = {'ms': 'http://schemas.microsoft.com/developer/msbuild/2003'}

    def __init__(self, vcxproj_path: str):
        self.vcxproj_path = Path(vcxproj_path)
        self.project_dir = self.vcxproj_path.parent
        self.tree = ET.parse(vcxproj_path)
        self.root = self.tree.getroot()

        # Remove namespace prefix for easier parsing
        self._strip_namespace()

    def _strip_namespace(self):
        """Remove namespace prefixes from all elements."""
        for elem in self.root.iter():
            if '}' in elem.tag:
                elem.tag = elem.tag.split('}', 1)[1]
            for attr in list(elem.attrib):
                if '}' in attr:
                    new_attr = attr.split('}', 1)[1]
                    elem.attrib[new_attr] = elem.attrib.pop(attr)

    def _get_condition_match(self, condition: str, config: str, platform: str) -> bool:
        """Check if a condition matches the target configuration and platform."""
        if not condition:
            return True

        # Handle various condition formats
        config_pattern = f"'{config}|{platform}'"
        config_pattern_alt = f"'{config}\\|{platform}'"

        condition_lower = condition.lower()
        target = f"'{config.lower()}|{platform.lower()}'"

        return target in condition_lower or config.lower() in condition_lower

    def _find_elements_for_config(self, tag_path: str, config: str, platform: str) -> List[ET.Element]:
        """Find all elements matching tag path for a specific configuration."""
        results = []

        # Search in ItemDefinitionGroup with matching condition
        for item_def_group in self.root.findall('.//ItemDefinitionGroup'):
            condition = item_def_group.get('Condition', '')
            if self._get_condition_match(condition, config, platform):
                for elem in item_def_group.findall(f'.//{tag_path}'):
                    results.append(elem)

        # Also search in PropertyGroup with matching condition
        for prop_group in self.root.findall('.//PropertyGroup'):
            condition = prop_group.get('Condition', '')
            if self._get_condition_match(condition, config, platform):
                for elem in prop_group.findall(f'.//{tag_path}'):
                    results.append(elem)

        # Search global (no condition)
        for elem in self.root.findall(f'.//{tag_path}'):
            parent = self._get_parent(elem)
            if parent is not None:
                condition = parent.get('Condition', '')
                if not condition:  # No condition means it applies globally
                    if elem not in results:
                        results.append(elem)

        return results

    def _get_parent(self, element: ET.Element) -> Optional[ET.Element]:
        """Get parent element (ElementTree doesn't have parent reference)."""
        parent_map = {c: p for p in self.root.iter() for c in p}
        return parent_map.get(element)

    def _expand_macros(self, value: str) -> str:
        """Expand common MSBuild macros."""
        if not value:
            return value

        macros = {
            '$(ProjectDir)': str(self.project_dir) + '/',
            '$(SolutionDir)': str(self.project_dir.parent) + '/',
            '$(Configuration)': 'Release',
            '$(Platform)': 'x64',
            '$(IntDir)': 'build/',
            '$(OutDir)': 'build/',
            '$(TargetName)': self.get_project_name(),
            '$(ProjectName)': self.get_project_name(),
        }

        result = value
        for macro, replacement in macros.items():
            result = result.replace(macro, replacement)

        # Remove any remaining unresolved macros
        result = re.sub(r'\$\([^)]+\)', '', result)

        return result

    def get_project_name(self) -> str:
        """Get project name from file or ProjectName element."""
        name_elem = self.root.find('.//ProjectName')
        if name_elem is not None and name_elem.text:
            return name_elem.text

        root_ns = self.root.find('.//RootNamespace')
        if root_ns is not None and root_ns.text:
            return root_ns.text

        return self.vcxproj_path.stem

    def get_configurations(self) -> List[Tuple[str, str]]:
        """Get all available configuration/platform combinations."""
        configs = []

        for item in self.root.findall('.//ProjectConfiguration'):
            config = item.find('Configuration')
            platform = item.find('Platform')
            if config is not None and platform is not None:
                configs.append((config.text, platform.text))

        if not configs:
            # Default configurations
            configs = [('Debug', 'Win32'), ('Debug', 'x64'),
                      ('Release', 'Win32'), ('Release', 'x64')]

        return configs

    def get_preprocessor_definitions(self, config: str = 'Release', platform: str = 'x64') -> List[str]:
        """Extract preprocessor definitions for a configuration."""
        definitions = set()

        elements = self._find_elements_for_config('PreprocessorDefinitions', config, platform)

        for elem in elements:
            if elem.text:
                text = self._expand_macros(elem.text)
                for defn in text.split(';'):
                    defn = defn.strip()
                    if defn and defn != '%(PreprocessorDefinitions)':
                        definitions.add(defn)

        # Add common Windows definitions if not present
        common_defs = ['WIN32', '_WINDOWS', 'UNICODE', '_UNICODE']
        if config == 'Debug':
            common_defs.extend(['_DEBUG', 'DEBUG'])
        else:
            common_defs.append('NDEBUG')

        for d in common_defs:
            if d not in definitions and f'_{d}' not in definitions:
                definitions.add(d)

        return sorted(list(definitions))

    def get_include_directories(self, config: str = 'Release', platform: str = 'x64') -> List[str]:
        """Extract additional include directories."""
        includes = set()

        elements = self._find_elements_for_config('AdditionalIncludeDirectories', config, platform)

        for elem in elements:
            if elem.text:
                text = self._expand_macros(elem.text)
                for inc in text.split(';'):
                    inc = inc.strip()
                    if inc and inc != '%(AdditionalIncludeDirectories)':
                        # Convert to relative path
                        inc = inc.replace('\\', '/')
                        includes.add(inc)

        return sorted(list(includes))

    def get_source_files(self) -> List[str]:
        """Get all C/C++ source files."""
        sources = []

        for item in self.root.findall('.//ClCompile'):
            include = item.get('Include')
            if include:
                # Convert Windows path to Unix
                path = include.replace('\\', '/')
                sources.append(path)

        return sources

    def get_header_files(self) -> List[str]:
        """Get all header files."""
        headers = []

        for item in self.root.findall('.//ClInclude'):
            include = item.get('Include')
            if include:
                path = include.replace('\\', '/')
                headers.append(path)

        return headers

    def get_resource_files(self) -> List[str]:
        """Get all resource files (.rc)."""
        resources = []

        for item in self.root.findall('.//ResourceCompile'):
            include = item.get('Include')
            if include:
                path = include.replace('\\', '/')
                resources.append(path)

        # Also check for .rc in None elements
        for item in self.root.findall('.//None'):
            include = item.get('Include', '')
            if include.lower().endswith('.rc'):
                path = include.replace('\\', '/')
                resources.append(path)

        return resources

    def get_additional_libraries(self, config: str = 'Release', platform: str = 'x64') -> List[str]:
        """Extract additional library dependencies."""
        libraries = set()

        elements = self._find_elements_for_config('AdditionalDependencies', config, platform)

        for elem in elements:
            if elem.text:
                text = self._expand_macros(elem.text)
                for lib in text.split(';'):
                    lib = lib.strip()
                    if lib and lib != '%(AdditionalDependencies)':
                        # Remove .lib extension for MinGW compatibility
                        lib = re.sub(r'\.lib$', '', lib, flags=re.IGNORECASE)
                        libraries.add(lib)

        return sorted(list(libraries))

    def get_additional_options(self, config: str = 'Release', platform: str = 'x64') -> List[str]:
        """Extract additional compiler options."""
        options = []

        elements = self._find_elements_for_config('AdditionalOptions', config, platform)

        for elem in elements:
            if elem.text:
                text = self._expand_macros(elem.text)
                # Split by space but preserve quoted strings
                parts = re.findall(r'[^\s"]+|"[^"]*"', text)
                for part in parts:
                    part = part.strip()
                    if part and part != '%(AdditionalOptions)':
                        options.append(part)

        return options

    def get_runtime_library(self, config: str = 'Release', platform: str = 'x64') -> str:
        """Get runtime library setting (MT, MTd, MD, MDd)."""
        elements = self._find_elements_for_config('RuntimeLibrary', config, platform)

        for elem in elements:
            if elem.text:
                return elem.text

        return 'MultiThreadedDLL' if config == 'Release' else 'MultiThreadedDebugDLL'

    def get_subsystem(self, config: str = 'Release', platform: str = 'x64') -> str:
        """Get application subsystem (Console, Windows)."""
        elements = self._find_elements_for_config('SubSystem', config, platform)

        for elem in elements:
            if elem.text:
                return elem.text

        return 'Console'

    def get_character_set(self) -> str:
        """Get character set setting."""
        elem = self.root.find('.//CharacterSet')
        if elem is not None and elem.text:
            return elem.text
        return 'Unicode'

    def get_cpp_standard(self, config: str = 'Release', platform: str = 'x64') -> str:
        """Get C++ language standard."""
        elements = self._find_elements_for_config('LanguageStandard', config, platform)

        for elem in elements:
            if elem.text:
                # Convert MSVC format to standard format
                std = elem.text.lower()
                if 'c++17' in std or 'stdcpp17' in std:
                    return 'c++17'
                elif 'c++14' in std or 'stdcpp14' in std:
                    return 'c++14'
                elif 'c++20' in std or 'stdcpp20' in std:
                    return 'c++20'
                elif 'latest' in std:
                    return 'c++20'

        return 'c++11'  # Default

    def get_warning_level(self, config: str = 'Release', platform: str = 'x64') -> int:
        """Get warning level."""
        elements = self._find_elements_for_config('WarningLevel', config, platform)

        for elem in elements:
            if elem.text:
                match = re.search(r'(\d+)', elem.text)
                if match:
                    return int(match.group(1))

        return 3  # Default

    def get_optimization(self, config: str = 'Release', platform: str = 'x64') -> str:
        """Get optimization level."""
        elements = self._find_elements_for_config('Optimization', config, platform)

        for elem in elements:
            if elem.text:
                opt = elem.text.lower()
                if 'disabled' in opt:
                    return '-O0'
                elif 'full' in opt or 'maxspeed' in opt:
                    return '-O3'
                elif 'minspace' in opt:
                    return '-Os'
                elif 'maxspeed' in opt:
                    return '-O2'

        return '-O2' if config == 'Release' else '-O0'

    def parse_all(self, config: str = 'Release', platform: str = 'x64') -> Dict:
        """Parse all project settings and return as dictionary."""
        # Map Win32 to x86 for consistency
        if platform == 'Win32':
            platform = 'x86'

        return {
            'project_name': self.get_project_name(),
            'project_dir': str(self.project_dir),
            'configurations': self.get_configurations(),
            'config': config,
            'platform': platform,
            'preprocessor_definitions': self.get_preprocessor_definitions(config, platform),
            'include_directories': self.get_include_directories(config, platform),
            'source_files': self.get_source_files(),
            'header_files': self.get_header_files(),
            'resource_files': self.get_resource_files(),
            'additional_libraries': self.get_additional_libraries(config, platform),
            'additional_options': self.get_additional_options(config, platform),
            'runtime_library': self.get_runtime_library(config, platform),
            'subsystem': self.get_subsystem(config, platform),
            'character_set': self.get_character_set(),
            'cpp_standard': self.get_cpp_standard(config, platform),
            'warning_level': self.get_warning_level(config, platform),
            'optimization': self.get_optimization(config, platform),
        }


def main():
    parser = argparse.ArgumentParser(description='Parse Visual Studio .vcxproj files')
    parser.add_argument('vcxproj', help='Path to .vcxproj file')
    parser.add_argument('-c', '--config', default='Release', help='Build configuration (Debug/Release)')
    parser.add_argument('-p', '--platform', default='x64', help='Target platform (x64/x86/Win32)')
    parser.add_argument('-o', '--output', help='Output JSON file (default: stdout)')

    args = parser.parse_args()

    try:
        vcx_parser = VcxprojParser(args.vcxproj)
        result = vcx_parser.parse_all(args.config, args.platform)

        json_output = json.dumps(result, indent=2)

        if args.output:
            with open(args.output, 'w') as f:
                f.write(json_output)
        else:
            print(json_output)

    except Exception as e:
        print(f"Error parsing {args.vcxproj}: {e}", file=__import__('sys').stderr)
        __import__('sys').exit(1)


if __name__ == '__main__':
    main()
