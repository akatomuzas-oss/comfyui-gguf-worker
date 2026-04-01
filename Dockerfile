FROM runpod/worker-comfyui:5.5.1-base
# Rebuild: 2026-04-01
# Worker runs ComfyUI from /workspace/ComfyUI/ (volume) using system Python
# Custom node CODE is on the volume, but pip deps must be in system Python

# Pre-install pip deps that custom nodes need at runtime
# These persist in the Docker image — zero cold start penalty
RUN pip install --no-cache-dir ultralytics onnxruntime

# Copy the model download script
COPY download-models.sh /download-models.sh
RUN chmod +x /download-models.sh

CMD ["/bin/bash", "-c", "/download-models.sh ; /start.sh"]
