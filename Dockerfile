FROM runpod/worker-comfyui:5.5.1-base
# Rebuild: 2026-04-01i
# CRITICAL: Do NOT upgrade numpy — base image has 1.26.x, numpy 2.x breaks torch.

# All deps for Impact Pack, Impact Subpack, and IPAdapter Plus.
# Impact Pack needs: segment_anything, scikit-image, piexif, transformers, opencv, scipy, dill, matplotlib
# Subpack adds: ultralytics
# sam2 from GitHub is heavy — skip it (not used in our workflow, only segment_anything is)
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
    git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git

# Tell ComfyUI to load extra model paths from the volume config
# start.sh appends ${EXTRA_ARGS} to `python main.py`
ENV EXTRA_ARGS="--extra-model-paths-config /workspace/ComfyUI/extra_model_paths.yaml"

COPY download-models.sh /download-models.sh
RUN chmod +x /download-models.sh

CMD ["/bin/bash", "-c", "/download-models.sh ; /start.sh"]
