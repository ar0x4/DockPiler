#!/usr/bin/env python3
"""
sln_parser.py - Parse Visual Studio Solution files (.sln)

Extracts project references, dependencies, and determines build order.
"""

import re
import os
import json
import argparse
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple
from collections import defaultdict


class SlnParser:
    """Parser for Visual Studio .sln solution files."""

    # Regex patterns for parsing .sln files
    PROJECT_PATTERN = re.compile(
        r'Project\("\{([^}]+)\}"\)\s*=\s*"([^"]+)",\s*"([^"]+)",\s*"\{([^}]+)\}"',
        re.MULTILINE
    )

    PROJECT_SECTION_START = re.compile(r'ProjectSection\((\w+)\)\s*=\s*(\w+)')
    PROJECT_SECTION_END = re.compile(r'EndProjectSection')

    GLOBAL_SECTION_START = re.compile(r'GlobalSection\((\w+)\)\s*=\s*(\w+)')
    GLOBAL_SECTION_END = re.compile(r'EndGlobalSection')

    # Project type GUIDs
    PROJECT_TYPES = {
        '8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942': 'C++',
        'FAE04EC0-301F-11D3-BF4B-00C04F79EFBC': 'C#',
        'F184B08F-C81C-45F6-A57F-5ABD9991F28F': 'VB.NET',
        '2150E333-8FDC-42A3-9474-1A3956D46DE8': 'SolutionFolder',
        '930C7802-8A8C-48F9-8165-68863BCCD9DD': 'WiX',
        'E24C65DC-7377-472B-9ABA-BC803B73C61A': 'Website',
        '9A19103F-16F7-4668-BE54-9A1E7A4F7556': 'C# SDK-style',
    }

    def __init__(self, sln_path: str):
        self.sln_path = Path(sln_path)
        self.solution_dir = self.sln_path.parent

        with open(sln_path, 'r', encoding='utf-8-sig') as f:
            self.content = f.read()

        self.projects: Dict[str, Dict] = {}
        self.dependencies: Dict[str, List[str]] = defaultdict(list)
        self.build_configurations: List[Tuple[str, str]] = []

        self._parse()

    def _parse(self):
        """Parse the solution file."""
        self._parse_projects()
        self._parse_project_dependencies()
        self._parse_configurations()

    def _parse_projects(self):
        """Extract all project definitions."""
        for match in self.PROJECT_PATTERN.finditer(self.content):
            type_guid, name, path, project_guid = match.groups()

            # Convert path to Unix style
            path = path.replace('\\', '/')

            # Get project type
            project_type = self.PROJECT_TYPES.get(type_guid.upper(), 'Unknown')

            self.projects[project_guid.upper()] = {
                'name': name,
                'path': path,
                'type_guid': type_guid.upper(),
                'project_type': project_type,
                'guid': project_guid.upper(),
                'full_path': str(self.solution_dir / path),
            }

    def _parse_project_dependencies(self):
        """Extract project dependencies from ProjectSection(ProjectDependencies)."""
        # Find project blocks and their dependencies
        project_block_pattern = re.compile(
            r'Project\("[^"]+"\)\s*=\s*"[^"]+",\s*"[^"]+",\s*"\{([^}]+)\}".*?EndProject',
            re.DOTALL
        )

        dependency_pattern = re.compile(r'\{([^}]+)\}\s*=\s*\{([^}]+)\}')

        for match in project_block_pattern.finditer(self.content):
            project_guid = match.group(1).upper()
            block_content = match.group(0)

            # Check for ProjectDependencies section
            if 'ProjectDependencies' in block_content:
                deps_start = block_content.find('ProjectDependencies')
                deps_end = block_content.find('EndProjectSection', deps_start)

                if deps_start != -1 and deps_end != -1:
                    deps_section = block_content[deps_start:deps_end]

                    for dep_match in dependency_pattern.finditer(deps_section):
                        dep_guid = dep_match.group(1).upper()
                        self.dependencies[project_guid].append(dep_guid)

    def _parse_configurations(self):
        """Extract solution configurations."""
        config_pattern = re.compile(r'(\w+)\|(\w+)\s*=\s*\w+\|\w+')

        # Look in GlobalSection(SolutionConfigurationPlatforms)
        global_section_match = re.search(
            r'GlobalSection\(SolutionConfigurationPlatforms\).*?EndGlobalSection',
            self.content,
            re.DOTALL
        )

        if global_section_match:
            section_content = global_section_match.group(0)
            configs_found = set()

            for match in config_pattern.finditer(section_content):
                config, platform = match.groups()
                if (config, platform) not in configs_found:
                    configs_found.add((config, platform))
                    self.build_configurations.append((config, platform))

        if not self.build_configurations:
            # Default configurations
            self.build_configurations = [
                ('Debug', 'Win32'), ('Debug', 'x64'),
                ('Release', 'Win32'), ('Release', 'x64')
            ]

    def get_projects(self) -> List[Dict]:
        """Get all projects in the solution."""
        return list(self.projects.values())

    def get_cpp_projects(self) -> List[Dict]:
        """Get only C++ projects (.vcxproj)."""
        return [p for p in self.projects.values()
                if p['project_type'] == 'C++' and p['path'].endswith('.vcxproj')]

    def get_csharp_projects(self) -> List[Dict]:
        """Get only C# projects (.csproj)."""
        return [p for p in self.projects.values()
                if p['project_type'] in ('C#', 'C# SDK-style') and p['path'].endswith('.csproj')]

    def get_project_dependencies(self, project_guid: str) -> List[Dict]:
        """Get dependencies for a specific project."""
        dep_guids = self.dependencies.get(project_guid.upper(), [])
        return [self.projects[guid] for guid in dep_guids if guid in self.projects]

    def get_build_order(self, project_type: Optional[str] = None) -> List[Dict]:
        """
        Get projects in topological build order (dependencies first).

        Args:
            project_type: Filter by type ('C++', 'C#', etc.) or None for all
        """
        # Build dependency graph
        in_degree = defaultdict(int)
        graph = defaultdict(list)

        # Filter projects by type
        if project_type:
            relevant_projects = {
                guid: proj for guid, proj in self.projects.items()
                if proj['project_type'] == project_type
            }
        else:
            # Exclude solution folders
            relevant_projects = {
                guid: proj for guid, proj in self.projects.items()
                if proj['project_type'] != 'SolutionFolder'
            }

        # Initialize in-degrees
        for guid in relevant_projects:
            in_degree[guid] = 0

        # Build graph and calculate in-degrees
        for guid in relevant_projects:
            for dep_guid in self.dependencies.get(guid, []):
                if dep_guid in relevant_projects:
                    graph[dep_guid].append(guid)
                    in_degree[guid] += 1

        # Topological sort using Kahn's algorithm
        queue = [guid for guid in relevant_projects if in_degree[guid] == 0]
        result = []

        while queue:
            # Sort queue by project name for deterministic order
            queue.sort(key=lambda g: relevant_projects[g]['name'])
            current = queue.pop(0)
            result.append(relevant_projects[current])

            for neighbor in graph[current]:
                in_degree[neighbor] -= 1
                if in_degree[neighbor] == 0:
                    queue.append(neighbor)

        # Check for cycles
        if len(result) != len(relevant_projects):
            # Some projects have circular dependencies, add remaining
            remaining = [p for g, p in relevant_projects.items()
                        if p not in result]
            result.extend(remaining)

        return result

    def get_configurations(self) -> List[Tuple[str, str]]:
        """Get all solution configurations."""
        return self.build_configurations

    def parse_all(self) -> Dict:
        """Parse all solution information and return as dictionary."""
        cpp_projects = self.get_cpp_projects()
        csharp_projects = self.get_csharp_projects()

        return {
            'solution_file': str(self.sln_path),
            'solution_dir': str(self.solution_dir),
            'configurations': self.build_configurations,
            'total_projects': len(self.projects),
            'cpp_projects': cpp_projects,
            'csharp_projects': csharp_projects,
            'cpp_build_order': self.get_build_order('C++'),
            'csharp_build_order': [p for p in self.get_build_order() if p['project_type'] in ('C#', 'C# SDK-style')],
            'all_build_order': self.get_build_order(),
            'dependencies': {
                guid: [self.projects.get(d, {'name': d})['name'] for d in deps]
                for guid, deps in self.dependencies.items()
                if guid in self.projects
            },
        }


def find_solution_file(directory: str) -> Optional[str]:
    """Find .sln file in directory."""
    dir_path = Path(directory)

    sln_files = list(dir_path.glob('*.sln'))

    if not sln_files:
        return None

    # If multiple .sln files, prefer one with same name as directory
    dir_name = dir_path.name.lower()
    for sln in sln_files:
        if sln.stem.lower() == dir_name:
            return str(sln)

    # Return first one found
    return str(sln_files[0])


def get_vcxproj_config_type(vcxproj_path: str) -> str:
    """Get configuration type (Application, DynamicLibrary, StaticLibrary) from vcxproj."""
    try:
        import xml.etree.ElementTree as ET
        tree = ET.parse(vcxproj_path)
        root = tree.getroot()

        # Remove namespace for easier parsing
        for elem in root.iter():
            if '}' in elem.tag:
                elem.tag = elem.tag.split('}', 1)[1]

        # Look for ConfigurationType
        for elem in root.findall('.//ConfigurationType'):
            if elem.text:
                return elem.text

        return 'Application'  # Default
    except Exception:
        return 'Application'


def main():
    parser = argparse.ArgumentParser(description='Parse Visual Studio .sln solution files')
    parser.add_argument('sln', nargs='?', help='Path to .sln file (or directory to search)')
    parser.add_argument('-o', '--output', help='Output JSON file (default: stdout)')
    parser.add_argument('--cpp-only', action='store_true', help='Only show C++ projects')
    parser.add_argument('--csharp-only', action='store_true', help='Only show C# projects')
    parser.add_argument('--build-order', action='store_true', help='Show build order only')
    parser.add_argument('--dlls-first', action='store_true', help='Sort DLL projects before EXE projects')

    args = parser.parse_args()

    sln_path = args.sln or '.'

    # If directory, find .sln file
    if os.path.isdir(sln_path):
        sln_path = find_solution_file(sln_path)
        if not sln_path:
            print("Error: No .sln file found in directory", file=__import__('sys').stderr)
            __import__('sys').exit(1)

    try:
        sln_parser = SlnParser(sln_path)

        if args.build_order:
            if args.cpp_only:
                build_order = sln_parser.get_build_order('C++')
            elif args.csharp_only:
                build_order = [p for p in sln_parser.get_build_order()
                               if p['project_type'] in ('C#', 'C# SDK-style')]
            else:
                build_order = sln_parser.get_build_order()

            # If --dlls-first, sort so DLLs come before EXEs
            if args.dlls_first and args.cpp_only:
                def get_sort_key(proj):
                    config_type = get_vcxproj_config_type(proj['full_path'])
                    # DynamicLibrary = 0 (first), StaticLibrary = 1, Application = 2 (last)
                    if config_type == 'DynamicLibrary':
                        return 0
                    elif config_type == 'StaticLibrary':
                        return 1
                    else:
                        return 2
                build_order = sorted(build_order, key=get_sort_key)

            result = {'build_order': build_order}
        elif args.cpp_only:
            result = {'cpp_projects': sln_parser.get_cpp_projects()}
        elif args.csharp_only:
            result = {'csharp_projects': sln_parser.get_csharp_projects()}
        else:
            result = sln_parser.parse_all()

        json_output = json.dumps(result, indent=2)

        if args.output:
            with open(args.output, 'w') as f:
                f.write(json_output)
        else:
            print(json_output)

    except Exception as e:
        print(f"Error parsing {sln_path}: {e}", file=__import__('sys').stderr)
        __import__('sys').exit(1)


if __name__ == '__main__':
    main()
