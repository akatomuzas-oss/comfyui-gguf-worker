#!/usr/bin/env bash
# Bake pose LoRAs into the Docker image at build time.
#
# Sources mix:
#   - PUBLIC HF repos (no auth) — for LoRAs whose authors uploaded to HF.
#   - Civitai (auth required) — for DR34MSC4PE's All-In-One LoRA which
#     is the documented multi-pose replacement for the old yeqiu168182
#     missionary/oral-insertion LoRAs that shipped with empty model
#     cards. Civitai requires a Bearer token on download requests; the
#     Dockerfile mounts /run/secrets/civitai_token via buildx --secret
#     so the value never lands in image layers or build logs.
#
# Files are placed at /comfyui/models/loras/ with the EXACT filenames
# the worker code expects (POSE_LORA_MAP in
# src/lib/comfyui/video-workflows.ts).
#
# Cold-start impact: zero. Files are in the image, download-models.sh's
# "skip if exists" check leaves them alone.

set -euo pipefail

DEST=/comfyui/models/loras
mkdir -p "$DEST"
cd "$DEST"

# Hardened wget: 3 retries, 120s timeout, fail on HTTP errors so a missing
# file kills the build instead of shipping a 0-byte safetensors.
WGET="wget --tries=3 --timeout=120 --quiet --show-progress --progress=dot:giga"

# Read Civitai token from the buildx secret mount (see Dockerfile RUN
# line). If the file doesn't exist (e.g. running this script outside CI
# without --secret), fall back to the env var; if neither is set, the
# Civitai fetch step below fails loudly so we never ship an image
# missing the all-in-one LoRA.
CIVITAI_TOKEN_FILE="/run/secrets/civitai_token"
CIVITAI_TOKEN_VALUE=""
if [ -f "$CIVITAI_TOKEN_FILE" ]; then
    CIVITAI_TOKEN_VALUE=$(cat "$CIVITAI_TOKEN_FILE")
elif [ -n "${CIVITAI_TOKEN:-}" ]; then
    CIVITAI_TOKEN_VALUE="$CIVITAI_TOKEN"
fi

fetch() {
    local url="$1" target="${2:-}"
    if [ -n "$target" ]; then
        $WGET -O "$target" "$url"
    else
        $WGET "$url"
    fi
    local fname="${target:-$(basename "$url")}"
    local size
    size=$(stat -c%s "$fname")
    if [ "$size" -lt 50000000 ]; then
        echo "ERROR: $fname is suspiciously small ($size bytes) — likely 404 HTML" >&2
        exit 1
    fi
    echo "  ✓ $fname ($(numfmt --to=iec --suffix=B "$size"))"
}

# Civitai requires Bearer auth → presigned R2 redirect. curl -L follows
# the redirect, the R2 URL itself is anonymous-readable.
fetch_civitai() {
    local version_id="$1" target="$2"
    if [ -z "$CIVITAI_TOKEN_VALUE" ]; then
        echo "ERROR: no CIVITAI_TOKEN provided — needed to download $target from civitai.com/api/download/models/$version_id" >&2
        exit 1
    fi
    curl -fL --retry 3 --retry-delay 5 --max-time 600 \
        -A "Mozilla/5.0" \
        -H "Authorization: Bearer $CIVITAI_TOKEN_VALUE" \
        -o "$target" \
        "https://civitai.com/api/download/models/$version_id"
    local size
    size=$(stat -c%s "$target")
    if [ "$size" -lt 50000000 ]; then
        echo "ERROR: $target is suspiciously small ($size bytes) — civitai download failed" >&2
        exit 1
    fi
    echo "  ✓ $target ($(numfmt --to=iec --suffix=B "$size")) [civitai $version_id]"
}

echo "═══ DR34ML4Y All-In-One NSFW (DR34MSC4PE, civitai 1811313) ═══"
# Replaces yeqiu168182 missionary (HIGH+LOW) and oral-insertion
# (HIGH+LOW) — those four files removed below. DR34ML4Y is documented
# with explicit leetspeak triggers (m15510n4ry, bl0wj0b, d0ubl3_bj,
# d0gg1e, c0wg1rl, r3v3rs3_c0wg1rl) for SIX poses in one dual-expert
# pair. Net image size impact: -214MB vs the four LoRAs it replaces.
fetch_civitai 2553151 "DR34ML4Y_I2V_14B_HIGH_V2.safetensors"
fetch_civitai 2553271 "DR34ML4Y_I2V_14B_LOW_V2.safetensors"

echo "═══ Doggystyle slider (wolfer45, dual-expert) ═══"
fetch "https://huggingface.co/wolfer45/I2V_doggyslider_high/resolve/main/I2V_doggyslider_high.safetensors"
fetch "https://huggingface.co/wolfer45/I2V_doggyslider_low/resolve/main/I2V_doggyslider_low.safetensors"

echo "═══ Assertive Cowgirl (Robertopaulson, single-file → cloned to HIGH+LOW) ═══"
fetch "https://huggingface.co/Robertopaulson/assertive-cowgirl/resolve/main/Wan-Hip_Slammin_Assertive_Cowgirl.safetensors" \
      "Wan22-I2V-HIGH-Assertive_Cowgirl.safetensors"
cp Wan22-I2V-HIGH-Assertive_Cowgirl.safetensors Wan22-I2V-LOW-Assertive_Cowgirl.safetensors
echo "  · cloned HIGH → LOW"

echo "═══ General NSFW catch-all (yeqiu168182, dual-expert, RENAMED) ═══"
fetch "https://huggingface.co/yeqiu168182/NSFW-22-H-e8/resolve/main/NSFW-22-H-e8.safetensors" \
      "wan2.2_i2v_highnoise_general_nsfw.safetensors"
fetch "https://huggingface.co/yeqiu168182/NSFW-22-L-e8/resolve/main/NSFW-22-L-e8.safetensors" \
      "wan2.2_i2v_lownoise_general_nsfw.safetensors"

echo "═══ Female masturbation (yeqiu168182, single-file, RENAMED) ═══"
fetch "https://huggingface.co/yeqiu168182/dildo_ride-14b-v2/resolve/main/dildo_ride-14b-v2.safetensors" \
      "wan2.2-i2v-female-masturbation-v1.0.safetensors"

echo "═══ Sensual fingering (alekzinder, dual-expert) ═══"
fetch "https://huggingface.co/alekzinder/Perfect_Fingering_Wan_2.2_I2V/resolve/main/Sensual_fingering_v1_high_noise.safetensors"
fetch "https://huggingface.co/alekzinder/Perfect_Fingering_Wan_2.2_I2V/resolve/main/Sensual_fingering_v1_low_noise.safetensors"

echo "═══ Paizuri / titfuck (Apraxas, dual-expert, RENAMED) ═══"
fetch "https://huggingface.co/Apraxas/pov-paizuri-tf-wan/resolve/main/WAN-2.2-I2V-POV-Titfuck-Paizuri-HIGH-v1.0.safetensors" \
      "wan2.2-i2v-high-pov-paizuri-v1.0.safetensors"
fetch "https://huggingface.co/Apraxas/pov-paizuri-tf-wan/resolve/main/WAN-2.2-I2V-POV-Titfuck-Paizuri-LOW-v1.0.safetensors" \
      "wan2.2-i2v-low-pov-paizuri-v1.0.safetensors"

echo "═══ Titty drop / breast rub (yeqiu168182 T2V, single-file → cloned to HIGH+LOW) ═══"
fetch "https://huggingface.co/yeqiu168182/wan_tittydrop_v1_t2v_14b/resolve/main/wan_tittydrop_v1_t2v_14b.safetensors" \
      "WAN2.2-BreastRubv2_HighNoise.safetensors"
cp WAN2.2-BreastRubv2_HighNoise.safetensors WAN2.2-BreastRubv2_LowNoise.safetensors
echo "  · cloned tittydrop HIGH → LOW"

echo
echo "═══ Final manifest ($(ls -1 "$DEST"/*.safetensors | wc -l) files, $(du -sh "$DEST" | cut -f1) total) ═══"
ls -lh "$DEST"
