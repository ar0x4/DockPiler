#!/usr/bin/env python3
"""
library_mapper.py - Map Windows library names to MinGW equivalents

Provides comprehensive mapping from Windows SDK libraries to their
MinGW-w64 counterparts for cross-compilation.
"""

import re
import json
import argparse
from typing import Dict, List, Optional, Set


class LibraryMapper:
    """Map Windows library names to MinGW equivalents."""

    # Comprehensive mapping of Windows libraries to MinGW
    # Format: 'windows_name': 'mingw_name' (or None if not available)
    LIBRARY_MAP: Dict[str, Optional[str]] = {
        # === Core Windows Libraries ===
        'kernel32': 'kernel32',
        'kernel32.lib': 'kernel32',
        'user32': 'user32',
        'user32.lib': 'user32',
        'gdi32': 'gdi32',
        'gdi32.lib': 'gdi32',
        'ntdll': 'ntdll',
        'ntdll.lib': 'ntdll',

        # === Networking ===
        'ws2_32': 'ws2_32',
        'ws2_32.lib': 'ws2_32',
        'wsock32': 'wsock32',
        'wsock32.lib': 'wsock32',
        'iphlpapi': 'iphlpapi',
        'iphlpapi.lib': 'iphlpapi',
        'winhttp': 'winhttp',
        'winhttp.lib': 'winhttp',
        'wininet': 'wininet',
        'wininet.lib': 'wininet',
        'mswsock': 'mswsock',
        'mswsock.lib': 'mswsock',
        'dnsapi': 'dnsapi',
        'dnsapi.lib': 'dnsapi',
        'fwpuclnt': 'fwpuclnt',
        'fwpuclnt.lib': 'fwpuclnt',
        'rasapi32': 'rasapi32',
        'rasapi32.lib': 'rasapi32',

        # === Security & Cryptography ===
        'secur32': 'secur32',
        'secur32.lib': 'secur32',
        'crypt32': 'crypt32',
        'crypt32.lib': 'crypt32',
        'bcrypt': 'bcrypt',
        'bcrypt.lib': 'bcrypt',
        'ncrypt': 'ncrypt',
        'ncrypt.lib': 'ncrypt',
        'advapi32': 'advapi32',
        'advapi32.lib': 'advapi32',
        'wintrust': 'wintrust',
        'wintrust.lib': 'wintrust',
        'cryptui': 'cryptui',
        'cryptui.lib': 'cryptui',
        'cryptnet': 'cryptnet',
        'cryptnet.lib': 'cryptnet',
        'schannel': 'schannel',
        'schannel.lib': 'schannel',
        'sspicli': 'sspicli',
        'sspicli.lib': 'sspicli',

        # === Shell & UI ===
        'shell32': 'shell32',
        'shell32.lib': 'shell32',
        'shlwapi': 'shlwapi',
        'shlwapi.lib': 'shlwapi',
        'comctl32': 'comctl32',
        'comctl32.lib': 'comctl32',
        'comdlg32': 'comdlg32',
        'comdlg32.lib': 'comdlg32',
        'uxtheme': 'uxtheme',
        'uxtheme.lib': 'uxtheme',
        'dwmapi': 'dwmapi',
        'dwmapi.lib': 'dwmapi',

        # === COM / OLE ===
        'ole32': 'ole32',
        'ole32.lib': 'ole32',
        'oleaut32': 'oleaut32',
        'oleaut32.lib': 'oleaut32',
        'uuid': 'uuid',
        'uuid.lib': 'uuid',
        'combase': 'combase',
        'combase.lib': 'combase',
        'propsys': 'propsys',
        'propsys.lib': 'propsys',

        # === RPC ===
        'rpcrt4': 'rpcrt4',
        'rpcrt4.lib': 'rpcrt4',
        'rpcns4': 'rpcns4',
        'rpcns4.lib': 'rpcns4',

        # === System Services ===
        'psapi': 'psapi',
        'psapi.lib': 'psapi',
        'dbghelp': 'dbghelp',
        'dbghelp.lib': 'dbghelp',
        'version': 'version',
        'version.lib': 'version',
        'wtsapi32': 'wtsapi32',
        'wtsapi32.lib': 'wtsapi32',
        'userenv': 'userenv',
        'userenv.lib': 'userenv',
        'powrprof': 'powrprof',
        'powrprof.lib': 'powrprof',
        'setupapi': 'setupapi',
        'setupapi.lib': 'setupapi',
        'cfgmgr32': 'cfgmgr32',
        'cfgmgr32.lib': 'cfgmgr32',
        'newdev': 'newdev',
        'newdev.lib': 'newdev',

        # === I/O & Storage ===
        'mpr': 'mpr',
        'mpr.lib': 'mpr',
        'netapi32': 'netapi32',
        'netapi32.lib': 'netapi32',
        'winspool': 'winspool',
        'winspool.lib': 'winspool',
        'imm32': 'imm32',
        'imm32.lib': 'imm32',

        # === Graphics & Multimedia ===
        'opengl32': 'opengl32',
        'opengl32.lib': 'opengl32',
        'glu32': 'glu32',
        'glu32.lib': 'glu32',
        'winmm': 'winmm',
        'winmm.lib': 'winmm',
        'msimg32': 'msimg32',
        'msimg32.lib': 'msimg32',

        # === ODBC ===
        'odbc32': 'odbc32',
        'odbc32.lib': 'odbc32',
        'odbccp32': 'odbccp32',
        'odbccp32.lib': 'odbccp32',

        # === Debug & Diagnostics ===
        'imagehlp': 'imagehlp',
        'imagehlp.lib': 'imagehlp',
        'dbgeng': 'dbgeng',
        'dbgeng.lib': 'dbgeng',

        # === Security Token ===
        'wevtapi': 'wevtapi',
        'wevtapi.lib': 'wevtapi',

        # === Virtualization ===
        'virtdisk': 'virtdisk',
        'virtdisk.lib': 'virtdisk',

        # === WMI ===
        'wbemuuid': 'wbemuuid',
        'wbemuuid.lib': 'wbemuuid',

        # === Task Scheduler ===
        'taskschd': 'taskschd',
        'taskschd.lib': 'taskschd',

        # === Windows Management ===
        'wmi': 'wmi',
        'wmi.lib': 'wmi',

        # === Active Directory ===
        'activeds': 'activeds',
        'activeds.lib': 'activeds',
        'adsiid': 'adsiid',
        'adsiid.lib': 'adsiid',

        # === Cabinet ===
        'cabinet': 'cabinet',
        'cabinet.lib': 'cabinet',

        # === Service Control ===
        'svcctl': None,  # Not available in MinGW

        # === Runtime Libraries (often handled differently) ===
        'msvcrt': 'msvcrt',
        'msvcrt.lib': 'msvcrt',
        'msvcrtd': 'msvcrt',  # Debug version maps to same
        'msvcrtd.lib': 'msvcrt',
        'ucrt': 'ucrt',
        'ucrt.lib': 'ucrt',
        'ucrtd': 'ucrt',
        'ucrtd.lib': 'ucrt',
        'vcruntime': None,  # Handled by MinGW runtime
        'vcruntime.lib': None,
        'libcmt': None,  # Static CRT - use -static flag instead
        'libcmt.lib': None,
        'libcmtd': None,
        'libcmtd.lib': None,

        # === DirectX (limited support) ===
        'd3d9': 'd3d9',
        'd3d9.lib': 'd3d9',
        'd3d11': 'd3d11',
        'd3d11.lib': 'd3d11',
        'd3d12': 'd3d12',
        'd3d12.lib': 'd3d12',
        'dxgi': 'dxgi',
        'dxgi.lib': 'dxgi',
        'dxguid': 'dxguid',
        'dxguid.lib': 'dxguid',
        'd3dcompiler': 'd3dcompiler_47',
        'd3dcompiler.lib': 'd3dcompiler_47',
        'dinput8': 'dinput8',
        'dinput8.lib': 'dinput8',
        'dsound': 'dsound',
        'dsound.lib': 'dsound',
        'dwrite': 'dwrite',
        'dwrite.lib': 'dwrite',
        'd2d1': 'd2d1',
        'd2d1.lib': 'd2d1',

        # === Synchronization primitives ===
        'synchronization': 'synchronization',
        'synchronization.lib': 'synchronization',

        # === Windows Store / UWP (limited/no support) ===
        'windowsapp': None,
        'windowsapp.lib': None,
        'runtimeobject': 'runtimeobject',
        'runtimeobject.lib': 'runtimeobject',

        # === NLS ===
        'normaliz': 'normaliz',
        'normaliz.lib': 'normaliz',

        # === Sensor API ===
        'sensorsapi': 'sensorsapi',
        'sensorsapi.lib': 'sensorsapi',

        # === Portable Devices ===
        'portabledeviceguids': 'portabledeviceguids',
        'portabledeviceguids.lib': 'portabledeviceguids',

        # === Credential UI ===
        'credui': 'credui',
        'credui.lib': 'credui',

        # === HID ===
        'hid': 'hid',
        'hid.lib': 'hid',

        # === Bluetooth ===
        'bthprops': 'bthprops',
        'bthprops.lib': 'bthprops',

        # === URL handling ===
        'urlmon': 'urlmon',
        'urlmon.lib': 'urlmon',

        # === HTML Help ===
        'htmlhelp': 'htmlhelp',
        'htmlhelp.lib': 'htmlhelp',

        # === PDF ===
        'windows.data.pdf': None,  # UWP only

        # === Media Foundation (partial support) ===
        'mf': 'mf',
        'mf.lib': 'mf',
        'mfplat': 'mfplat',
        'mfplat.lib': 'mfplat',
        'mfuuid': 'mfuuid',
        'mfuuid.lib': 'mfuuid',
        'mfreadwrite': 'mfreadwrite',
        'mfreadwrite.lib': 'mfreadwrite',

        # === Bluetooth ===
        'bluetoothapis': 'bluetoothapis',
        'bluetoothapis.lib': 'bluetoothapis',

        # === BITS (Background Intelligent Transfer) ===
        'bits': 'bits',
        'bits.lib': 'bits',

        # === COM+ ===
        'comsvcs': 'comsvcs',
        'comsvcs.lib': 'comsvcs',

        # === IIS (not available) ===
        'httpapi': 'httpapi',
        'httpapi.lib': 'httpapi',

        # === Winlogon ===
        'authz': 'authz',
        'authz.lib': 'authz',

        # === Performance ===
        'pdh': 'pdh',
        'pdh.lib': 'pdh',

        # === Thread pools ===
        'ntoskrnl': None,  # Kernel mode only

        # === ATL/MFC (not available in MinGW) ===
        'atl': None,
        'atl.lib': None,
        'atlsd': None,
        'mfc': None,
        'mfc.lib': None,

        # === Pthread (MinGW-specific) ===
        'pthread': 'pthread',
        'pthreadGC2': 'pthread',
    }

    # Categories for documentation/grouping
    CATEGORIES = {
        'core': ['kernel32', 'user32', 'gdi32', 'ntdll'],
        'networking': ['ws2_32', 'wsock32', 'iphlpapi', 'winhttp', 'wininet', 'mswsock', 'dnsapi'],
        'security': ['secur32', 'crypt32', 'bcrypt', 'ncrypt', 'advapi32', 'wintrust'],
        'shell': ['shell32', 'shlwapi', 'comctl32', 'comdlg32'],
        'com': ['ole32', 'oleaut32', 'uuid', 'rpcrt4'],
        'system': ['psapi', 'dbghelp', 'version', 'wtsapi32', 'userenv', 'setupapi'],
        'graphics': ['opengl32', 'glu32', 'winmm', 'd3d9', 'd3d11', 'dxgi'],
        'io': ['mpr', 'netapi32', 'winspool'],
    }

    def __init__(self):
        # Build reverse lookup (case-insensitive)
        self._lookup = {}
        for win_name, mingw_name in self.LIBRARY_MAP.items():
            self._lookup[win_name.lower()] = mingw_name
            # Also add without .lib
            base_name = win_name.lower().replace('.lib', '')
            if base_name not in self._lookup:
                self._lookup[base_name] = mingw_name

    def map_library(self, lib_name: str) -> Optional[str]:
        """
        Map a Windows library name to MinGW equivalent.

        Args:
            lib_name: Windows library name (with or without .lib extension)

        Returns:
            MinGW library name or None if not available
        """
        # Normalize name
        normalized = lib_name.lower().strip()

        # Remove path if present
        if '/' in normalized or '\\' in normalized:
            normalized = normalized.split('/')[-1].split('\\')[-1]

        # Remove .lib extension
        normalized = normalized.replace('.lib', '')

        # Look up
        return self._lookup.get(normalized)

    def map_libraries(self, lib_names: List[str]) -> List[str]:
        """
        Map multiple library names, filtering out unavailable ones.

        Args:
            lib_names: List of Windows library names

        Returns:
            List of available MinGW library names (deduplicated)
        """
        result = []
        seen = set()

        for lib in lib_names:
            mapped = self.map_library(lib)
            if mapped and mapped not in seen:
                result.append(mapped)
                seen.add(mapped)

        return result

    def get_default_libraries(self) -> List[str]:
        """Get a list of commonly needed Windows libraries."""
        return [
            'kernel32', 'user32', 'gdi32', 'advapi32',
            'shell32', 'ole32', 'oleaut32', 'uuid',
            'ws2_32', 'crypt32', 'secur32', 'rpcrt4',
            'ntdll', 'shlwapi', 'version', 'psapi',
            'comdlg32', 'comctl32'
        ]

    def get_libraries_for_api(self, api_pattern: str) -> List[str]:
        """
        Suggest libraries based on API usage patterns.

        Args:
            api_pattern: API function name or pattern

        Returns:
            List of likely required libraries
        """
        suggestions = []
        api_lower = api_pattern.lower()

        # Network APIs
        if any(x in api_lower for x in ['socket', 'wsa', 'send', 'recv', 'connect', 'bind', 'listen']):
            suggestions.extend(['ws2_32', 'mswsock'])

        # Crypto APIs
        if any(x in api_lower for x in ['crypt', 'cert', 'hash', 'encrypt', 'decrypt']):
            suggestions.extend(['crypt32', 'bcrypt', 'ncrypt'])

        # Security APIs
        if any(x in api_lower for x in ['security', 'token', 'privilege', 'acl', 'sid']):
            suggestions.extend(['advapi32', 'secur32'])

        # Registry APIs
        if any(x in api_lower for x in ['reg', 'registry']):
            suggestions.append('advapi32')

        # COM APIs
        if any(x in api_lower for x in ['co', 'ole', 'variant', 'bstr']):
            suggestions.extend(['ole32', 'oleaut32', 'uuid'])

        # Shell APIs
        if any(x in api_lower for x in ['shell', 'shget', 'path']):
            suggestions.extend(['shell32', 'shlwapi'])

        # Process/Thread APIs
        if any(x in api_lower for x in ['process', 'thread', 'module', 'heap']):
            suggestions.extend(['kernel32', 'psapi'])

        # Window APIs
        if any(x in api_lower for x in ['window', 'wnd', 'message', 'dialog']):
            suggestions.extend(['user32', 'comctl32', 'comdlg32'])

        # Graphics APIs
        if any(x in api_lower for x in ['gdi', 'dc', 'bitmap', 'font', 'paint']):
            suggestions.append('gdi32')

        # HTTP APIs
        if any(x in api_lower for x in ['http', 'internet', 'url']):
            suggestions.extend(['winhttp', 'wininet'])

        # RPC APIs
        if any(x in api_lower for x in ['rpc', 'ndr']):
            suggestions.append('rpcrt4')

        # Remove duplicates while preserving order
        seen = set()
        result = []
        for lib in suggestions:
            if lib not in seen:
                seen.add(lib)
                result.append(lib)

        return result

    def is_available(self, lib_name: str) -> bool:
        """Check if a library is available in MinGW."""
        return self.map_library(lib_name) is not None

    def get_all_mappings(self) -> Dict[str, Optional[str]]:
        """Get all library mappings."""
        return dict(self.LIBRARY_MAP)


def main():
    parser = argparse.ArgumentParser(description='Map Windows libraries to MinGW equivalents')
    parser.add_argument('libraries', nargs='*', help='Library names to map')
    parser.add_argument('-a', '--all', action='store_true', help='Show all mappings')
    parser.add_argument('-d', '--defaults', action='store_true', help='Show default libraries')
    parser.add_argument('--api', help='Suggest libraries for API pattern')
    parser.add_argument('-j', '--json', action='store_true', help='Output as JSON')

    args = parser.parse_args()

    mapper = LibraryMapper()

    if args.all:
        mappings = mapper.get_all_mappings()
        if args.json:
            print(json.dumps(mappings, indent=2))
        else:
            for win, mingw in sorted(mappings.items()):
                status = mingw if mingw else '(not available)'
                print(f"{win} -> {status}")

    elif args.defaults:
        defaults = mapper.get_default_libraries()
        if args.json:
            print(json.dumps(defaults, indent=2))
        else:
            for lib in defaults:
                print(lib)

    elif args.api:
        suggestions = mapper.get_libraries_for_api(args.api)
        if args.json:
            print(json.dumps(suggestions, indent=2))
        else:
            print(f"Suggested libraries for '{args.api}':")
            for lib in suggestions:
                print(f"  {lib}")

    elif args.libraries:
        if args.json:
            result = {}
            for lib in args.libraries:
                result[lib] = mapper.map_library(lib)
            print(json.dumps(result, indent=2))
        else:
            for lib in args.libraries:
                mapped = mapper.map_library(lib)
                if mapped:
                    print(f"{lib} -> {mapped}")
                else:
                    print(f"{lib} -> (not available in MinGW)")

    else:
        parser.print_help()


if __name__ == '__main__':
    main()
