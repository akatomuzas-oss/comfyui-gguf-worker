#!/bin/bash
# Download CyberRealistic Pony models to network volume on first cold start
# Only downloads if files don't already exist on the volume
# This script NEVER exits with error — start.sh must always run after it

set +e  # Don't exit on error

VOLUME="/runpod-volume"
MODELS_DIR="$VOLUME/models"
CHECKPOINTS_DIR="$MODELS_DIR/checkpoints"
LORAS_DIR="$MODELS_DIR/loras"

echo "worker-comfyui-custom: Checking for models on network volume..."

# Check if volume is mounted
if [ ! -d "$VOLUME" ]; then
    echo "worker-comfyui-custom: No network volume mounted at $VOLUME, skipping model download"
    exit 0
fi

# Create directories if they don't exist
mkdir -p "$CHECKPOINTS_DIR" "$LORAS_DIR" 2>/dev/null

# Function to download a file if it doesn't exist
download_if_missing() {
    local url="$1"
    local dest="$2"
    local name="$3"
    local min_size="${4:-1000000}"
    local timeout="${5:-300}"  # Download timeout in seconds

    if [ -f "$dest" ]; then
        local size
        size=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest" 2>/dev/null || echo "0")
        if [ "$size" -gt "$min_size" ] 2>/dev/null; then
            echo "worker-comfyui-custom: $name already exists ($size bytes), skipping"
            return 0
        else
            echo "worker-comfyui-custom: $name exists but too small ($size bytes), re-downloading..."
            rm -f "$dest"
        fi
    fi

    echo "worker-comfyui-custom: Downloading $name from $url ..."
    local start
    start=$(date +%s)

    # Use wget with timeout, redirect following, and quiet mode
    wget --timeout=30 --tries=2 --max-redirect=5 -q -O "$dest" "$url" 2>&1

    local exit_code=$?
    local end
    end=$(date +%s)
    local elapsed=$((end - start))

    if [ $exit_code -eq 0 ] && [ -f "$dest" ]; then
        local size
        size=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest" 2>/dev/null || echo "0")
        if [ "$size" -gt "$min_size" ] 2>/dev/null; then
            echo "worker-comfyui-custom: Downloaded $name ($size bytes) in ${elapsed}s"
            return 0
        else
            echo "worker-comfyui-custom: WARNING: $name downloaded but too small ($size bytes), removing"
            rm -f "$dest"
            return 1
        fi
    else
        echo "worker-comfyui-custom: WARNING: Failed to download $name (exit code: $exit_code) after ${elapsed}s"
        rm -f "$dest"
        return 1
    fi
}

# --- Checkpoint ---
# CyberRealistic Pony v16 FP16 (~3.5GB) from HuggingFace
download_if_missing \
    "https://huggingface.co/cyberdelia/CyberRealisticPony/resolve/main/CyberRealisticPony_V16.0_FP16.safetensors" \
    "$CHECKPOINTS_DIR/cyberrealistic-pony-v16.safetensors" \
    "CyberRealistic Pony v16 (FP16)" \
    3000000000

# --- LoRAs ---
# igbaddie-PN (CivitAI model 500352, version 556208)
download_if_missing \
    "https://civitai.com/api/download/models/556208" \
    "$LORAS_DIR/igbaddie-PN.safetensors" \
    "igbaddie-PN LoRA" \
    1000000

# AmateurStyle v1 Pony Realism (HuggingFace mirror — CivitAI requires auth)
# Original: CivitAI model 480835 "Pony Amateur" by MarkBW, version 534756
download_if_missing \
    "https://huggingface.co/MarkBW/pony-amateur-xl/resolve/main/AmateurStyle_v1_PONY_REALISM.safetensors" \
    "$LORAS_DIR/AmateurStyle_v1_PONY_REALISM.safetensors" \
    "AmateurStyle v1 Pony Realism LoRA" \
    1000000

echo "worker-comfyui-custom: Model check complete."
echo "worker-comfyui-custom: Checkpoints:"
ls -lh "$CHECKPOINTS_DIR/" 2>/dev/null || echo "  (none)"
echo "worker-comfyui-custom: LoRAs:"
ls -lh "$LORAS_DIR/" 2>/dev/null || echo "  (none)"

# Always exit 0 so start.sh runs
exit 0
