# 2024.1
FROM quay.io/modh/cuda-notebooks@sha256:0bcc4f25f212c93915e7efa80cd4a26ceb29151b33ac217e8b48a0184e42b588
ARG ILAB_VERSION=0.14.1
USER root
RUN dnf -y install https://rpmfind.net/linux/epel/9/Everything/x86_64/Packages/n/nvtop-3.0.2-1.el9.x86_64.rpm
RUN pip install --upgrade pip
RUN NVCC_APPEND_FLAGS='-allow-unsupported-compiler' CUDACXX=/usr/local/cuda/bin/nvcc CMAKE_ARGS="-DLLAMA_CUBLAS=on -DLLAMA_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=all-major" FORCE_CMAKE=1 pip install --verbose git+https://github.com/instructlab/instructlab.git@v${ILAB_VERSION} --no-cache-dir
USER 1001
