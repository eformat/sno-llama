# 2024.1
FROM quay.io/modh/odh-pytorch-notebook@sha256:354f98690a02c5b2519da72be22555562c6652bc9db8ece2f3c03476fd6369ff

USER 0
WORKDIR /opt

ENV LD_LIBRARY_PATH=/usr/lib64/:/usr/local/nvidia/lib:/usr/local/nvidia/lib64:/usr/local/cuda-12.1/compat

RUN NVCC_APPEND_FLAGS='-allow-unsupported-compiler' \
  CUDACXX=/usr/local/cuda/bin/nvcc \
  CMAKE_ARGS="-DGGML_CUDA=on -DCMAKE_CUDA_ARCHITECTURES=all-major" \
  FORCE_CMAKE=1 \
  pip install llama-cpp-python[server] --no-cache-dir --force-reinstall --upgrade

ENV MODELNAME=test
ENV MODELLOCATION=/tmp/models

## Set value to "--chat_format chatml" for prompt formats
## see https://github.com/abetlen/llama-cpp-python/blob/main/llama_cpp/llama_chat_format.py
ENV CHAT_FORMAT=""
EXPOSE 8080

ENTRYPOINT python3 -m llama_cpp.server --model ${MODELLOCATION}/${MODELNAME} ${CHAT_FORMAT} --host 0.0.0.0 --port 8080
