FROM runpod/worker-comfyui:5.5.1-base
RUN cd /comfyui/custom_nodes && \
    git clone https://github.com/city96/ComfyUI-GGUF.git && \
    cd ComfyUI-GGUF && pip install -r requirements.txt
