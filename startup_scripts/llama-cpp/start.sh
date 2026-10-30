#!/bin/bash

# ==============================================================================
# Start script for llama.cpp in ROUTER MODE (multi-model)
# Optimized for 16GB VRAM (NVIDIA RTX 4090 notebook) + i9-14900HX + 96GB RAM
# ==============================================================================
#
# Router mode: llama-server launches with NO --model. Per-model config lives
# in models.ini (next to this script). Clients route by the "model" field.
# Add a new [section] to models.ini to register another model.

# Point to your llama.cpp build directory
LLAMA_CPP_DIR="$(dirname "$0")/llama.cpp/build"

# Add shared libraries to the library path
export LD_LIBRARY_PATH="$LLAMA_CPP_DIR/lib:$LLAMA_CPP_DIR/bin:${LD_LIBRARY_PATH:-}"

# ==============================================================================
# ROUTER CONFIGURATION (applies to the router process itself)
# ==============================================================================

HOST="0.0.0.0"
PORT="8001"
PRESET_SRC="$(dirname "$0")/models.ini"  # per-model preset template
PRESET="$(mktemp)" # rendered copy (models.ini cannot read env vars itself)
trap 'rm -f "$PRESET"' EXIT

# Model paths come from .env (gitignored) next to this script; no defaults.
ENV_FILE="$(dirname "$0")/.env"
if [ -f "$ENV_FILE" ]; then
        # shellcheck disable=SC1090
        source "$ENV_FILE"
fi
: "${LLAMA_MODELS_DIR:?Set LLAMA_MODELS_DIR in $(dirname "$0")/.env (see .env.example)}"
sed "s|\${MODELS_DIR}|$LLAMA_MODELS_DIR|g" "$PRESET_SRC" > "$PRESET"
MODELS_MAX=1                        # max models loaded at once (0 = unlimited)
N_PARALLEL=1                        # slots per model instance
THREADS=14                          # CPU threads (P-Cores only)

# Shared infra args below are INHERITED by every model instance and act as
# defaults. Any of them can be overridden per-model inside models.ini.
# (Model-specific things like ctx, sampling, mmproj, MTP live in models.ini.)

BATCH_SIZE=2048
UBATCH_SIZE=2048
CACHE_K="q8_0"
CACHE_V="q8_0"
CTX_CHECKPOINT=64
LOAD_MODE="mlock" # lock model in RAM (replaces --mlock --no-mmap)
FLASH_ATTN="on"

# ==============================================================================
# GPU CLOCK MANAGEMENT (OPTIONAL)
# ==============================================================================

# To enable graphics clock limiting, set INFER_GRAPHICS_MAX to a value lower
# than stock (3105 MHz). Leave empty or commented out to run at stock speeds.
# The minimum is set to 210 MHz (lowest supported) so the GPU can idle normally.
#
# Recommended values for inference:
#   2700 - Moderate reduction (~13% less than stock), minimal speed impact
#   2400 - Aggressive reduction (~23% less than stock), noticeable speed impact
#   2100 - Maximum reduction (~32% less than stock), significant speed impact

INFER_GRAPHICS_MAX=2700 # MHz ceiling (unset or comment out to disable)
INFER_GRAPHICS_MIN=210  # MHz floor (lowest supported)

# ==============================================================================
# GPU SETUP
# ==============================================================================

# Capture current persistence mode so we can restore it on exit
ORIGINAL_PERSISTENCE=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | tr -d '[:space:]')
if [ -z "$ORIGINAL_PERSISTENCE" ]; then
        ORIGINAL_PERSISTENCE="Disabled"
fi

# Enable persistence mode for smoother GPU state transitions
sudo nvidia-smi -pm 1

# Lock graphics clock range if INFER_GRAPHICS_MAX is set
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
echo "Starting llama.cpp server (ROUTER MODE)..."
echo "Preset: $PRESET_SRC (models dir: $LLAMA_MODELS_DIR)"
echo "Max simultaneous models: $MODELS_MAX"
echo "Threads: $THREADS (P-Cores only)"
if [ "$CLOCK_LOCKED" = true ]; then
        echo "GPU graphics clock: ${INFER_GRAPHICS_MIN}-${INFER_GRAPHICS_MAX} MHz (memory: auto)"
else
        echo "GPU graphics clock: stock (no limit applied)"
fi
echo "GPU persistence: Enabled (original: ${ORIGINAL_PERSISTENCE})"
echo "Listening on: http://$HOST:$PORT"
echo "List models:  curl http://$HOST:$PORT/v1/models"
echo ""

# No --model: that is what puts the server into router mode.
# Shared args below are inherited by every spawned model instance;
# per-model overrides (ctx, sampling, mmproj, MTP, load-on-startup) live in models.ini.
"$LLAMA_CPP_DIR/bin/llama-server" \
        --host "$HOST" \
        --port "$PORT" \
        --models-preset "$PRESET" \
        --models-max "$MODELS_MAX" \
        -np "$N_PARALLEL" \
        -b "$BATCH_SIZE" \
        -ub "$UBATCH_SIZE" \
        --cache-type-k "$CACHE_K" \
        --cache-type-v "$CACHE_V" \
        -ctxcp "$CTX_CHECKPOINT" \
        --threads "$THREADS" \
        --load-mode "$LOAD_MODE" \
        --flash-attn "$FLASH_ATTN" \
        --no-warmup \
        --jinja

# ==============================================================================
# RESTORE SETTINGS
# ==============================================================================

echo ""
echo "Restoring GPU settings..."

# Reset graphics clock lock if it was applied
if [ "$CLOCK_LOCKED" = true ]; then
        sudo nvidia-smi -rgc 2>/dev/null
        if [ $? -eq 0 ]; then
                echo "  Graphics clock lock removed (returning to stock)"
        else
                echo "  WARNING: Could not reset graphics clock"
        fi
fi

# Restore persistence mode
if [ "$ORIGINAL_PERSISTENCE" = "Disabled" ]; then
        sudo nvidia-smi -pm 0
        echo "  Persistence mode restored to Disabled"
else
        echo "  Persistence mode left Enabled (was already Enabled)"
fi

echo "Server stopped."
