#!/usr/bin/env bash
# ABOUTME: Cross-platform credential extraction library for Claude authentication
# ABOUTME: Supports macOS Keychain, Linux libsecret, and WSL2 Windows Credential Manager

KEYCHAIN_SERVICE="claude-auth"

# Detect host platform - order matters (WSL2 must be checked before Linux)
detect_host_platform() {
    if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl2"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    else
        echo "unknown"
    fi
}

# Extract credentials from macOS Keychain
extract_credentials_macos() {
    local auth
    auth=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null || true)
    if [ -n "$auth" ]; then
        echo "$auth"
        return 0
    fi
    return 1
}

# Extract credentials from Linux libsecret (GNOME Keyring)
extract_credentials_linux() {
    if ! command -v secret-tool >/dev/null 2>&1; then
        echo "WARNING: secret-tool not found. Install libsecret-tools for keyring support." >&2
        return 1
    fi

    local auth
    auth=$(secret-tool lookup service "$KEYCHAIN_SERVICE" 2>/dev/null || true)
    if [ -n "$auth" ]; then
        echo "$auth"
        return 0
    fi
    return 1
}

# Extract credentials from Windows Credential Manager via WSL2 PowerShell interop
extract_credentials_wsl2() {
    if ! command -v powershell.exe >/dev/null 2>&1; then
        echo "WARNING: PowerShell interop not available in WSL2." >&2
        return 1
    fi

    local auth
    # Use PowerShell to retrieve credential from Windows Credential Manager
    # Note: Requires CredentialManager module or uses cmdkey fallback
    auth=$(powershell.exe -NoProfile -NonInteractive -Command "
        try {
            # Try using Get-StoredCredential if CredentialManager module is available
            if (Get-Command Get-StoredCredential -ErrorAction SilentlyContinue) {
                \$cred = Get-StoredCredential -Target '$KEYCHAIN_SERVICE'
                if (\$cred) {
                    \$ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR(\$cred.Password)
                    try {
                        [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(\$ptr)
                    } finally {
                        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR(\$ptr)
                    }
                }
            } else {
                # Fallback: Use Windows Credential Manager API directly
                Add-Type -AssemblyName System.Security
                \$target = '$KEYCHAIN_SERVICE'
                \$credType = [System.Runtime.InteropServices.Marshal]::SizeOf([Type][IntPtr])
                # This is a simplified approach - may need adjustment
                Write-Error 'CredentialManager module not installed'
            }
        } catch {
            Write-Error \$_.Exception.Message
        }
    " 2>/dev/null | tr -d '\r')

    if [ -n "$auth" ]; then
        echo "$auth"
        return 0
    fi
    return 1
}

# Dispatcher - extract credentials based on detected platform
extract_credentials() {
    local platform
    platform=$(detect_host_platform)

    case "$platform" in
        macos)
            extract_credentials_macos
            ;;
        linux)
            extract_credentials_linux
            ;;
        wsl2)
            extract_credentials_wsl2
            ;;
        *)
            echo "WARNING: Unknown platform '$platform' - credential extraction not supported" >&2
            return 1
            ;;
    esac
}

# Extract credentials and store to temporary file
# Returns path to temp file (caller is responsible for cleanup)
extract_and_store_credentials() {
    local host_home="${HOST_HOME:-$HOME}"
    local auth_content
    local temp_file
    local platform

    platform=$(detect_host_platform)

    # Try platform-specific credential store first
    auth_content=$(extract_credentials 2>/dev/null || true)

    if [ -n "$auth_content" ]; then
        echo "Found Claude authentication in ${platform} credential store" >&2
        temp_file=$(mktemp)
        echo "$auth_content" > "$temp_file"
        chmod 600 "$temp_file"
        echo "$temp_file"
        return 0
    fi

    # Fall back to file-based auth
    if [ -n "$host_home" ] && [ -f "$host_home/.claude.json" ]; then
        echo "No credential store entry found - using fallback: ~/.claude.json file" >&2
        echo "$host_home/.claude.json"
        return 0
    fi

    # Provide helpful message based on platform
    echo "No Claude authentication found" >&2
    case "$platform" in
        macos)
            echo "To add: ./src/setup-credentials.sh" >&2
            ;;
        linux)
            echo "To add: ./src/setup-credentials.sh (requires libsecret-tools)" >&2
            ;;
        wsl2)
            echo "To add: ./src/setup-credentials.sh (uses Windows Credential Manager)" >&2
            ;;
    esac

    return 1
}

# Check if credentials exist in platform credential store
check_credentials() {
    local platform
    platform=$(detect_host_platform)

    case "$platform" in
        macos)
            if security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
                echo "Credential store entry '$KEYCHAIN_SERVICE' exists (macOS Keychain)"
                return 0
            fi
            ;;
        linux)
            if command -v secret-tool >/dev/null 2>&1; then
                if secret-tool lookup service "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
                    echo "Credential store entry '$KEYCHAIN_SERVICE' exists (libsecret)"
                    return 0
                fi
            fi
            ;;
        wsl2)
            # Check Windows Credential Manager
            if powershell.exe -NoProfile -NonInteractive -Command "
                cmdkey /list | Select-String -Pattern '$KEYCHAIN_SERVICE' -Quiet
            " 2>/dev/null | grep -qi true; then
                echo "Credential store entry '$KEYCHAIN_SERVICE' exists (Windows Credential Manager)"
                return 0
            fi
            ;;
    esac

    echo "Credential store entry '$KEYCHAIN_SERVICE' does not exist"
    return 1
}

# Remove credentials from platform credential store
remove_credentials() {
    local platform
    platform=$(detect_host_platform)

    case "$platform" in
        macos)
            if security delete-generic-password -s "$KEYCHAIN_SERVICE" 2>/dev/null; then
                echo "Removed credential store entry '$KEYCHAIN_SERVICE' (macOS Keychain)"
                return 0
            fi
            ;;
        linux)
            if command -v secret-tool >/dev/null 2>&1; then
                if secret-tool clear service "$KEYCHAIN_SERVICE" 2>/dev/null; then
                    echo "Removed credential store entry '$KEYCHAIN_SERVICE' (libsecret)"
                    return 0
                fi
            fi
            ;;
        wsl2)
            if powershell.exe -NoProfile -NonInteractive -Command "
                cmdkey /delete:$KEYCHAIN_SERVICE
            " 2>/dev/null; then
                echo "Removed credential store entry '$KEYCHAIN_SERVICE' (Windows Credential Manager)"
                return 0
            fi
            ;;
    esac

    echo "No credential store entry '$KEYCHAIN_SERVICE' to remove"
    return 1
}
