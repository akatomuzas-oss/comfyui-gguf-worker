#!/bin/bash
# Download models on cold start — all from HuggingFace for max speed + global availability
# No network volume required — models cached on worker local disk between invocations.
# All downloads run in parallel via aria2c (16 connections per file).
# Script NEVER exits with error.

set +e

HF_REPO="https://huggingface.co/tomuzas/aivora-models/resolve/main"
# HF_TOKEN env var set on RunPod template for private repo access
HF_AUTH=""
if [ -n "$HF_TOKEN" ]; then
    HF_AUTH="Authorization: Bearer $HF_TOKEN"
    echo "worker-comfyui-custom: HF token found, private repo access enabled"
fi

# ── Model directories ──────────────────────────────────────────────────────────
# Use /runpod-volume if available (legacy), otherwise /comfyui/models
VOLUME="/runpod-volume"
if [ -d "$VOLUME" ]; then
    MODELS_DIR="$VOLUME/models"
    echo "worker-comfyui-custom: Volume detected → $MODELS_DIR"
else
    MODELS_DIR="/comfyui/models"
    echo "worker-comfyui-custom: No volume → local $MODELS_DIR"
fi
CHECKPOINTS_DIR="$MODELS_DIR/checkpoints"
DIFFUSION_DIR="$MODELS_DIR/diffusion_models"
UNET_DIR="$MODELS_DIR/unet"
LORAS_DIR="$MODELS_DIR/loras"
IPADAPTER_DIR="$MODELS_DIR/ipadapter"
CLIP_VISION_DIR="$MODELS_DIR/clip_vision"
CLIP_DIR="$MODELS_DIR/clip"
TEXT_ENCODERS_DIR="$MODELS_DIR/text_encoders"
VAE_DIR="$MODELS_DIR/vae"
UPSCALE_DIR="$MODELS_DIR/upscale_models"
ULTRALYTICS_DIR="$MODELS_DIR/ultralytics/bbox"
mkdir -p "$CHECKPOINTS_DIR" "$DIFFUSION_DIR" "$UNET_DIR" "$LORAS_DIR" "$IPADAPTER_DIR" \
         "$CLIP_VISION_DIR" "$CLIP_DIR" "$TEXT_ENCODERS_DIR" "$VAE_DIR" "$UPSCALE_DIR" \
         "$ULTRALYTICS_DIR" 2>/dev/null

# Clean up broken _pip_deps directory if it exists (leftover from old setup attempts)
rm -rf "$VOLUME/ComfyUI/custom_nodes/_pip_deps" 2>/dev/null

# =============================================================================
# CUSTOM NODE BRIDGE — ensure nodes are visible no matter which path ComfyUI uses
# =============================================================================
DOCKER_NODES="/comfyui/custom_nodes"
VOLUME_COMFYUI="$VOLUME/ComfyUI"
VOLUME_NODES="$VOLUME_COMFYUI/custom_nodes"

mkdir -p "$VOLUME_NODES" 2>/dev/null

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

# MODEL PATH BRIDGE
DOCKER_MODELS="/comfyui/models"
echo "worker-comfyui-custom: Bridging model directories..."
for dir_name in checkpoints diffusion_models unet loras ipadapter clip_vision clip text_encoders vae upscale_models ultralytics; do
    src="$MODELS_DIR/$dir_name"
    dst="$DOCKER_MODELS/$dir_name"
    if [ -d "$src" ]; then
        if [ -L "$dst" ] || [ ! -d "$dst" ]; then
            rm -rf "$dst" 2>/dev/null
            ln -sf "$src" "$dst" && echo "worker-comfyui-custom:   ✓ models/$dir_name → docker"
        else
            for f in "$src"/*; do
                [ -e "$f" ] || continue
                fname=$(basename "$f")
                [ ! -e "$dst/$fname" ] && ln -sf "$f" "$dst/$fname" 2>/dev/null
            done
            echo "worker-comfyui-custom:   ✓ models/$dir_name (contents linked)"
        fi
    fi
done

# extra_model_paths.yaml as belt-and-suspenders
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
    text_encoders: models/text_encoders/
    vae: models/vae/
    upscale_models: models/upscale_models/
YAMLEOF
    echo "worker-comfyui-custom: Created extra_model_paths.yaml"
fi

# ── Download helper ────────────────────────────────────────────────────────────
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
    if command -v aria2c &>/dev/null; then
        if [ -n "$HF_AUTH" ]; then
            aria2c -x 16 -s 16 --max-tries=3 --timeout=120 --max-file-not-found=3 \
                --allow-overwrite=true --auto-file-renaming=false --console-log-level=error \
                --header="$HF_AUTH" \
                -d "$dest_dir" -o "$dest_file" "$url" 2>&1 | tail -1
        else
            aria2c -x 16 -s 16 --max-tries=3 --timeout=120 --max-file-not-found=3 \
                --allow-overwrite=true --auto-file-renaming=false --console-log-level=error \
                -d "$dest_dir" -o "$dest_file" "$url" 2>&1 | tail -1
        fi
    else
        if [ -n "$HF_AUTH" ]; then
            wget --timeout=120 --tries=3 --max-redirect=5 -q --header="$HF_AUTH" -O "$dest" "$url" 2>&1
        else
            wget --timeout=120 --tries=3 --max-redirect=5 -q -O "$dest" "$url" 2>&1
        fi
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

DOWNLOAD_START=$(date +%s)

# =============================================================================
# IMAGE GENERATION MODELS (~10GB total)
# =============================================================================

# Checkpoint
download "$HF_REPO/checkpoints/cyberrealistic-pony-v16.safetensors" \
    "$CHECKPOINTS_DIR/cyberrealistic-pony-v16.safetensors" "CyberRealistic Pony v16" 3000000000 &
PID_IMG1=$!

# Quality LoRAs
download "$HF_REPO/loras/AmateurStyle_v1_PONY_REALISM.safetensors" \
    "$LORAS_DIR/AmateurStyle_v1_PONY_REALISM.safetensors" "AmateurStyle LoRA" 1000000 &
PID_IMG2=$!

download "https://civitai.com/api/download/models/556208" \
    "$LORAS_DIR/igbaddie-PN.safetensors" "igbaddie-PN LoRA" 1000000 &
PID_IMG3=$!

# IP-Adapter face locking
download "$HF_REPO/ipadapter/ip-adapter-plus-face_sdxl_vit-h.safetensors" \
    "$IPADAPTER_DIR/ip-adapter-plus-face_sdxl_vit-h.safetensors" "IP-Adapter Plus Face" 50000000 &
PID_IMG4=$!

download "$HF_REPO/clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors" \
    "$CLIP_VISION_DIR/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors" "CLIP-ViT-H-14" 1000000000 &
PID_IMG5=$!

# FaceDetailer + hand detector
download "https://huggingface.co/ultralytics/assets/resolve/main/yolov8m-face.pt" \
    "$ULTRALYTICS_DIR/face_yolov8m.pt" "YOLO v8m Face" 10000000 &
PID_IMG6=$!

download "$HF_REPO/ultralytics/bbox/hand_yolov8s.pt" \
    "$ULTRALYTICS_DIR/hand_yolov8s.pt" "YOLO v8s Hand" 5000000 &
PID_IMG7=$!

# Upscaler
download "$HF_REPO/upscale_models/4x-UltraSharp.pth" \
    "$UPSCALE_DIR/4x-UltraSharp.pth" "4x-UltraSharp" 30000000 &
PID_IMG8=$!

# =============================================================================
# VIDEO GENERATION MODELS — BoundBite v10 dual-expert (~36GB total)
# =============================================================================

# BoundBite v10 — UNETLoader scans diffusion_models/ and unet/, NOT checkpoints/
download "$HF_REPO/checkpoints/wan22I2V-BoundBite-High-v10.safetensors" \
    "$DIFFUSION_DIR/wan22I2V-BoundBite-High-v10.safetensors" "BoundBite v10 High" 10000000000 &
PID_VID1=$!

download "$HF_REPO/checkpoints/wan22I2V-BoundBite-Low-v10.safetensors" \
    "$DIFFUSION_DIR/wan22I2V-BoundBite-Low-v10.safetensors" "BoundBite v10 Low" 10000000000 &
PID_VID2=$!

# Text encoder — CLIPLoader scans clip/ and text_encoders/
download "$HF_REPO/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
    "$CLIP_DIR/umt5_xxl_fp8_e4m3fn_scaled.safetensors" "UMT5-XXL FP8" 3000000000 &
PID_VID3=$!

download "$HF_REPO/vae/wan_2.1_vae.safetensors" \
    "$VAE_DIR/wan_2.1_vae.safetensors" "WAN 2.1 VAE" 100000000 &
PID_VID4=$!

download "$HF_REPO/clip_vision/clip_vision_h.safetensors" \
    "$CLIP_VISION_DIR/clip_vision_h.safetensors" "CLIP Vision H (WAN)" 1000000000 &
PID_VID5=$!

# NSFW motion LoRAs (dual-expert pairs)
download "$HF_REPO/loras/wan2.2_i2v_highnoise_pov_missionary_v1.0.safetensors" \
    "$LORAS_DIR/wan2.2_i2v_highnoise_pov_missionary_v1.0.safetensors" "Missionary LoRA (High)" 100000000 &
PID_VID6=$!

download "$HF_REPO/loras/wan2.2_i2v_lownoise_pov_missionary_v1.0.safetensors" \
    "$LORAS_DIR/wan2.2_i2v_lownoise_pov_missionary_v1.0.safetensors" "Missionary LoRA (Low)" 100000000 &
PID_VID7=$!

download "$HF_REPO/loras/wan2.2_i2v_highnoise_general_nsfw.safetensors" \
    "$LORAS_DIR/wan2.2_i2v_highnoise_general_nsfw.safetensors" "NSFW General LoRA (High)" 100000000 &
PID_VID8=$!

download "$HF_REPO/loras/wan2.2_i2v_lownoise_general_nsfw.safetensors" \
    "$LORAS_DIR/wan2.2_i2v_lownoise_general_nsfw.safetensors" "NSFW General LoRA (Low)" 100000000 &
PID_VID9=$!

download "$HF_REPO/loras/wan2.2-i2v-high-oral-insertion-v1.0.safetensors" \
    "$LORAS_DIR/wan2.2-i2v-high-oral-insertion-v1.0.safetensors" "Oral LoRA (High)" 100000000 &
PID_VID10=$!

download "$HF_REPO/loras/wan2.2-i2v-low-oral-insertion-v1.0.safetensors" \
    "$LORAS_DIR/wan2.2-i2v-low-oral-insertion-v1.0.safetensors" "Oral LoRA (Low)" 100000000 &
PID_VID11=$!

# Paizuri / Titfuck LoRA (HuggingFace — dual expert pair)
download "$HF_REPO/loras/wan2.2-i2v-high-pov-paizuri-v1.0.safetensors" \
    "$LORAS_DIR/wan2.2-i2v-high-pov-paizuri-v1.0.safetensors" "Paizuri LoRA (High)" 100000000 &
PID_VID12=$!

download "$HF_REPO/loras/wan2.2-i2v-low-pov-paizuri-v1.0.safetensors" \
    "$LORAS_DIR/wan2.2-i2v-low-pov-paizuri-v1.0.safetensors" "Paizuri LoRA (Low)" 100000000 &
PID_VID13=$!

# Solo fingering LoRA (single-file, used on both experts)
download "$HF_REPO/loras/wan2.2-i2v-fingering-v1.0.safetensors" \
    "$LORAS_DIR/wan2.2-i2v-fingering-v1.0.safetensors" "Fingering LoRA" 100000000 &
PID_VID14=$!

# Female masturbation LoRA (single-file, used on both experts)
download "$HF_REPO/loras/wan2.2-i2v-female-masturbation-v1.0.safetensors" \
    "$LORAS_DIR/wan2.2-i2v-female-masturbation-v1.0.safetensors" "Masturbation LoRA" 100000000 &
PID_VID15=$!

# =============================================================================
# Wait for ALL downloads
# =============================================================================
wait $PID_IMG1 $PID_IMG2 $PID_IMG3 $PID_IMG4 $PID_IMG5 $PID_IMG6 $PID_IMG7 $PID_IMG8 \
     $PID_VID1 $PID_VID2 $PID_VID3 $PID_VID4 $PID_VID5 $PID_VID6 $PID_VID7 $PID_VID8 $PID_VID9 $PID_VID10 $PID_VID11 \
     $PID_VID12 $PID_VID13 $PID_VID14 $PID_VID15

DOWNLOAD_END=$(date +%s)
echo "worker-comfyui-custom: All downloads complete in $((DOWNLOAD_END-DOWNLOAD_START))s"

echo "worker-comfyui-custom: All setup complete."

exit 0
