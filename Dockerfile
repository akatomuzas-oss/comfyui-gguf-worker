FROM runpod/worker-comfyui:5.5.1-base
# Rebuild: 2026-04-01d
# Worker runs ComfyUI from /workspace/ComfyUI/ (volume) using system Python.
# No venv exists — system Python IS the ComfyUI Python.
# Custom node code lives on the network volume already.
# We just need pip deps that custom nodes require beyond base ComfyUI.

# Install deps for custom nodes WITHOUT upgrading numpy (base image has 1.26.x)
# --no-deps on insightface to prevent it pulling numpy 2.x which breaks torch
RUN pip install --no-cache-dir --no-deps insightface && \
    pip install --no-cache-dir onnxruntime onnx easydict prettytable albumentations && \
    pip install --no-cache-dir ultralytics && \
    pip install --no-cache-dir piexif segment_anything

# Model download script (no custom node syncing needed — nodes are on the volume)
COPY download-models.sh /download-models.sh
RUN chmod +x /download-models.sh

CMD ["/bin/bash", "-c", "/download-models.sh ; /start.sh"]
