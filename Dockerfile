FROM runpod/worker-comfyui:5.5.1-base
# Rebuild: 2026-03-27 — fix worker crash after latest-base migration
# GGUF node disabled — suspected of forcing lowvram mode on standard safetensors checkpoints
# RUN cd /comfyui/custom_nodes && \
#     git clone https://github.com/city96/ComfyUI-GGUF.git && \
#     cd ComfyUI-GGUF && pip install -r requirements.txt
