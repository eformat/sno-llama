# 2025.1 - oc get is -n redhat-ods-applications minimal-gpu -o yaml
FROM quay.io/modh/cuda-notebooks@sha256:26bd9460f36016a618f003f99c30209c25dbfa36929f0a7a8b9055557d09a709 as build
USER root
RUN dnf -y install cmake gcc-toolset-12
WORKDIR /opt/app-root/src
RUN git clone https://github.com/ggerganov/llama.cpp.git
ENV LD_LIBRARY_PATH=/usr/lib64/
RUN cd /opt/app-root/src/llama.cpp && \
    scl enable gcc-toolset-12 "cmake -B build -DLLAMA_CUDA=ON" && \
    scl enable gcc-toolset-12 "cmake --build build --config Release -j16"

FROM quay.io/modh/cuda-notebooks@sha256:26bd9460f36016a618f003f99c30209c25dbfa36929f0a7a8b9055557d09a709
COPY --from=build /opt/app-root/src/llama.cpp/build/bin/libggml.so /libggml.so
COPY --from=build /opt/app-root/src/llama.cpp/build/bin/libggml-cuda.so /libggml-cuda.so
COPY --from=build /opt/app-root/src/llama.cpp/build/bin/libggml-base.so /libggml-base.so
COPY --from=build /opt/app-root/src/llama.cpp/build/bin/libggml-cpu.so /libggml-cpu.so
COPY --from=build /opt/app-root/src/llama.cpp/build/bin/libllama.so /libllama.so
COPY --from=build /opt/app-root/src/llama.cpp/build/bin/llama-server /llama-server
USER root
RUN dnf -y install https://rpmfind.net/linux/epel/9/Everything/x86_64/Packages/n/nvtop-3.2.0-3.el9.x86_64.rpm
USER 1001
ENV LLAMA_ARG_HOST=0.0.0.0
ENV LD_LIBRARY_PATH=/usr/lib64:/usr/local/cuda-12.6/compat/:/
ENTRYPOINT [ "/llama-server" ]
