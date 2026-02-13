#!/usr/bin/env bash
set -euo pipefail
trap 'echo "$0: line $LINENO: $BASH_COMMAND: exitcode $?"' ERR

# ABOUTME: Runtime MCP server installation with caching
# ABOUTME: Runs at container startup, skips if config unchanged (hash match)

MCP_CONFIG="/app/mcp-servers.txt"
MCP_HASH_FILE="$HOME/.claude/cache/.mcp-hash"

# Ensure cache directory exists
mkdir -p "$HOME/.claude/cache"

# Check if MCP config exists
if [ ! -f "$MCP_CONFIG" ]; then
    echo "No MCP servers config found at $MCP_CONFIG - skipping"
    exit 0
fi

# Calculate hash of current MCP config
if command -v md5sum >/dev/null 2>&1; then
    CURRENT_HASH=$(md5sum "$MCP_CONFIG" | cut -d' ' -f1)
elif command -v md5 >/dev/null 2>&1; then
    CURRENT_HASH=$(md5 -q "$MCP_CONFIG")
else
    echo "WARNING: No md5sum or md5 available - cannot cache MCP installation"
    CURRENT_HASH=""
fi

# Check if we can skip installation (hash match)
if [ -n "$CURRENT_HASH" ] && [ -f "$MCP_HASH_FILE" ]; then
    STORED_HASH=$(cat "$MCP_HASH_FILE" 2>/dev/null || echo "")
    if [ "$CURRENT_HASH" = "$STORED_HASH" ]; then
        echo "MCP servers already installed (config unchanged)"
        exit 0
    fi
fi

echo "Installing MCP servers..."

# Source .env file if it exists (baked into image)
if [ -f /app/.env ]; then
    set -a
    source /app/.env 2>/dev/null || true
    set +a
    echo "Loaded environment variables from .env"
fi

command_buffer=""
in_multiline=false

while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments (but only when not in multi-line mode)
    if ! $in_multiline && ([[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]]); then
        continue
    fi

    # Detect start of multi-line command (contains '{ without closing '}')
    if [[ "$line" =~ \'?\{[^}]*$ ]] && [[ "$line" =~ ^claude ]]; then
        in_multiline=true
        command_buffer="$line"
        continue
    fi

    # Accumulate multi-line command
    if $in_multiline; then
        command_buffer="$command_buffer"$'\n'"$line"
        # Check if we've reached the end (line contains }' )
        if [[ "$line" =~ \}\'[[:space:]]*$ ]]; then
            in_multiline=false
            line="$command_buffer"
            command_buffer=""
        else
            continue
        fi
    fi

    # Check for missing variables
    var_names=$(echo "$line" | grep -o '\${[^}]*}' | sed 's/[${}]//g' || echo "")

    missing_vars=""
    for var in $var_names; do
        if [ -z "${!var:-}" ]; then
            missing_vars="$missing_vars $var"
        fi
    done

    if [ -n "$missing_vars" ]; then
        echo "Skipping MCP server - missing environment variables:$missing_vars"
        continue
    fi

    # Expansion Logic
    if [[ -n "$var_names" ]]; then
        if [[ "$line" =~ "add-json" ]]; then
            expanded_line="$line"
            vars_in_line=$(echo "$line" | grep -o '\${[^}]*}' | sed 's/[${}]//g' | sort -u || echo "")
            for var in $vars_in_line; do
                if [ -n "${!var:-}" ]; then
                    value="${!var}"
                    expanded_line=$(echo "$expanded_line" | sed "s|\${$var}|$value|g")
                fi
            done
        else
            if command -v envsubst >/dev/null 2>&1; then
                expanded_line=$(echo "$line" | envsubst)
            else
                echo "Error: envsubst not found. Please install gettext-base."
                exit 1
            fi
        fi
    else
        expanded_line="$line"
    fi

    echo "Executing: $(echo "$expanded_line" | head -c 100)..."

    if eval "$expanded_line"; then
        echo "Successfully installed MCP server"
    else
        echo "Failed to install MCP server (continuing)"
    fi

    echo "---"
done < "$MCP_CONFIG"

# Store hash for future cache checks
if [ -n "$CURRENT_HASH" ]; then
    echo "$CURRENT_HASH" > "$MCP_HASH_FILE"
    echo "MCP server installation complete (hash cached)"
else
    echo "MCP server installation complete"
fi
