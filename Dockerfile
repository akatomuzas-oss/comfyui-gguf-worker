FROM runpod/worker-comfyui:5.5.1-base
# Rebuild: 2026-04-01c
# Worker runs ComfyUI from /workspace/ComfyUI/ (volume) using system Python.
# start.sh does: rm -rf /workspace && ln -s /runpod-volume /workspace
# So custom nodes must end up at /runpod-volume/ComfyUI/custom_nodes/

# Pre-install ALL pip deps custom nodes might need
RUN pip install --no-cache-dir ultralytics onnxruntime insightface

# Clone custom nodes into Docker image for syncing to volume
RUN git clone --depth 1 https://github.com/cubiq/ComfyUI_IPAdapter_plus.git /docker-custom-nodes/ComfyUI_IPAdapter_plus && \
    git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Impact-Pack.git /docker-custom-nodes/ComfyUI-Impact-Pack && \
    cd /docker-custom-nodes/ComfyUI-Impact-Pack && \
    pip install --no-cache-dir -r requirements.txt || true && \
    python install.py || true

# Pre-flight diagnostic script
COPY preflight.py /preflight.py

# Model download + node setup script
COPY download-models.sh /download-models.sh
RUN chmod +x /download-models.sh

CMD ["/bin/bash", "-c", "/download-models.sh ; python /preflight.py ; /start.sh"]
