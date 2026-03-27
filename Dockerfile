FROM runpod/worker-comfyui:5.5.1-base
# Rebuild: 2026-03-27 — downloads models to local /comfyui/models if no volume
# FlashBoot enabled — first cold start downloads, subsequent boots from snapshot

# Copy the model download script
COPY download-models.sh /download-models.sh
RUN chmod +x /download-models.sh

# Override CMD to run model download before normal startup
# Use ; instead of && so start.sh always runs even if download fails
CMD ["/bin/bash", "-c", "/download-models.sh ; /start.sh"]
