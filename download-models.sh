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
# CUSTOM NODE BRIDGE — ensure nodes are visible no matter which path ComfyUI uses
# =============================================================================
# Custom nodes are baked into Docker at /comfyui/custom_nodes/.
# But start.sh may run ComfyUI from /workspace/ComfyUI/ (= /runpod-volume/ComfyUI/).
# Bridge: symlink Docker-baked nodes into the volume path so both locations work.
# =============================================================================

DOCKER_NODES="/comfyui/custom_nodes"
VOLUME_COMFYUI="$VOLUME/ComfyUI"
VOLUME_NODES="$VOLUME_COMFYUI/custom_nodes"

# Ensure volume ComfyUI custom_nodes dir exists
mkdir -p "$VOLUME_NODES" 2>/dev/null

# Bridge Docker-baked nodes → volume (so /workspace/ComfyUI/ path finds them)
echo "worker-comfyui-custom: Bridging Docker custom nodes → volume..."
for node_dir in "$DOCKER_NODES"/*/; do
    [ -d "$node_dir" ] || continue
    node_name=$(basename "$node_dir")
    [[ "$node_name" == __pycache__* ]] && continue
    [[ "$node_name" == .* ]] && continue
    if [ ! -e "$VOLUME_NODES/$node_name" ]; then
        ln -sf "$node_dir" "$VOLUME_NODES/$node_name" 2>/dev/null && \
            echo "worker-comfyui-custom:   ✓ $node_name → volume"
    else
        echo "worker-comfyui-custom:   · $node_name (already on volume)"
    fi
done

# Also bridge any extra volume-only nodes → Docker (belt and suspenders)
for node_dir in "$VOLUME_NODES"/*/; do
    [ -d "$node_dir" ] || continue
    node_name=$(basename "$node_dir")
    [[ "$node_name" == __pycache__* ]] && continue
    [[ "$node_name" == .* ]] && continue
    if [ ! -e "$DOCKER_NODES/$node_name" ]; then
        ln -sf "$node_dir" "$DOCKER_NODES/$node_name" 2>/dev/null && \
            echo "worker-comfyui-custom:   ✓ $node_name → docker"
    fi
done

# MODEL PATH BRIDGE — symlink volume model dirs into Docker ComfyUI models
# The extra_model_paths.yaml approach is unreliable, so we also directly symlink.
DOCKER_MODELS="/comfyui/models"
echo "worker-comfyui-custom: Bridging model directories..."
for dir_name in checkpoints loras ipadapter clip_vision ultralytics; do
    src="$MODELS_DIR/$dir_name"
    dst="$DOCKER_MODELS/$dir_name"
    if [ -d "$src" ]; then
        if [ -L "$dst" ] || [ ! -d "$dst" ]; then
            rm -rf "$dst" 2>/dev/null
            ln -sf "$src" "$dst" && echo "worker-comfyui-custom:   ✓ models/$dir_name → docker"
        else
            # Docker already has this dir — symlink contents instead
            for f in "$src"/*; do
                [ -e "$f" ] || continue
                fname=$(basename "$f")
                [ ! -e "$dst/$fname" ] && ln -sf "$f" "$dst/$fname" 2>/dev/null
            done
            echo "worker-comfyui-custom:   ✓ models/$dir_name (contents linked)"
        fi
    fi
done

# Also create extra_model_paths.yaml as belt-and-suspenders
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
    local dest_dir=$(dirname "$dest")
    local dest_file=$(basename "$dest")
    # aria2c: 16 parallel connections per file — ~4-8x faster than wget for large models
    if command -v aria2c &>/dev/null; then
        aria2c -x 16 -s 16 --max-tries=3 --timeout=120 --max-file-not-found=3 \
            --allow-overwrite=true --auto-file-renaming=false \
            -d "$dest_dir" -o "$dest_file" "$url" 2>&1 | tail -1
    else
        wget --timeout=120 --tries=3 --max-redirect=5 -q -O "$dest" "$url" 2>&1
    fi
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

# === WAN 2.2 I2V NSFW Motion LoRAs (dual-expert: high-noise + low-noise pairs) ===

# POV Missionary (dtwr434) — high & low noise experts
download "https://civitai.com/api/download/models/2098405" \
    "$LORAS_DIR/wan2.2_i2v_highnoise_pov_missionary_v1.0.safetensors" "WAN Missionary LoRA (High)" 100000000 &
PID7=$!

download "https://civitai.com/api/download/models/2098396" \
    "$LORAS_DIR/wan2.2_i2v_lownoise_pov_missionary_v1.0.safetensors" "WAN Missionary LoRA (Low)" 100000000 &
PID8=$!

# CubeyAI General NSFW — high & low noise experts (covers doggy, cowgirl, anal, etc.)
download "https://civitai.com/api/download/models/2073605" \
    "$LORAS_DIR/NSFW-22-H-e8.safetensors" "WAN NSFW General LoRA (High)" 100000000 &
PID9=$!

download "https://civitai.com/api/download/models/2083303" \
    "$LORAS_DIR/NSFW-22-L-e8.safetensors" "WAN NSFW General LoRA (Low)" 100000000 &
PID10=$!

# Oral Insertion (LocalOptima) — bundled as zip, needs unzip
download "https://civitai.com/api/download/models/2121297" \
    "$LORAS_DIR/wan2.2-i2v-oral-insertion-v1.0.zip" "WAN Oral LoRA (zip)" 100000000 &
PID11=$!

# Wait for all downloads
wait $PID1 $PID2 $PID3 $PID4 $PID5 $PID6 $PID7 $PID8 $PID9 $PID10 $PID11

# Unzip oral insertion LoRA if it exists and hasn't been extracted yet
ORAL_ZIP="$LORAS_DIR/wan2.2-i2v-oral-insertion-v1.0.zip"
if [ -f "$ORAL_ZIP" ]; then
    # Check if already extracted (look for any oral insertion safetensors)
    ORAL_COUNT=$(ls "$LORAS_DIR"/wan2.2*oral*safetensors 2>/dev/null | wc -l)
    if [ "$ORAL_COUNT" -lt 2 ]; then
        echo "worker-comfyui-custom: Extracting oral insertion LoRA..."
        unzip -o "$ORAL_ZIP" -d "$LORAS_DIR/" 2>/dev/null
        # List extracted files
        ls -la "$LORAS_DIR"/wan2.2*oral* 2>/dev/null
        echo "worker-comfyui-custom: Oral LoRA extracted"
    else
        echo "worker-comfyui-custom: Oral LoRA already extracted, skip"
    fi
fi

echo "worker-comfyui-custom: All setup complete."

exit 0
