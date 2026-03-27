#!/bin/bash
# Download CyberRealistic Pony models on cold start
# Downloads to /comfyui/models (local) or /runpod-volume/models (if volume mounted)
# All downloads run in parallel for speed. Script NEVER exits with error.

set +e

VOLUME="/runpod-volume"
if [ -d "$VOLUME" ]; then
    MODELS_DIR="$VOLUME/models"
    echo "worker-comfyui-custom: Volume detected → $MODELS_DIR"
else
    MODELS_DIR="/comfyui/models"
    echo "worker-comfyui-custom: No volume → local $MODELS_DIR"
fi
CHECKPOINTS_DIR="$MODELS_DIR/checkpoints"
LORAS_DIR="$MODELS_DIR/loras"
mkdir -p "$CHECKPOINTS_DIR" "$LORAS_DIR" 2>/dev/null

download() {
    local url="$1" dest="$2" name="$3" min_size="${4:-1000000}"
    if [ -f "$dest" ]; then
        local size=$(stat -c%s "$dest" 2>/dev/null || echo "0")
        if [ "$size" -gt "$min_size" ] 2>/dev/null; then
            echo "worker-comfyui-custom: $name exists (${size}B), skip"
            return 0
        fi
        rm -f "$dest"
    fi
    echo "worker-comfyui-custom: Downloading $name ..."
    local start=$(date +%s)
    wget --timeout=60 --tries=3 --max-redirect=5 -q -O "$dest" "$url" 2>&1
    local end=$(date +%s)
    if [ -f "$dest" ]; then
        local size=$(stat -c%s "$dest" 2>/dev/null || echo "0")
        if [ "$size" -gt "$min_size" ] 2>/dev/null; then
            echo "worker-comfyui-custom: $name done (${size}B) in $((end-start))s"
            return 0
        fi
    fi
    echo "worker-comfyui-custom: WARN: $name failed after $((end-start))s"
    rm -f "$dest"
    return 1
}

# Download all 3 in parallel
download "https://huggingface.co/cyberdelia/CyberRealisticPony/resolve/main/CyberRealisticPony_V16.0_FP16.safetensors" \
    "$CHECKPOINTS_DIR/cyberrealistic-pony-v16.safetensors" "CyberRealistic Pony v16" 3000000000 &
PID1=$!

download "https://civitai.com/api/download/models/556208" \
    "$LORAS_DIR/igbaddie-PN.safetensors" "igbaddie-PN LoRA" 1000000 &
PID2=$!

download "https://huggingface.co/MarkBW/pony-amateur-xl/resolve/main/AmateurStyle_v1_PONY_REALISM.safetensors" \
    "$LORAS_DIR/AmateurStyle_v1_PONY_REALISM.safetensors" "AmateurStyle LoRA" 1000000 &
PID3=$!

# Wait for all downloads
wait $PID1 $PID2 $PID3

echo "worker-comfyui-custom: Download complete."
ls -lh "$CHECKPOINTS_DIR/" 2>/dev/null
ls -lh "$LORAS_DIR/" 2>/dev/null

exit 0
