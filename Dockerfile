FROM runpod/worker-comfyui:latest-base
# Rebuild: 2026-04-02b — bake VHS + ffmpeg for MP4 video export
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
    git clone --depth 1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git

# VHS deps (imageio-ffmpeg bundles its own ffmpeg, but system ffmpeg is faster)
RUN pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt

# Tell ComfyUI to load extra model paths from the volume config
# start.sh appends ${EXTRA_ARGS} to `python main.py`
ENV EXTRA_ARGS="--extra-model-paths-config /workspace/ComfyUI/extra_model_paths.yaml"

COPY download-models.sh /download-models.sh
COPY warmup.sh /warmup.sh
RUN chmod +x /download-models.sh /warmup.sh

CMD ["/bin/bash", "-c", "/download-models.sh ; /start.sh & sleep 15 && /warmup.sh && wait"]
