#!/bin/bash
set -euo pipefail
set -x

# Compile the Mooncake project
SOURCE_DIR="$(cd $(dirname ${BASH_SOURCE[0]})/.. && pwd)"
BUILD_DIR="$SOURCE_DIR/build"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake "$SOURCE_DIR" -DUSE_CUDA=ON -DWITH_NVIDIA_PEERMEM=OFF -DUSE_MNNVL=ON -DCMAKE_PREFIX_PATH=/home/inf-daole/.local/mooncake-deps
make -j$(nproc)
