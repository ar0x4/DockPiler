#!/usr/bin/env python3
"""
midl_header_generator.py - Generate MIDL headers from IDL files

This script parses Microsoft IDL files and generates the corresponding
header files that are normally created by the MIDL compiler. This enables
cross-compilation of projects that use RPC without needing the MIDL compiler.
"""

import re
import os
import sys
import argparse
from pathlib import Path
from typing import List, Dict, Optional, Tuple


class MidlHeaderGenerator:
    """Generate MIDL-compatible header files from IDL sources."""

    def __init__(self, idl_path: str, arch: str = 'x64'):
        self.idl_path = Path(idl_path)
        self.arch = arch
        self.idl_name = self.idl_path.stem
        self.content = self.idl_path.read_text(errors='ignore')

        # Parsed data
        self.uuid: Optional[str] = None
        self.version: str = '1.0'
        self.interface_name: Optional[str] = None
        self.typedefs: List[str] = []
        self.functions: List[Dict] = []

    def parse(self):
        """Parse the IDL file to extract interface definitions."""
        # Extract UUID
        uuid_match = re.search(r'uuid\s*\(\s*([0-9a-fA-F-]+)\s*\)', self.content)
        if uuid_match:
            self.uuid = uuid_match.group(1)

        # Extract version
        version_match = re.search(r'version\s*\(\s*(\d+\.\d+)\s*\)', self.content)
        if version_match:
            self.version = version_match.group(1)

        # Extract interface name
        iface_match = re.search(r'interface\s+(\w+)', self.content)
        if iface_match:
            self.interface_name = iface_match.group(1)

        # Extract typedef structs
        self._parse_typedefs()

        # Extract function declarations
        self._parse_functions()

    def _parse_typedefs(self):
        """Extract typedef definitions from the IDL."""
        # Match typedef struct { ... } name;
        typedef_pattern = r'typedef\s+struct\s+(\w+)\s*\{([^}]+)\}\s*(\w+)\s*;'

        for match in re.finditer(typedef_pattern, self.content, re.DOTALL):
            struct_name = match.group(1)
            struct_body = match.group(2)
            typedef_name = match.group(3)

            # Clean up the struct body - remove IDL attributes
            cleaned_body = self._clean_idl_attributes(struct_body)

            # Convert IDL types to C types
            cleaned_body = self._convert_types(cleaned_body)

            self.typedefs.append({
                'struct_name': struct_name,
                'body': cleaned_body,
                'typedef_name': typedef_name
            })

    def _parse_functions(self):
        """Extract function declarations from the IDL."""
        # Match function declarations: type name(...); with optional // comment
        # Look for multi-line function declarations
        func_pattern = r'^\s*(long|void|int|short|HRESULT)\s+(\w+)\s*\(([^;]*)\)\s*;(\s*//.*)?'

        for match in re.finditer(func_pattern, self.content, re.MULTILINE | re.DOTALL):
            return_type = match.group(1)
            func_name = match.group(2)
            params = match.group(3)
            comment = match.group(4) or ''

            # Clean up parameters
            cleaned_params = self._clean_function_params(params)

            # For functions marked "Not used", they still exist in stub files
            # but take only handle_t as their parameter
            if 'not used' in comment.lower():
                # These stub functions just take a binding handle
                cleaned_params = 'RPC_BINDING_HANDLE IDL_handle'

            self.functions.append({
                'return_type': return_type,
                'name': func_name,
                'params': cleaned_params
            })

    def _clean_idl_attributes(self, text: str) -> str:
        """Remove IDL attributes like [unique], [string], etc."""
        # Remove attribute lists like [unique] [string]
        text = re.sub(r'\[\s*(unique|string|ref|in|out|size_is\([^)]*\)|length_is\([^)]*\))\s*\]\s*', '', text)
        return text

    def _clean_function_params(self, params: str) -> str:
        """Clean function parameters, removing IDL attributes."""
        # Remove [in], [out], [ref], etc.
        params = re.sub(r'\[\s*(in|out|ref|unique|string|context_handle|size_is\([^)]*\)|length_is\([^)]*\))\s*\]\s*', '', params)
        # Convert types
        params = self._convert_types(params)
        # Clean up whitespace
        params = re.sub(r'\s+', ' ', params).strip()
        return params

    def _convert_types(self, text: str) -> str:
        """Convert IDL types to C types."""
        # Type mappings
        mappings = {
            r'\bhyper\b': '__int64',
            r'\bhandle_t\b': 'RPC_BINDING_HANDLE',
            r'\bwchar_t\s*\*': 'wchar_t*',
        }

        for pattern, replacement in mappings.items():
            text = re.sub(pattern, replacement, text)

        return text

    def generate(self) -> str:
        """Generate the header file content."""
        self.parse()

        lines = []

        # Header guard and includes
        guard_name = f'__{self.idl_name.upper()}_H__'
        lines.extend([
            f'/* MIDL header - auto-generated by DockPiler from {self.idl_name}.idl */',
            f'#ifndef {guard_name}',
            f'#define {guard_name}',
            '',
            '#ifndef __REQUIRED_RPCNDR_H_VERSION__',
            '#define __REQUIRED_RPCNDR_H_VERSION__ 475',
            '#endif',
            '',
            '#include <rpc.h>',
            '#include <rpcndr.h>',
            '',
            '#ifndef COM_NO_WINDOWS_H',
            '#include <windows.h>',
            '#include <ole2.h>',
            '#endif',
            '',
            '#ifdef __cplusplus',
            'extern "C" {',
            '#endif',
            '',
        ])

        # Interface handle declarations
        if self.interface_name:
            version_str = self.version.replace('.', '_')
            lines.extend([
                f'/* Interface: {self.interface_name} */',
            ])
            if self.uuid:
                lines.append(f'/* UUID: {self.uuid} */')
            lines.extend([
                '',
                f'extern RPC_IF_HANDLE {self.interface_name}_v{version_str}_c_ifspec;',
                f'extern RPC_IF_HANDLE {self.interface_name}_v{version_str}_s_ifspec;',
                '',
            ])

        # Typedef declarations
        if self.typedefs:
            lines.append('/* Type definitions */')
            for td in self.typedefs:
                lines.extend([
                    f'typedef struct {td["struct_name"]}',
                    '{',
                    td['body'],
                    f'}} {td["typedef_name"]};',
                    '',
                ])

        # Function prototypes (for client-side RPC calls)
        if self.functions:
            lines.append('/* Function prototypes */')
            for func in self.functions:
                if func['params']:
                    lines.append(f'{func["return_type"]} {func["name"]}({func["params"]});')
                else:
                    lines.append(f'{func["return_type"]} {func["name"]}(void);')
            lines.append('')

        # Close extern "C" and header guard
        lines.extend([
            '#ifdef __cplusplus',
            '}',
            '#endif',
            '',
            f'#endif /* {guard_name} */',
            '',
        ])

        return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description='Generate MIDL header from IDL file')
    parser.add_argument('idl_file', help='Path to the IDL file')
    parser.add_argument('-o', '--output', help='Output header file path')
    parser.add_argument('-a', '--arch', default='x64', choices=['x64', 'x86'],
                        help='Target architecture')

    args = parser.parse_args()

    idl_path = Path(args.idl_file)
    if not idl_path.exists():
        print(f"Error: IDL file not found: {args.idl_file}", file=sys.stderr)
        sys.exit(1)

    # Default output path
    if args.output:
        output_path = Path(args.output)
    else:
        output_path = idl_path.with_name(f'{idl_path.stem}_h.h')

    # Generate header
    generator = MidlHeaderGenerator(str(idl_path), args.arch)
    header_content = generator.generate()

    # Write output
    output_path.write_text(header_content)
    print(f"Generated: {output_path}")


if __name__ == '__main__':
    main()
