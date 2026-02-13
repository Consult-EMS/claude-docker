#!/usr/bin/env bash
# ABOUTME: Library for building Docker mount arguments for Claude config
# ABOUTME: Implements selective read-only/read-write mounts for config sharing

# Read-only directories (git-managed, shared across sessions)
CLAUDE_RO_DIRS=(
    "skills"
    "agents"
    "commands"
    "plugins"
)

# Read-only files
CLAUDE_RO_FILES=(
    "CLAUDE.md"
)

# Read-write directories (session data, writable)
CLAUDE_RW_DIRS=(
    "plans"
    "cache"
    "projects"
    "todos"
    "debug"
)

# Read-write files
CLAUDE_RW_FILES=(
    "settings.json"
    ".credentials.json"
    "history.jsonl"
)

# Ensure writable paths exist on host before mounting
ensure_writable_paths_exist() {
    local claude_dir="$1"

    if [ -z "$claude_dir" ]; then
        echo "ERROR: Claude config directory not specified" >&2
        return 1
    fi

    # Create RW directories
    for dir in "${CLAUDE_RW_DIRS[@]}"; do
        if [ ! -d "$claude_dir/$dir" ]; then
            mkdir -p "$claude_dir/$dir"
        fi
    done

    # Touch RW files so they can be mounted
    for file in "${CLAUDE_RW_FILES[@]}"; do
        if [ ! -f "$claude_dir/$file" ]; then
            touch "$claude_dir/$file"
        fi
    done
}

# Build read-only mount arguments
# Output: Docker mount arguments for RO paths
build_readonly_mounts() {
    local claude_dir="$1"
    local container_claude="/home/claude-user/.claude"
    local mounts=""

    # Mount RO directories
    for dir in "${CLAUDE_RO_DIRS[@]}"; do
        if [ -d "$claude_dir/$dir" ]; then
            mounts="$mounts -v $claude_dir/$dir:$container_claude/$dir:ro"
        fi
    done

    # Mount RO files
    for file in "${CLAUDE_RO_FILES[@]}"; do
        if [ -f "$claude_dir/$file" ]; then
            mounts="$mounts -v $claude_dir/$file:$container_claude/$file:ro"
        fi
    done

    echo "$mounts"
}

# Build read-write mount arguments
# Output: Docker mount arguments for RW paths
build_readwrite_mounts() {
    local claude_dir="$1"
    local container_claude="/home/claude-user/.claude"
    local mounts=""

    # Mount RW directories
    for dir in "${CLAUDE_RW_DIRS[@]}"; do
        if [ -d "$claude_dir/$dir" ]; then
            mounts="$mounts -v $claude_dir/$dir:$container_claude/$dir:rw"
        fi
    done

    # Mount RW files
    for file in "${CLAUDE_RW_FILES[@]}"; do
        if [ -f "$claude_dir/$file" ]; then
            mounts="$mounts -v $claude_dir/$file:$container_claude/$file:rw"
        fi
    done

    echo "$mounts"
}

# Build all Claude config mounts (combines RO and RW)
build_claude_mounts() {
    local claude_dir="$1"
    local ro_mounts
    local rw_mounts

    # Ensure writable paths exist first
    ensure_writable_paths_exist "$claude_dir"

    ro_mounts=$(build_readonly_mounts "$claude_dir")
    rw_mounts=$(build_readwrite_mounts "$claude_dir")

    echo "$ro_mounts $rw_mounts"
}

# Validate Claude config directory has minimum required structure
validate_claude_config() {
    local claude_dir="$1"
    local errors=0

    if [ -z "$claude_dir" ]; then
        echo "ERROR: Claude config directory not specified" >&2
        return 1
    fi

    if [ ! -d "$claude_dir" ]; then
        echo "ERROR: Claude config directory does not exist: $claude_dir" >&2
        return 1
    fi

    # Check for essential read-only content (at least CLAUDE.md should exist)
    if [ ! -f "$claude_dir/CLAUDE.md" ]; then
        echo "WARNING: No CLAUDE.md found in $claude_dir" >&2
        echo "  This file contains global Claude instructions" >&2
    fi

    # Check for skills directory (optional but recommended)
    if [ ! -d "$claude_dir/skills" ]; then
        echo "WARNING: No skills/ directory found in $claude_dir" >&2
        echo "  Skills provide reusable capabilities for Claude" >&2
    fi

    return 0
}

# Get default Claude config directory
get_default_claude_dir() {
    local host_home="${HOST_HOME:-$HOME}"

    # Check for override
    if [ -n "${CLAUDE_USER_CONFIG:-}" ]; then
        echo "$CLAUDE_USER_CONFIG"
        return
    fi

    # Default to ~/.claude
    echo "$host_home/.claude"
}

# Print mount configuration summary
print_mount_summary() {
    local claude_dir="$1"

    echo "Claude config mounts:"
    echo "  Source: $claude_dir"
    echo "  Read-only:"
    for dir in "${CLAUDE_RO_DIRS[@]}"; do
        if [ -d "$claude_dir/$dir" ]; then
            echo "    - $dir/"
        fi
    done
    for file in "${CLAUDE_RO_FILES[@]}"; do
        if [ -f "$claude_dir/$file" ]; then
            echo "    - $file"
        fi
    done
    echo "  Read-write:"
    for dir in "${CLAUDE_RW_DIRS[@]}"; do
        if [ -d "$claude_dir/$dir" ]; then
            echo "    - $dir/"
        fi
    done
    for file in "${CLAUDE_RW_FILES[@]}"; do
        if [ -f "$claude_dir/$file" ]; then
            echo "    - $file"
        fi
    done
}
