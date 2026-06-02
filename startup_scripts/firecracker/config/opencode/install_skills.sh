#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/opencode"

echo "=== OpenCode Skills Installer ==="
echo "Source: $SCRIPT_DIR"
echo "Target: $DEST"
echo ""

# 1. Create directories
echo "[1/4] Creating directories..."
mkdir -p "$DEST/tools" "$DEST/skills"

# 2. Copy utils
echo "[2/4] Copying utils..."
cp "$SCRIPT_DIR"/utils/*.ts "$DEST/utils/"
echo "  → $(ls "$DEST/utils/"*.ts | wc -l) utils(s) copied"

# 2. Copy tools
echo "[3/4] Installing tools..."
cp "$SCRIPT_DIR"/tools/*.ts "$DEST/tools/"
echo "  → $(ls "$DEST/tools/"*.ts | wc -l) tool(s) copied"

# 3. Copy skills (preserve subdirectory structure)
echo "[4/4] Installing skills..."
for skill_dir in "$SCRIPT_DIR"/skills/*/; do
  skill_name="$(basename "$skill_dir")"
  mkdir -p "$DEST/skills/$skill_name"
  cp "$skill_dir"SKILL.md "$DEST/skills/$skill_name/"
  echo "  → $skill_name copied"
done

echo ""
echo "=== Done ==="
echo "Tools available globally at: $DEST/tools/"
echo "Skills available globally at: $DEST/skills/"
echo "Restart opencode to pick up changes."
