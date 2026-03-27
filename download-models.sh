#!/bin/bash
# Download CyberRealistic Pony models to network volume on first cold start
# Only downloads if files don't already exist on the volume

VOLUME="/runpod-volume"
MODELS_DIR="$VOLUME/models"
CHECKPOINTS_DIR="$MODELS_DIR/checkpoints"
LORAS_DIR="$MODELS_DIR/loras"

echo "worker-comfyui-custom: Checking for models on network volume..."

# Create directories if they don't exist
mkdir -p "$CHECKPOINTS_DIR" "$LORAS_DIR"

# Function to download a file if it doesn't exist
download_if_missing() {
    local url="$1"
    local dest="$2"
    local name="$3"
    local min_size="${4:-1000000}"  # Minimum expected size in bytes (default 1MB)

    if [ -f "$dest" ]; then
        local size
        size=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest" 2>/dev/null)
        if [ "$size" -gt "$min_size" ]; then
            echo "worker-comfyui-custom: $name already exists ($(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size} bytes")), skipping"
            return 0
        else
            echo "worker-comfyui-custom: $name exists but too small ($size bytes), re-downloading..."
            rm -f "$dest"
        fi
    fi

    echo "worker-comfyui-custom: Downloading $name..."
    local start
    start=$(date +%s)

    # Use wget with resume support and redirect following
    wget -q --show-progress --continue -O "$dest" "$url"

    local exit_code=$?
    local end
    end=$(date +%s)
    local elapsed=$((end - start))

    if [ $exit_code -eq 0 ] && [ -f "$dest" ]; then
        local size
        size=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest" 2>/dev/null)
        echo "worker-comfyui-custom: Downloaded $name ($(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size} bytes")) in ${elapsed}s"
    else
        echo "worker-comfyui-custom: FAILED to download $name (exit code: $exit_code)"
        rm -f "$dest"
        return 1
    fi
}

# --- Checkpoint ---
# CyberRealistic Pony v16 FP16 (~3.5GB) from HuggingFace (cyberdelia/CyberRealisticPony)
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

# AmateurStyle v1 Pony Realism (CivitAI model 1410317, version 1594293)
download_if_missing \
    "https://civitai.com/api/download/models/1594293" \
    "$LORAS_DIR/AmateurStyle_v1_PONY_REALISM.safetensors" \
    "AmateurStyle v1 Pony Realism LoRA" \
    1000000

echo "worker-comfyui-custom: Model check complete."
echo "worker-comfyui-custom: Checkpoints:"
ls -lh "$CHECKPOINTS_DIR/" 2>/dev/null
echo "worker-comfyui-custom: LoRAs:"
ls -lh "$LORAS_DIR/" 2>/dev/null
