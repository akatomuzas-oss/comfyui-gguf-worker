FROM runpod/worker-comfyui:5.5.1-base
# Rebuild: 2026-04-01 — custom nodes installed via download script into volume venv
# The worker runs ComfyUI from /runpod-volume/ComfyUI/ not /comfyui/
# So custom nodes must be installed on the volume, not in the Docker image

# Copy the model download + custom node install script
COPY download-models.sh /download-models.sh
RUN chmod +x /download-models.sh

# Override CMD to run setup before normal startup
# Use ; instead of && so start.sh always runs even if download fails
CMD ["/bin/bash", "-c", "/download-models.sh ; /start.sh"]
