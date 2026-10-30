#!/bin/bash

# ==============================================================================
# Start script for audiocpp_server (multi-model)
# Same pattern as ../llama-cpp: models.json template next to this script gets
# ${MODELS_DIR} rendered, then the server reads it via --config.
# Add a new entry to the "models" array in models.json to register a model.
# ==============================================================================

# Build output (see build.sh)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUDIOCPP_DIR="$SCRIPT_DIR/audio.cpp"
BIN_DIR="$AUDIOCPP_DIR/build/bin"

# start.sh depends on build.sh having produced the server binary.
if [ ! -x "$BIN_DIR/audiocpp_server" ]; then
        echo "ERROR: $BIN_DIR/audiocpp_server not found — run ./build.sh first" >&2
        exit 1
fi

# models.json template -> rendered copy (JSON cannot read env vars itself)
CONFIG_SRC="$SCRIPT_DIR/models.json"
CONFIG="$(mktemp)"
trap 'rm -f "$CONFIG"' EXIT

# Model paths come from .env (gitignored) next to this script; no defaults.
ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
        # shellcheck disable=SC1090
        source "$ENV_FILE"
fi
: "${AUDIO_MODELS_DIR:?Set AUDIO_MODELS_DIR in $SCRIPT_DIR/.env (see .env.example)}"
sed "s|\${MODELS_DIR}|$AUDIO_MODELS_DIR|g" "$CONFIG_SRC" > "$CONFIG"

# Host-side CUDA runtime libraries if the build links them dynamically
# (shared libs land in build/bin, see CMAKE_LIBRARY_OUTPUT_DIRECTORY).
export LD_LIBRARY_PATH="$BIN_DIR:${LD_LIBRARY_PATH:-}"

# ==============================================================================
# GPU CLOCK MANAGEMENT (OPTIONAL) — identical scheme to ../llama-cpp/start.sh
# ==============================================================================

INFER_GRAPHICS_MAX=2700 # MHz ceiling (unset or comment out to disable)
INFER_GRAPHICS_MIN=210  # MHz floor (lowest supported)

ORIGINAL_PERSISTENCE=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | tr -d '[:space:]') || true
if [ -z "$ORIGINAL_PERSISTENCE" ]; then
        ORIGINAL_PERSISTENCE="Disabled"
fi
sudo nvidia-smi -pm 1

CLOCK_LOCKED=false
if [ -n "$INFER_GRAPHICS_MAX" ]; then
        echo "Locking GPU graphics clock ceiling for inference..."
        sudo nvidia-smi -lgc "$INFER_GRAPHICS_MIN","$INFER_GRAPHICS_MAX" 2>/dev/null
        if [ $? -eq 0 ]; then
                CLOCK_LOCKED=true
                echo "  Graphics clock range: ${INFER_GRAPHICS_MIN}-${INFER_GRAPHICS_MAX} MHz (stock max: 3105)"
        else
                echo "  WARNING: Could not lock graphics clock (may not be supported)"
        fi
fi

# ==============================================================================
# EXECUTION
# ==============================================================================

echo ""
echo "Starting audiocpp_server (multi-model)..."
echo "Config: $CONFIG_SRC (models dir: $AUDIO_MODELS_DIR)"
echo "Listening on: http://0.0.0.0:8001 (from models.json, same port as ../llama-cpp — run one at a time)"
echo "List models:  curl http://localhost:8001/v1/models"
echo ""

# Run from the audio.cpp repo root so the default Silero VAD path
# (assets/framework/models/silero_vad) resolves, as upstream intends.
cd "$AUDIOCPP_DIR"
"$BIN_DIR/audiocpp_server" \
        --config "$CONFIG" \
        --log --log-file "$SCRIPT_DIR/audiocpp_server.log"

# ==============================================================================
# RESTORE SETTINGS
# ==============================================================================

echo ""
echo "Restoring GPU settings..."

if [ "$CLOCK_LOCKED" = true ]; then
        sudo nvidia-smi -rgc 2>/dev/null
        if [ $? -eq 0 ]; then
                echo "  Graphics clock lock removed (returning to stock)"
        else
                echo "  WARNING: Could not reset graphics clock"
        fi
fi

if [ "$ORIGINAL_PERSISTENCE" = "Disabled" ]; then
        sudo nvidia-smi -pm 0
        echo "  Persistence mode restored to Disabled"
else
        echo "  Persistence mode left Enabled (was already Enabled)"
fi

echo "Server stopped."
