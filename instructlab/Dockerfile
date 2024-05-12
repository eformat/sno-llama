FROM quay.io/modh/cuda-notebooks@sha256:12485b71290f761bff93843e14c40771dab3bb04e956a8a98b69e4b573c5f8ee
USER root
RUN dnf -y install https://rpmfind.net/linux/epel/9/Everything/x86_64/Packages/n/nvtop-3.0.2-1.el9.x86_64.rpm
RUN pip install --upgrade pip
RUN NVCC_APPEND_FLAGS='-allow-unsupported-compiler' CUDACXX=/usr/local/cuda/bin/nvcc CMAKE_ARGS="-DLLAMA_CUBLAS=on -DLLAMA_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=all-major" FORCE_CMAKE=1 pip install --verbose git+https://github.com/instructlab/instructlab.git@stable --no-cache-dir
USER 1001
