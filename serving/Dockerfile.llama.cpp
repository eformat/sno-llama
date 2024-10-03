# 2024.1
FROM quay.io/modh/cuda-notebooks@sha256:d8295bcf45a6a522f78c07dc62634a7775fc434621973bd81db243a5a63a1ffa AS build
USER root
RUN dnf -y install https://rpmfind.net/linux/epel/9/Everything/x86_64/Packages/n/nvtop-3.1.0-2.el9.x86_64.rpm
WORKDIR /opt/app-root/src
RUN git clone https://github.com/ggerganov/llama.cpp.git
ENV LD_LIBRARY_PATH=/usr/lib64/:/usr/local/cuda-12.1/compat
RUN cd /opt/app-root/src/llama.cpp && \
    cmake -B build -DLLAMA_CUDA=ON && \
    cmake --build build --config Release -j16

FROM quay.io/modh/cuda-notebooks@sha256:d8295bcf45a6a522f78c07dc62634a7775fc434621973bd81db243a5a63a1ffa
COPY --from=build /opt/app-root/src/llama.cpp/build/ggml/src/libggml.so /libggml.so
COPY --from=build /opt/app-root/src/llama.cpp/build/src/libllama.so /libllama.so
COPY --from=build /opt/app-root/src/llama.cpp/build/bin/llama-server /llama-server
ENV LLAMA_ARG_HOST=0.0.0.0
ENV LD_LIBRARY_PATH=/
USER 1001
ENTRYPOINT [ "/llama-server" ]
