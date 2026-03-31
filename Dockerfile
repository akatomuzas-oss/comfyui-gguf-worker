FROM runpod/worker-comfyui:5.5.1-base
# Rebuild: 2026-04-01 — adds IP-Adapter + Impact Pack custom nodes

# Install custom nodes for face identity locking + face detail fix
# These must be baked into the image — network volume only stores model weights
RUN cd /comfyui/custom_nodes && \
    git clone https://github.com/cubiq/ComfyUI_IPAdapter_plus && \
    git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack && \
    cd ComfyUI-Impact-Pack && pip install --no-cache-dir -r requirements.txt

# Copy the model download script
COPY download-models.sh /download-models.sh
RUN chmod +x /download-models.sh

# Override CMD to run model download before normal startup
# Use ; instead of && so start.sh always runs even if download fails
CMD ["/bin/bash", "-c", "/download-models.sh ; /start.sh"]
