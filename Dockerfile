FROM runpod/worker-comfyui:latest-base
# Rebuild: 2026-05-06 — bake pose LoRAs into image so cold-starts don't have
# to download them and the worker doesn't depend on tomuzas/aivora-models
# being populated. Files now ship inside /comfyui/models/loras/.
# CRITICAL: Do NOT upgrade numpy — base image has 1.26.x, numpy 2.x breaks torch.

# All deps for Impact Pack, Impact Subpack, and IPAdapter Plus.
# Impact Pack needs: segment_anything, scikit-image, piexif, transformers, opencv, scipy, dill, matplotlib
# Subpack adds: ultralytics
# sam2 from GitHub is heavy — skip it (not used in our workflow, only segment_anything is)
# aria2c for multi-connection downloads, ffmpeg for VHS_VideoCombine H.264 encoding
RUN apt-get update -qq && apt-get install -y --no-install-recommends aria2 ffmpeg && rm -rf /var/lib/apt/lists/*

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
RUN cd /comfyui/custom_nodes && \
    git clone --depth 1 https://github.com/cubiq/ComfyUI_IPAdapter_plus.git && \
    git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Impact-Pack.git && \
    git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git && \
    git clone --depth 1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git && \
    git clone --depth 1 https://github.com/welltop-cn/ComfyUI-TeaCache.git

# VHS deps (imageio-ffmpeg bundles its own ffmpeg, but system ffmpeg is faster)
RUN pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt

# TeaCache deps (einops + diffusers)
RUN pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-TeaCache/requirements.txt "numpy<2"

# Tell ComfyUI to load extra model paths from the volume config
# start.sh appends ${EXTRA_ARGS} to `python main.py`
ENV EXTRA_ARGS="--extra-model-paths-config /workspace/ComfyUI/extra_model_paths.yaml"

# Bake pose LoRAs at build time. All sources are public HF author repos
# (no auth needed). Files live at /comfyui/models/loras/ with the exact
# filenames POSE_LORA_MAP in src/lib/comfyui/video-workflows.ts expects.
# download-models.sh's "skip if exists" check leaves them alone at runtime.
COPY install-pose-loras.sh /install-pose-loras.sh
RUN chmod +x /install-pose-loras.sh && /install-pose-loras.sh && rm /install-pose-loras.sh

COPY download-models.sh /download-models.sh
COPY warmup.sh /warmup.sh
RUN chmod +x /download-models.sh /warmup.sh

CMD ["/bin/bash", "-c", "/download-models.sh ; /start.sh & sleep 15 && /warmup.sh && wait"]
