#!/bin/bash
# Download models on cold start
# Custom node code lives on the network volume at /runpod-volume/ComfyUI/custom_nodes/
# Pip deps are baked into the Docker image.
# All downloads run in parallel. Script NEVER exits with error.

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
IPADAPTER_DIR="$MODELS_DIR/ipadapter"
CLIP_VISION_DIR="$MODELS_DIR/clip_vision"
ULTRALYTICS_DIR="$MODELS_DIR/ultralytics/bbox"
mkdir -p "$CHECKPOINTS_DIR" "$LORAS_DIR" "$IPADAPTER_DIR" "$CLIP_VISION_DIR" "$ULTRALYTICS_DIR" 2>/dev/null

# Clean up broken _pip_deps directory if it exists (leftover from old setup attempts)
rm -rf "$VOLUME/ComfyUI/custom_nodes/_pip_deps" 2>/dev/null

# =============================================================================
# CUSTOM NODE BRIDGE — symlink volume custom nodes into Docker ComfyUI
# =============================================================================
# Problem: ComfyUI may run from /comfyui/ (Docker) or /workspace/ComfyUI/ (volume).
# The base image's start.sh does: rm -rf /workspace && ln -s /runpod-volume /workspace
# then cd /workspace/ComfyUI && python main.py. But if ComfyUI's node scanner
# uses a hardcoded path or the symlink race-conditions, custom nodes are invisible.
#
# Fix: symlink every custom node from the volume into BOTH possible locations,
# AND create extra_model_paths.yaml as a belt-and-suspenders config.
# =============================================================================

VOLUME_NODES="$VOLUME/ComfyUI/custom_nodes"
DOCKER_NODES="/comfyui/custom_nodes"

if [ -d "$VOLUME_NODES" ] && [ -d "$DOCKER_NODES" ]; then
    echo "worker-comfyui-custom: Bridging custom nodes from volume → Docker..."
    for node_dir in "$VOLUME_NODES"/*/; do
        [ -d "$node_dir" ] || continue
        node_name=$(basename "$node_dir")
        # Skip internal dirs
        [[ "$node_name" == __pycache__* ]] && continue
        [[ "$node_name" == .* ]] && continue
        if [ ! -e "$DOCKER_NODES/$node_name" ]; then
            ln -sf "$node_dir" "$DOCKER_NODES/$node_name" 2>/dev/null && \
                echo "worker-comfyui-custom:   ✓ $node_name"
        else
            echo "worker-comfyui-custom:   · $node_name (already exists)"
        fi
    done
else
    echo "worker-comfyui-custom: WARN: Volume nodes=$VOLUME_NODES exists=$([ -d "$VOLUME_NODES" ] && echo yes || echo no), Docker nodes=$DOCKER_NODES exists=$([ -d "$DOCKER_NODES" ] && echo yes || echo no)"
fi

# Create extra_model_paths.yaml — tells ComfyUI to also look at the volume for models
# This is the official ComfyUI way to merge multiple model directories
EXTRA_PATHS_FILE="$VOLUME/ComfyUI/extra_model_paths.yaml"
if [ -d "$VOLUME/ComfyUI" ]; then
    cat > "$EXTRA_PATHS_FILE" << 'YAMLEOF'
runpod_volume:
    base_path: /runpod-volume/
    checkpoints: models/checkpoints/
    loras: models/loras/
    ipadapter: models/ipadapter/
    clip_vision: models/clip_vision/
    ultralytics: models/ultralytics/
YAMLEOF
    echo "worker-comfyui-custom: Created extra_model_paths.yaml"
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
