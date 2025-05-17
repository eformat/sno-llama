# 2025.1 - oc get is -n redhat-ods-applications minimal-gpu -o yaml
FROM quay.io/modh/cuda-notebooks@sha256:26bd9460f36016a618f003f99c30209c25dbfa36929f0a7a8b9055557d09a709 as build
USER root
RUN dnf -y install cmake
WORKDIR /opt/app-root/src
RUN git clone https://github.com/ggerganov/llama.cpp.git
ENV LD_LIBRARY_PATH=/usr/lib64/:/usr/local/cuda-12.1/compat
RUN cd /opt/app-root/src/llama.cpp && \
    cmake -B build -DLLAMA_CUDA=ON && \
    cmake --build build --config Release -j16

FROM quay.io/modh/cuda-notebooks@sha256:26bd9460f36016a618f003f99c30209c25dbfa36929f0a7a8b9055557d09a709
COPY --from=build /opt/app-root/src/llama.cpp/build/ggml/src/libggml.so /libggml.so
COPY --from=build /opt/app-root/src/llama.cpp/build/src/libllama.so /libllama.so
COPY --from=build /opt/app-root/src/llama.cpp/build/bin/llama-server /llama-server
USER root
RUN dnf -y install https://rpmfind.net/linux/epel/9/Everything/x86_64/Packages/n/nvtop-3.2.0-3.el9.x86_64.rpm
USER 1001
ENV LLAMA_ARG_HOST=0.0.0.0
ENV LD_LIBRARY_PATH=/
ENTRYPOINT [ "/llama-server" ]
