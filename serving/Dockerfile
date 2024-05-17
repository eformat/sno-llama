# 2024.1
FROM quay.io/modh/odh-pytorch-notebook@sha256:604c8c92a0751fe6573912f8689366855d3e7d28698eade4d7875f9afc9a2276

USER 0
WORKDIR /opt

RUN NVCC_APPEND_FLAGS='-allow-unsupported-compiler' \
  CUDACXX=/usr/local/cuda/bin/nvcc \
  CMAKE_ARGS="-DLLAMA_CUBLAS=on -DCMAKE_CUDA_ARCHITECTURES=all-major" \
  FORCE_CMAKE=1 \
  pip install llama-cpp-python[server] --no-cache-dir --force-reinstall --upgrade

ENV MODELNAME=test
ENV MODELLOCATION=/tmp/models

## Set value to "--chat_format chatml" for prompt formats
## see https://github.com/abetlen/llama-cpp-python/blob/main/llama_cpp/llama_chat_format.py
ENV CHAT_FORMAT=""
EXPOSE 8080

ENTRYPOINT python3 -m llama_cpp.server --model ${MODELLOCATION}/${MODELNAME} ${CHAT_FORMAT} --host 0.0.0.0 --port 8080
