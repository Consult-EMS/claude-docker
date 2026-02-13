#!/usr/bin/env bash
set -euo pipefail

# ABOUTME: Cross-platform helper script to store Claude authentication in credential store
# ABOUTME: Supports macOS Keychain, Linux libsecret, and WSL2 Windows Credential Manager

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/lib-credentials.sh"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Store Claude Code authentication in platform credential store for secure Docker access."
    echo ""
    echo "Supported platforms:"
    echo "  macOS  - Keychain"
    echo "  Linux  - libsecret (GNOME Keyring) - requires libsecret-tools"
    echo "  WSL2   - Windows Credential Manager"
    echo ""
    echo "Options:"
    echo "  --check    Check if credential store entry exists"
    echo "  --remove   Remove existing credential store entry"
    echo "  --help     Show this help message"
    echo ""
    echo "Without options: Stores ~/.claude.json content in credential store"
}

check_entry() {
    check_credentials
}

remove_entry() {
    remove_credentials
}

store_auth_macos() {
    local auth_content="$1"

    # -U flag updates if exists, creates if not
    security add-generic-password \
        -s "$KEYCHAIN_SERVICE" \
        -a "$USER" \
        -w "$auth_content" \
        -U

    echo "Claude authentication stored in macOS Keychain as '$KEYCHAIN_SERVICE'"
}

store_auth_linux() {
    local auth_content="$1"

    if ! command -v secret-tool >/dev/null 2>&1; then
        echo "ERROR: secret-tool not found"
        echo ""
        echo "Install libsecret-tools:"
        echo "  Ubuntu/Debian: sudo apt install libsecret-tools"
        echo "  Fedora: sudo dnf install libsecret"
        echo "  Arch: sudo pacman -S libsecret"
        exit 1
    fi

    # Store using secret-tool
    echo "$auth_content" | secret-tool store --label "Claude Auth" service "$KEYCHAIN_SERVICE"

    echo "Claude authentication stored in libsecret as '$KEYCHAIN_SERVICE'"
}

store_auth_wsl2() {
    local auth_content="$1"

    if ! command -v powershell.exe >/dev/null 2>&1; then
        echo "ERROR: PowerShell interop not available"
        echo "Ensure WSL2 is properly configured with Windows interop enabled."
        exit 1
    fi

    # Use cmdkey.exe to store credential in Windows Credential Manager
    # Note: cmdkey stores username:password, we use a generic target
    powershell.exe -NoProfile -NonInteractive -Command "
        # Try using CredentialManager module first
        if (Get-Command New-StoredCredential -ErrorAction SilentlyContinue) {
            New-StoredCredential -Target '$KEYCHAIN_SERVICE' -UserName 'claude' -Password '$auth_content' -Type Generic -Persist LocalMachine | Out-Null
            Write-Host 'Stored using CredentialManager module'
        } else {
            # Fallback to cmdkey
            # cmdkey requires interactive prompt for password, so we use a different approach
            # Store as a generic credential using Windows API
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class CredManager {
    [DllImport(\"advapi32.dll\", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CredWrite([In] ref CREDENTIAL credential, [In] uint flags);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }
}
'@
            \$cred = New-Object CredManager+CREDENTIAL
            \$cred.Type = 1  # CRED_TYPE_GENERIC
            \$cred.TargetName = '$KEYCHAIN_SERVICE'
            \$cred.Persist = 2  # CRED_PERSIST_LOCAL_MACHINE
            \$cred.UserName = 'claude'
            \$bytes = [System.Text.Encoding]::Unicode.GetBytes('$auth_content')
            \$cred.CredentialBlobSize = \$bytes.Length
            \$cred.CredentialBlob = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(\$bytes.Length)
            [System.Runtime.InteropServices.Marshal]::Copy(\$bytes, 0, \$cred.CredentialBlob, \$bytes.Length)
            [CredManager]::CredWrite([ref]\$cred, 0)
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal(\$cred.CredentialBlob)
            Write-Host 'Stored using Windows Credential Manager API'
        }
    "

    echo "Claude authentication stored in Windows Credential Manager as '$KEYCHAIN_SERVICE'"
}

store_auth() {
    local platform
    platform=$(detect_host_platform)

    AUTH_FILE="$HOME/.claude.json"

    if [ ! -f "$AUTH_FILE" ]; then
        echo "ERROR: No $AUTH_FILE found"
        echo ""
        echo "Please authenticate Claude Code first by running:"
        echo "  claude --login"
        echo ""
        echo "Then run this script again."
        exit 1
    fi

    AUTH_CONTENT=$(cat "$AUTH_FILE")

    if [ -z "$AUTH_CONTENT" ]; then
        echo "ERROR: $AUTH_FILE is empty"
        exit 1
    fi

    echo "Detected platform: $platform"

    case "$platform" in
        macos)
            store_auth_macos "$AUTH_CONTENT"
            ;;
        linux)
            store_auth_linux "$AUTH_CONTENT"
            ;;
        wsl2)
            store_auth_wsl2 "$AUTH_CONTENT"
            ;;
        *)
            echo "ERROR: Unsupported platform '$platform'"
            echo "Supported platforms: macOS, Linux (with libsecret), WSL2"
            exit 1
            ;;
    esac

    echo ""
    echo "You can now run claude-docker without needing ~/.claude.json"
    echo "The authentication will be securely retrieved from credential store at startup."
}

# Parse arguments
case "${1:-}" in
    --check)
        check_entry
        ;;
    --remove)
        remove_entry
        ;;
    --help|-h)
        usage
        ;;
    "")
        store_auth
        ;;
    *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
esac
