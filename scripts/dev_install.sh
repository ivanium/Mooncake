#!/bin/bash
# Dev install: copies built artifacts into mooncake-wheel/mooncake/ and does
# an editable pip install.  No sudo required.
#
# Prerequisites:
#   - C++ code already built (cmake --build build)
#   - A Python venv is active
#
# Usage: ./scripts/dev_install.sh [--uninstall-first]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${REPO_ROOT}/build}"
WHEEL_DIR="${REPO_ROOT}/mooncake-wheel"
PKG_DIR="${WHEEL_DIR}/mooncake"

# --------------------------------------------------------------------------
# Sanity checks
# --------------------------------------------------------------------------
if [ ! -d "$BUILD_DIR" ]; then
    echo "Error: Build directory not found at ${BUILD_DIR}"
    echo "       Run cmake/make first, then re-run this script."
    exit 1
fi

if ! python -c "import sys" 2>/dev/null; then
    echo "Error: No Python found. Activate your venv first."
    exit 1
fi

echo "=== Mooncake dev install ==="
echo "Build dir : ${BUILD_DIR}"
echo "Wheel dir : ${WHEEL_DIR}"
echo "Python    : $(which python)"
echo ""

# --------------------------------------------------------------------------
# Optionally uninstall existing pip packages
# --------------------------------------------------------------------------
if [[ "${1:-}" == "--uninstall-first" ]]; then
    echo "--- Uninstalling existing mooncake packages ---"
    for pkg in mooncake-transfer-engine mooncake-transfer-engine-cuda13 mooncake-transfer-engine-non-cuda; do
        pip uninstall -y "$pkg" 2>/dev/null || true
    done
    echo ""
fi

# --------------------------------------------------------------------------
# Copy built artifacts  (mirrors build_wheel.sh logic)
# --------------------------------------------------------------------------
echo "--- Copying built artifacts into ${PKG_DIR} ---"

# Required: engine.so
ENGINE_SO=$(ls ${BUILD_DIR}/mooncake-integration/engine.*.so 2>/dev/null | head -1)
if [ -z "$ENGINE_SO" ]; then
    echo "Error: engine.*.so not found in ${BUILD_DIR}/mooncake-integration/"
    echo "       Make sure the C++ build completed successfully."
    exit 1
fi
cp -v "$ENGINE_SO" "${PKG_DIR}/engine.so"

# Required: libasio.so
if [ -f "${BUILD_DIR}/mooncake-asio/libasio.so" ]; then
    cp -v "${BUILD_DIR}/mooncake-asio/libasio.so" "${PKG_DIR}/libasio.so"
else
    echo "Warning: libasio.so not found, engine.so may fail to load"
fi

# Optional: store.so + binaries
STORE_SO=$(ls ${BUILD_DIR}/mooncake-integration/store.*.so 2>/dev/null | head -1)
if [ -n "$STORE_SO" ]; then
    cp -v "$STORE_SO" "${PKG_DIR}/store.so"
    cp -v "${BUILD_DIR}/mooncake-store/src/mooncake_master" "${PKG_DIR}/" 2>/dev/null || true
    cp -v "${BUILD_DIR}/mooncake-store/src/mooncake_client" "${PKG_DIR}/" 2>/dev/null || true
    # async_store.py from integration
    cp -v "${REPO_ROOT}/mooncake-integration/store/async_store.py" "${PKG_DIR}/async_store.py" 2>/dev/null || true
fi

# Optional: shared libs
for lib in \
    "${BUILD_DIR}/mooncake-store/src/libmooncake_store.so" \
    "${BUILD_DIR}/mooncake-common/etcd/libetcd_wrapper.so" \
    "${BUILD_DIR}/mooncake-transfer-engine/src/libtransfer_engine.so" \
    "${BUILD_DIR}/mooncake-transfer-engine/src/transport/ascend_transport/ascend_transport.so" \
    "${BUILD_DIR}/mooncake-transfer-engine/src/transport/ascend_transport/hccl_transport/ascend_transport_c/libascend_transport_mem.so"; do
    if [ -f "$lib" ]; then
        cp -v "$lib" "${PKG_DIR}/"
    fi
done

# Optional: nvlink_allocator.so + allocator.py
if [ -f "${BUILD_DIR}/mooncake-transfer-engine/nvlink-allocator/nvlink_allocator.so" ]; then
    cp -v "${BUILD_DIR}/mooncake-transfer-engine/nvlink-allocator/nvlink_allocator.so" "${PKG_DIR}/"
    cp -v "${REPO_ROOT}/mooncake-integration/allocator.py" "${PKG_DIR}/allocator.py" 2>/dev/null || true
fi

# Optional: ubshmem_fabric_allocator.so (NPU)
if [ -f "${BUILD_DIR}/mooncake-transfer-engine/ubshmem-allocator/ubshmem_fabric_allocator.so" ]; then
    cp -v "${BUILD_DIR}/mooncake-transfer-engine/ubshmem-allocator/ubshmem_fabric_allocator.so" "${PKG_DIR}/"
    cp -v "${REPO_ROOT}/mooncake-integration/allocator_ascend_npu.py" "${PKG_DIR}/allocator_ascend_npu.py" 2>/dev/null || true
fi

# Optional: transfer_engine_bench
if [ -f "${BUILD_DIR}/mooncake-transfer-engine/example/transfer_engine_bench" ]; then
    cp -v "${BUILD_DIR}/mooncake-transfer-engine/example/transfer_engine_bench" "${PKG_DIR}/"
fi

# Optional: EP/PG CUDA extensions
EP_STAGING="${BUILD_DIR}/ep_pg_staging"
if [ -d "$EP_STAGING" ] && ls "$EP_STAGING"/*.so &>/dev/null; then
    echo ""
    echo "--- Copying EP/PG CUDA extensions ---"
    for so in "$EP_STAGING"/*.so; do
        cp -v "$so" "${PKG_DIR}/"
    done
fi

echo ""

# --------------------------------------------------------------------------
# Editable install
# --------------------------------------------------------------------------
echo "--- Running editable install ---"
cd "${WHEEL_DIR}"
pip install -e .

echo ""
echo "=== Done ==="
echo ""
echo "If you get import errors about missing .so files, set:"
echo "  export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:${PKG_DIR}"
echo ""
echo "After rebuilding C++, re-run this script to update the .so files."
