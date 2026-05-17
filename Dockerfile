# syntax=docker/dockerfile:1.7
# The syntax directive above enables BuildKit features used below
# (RUN --mount=type=secret). Required so the Civitai token used by
# install-pose-loras.sh never lands in image layers or build logs.

FROM runpod/worker-comfyui:latest-base
# Rebuild: 2026-05-17 — REVERTED from 5.8.5-z-image-turbo back to
# :latest-base. The z-image-turbo variant did not boot on our worker
# setup (stuck at "initializing" indefinitely). Going back to the
# stable base + relying on RES4LYF (added below) to provide
# ClownsharkSampler_Beta directly, which is a custom node and works
# regardless of the base image's bundled ComfyUI version.
#
# Prior: 2026-05-16b — switched base from :latest-base to the
# z-image-turbo variant (this caused the boot failure). Why we tried:
#
# 1. :latest-base on RunPod's Docker Hub is a months-old build whose
#    bundled ComfyUI predates the `res_2s` sampler — required by
#    Juggernaut Z / Z-Image fine-tunes for their trained noise
#    schedule. Even pull:true couldn't help us; the upstream tag
#    itself was stale.
# 2. 5.8.5-z-image-turbo (rebuilt 2026-03-20) ships a current ComfyUI
#    pinned to a version that supports Z-Image's full feature set
#    out of the box, plus the UNETLoader / VAELoader / CLIPLoader
#    nodes for the Qwen-text-encoder pipeline already wired in.
# 3. Our /workspace/ComfyUI/extra_model_paths.yaml still drives model
#    discovery — Juggernaut Z UNet, qwen_3_4b encoder, zimage_ae VAE,
#    and all Pony LoRAs continue to resolve from the volume. Nothing
#    in the model directory layout changes.
#
# The CI workflow keeps pull:true so any future rebuild picks up new
# 5.8.x-z-image-turbo digests.
#
# Prior: 2026-05-11 — add 4 new dedicated scene LoRAs from civitai
# (Multi-Girl Blowjobs, Spraying Cum, 5UCK1T, POV blowjob). These
# replace DR34ML4Y for double_blowjob / missionary_cumshot / blowjob
# poses that DR34ML4Y rendered with consistent failure modes (2 cocks,
# weak liquid physics, generic oral motion). Net image size +1.7GB.
#
# Prior: 2026-05-06b — DR34ML4Y All-In-One LoRA replaces yeqiu's
# missionary + oral-insertion. DR34MSC4PE-family LoRAs come from
# civitai (not HF) so the install script needs an auth token mounted
# at build time via BuildKit secret.
# Earlier rebuild today: bake pose LoRAs into image so cold-starts
# don't have to download them and the worker doesn't depend on
# tomuzas/aivora-models being populated. Files ship in /comfyui/models/loras/.
# CRITICAL: Do NOT upgrade numpy — base image has 1.26.x, numpy 2.x breaks torch.

# All deps for Impact Pack, Impact Subpack, and IPAdapter Plus.
# Impact Pack needs: segment_anything, scikit-image, piexif, transformers, opencv, scipy, dill, matplotlib
# Subpack adds: ultralytics
# sam2 from GitHub is heavy — skip it (not used in our workflow, only segment_anything is)
# aria2c for multi-connection downloads, ffmpeg for VHS_VideoCombine H.264 encoding
RUN apt-get update -qq && apt-get install -y --no-install-recommends aria2 ffmpeg curl && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    piexif \
    segment_anything \
    "ultralytics<8.5" \
    matplotlib \
    opencv-python-headless \
    dill \
    scikit-image \
    scipy \
    transformers \
    "numpy<2" \
    && pip check 2>/dev/null || true

# Bake custom nodes directly into the Docker image.
# Volume symlinks don't work — start.sh path handling breaks them.
#
# 2026-05-17: added RES4LYF for Juggernaut Z / Z-Image production.
# Provides ClownsharkSampler_Beta — the official sampler node from
# RunDiffusion's published Z-Image workflow. Stock KSampler + res_2s
# is a workable fallback but ClownsharkSampler exposes the noise
# schedule controls the model card recommends for max quality.
RUN cd /comfyui/custom_nodes && \
    git clone --depth 1 https://github.com/cubiq/ComfyUI_IPAdapter_plus.git && \
    git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Impact-Pack.git && \
    git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git && \
    git clone --depth 1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git && \
    git clone --depth 1 https://github.com/welltop-cn/ComfyUI-TeaCache.git && \
    git clone --depth 1 https://github.com/ClownsharkBatwing/RES4LYF.git

# VHS deps (imageio-ffmpeg bundles its own ffmpeg, but system ffmpeg is faster)
RUN pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt

# TeaCache deps (einops + diffusers)
RUN pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-TeaCache/requirements.txt "numpy<2"

# RES4LYF deps — keeps numpy pinned so torch doesn't break.
# The repo has a requirements.txt but installs are best-effort: some
# entries (like specific torch wheels) may pull dependencies we want
# to stay frozen at the base image's versions. `|| true` lets the
# image build keep going even if a single optional dep balks.
RUN pip install --no-cache-dir -r /comfyui/custom_nodes/RES4LYF/requirements.txt "numpy<2" 2>&1 | tail -5 || true

# Tell ComfyUI to load extra model paths from the volume config
# start.sh appends ${EXTRA_ARGS} to `python main.py`
ENV EXTRA_ARGS="--extra-model-paths-config /workspace/ComfyUI/extra_model_paths.yaml"

# Bake pose LoRAs at build time. Sources are mostly public HF author
# repos plus DR34ML4Y from civitai (the all-in-one NSFW LoRA — auth'd
# via the civitai_token secret mount below). Files live at
# /comfyui/models/loras/ with the exact filenames POSE_LORA_MAP in
# src/lib/comfyui/video-workflows.ts expects. download-models.sh's
# "skip if exists" check leaves them alone at runtime.
#
# --mount=type=secret reads the token at /run/secrets/civitai_token
# only during this RUN step — it does not get persisted into the
# image layer or surface in `docker history`. The CI workflow passes
# the secret via build-push-action's `secrets:` input.
COPY install-pose-loras.sh /install-pose-loras.sh
RUN --mount=type=secret,id=civitai_token \
    chmod +x /install-pose-loras.sh \
    && /install-pose-loras.sh \
    && rm /install-pose-loras.sh

COPY download-models.sh /download-models.sh
COPY warmup.sh /warmup.sh
RUN chmod +x /download-models.sh /warmup.sh

CMD ["/bin/bash", "-c", "/download-models.sh ; /start.sh & sleep 15 && /warmup.sh && wait"]
