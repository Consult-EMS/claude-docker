#!/usr/bin/env bash
set -euo pipefail

# ABOUTME: Helper script to store Claude authentication in macOS Keychain
# ABOUTME: Reads ~/.claude.json and stores it as 'claude-auth' keychain entry

KEYCHAIN_SERVICE="claude-auth"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Store Claude Code authentication in macOS Keychain for secure Docker access."
    echo ""
    echo "Options:"
    echo "  --check    Check if keychain entry exists"
    echo "  --remove   Remove existing keychain entry"
    echo "  --help     Show this help message"
    echo ""
    echo "Without options: Stores ~/.claude.json content in Keychain"
}

check_macos() {
    if [[ "$OSTYPE" != "darwin"* ]]; then
        echo "ERROR: This script only works on macOS"
        exit 1
    fi
}

check_entry() {
    check_macos
    if security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
        echo "Keychain entry '$KEYCHAIN_SERVICE' exists"
        return 0
    else
        echo "Keychain entry '$KEYCHAIN_SERVICE' does not exist"
        return 1
    fi
}

remove_entry() {
    check_macos
    if security delete-generic-password -s "$KEYCHAIN_SERVICE" 2>/dev/null; then
        echo "Removed keychain entry '$KEYCHAIN_SERVICE'"
    else
        echo "No keychain entry '$KEYCHAIN_SERVICE' to remove"
    fi
}

store_auth() {
    check_macos

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

    # -U flag updates if exists, creates if not
    security add-generic-password \
        -s "$KEYCHAIN_SERVICE" \
        -a "$USER" \
        -w "$AUTH_CONTENT" \
        -U

    echo "Claude authentication stored in Keychain as '$KEYCHAIN_SERVICE'"
    echo ""
    echo "You can now run claude-docker without needing ~/.claude.json"
    echo "The authentication will be securely retrieved from Keychain at startup."
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
