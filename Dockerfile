FROM runpod/worker-comfyui:5.5.1-base
# Rebuild: 2026-04-01b
# Worker runs ComfyUI from /workspace/ComfyUI/ (volume) using system Python.
# start.sh does: rm -rf /workspace && ln -s /runpod-volume /workspace
# So custom nodes must end up at /runpod-volume/ComfyUI/custom_nodes/
#
# Strategy:
# 1. Clone custom nodes + install deps at build time (baked in Docker image)
# 2. download-models.sh copies them to volume on every cold start
# This ensures nodes + deps are always present regardless of volume state.

# Pre-install pip deps that custom nodes need at runtime
RUN pip install --no-cache-dir ultralytics onnxruntime insightface

# Clone custom nodes into Docker image (will be copied to volume on cold start)
RUN git clone --depth 1 https://github.com/cubiq/ComfyUI_IPAdapter_plus.git /docker-custom-nodes/ComfyUI_IPAdapter_plus && \
    git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Impact-Pack.git /docker-custom-nodes/ComfyUI-Impact-Pack && \
    cd /docker-custom-nodes/ComfyUI-Impact-Pack && \
    pip install --no-cache-dir -r requirements.txt || true && \
    python install.py || true

# Copy the model download + node setup script
COPY download-models.sh /download-models.sh
RUN chmod +x /download-models.sh

CMD ["/bin/bash", "-c", "/download-models.sh ; /start.sh"]
