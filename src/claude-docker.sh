#!/usr/bin/env bash
set -euo pipefail
trap 'echo "$0: line $LINENO: $BASH_COMMAND: exitcode $?"' ERR
# ABOUTME: Wrapper script to run Claude Code in Docker container
# ABOUTME: Handles project mounting, persistent Claude config, and environment variables

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/lib-common.sh"
source "$SCRIPT_DIR/lib-credentials.sh"

# Parse command line arguments
DOCKER="${DOCKER:-docker}"
NO_CACHE=""
FORCE_REBUILD=false
CONTINUE_FLAG=""
MEMORY_LIMIT=""
GPU_ACCESS=""
CC_VERSION=""
ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --podman)
            DOCKER=podman
            shift
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        --continue)
            CONTINUE_FLAG="--continue"
            shift
            ;;
        --memory)
            MEMORY_LIMIT="$2"
            shift 2
            ;;
        --gpus)
            GPU_ACCESS="$2"
            shift 2
            ;;
        --cc-version)
            CC_VERSION="$2"
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# Validate container runtime
check_container_runtime "$DOCKER" "1.44"

# Get the absolute path of the current directory
CURRENT_DIR=$(pwd)
HOST_HOME="${HOME:-}"
if [ -z "$HOST_HOME" ]; then
    HOST_HOME="$(get_home_for_uid "$(id -u)" || true)"
fi

# Extract Claude authentication from platform credential store (macOS/Linux/WSL2)
CLAUDE_AUTH_FILE=""
CLAUDE_AUTH_FILE=$(extract_and_store_credentials || true)

# Use .claude submodule from this repo as the shared config
CLAUDE_HOME_DIR="$PROJECT_ROOT/.claude"
# Use user's existing SSH keys
SSH_DIR="$HOST_HOME/.ssh"

# Check if .env exists in claude-docker directory for building
ENV_FILE="$PROJECT_ROOT/.env"
if [ -f "$ENV_FILE" ]; then
    echo "✓ Found .env file with credentials"
    # Source .env to get configuration variables
    set -a
    source "$ENV_FILE" 2>/dev/null || true
    set +a
else
    echo "⚠️  No .env file found at $ENV_FILE"
    echo "   Twilio MCP features will be unavailable."
    echo "   To enable: copy .env.example to .env in the claude-docker repository and add your credentials"
fi

# Use environment variables as defaults if command line args not provided
if [ -z "${MEMORY_LIMIT:-}" ] && [ -n "${DOCKER_MEMORY_LIMIT:-}" ]; then
    MEMORY_LIMIT="$DOCKER_MEMORY_LIMIT"
    echo "✓ Using memory limit from environment: $MEMORY_LIMIT"
fi

if [ -z "${GPU_ACCESS:-}" ] && [ -n "${DOCKER_GPU_ACCESS:-}" ]; then
    GPU_ACCESS="$DOCKER_GPU_ACCESS"
    echo "✓ Using GPU access from environment: $GPU_ACCESS"
fi

# Check if we need to rebuild the image
NEED_REBUILD=false

if ! "$DOCKER" images | grep -q "claude-docker"; then
    echo "Building Claude Docker image for first time..."
    NEED_REBUILD=true
fi

if [ "$FORCE_REBUILD" = true ]; then
    echo "Forcing rebuild of Claude Docker image..."
    NEED_REBUILD=true
fi

# Warn if --no-cache is used without rebuild
if [ -n "${NO_CACHE:-}" ] && [ "$NEED_REBUILD" = false ]; then
    echo "⚠️  Warning: --no-cache flag set but image already exists. Use --rebuild --no-cache to force rebuild without cache."
fi

if [ "$NEED_REBUILD" = true ]; then
    # Get git config: prefer .env overrides, fall back to host git config
    if [ -z "${GIT_USER_NAME:-}" ]; then
        GIT_USER_NAME=$(git config --global --get user.name 2>/dev/null || echo "")
    fi
    if [ -z "${GIT_USER_EMAIL:-}" ]; then
        GIT_USER_EMAIL=$(git config --global --get user.email 2>/dev/null || echo "")
    fi
    
    # Build docker command with conditional system packages and git config
    BUILD_ARGS="--build-arg USER_UID=$(id -u) --build-arg USER_GID=$(id -g)"
    if [ -n "${GIT_USER_NAME:-}" ] && [ -n "${GIT_USER_EMAIL:-}" ]; then
        BUILD_ARGS="$BUILD_ARGS --build-arg GIT_USER_NAME=\"$GIT_USER_NAME\" --build-arg GIT_USER_EMAIL=\"$GIT_USER_EMAIL\""
    fi
    if [ -n "${SYSTEM_PACKAGES:-}" ]; then
        echo "✓ Building with additional system packages: $SYSTEM_PACKAGES"
        BUILD_ARGS="$BUILD_ARGS --build-arg SYSTEM_PACKAGES=\"$SYSTEM_PACKAGES\""
    fi
    if [ -n "${CC_VERSION:-}" ]; then
        echo "✓ Building with Claude Code version: $CC_VERSION"
        BUILD_ARGS="$BUILD_ARGS --build-arg CC_VERSION=\"$CC_VERSION\""
    fi

    eval "'$DOCKER' build $NO_CACHE $BUILD_ARGS -t claude-docker:latest \"$PROJECT_ROOT\""
fi

# Verify required directories exist
if [ ! -d "$CLAUDE_HOME_DIR" ]; then
    echo "ERROR: Claude config directory not found: $CLAUDE_HOME_DIR"
    echo "Run: git submodule update --init --recursive"
    exit 1
fi

# Log configuration info
echo ""
echo "Claude config: $CLAUDE_HOME_DIR/"
echo "SSH keys: $SSH_DIR/"

# Check SSH key setup
if [ -f "$SSH_DIR/id_rsa" ]; then
    echo "SSH keys found for git operations"
else
    echo "No SSH keys found - git push/pull may not work"
fi

# Prepare additional mount arguments
MOUNT_ARGS=""
ENV_ARGS=""
DOCKER_OPTS=""

# Add memory limit if specified
if [ -n "${MEMORY_LIMIT:-}" ]; then
    echo "✓ Setting memory limit: $MEMORY_LIMIT"
    DOCKER_OPTS="$DOCKER_OPTS --memory $MEMORY_LIMIT"
fi

# Add GPU access if specified
if [ -n "${GPU_ACCESS:-}" ]; then
    # Check if nvidia-docker2 or nvidia-container-runtime is available
    if "$DOCKER" info 2>/dev/null | grep -q nvidia || which nvidia-docker >/dev/null 2>&1; then
        echo "✓ Enabling GPU access: $GPU_ACCESS"
        DOCKER_OPTS="$DOCKER_OPTS --gpus $GPU_ACCESS"
    else
        echo "⚠️  GPU access requested but NVIDIA Docker runtime not found"
        echo "   Install nvidia-docker2 or nvidia-container-runtime to enable GPU support"
        echo "   Continuing without GPU access..."
    fi
fi

# Enable host.docker.internal DNS so container can reach host services (e.g. vLLM on port 8000)
DOCKER_OPTS="$DOCKER_OPTS --add-host=host.docker.internal:host-gateway"

# Mount conda installation if specified
if [ -n "${CONDA_PREFIX:-}" ] && [ -d "$CONDA_PREFIX" ]; then
    echo "✓ Mounting conda installation from $CONDA_PREFIX"
    MOUNT_ARGS="$MOUNT_ARGS -v $CONDA_PREFIX:$CONDA_PREFIX:ro"
    ENV_ARGS="$ENV_ARGS -e CONDA_PREFIX=$CONDA_PREFIX -e CONDA_EXE=$CONDA_PREFIX/bin/conda"
else
    echo "No conda installation configured"
fi

# Mount additional conda directories if specified
if [ -n "${CONDA_EXTRA_DIRS:-}" ]; then
    echo "✓ Mounting additional conda directories..."
    CONDA_ENVS_PATHS=""
    CONDA_PKGS_PATHS=""
    for dir in $CONDA_EXTRA_DIRS; do
        if [ -d "$dir" ]; then
            echo "  - Mounting $dir"
            MOUNT_ARGS="$MOUNT_ARGS -v $dir:$dir:ro"
            # Build comma-separated list for CONDA_ENVS_DIRS
            if [[ "$dir" == *"env"* ]]; then
                if [ -z "${CONDA_ENVS_PATHS:-}" ]; then
                    CONDA_ENVS_PATHS="$dir"
                else
                    CONDA_ENVS_PATHS="$CONDA_ENVS_PATHS:$dir"
                fi
            fi
            # Build comma-separated list for CONDA_PKGS_DIRS
            if [[ "$dir" == *"pkg"* ]]; then
                if [ -z "${CONDA_PKGS_PATHS:-}" ]; then
                    CONDA_PKGS_PATHS="$dir"
                else
                    CONDA_PKGS_PATHS="$CONDA_PKGS_PATHS:$dir"
                fi
            fi
        else
            echo "  - Skipping $dir (not found)"
        fi
    done
    # Set CONDA_ENVS_DIRS environment variable if we found env paths
    if [ -n "${CONDA_ENVS_PATHS:-}" ]; then
        ENV_ARGS="$ENV_ARGS -e CONDA_ENVS_DIRS=$CONDA_ENVS_PATHS"
        echo "  - Setting CONDA_ENVS_DIRS=$CONDA_ENVS_PATHS"
    fi
    # Set CONDA_PKGS_DIRS environment variable if we found pkg paths
    if [ -n "${CONDA_PKGS_PATHS:-}" ]; then
        ENV_ARGS="$ENV_ARGS -e CONDA_PKGS_DIRS=$CONDA_PKGS_PATHS"
        echo "  - Setting CONDA_PKGS_DIRS=$CONDA_PKGS_PATHS"
    fi
else
    echo "No additional conda directories configured"
fi

# Mount auth file if available
AUTH_MOUNT=""
if [ -n "$CLAUDE_AUTH_FILE" ] && [ -f "$CLAUDE_AUTH_FILE" ]; then
    AUTH_MOUNT="-v $CLAUDE_AUTH_FILE:/home/claude-user/.claude.json:ro"
fi

# Cleanup temp auth file on exit
cleanup() {
    if [ -n "${CLAUDE_AUTH_FILE:-}" ] && [[ "$CLAUDE_AUTH_FILE" == /tmp/* ]]; then
        rm -f "$CLAUDE_AUTH_FILE"
    fi
}
trap cleanup EXIT

# Run Claude Code in Docker
echo "Starting Claude Code in Docker..."
"$DOCKER" run -it --rm \
    $DOCKER_OPTS \
    -v "$CURRENT_DIR:/workspace" \
    -v "$CLAUDE_HOME_DIR:/home/claude-user/.claude:ro" \
    -v "$SSH_DIR:/home/claude-user/.ssh:ro" \
    $AUTH_MOUNT \
    $MOUNT_ARGS \
    $ENV_ARGS \
    -e CLAUDE_CONTINUE_FLAG="$CONTINUE_FLAG" \
    --workdir /workspace \
    --name "claude-docker-$(basename "$CURRENT_DIR")-$$" \
    claude-docker:latest ${ARGS[@]+"${ARGS[@]}"}
