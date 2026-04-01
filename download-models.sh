#!/bin/bash
# Download models + sync custom nodes on cold start
# The worker runs ComfyUI from /workspace/ComfyUI/ (symlinked to /runpod-volume)
# Custom nodes are baked into Docker at /docker-custom-nodes/ and synced to volume here.
# All downloads run in parallel. Script NEVER exits with error.

set +e

VOLUME="/runpod-volume"
if [ -d "$VOLUME" ]; then
    MODELS_DIR="$VOLUME/models"
    CUSTOM_NODES_DIR="$VOLUME/ComfyUI/custom_nodes"
    echo "worker-comfyui-custom: Volume detected → $MODELS_DIR"
else
    MODELS_DIR="/comfyui/models"
    CUSTOM_NODES_DIR="/comfyui/custom_nodes"
    echo "worker-comfyui-custom: No volume → local $MODELS_DIR"
fi
CHECKPOINTS_DIR="$MODELS_DIR/checkpoints"
LORAS_DIR="$MODELS_DIR/loras"
IPADAPTER_DIR="$MODELS_DIR/ipadapter"
CLIP_VISION_DIR="$MODELS_DIR/clip_vision"
ULTRALYTICS_DIR="$MODELS_DIR/ultralytics/bbox"
mkdir -p "$CHECKPOINTS_DIR" "$LORAS_DIR" "$IPADAPTER_DIR" "$CLIP_VISION_DIR" "$ULTRALYTICS_DIR" "$CUSTOM_NODES_DIR" 2>/dev/null

# === Sync custom nodes from Docker image to volume ===
# Use symlinks — atomic, no partial copy issues, always points to Docker's fresh code
if [ -d "/docker-custom-nodes" ]; then
    echo "worker-comfyui-custom: Syncing custom nodes to volume via symlinks..."
    echo "worker-comfyui-custom: CUSTOM_NODES_DIR=$CUSTOM_NODES_DIR"
    echo "worker-comfyui-custom: Docker nodes: $(ls /docker-custom-nodes/)"
    for node_dir in /docker-custom-nodes/*/; do
        node_name=$(basename "$node_dir")
        target="$CUSTOM_NODES_DIR/$node_name"
        # Remove whatever was there (old clone, broken copy, stale symlink)
        rm -rf "$target"
        # Symlink to the Docker image's copy
        ln -sfn "$node_dir" "$target"
        echo "worker-comfyui-custom: Linked $node_name → $(readlink "$target")"
        # Verify the node has __init__.py
        if [ -f "$target/__init__.py" ]; then
            echo "worker-comfyui-custom: ✓ $node_name/__init__.py exists"
        else
            echo "worker-comfyui-custom: ✗ WARN: $node_name/__init__.py MISSING"
        fi
    done
    # List all custom nodes on volume for debugging
    echo "worker-comfyui-custom: All custom_nodes: $(ls "$CUSTOM_NODES_DIR/" 2>/dev/null)"
else
    echo "worker-comfyui-custom: WARN: /docker-custom-nodes not found, skipping sync"
fi

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
    wget --timeout=120 --tries=3 --max-redirect=5 -q -O "$dest" "$url" 2>&1
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

# === Checkpoint + LoRAs ===
download "https://huggingface.co/cyberdelia/CyberRealisticPony/resolve/main/CyberRealisticPony_V16.0_FP16.safetensors" \
    "$CHECKPOINTS_DIR/cyberrealistic-pony-v16.safetensors" "CyberRealistic Pony v16" 3000000000 &
PID1=$!

download "https://civitai.com/api/download/models/556208" \
    "$LORAS_DIR/igbaddie-PN.safetensors" "igbaddie-PN LoRA" 1000000 &
PID2=$!

download "https://huggingface.co/MarkBW/pony-amateur-xl/resolve/main/AmateurStyle_v1_PONY_REALISM.safetensors" \
    "$LORAS_DIR/AmateurStyle_v1_PONY_REALISM.safetensors" "AmateurStyle LoRA" 1000000 &
PID3=$!

# === IP-Adapter face locking models ===
download "https://huggingface.co/h94/IP-Adapter/resolve/main/sdxl_models/ip-adapter-plus-face_sdxl_vit-h.safetensors" \
    "$IPADAPTER_DIR/ip-adapter-plus-face_sdxl_vit-h.safetensors" "IP-Adapter Plus Face SDXL" 50000000 &
PID4=$!

download "https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors" \
    "$CLIP_VISION_DIR/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors" "CLIP-ViT-H-14" 1000000000 &
PID5=$!

# === FaceDetailer YOLO model ===
download "https://huggingface.co/ultralytics/assets/resolve/main/yolov8m-face.pt" \
    "$ULTRALYTICS_DIR/face_yolov8m.pt" "YOLO v8m Face" 10000000 &
PID6=$!

# Wait for all downloads
wait $PID1 $PID2 $PID3 $PID4 $PID5 $PID6

echo "worker-comfyui-custom: All setup complete."

exit 0
