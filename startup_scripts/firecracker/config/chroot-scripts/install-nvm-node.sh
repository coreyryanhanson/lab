#!/bin/bash
set -e

# Install nvm (idempotent — skips if already present)
if [ ! -d /root/.nvm ]; then
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi

export NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# Install latest LTS Node.js (idempotent — nvm skips if already installed)
nvm install --lts

# Explicitly set default alias (critical for non-interactive shells)
nvm alias default "$(nvm current)"

# Install OpenCode globally
npm install -g opencode-ai@latest

# Create nvm profile script with dynamic NODE_PATH
cat > /etc/profile.d/nvm.sh << 'NVM_PROFILE'
export NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# Make nvm global packages discoverable (even in non-interactive scripts)
# Derived from the active node's location — no hardcoded paths
[ -x "$(command -v node)" ] && export NODE_PATH="$(dirname "$(dirname "$(command -v node)")")/lib/node_modules"
NVM_PROFILE
