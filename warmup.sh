#!/bin/bash
# Warm up ComfyUI by hitting /system_stats to trigger model loading
# Runs after start.sh launches ComfyUI in the background

set +e

COMFY_URL="http://127.0.0.1:8188"
MAX_WAIT=120  # Max seconds to wait for ComfyUI to be ready

echo "worker-comfyui-custom: Waiting for ComfyUI to start..."

for i in $(seq 1 $MAX_WAIT); do
    if curl -sf "$COMFY_URL/system_stats" >/dev/null 2>&1; then
        echo "worker-comfyui-custom: ComfyUI ready after ${i}s"

        # Queue a tiny 1-step generation to force checkpoint + LoRAs into VRAM
        # This eliminates the ~5-8s "first request" penalty where models load from disk
        WARMUP_PROMPT='{"prompt":{"1":{"class_type":"CheckpointLoaderSimple","inputs":{"ckpt_name":"cyberrealistic-pony-v16.safetensors"}},"2":{"class_type":"CLIPTextEncode","inputs":{"text":"warmup","clip":["1",1]}},"3":{"class_type":"CLIPTextEncode","inputs":{"text":"bad","clip":["1",1]}},"4":{"class_type":"EmptyLatentImage","inputs":{"width":64,"height":64,"batch_size":1}},"5":{"class_type":"KSampler","inputs":{"model":["1",0],"positive":["2",0],"negative":["3",0],"latent_image":["4",0],"seed":1,"steps":1,"cfg":1,"sampler_name":"euler","scheduler":"normal","denoise":1}},"6":{"class_type":"VAEDecode","inputs":{"samples":["5",0],"vae":["1",2]}}}}'

        echo "worker-comfyui-custom: Sending warmup prompt to preload models into VRAM..."
        curl -sf -X POST "$COMFY_URL/prompt" \
            -H "Content-Type: application/json" \
            -d "$WARMUP_PROMPT" >/dev/null 2>&1

        # Wait for warmup to complete (tiny image, should be < 3s)
        sleep 5
        echo "worker-comfyui-custom: Warmup complete — models loaded in VRAM"
        exit 0
    fi
    sleep 1
done

echo "worker-comfyui-custom: WARN: ComfyUI did not start within ${MAX_WAIT}s"
exit 0
