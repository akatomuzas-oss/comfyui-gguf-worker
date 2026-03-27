FROM runpod/worker-comfyui:latest-base
# Rebuild: 2026-03-27 — auto-download models to network volume on first start
# Volume switched from q1t7ny8kys (corrupted) to v3miry3ae9 (aivora-models)

# Copy the model download script
COPY download-models.sh /download-models.sh
RUN chmod +x /download-models.sh

# Override CMD to run model download before normal startup
# Use ; instead of && so start.sh always runs even if download fails
CMD ["/bin/bash", "-c", "/download-models.sh ; /start.sh"]
