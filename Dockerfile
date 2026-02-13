# ABOUTME: Docker image for Claude Code with runtime MCP server support
# ABOUTME: Provides isolated Claude Code environment with cross-platform auth and config sharing

FROM node:20.18.1-slim

# delete default node user if exists
# we will likely need his UID
RUN deluser node || true
RUN delgroup node || true

# Install Node.js and required system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    wget \
    python3 \
    python3-pip \
    build-essential \
    sudo \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

# Install additional system packages if specified
ARG SYSTEM_PACKAGES=""
RUN if [ -n "$SYSTEM_PACKAGES" ]; then \
    echo "Installing additional system packages: $SYSTEM_PACKAGES" && \
    apt-get update && \
    apt-get install -y $SYSTEM_PACKAGES && \
    rm -rf /var/lib/apt/lists/*; \
else \
    echo "No additional system packages specified"; \
fi

# Create a non-root user with matching host UID/GID
ARG USER_UID=1000
ARG USER_GID=1000
RUN if getent group $USER_GID > /dev/null 2>&1; then \
        GROUP_NAME=$(getent group $USER_GID | cut -d: -f1); \
    else \
        groupadd -g $USER_GID claude-user && GROUP_NAME=claude-user; \
    fi && \
    useradd -m -s /bin/bash -u $USER_UID -g $GROUP_NAME claude-user && \
    echo "claude-user ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Create app directory
WORKDIR /app

# Install Claude Code globally (optionally a specific version)
ARG CC_VERSION=""
RUN if [ -n "$CC_VERSION" ]; then \
        echo "Installing Claude Code version: $CC_VERSION" && \
        npm install -g @anthropic-ai/claude-code@$CC_VERSION; \
    else \
        echo "Installing latest Claude Code" && \
        npm install -g @anthropic-ai/claude-code; \
    fi

# Ensure npm global bin is in PATH
ENV PATH="/usr/local/bin:${PATH}"

# Create directories for configuration
RUN mkdir -p /app/.claude /home/claude-user/.claude

# Copy startup script
COPY src/startup.sh /app/
RUN chmod +x /app/startup.sh

# Copy .env file during build to bake credentials into the image
# This enables one-time setup - no need for .env in project directories
COPY .env /app/.env

# Copy runtime MCP installer (MCP servers installed at startup, not build time)
COPY src/install-mcp-runtime.sh /app/
RUN chmod +x /app/install-mcp-runtime.sh

# Set proper ownership for everything
RUN chown -R claude-user /app /home/claude-user

# Switch to non-root user
USER claude-user

# Set HOME immediately after switching user
ENV HOME=/home/claude-user

# Install uv (Astral) for claude-user for Serena MCP (todo make this modular.)
# Note: Will be installed for claude-user after user creation
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Add claude-user's local bin to PATH
ENV PATH="/home/claude-user/.local/bin:${PATH}"

# MCP servers are now installed at runtime via startup.sh
# This allows per-project MCP configuration without rebuilding

# Configure git user during build using host git config passed as build args
ARG GIT_USER_NAME=""
ARG GIT_USER_EMAIL=""
RUN if [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; then \
        echo "Configuring git user from host: $GIT_USER_NAME <$GIT_USER_EMAIL>" && \
        git config --global user.name "$GIT_USER_NAME" && \
        git config --global user.email "$GIT_USER_EMAIL" && \
        echo "Git configuration complete"; \
    else \
        echo "Warning: No git user configured on host system"; \
        echo "Run 'git config --global user.name \"Your Name\"' and 'git config --global user.email \"you@example.com\"' on host first"; \
    fi

# Set working directory to mounted volume
WORKDIR /workspace

# Environment variables will be passed from host
ENV NODE_ENV=production

# Start both MCP server and Claude Code
ENTRYPOINT ["/app/startup.sh"]
