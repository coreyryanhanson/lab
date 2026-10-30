#!/bin/bash
set -euo pipefail

# Build audio.cpp (https://github.com/0xShug0/audio.cpp) with CUDA, mirroring
# the llama.cpp container build: ephemeral toolchain, host-mounted source.
# Only the model families needed right now are compiled (custom model set).

SRC_DIR="$(dirname "$0")/audio.cpp"
if [ ! -d "$SRC_DIR" ]; then
    git clone https://github.com/0xShug0/audio.cpp "$SRC_DIR"
fi

podman run --rm -it \
  -v "$SRC_DIR:/build:Z" \
  -w /build \
  -e CC=gcc-14 -e CXX=g++-14 \
  nvidia/cuda:13.3.0-devel-ubuntu24.04 \
  bash -c "apt-get update && \
    apt-get install -y --no-install-recommends gcc-14 g++-14 cmake ca-certificates && \
    ln -s /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1 && \
    echo '/usr/local/cuda/lib64/stubs' > /etc/ld.so.conf.d/cuda-stubs.conf && \
    ldconfig && \
    rm -rf build && \
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
      -DENGINE_ENABLE_CUDA=ON \
      -DENGINE_ENABLE_CUDA_GRAPHS=ON \
      -DCMAKE_CUDA_ARCHITECTURES=89 \
      -DAUDIOCPP_MODEL_SET=custom \
      -DAUDIOCPP_MODELS=nemotron_3_diar,qwen3_asr \
      -DAUDIOCPP_BUILD_NATIVE_MODEL_MANAGER=ON && \
    cmake --build build -j\$(nproc) \
      --target audiocpp_cli \
      --target audiocpp_server \
      --target audiocpp_model_manager"
