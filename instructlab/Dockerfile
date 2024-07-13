# 2024.1
FROM quay.io/modh/cuda-notebooks@sha256:3beed917f90b12239d57cf49c864c6249236c8ffcafcc7eb06b0b55272ef5b55
ARG ILAB_VERSION=0.17.1
USER root
RUN dnf -y install https://rpmfind.net/linux/epel/9/Everything/x86_64/Packages/n/nvtop-3.1.0-2.el9.x86_64.rpm
RUN pip install --upgrade pip
RUN NVCC_APPEND_FLAGS='-allow-unsupported-compiler' CUDACXX=/usr/local/cuda/bin/nvcc CMAKE_ARGS="-DGGML_CUDA=on -DLLAMA_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=all-major" FORCE_CMAKE=1 pip install --verbose git+https://github.com/instructlab/instructlab.git@v${ILAB_VERSION} --no-cache-dir
USER 1001
