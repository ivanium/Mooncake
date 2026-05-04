#!/bin/bash
set -euo pipefail
set -x

# Compile the Mooncake project against a local deps prefix.
#
# Overridable env vars:
#   MOONCAKE_DEPS_DIR  - prefix containing the cmake/ libs (default: ~/.local/mooncake-deps)
#   PYTHON             - python interpreter to bind against (default: python3 on PATH)
#   CUDA_LIB_DIR       - CUDA runtime libs for build-time linking (default: /usr/local/cuda/lib64)

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$SOURCE_DIR/build"

MOONCAKE_DEPS_DIR="${MOONCAKE_DEPS_DIR:-$HOME/.local/mooncake-deps}"
PYTHON="${PYTHON:-python3}"
CUDA_LIB_DIR="${CUDA_LIB_DIR:-/usr/local/cuda/lib64}"

PYTHON_EXECUTABLE="$(command -v "$PYTHON")"
PYTHON_LIB_DIR="$("$PYTHON_EXECUTABLE" -c 'import sys, os; print(os.path.join(sys.base_prefix, "lib"))')"

# Make deps libs reachable for any build-time invocation that loads .so files
# (e.g. cmake's try_compile, version probes). Prepended so they win over system.
export LD_LIBRARY_PATH="$CUDA_LIB_DIR:$PYTHON_LIB_DIR:$MOONCAKE_DEPS_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake "$SOURCE_DIR" \
    -DUSE_CUDA=ON \
    -DWITH_NVIDIA_PEERMEM=OFF \
    -DUSE_MNNVL=ON \
    -DCMAKE_PREFIX_PATH="$MOONCAKE_DEPS_DIR" \
    -DPython3_EXECUTABLE="$PYTHON_EXECUTABLE"

make -j"$(nproc)"
