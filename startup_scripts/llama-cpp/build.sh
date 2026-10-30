#!/bin/bash
set -euo pipefail

podman run --rm -it \
  -v "$(pwd)/llama.cpp:/build:Z" \
  -w /build \
  nvidia/cuda:13.3.0-devel-ubuntu24.04 \
  bash -c "apt-get update && \
    apt-get install -y --no-install-recommends cmake build-essential libssl-dev && \
    ln -s /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1 && \
    echo '/usr/local/cuda/lib64/stubs' > /etc/ld.so.conf.d/cuda-stubs.conf && \
    ldconfig && \
    rm -rf build && \
    cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=89 -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build -j\$(nproc)"
