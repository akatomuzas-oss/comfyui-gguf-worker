#!/bin/bash
# Download models + install custom nodes on cold start
# The worker runs ComfyUI from /runpod-volume/ComfyUI/ using /runpod-volume/venv/
# So custom nodes and pip deps must be installed THERE, not in the Docker image.
# All downloads run in parallel for speed. Script NEVER exits with error.

set +e

VOLUME="/runpod-volume"
if [ -d "$VOLUME" ]; then
    MODELS_DIR="$VOLUME/models"
    CUSTOM_NODES_DIR="$VOLUME/ComfyUI/custom_nodes"
    VENV_PIP="$VOLUME/venv/bin/pip"
    echo "worker-comfyui-custom: Volume detected → $MODELS_DIR"
else
    MODELS_DIR="/comfyui/models"
    CUSTOM_NODES_DIR="/comfyui/custom_nodes"
    VENV_PIP="pip"
    echo "worker-comfyui-custom: No volume → local $MODELS_DIR"
fi
CHECKPOINTS_DIR="$MODELS_DIR/checkpoints"
LORAS_DIR="$MODELS_DIR/loras"
IPADAPTER_DIR="$MODELS_DIR/ipadapter"
CLIP_VISION_DIR="$MODELS_DIR/clip_vision"
ULTRALYTICS_DIR="$MODELS_DIR/ultralytics/bbox"
mkdir -p "$CHECKPOINTS_DIR" "$LORAS_DIR" "$IPADAPTER_DIR" "$CLIP_VISION_DIR" "$ULTRALYTICS_DIR" 2>/dev/null

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

# === Install custom nodes into the volume's ComfyUI ===
# These persist on the volume — only cloned once, then skipped on subsequent starts
if [ -d "$CUSTOM_NODES_DIR" ]; then
    # IP-Adapter Plus (face identity locking)
    if [ ! -d "$CUSTOM_NODES_DIR/ComfyUI_IPAdapter_plus" ]; then
        echo "worker-comfyui-custom: Installing ComfyUI_IPAdapter_plus..."
        cd "$CUSTOM_NODES_DIR" && git clone https://github.com/cubiq/ComfyUI_IPAdapter_plus 2>&1
    else
        echo "worker-comfyui-custom: ComfyUI_IPAdapter_plus already installed, skip"
    fi

    # Impact Pack (FaceDetailer)
    if [ ! -d "$CUSTOM_NODES_DIR/ComfyUI-Impact-Pack" ]; then
        echo "worker-comfyui-custom: Installing ComfyUI-Impact-Pack..."
        cd "$CUSTOM_NODES_DIR" && git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack 2>&1
        cd ComfyUI-Impact-Pack && $VENV_PIP install --no-cache-dir -r requirements.txt 2>&1
    else
        echo "worker-comfyui-custom: ComfyUI-Impact-Pack already installed, skip"
    fi

    # Install ultralytics + onnxruntime into the volume's venv (Impact Pack needs these)
    # Use a marker file to avoid re-installing every cold start
    if [ ! -f "$VOLUME/.ultralytics_installed" ]; then
        echo "worker-comfyui-custom: Installing ultralytics + onnxruntime into venv..."
        $VENV_PIP install --no-cache-dir ultralytics onnxruntime 2>&1
        touch "$VOLUME/.ultralytics_installed"
    else
        echo "worker-comfyui-custom: ultralytics already installed, skip"
    fi
fi

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
ls -lh "$CHECKPOINTS_DIR/" 2>/dev/null
ls -lh "$LORAS_DIR/" 2>/dev/null
ls -lh "$IPADAPTER_DIR/" 2>/dev/null
ls -lh "$CLIP_VISION_DIR/" 2>/dev/null
ls -lh "$ULTRALYTICS_DIR/" 2>/dev/null

exit 0
