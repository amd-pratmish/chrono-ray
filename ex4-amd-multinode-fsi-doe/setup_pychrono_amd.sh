#!/usr/bin/env bash
# Build PyChrono (HIP + FSI-SPH + Python) using the working build-mi355x tree.
set -euo pipefail

ROOT="/home/pratmish/amd-chronos"
BUILD="${ROOT}/build-mi355x"
MARKER="${BUILD}/.pychrono_ready"
PY_BIN="${BUILD}/bin"
HIP_CLANG="/opt/rocm/llvm/bin/clang++"

if [[ -f "${MARKER}" ]]; then
  echo "PyChrono already built at ${BUILD}"
  exit 0
fi

export PATH="/home/pratmish/micromamba/envs/build-tools/bin:/opt/rocm/bin:/opt/rocm/llvm/bin:${PATH}"

if [[ ! -x "${HIP_CLANG}" ]]; then
  echo "ERROR: ${HIP_CLANG} not found. Run on an MI355X node with ROCm."
  exit 1
fi

if ! command -v swig >/dev/null 2>&1; then
  echo "ERROR: swig not found. Expected at /home/pratmish/micromamba/envs/build-tools/bin/swig"
  exit 1
fi

# Reconfigure existing HIP build with Python enabled (matches working mi355x config)
cmake -S "${ROOT}" -B "${BUILD}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_HIP_COMPILER="${HIP_CLANG}" \
  -DCHRONO_GPU_BACKEND=HIP \
  -DCHRONO_HIP_ARCHITECTURES=gfx950 \
  -DCH_ENABLE_MODULE_FSI=ON \
  -DCH_ENABLE_MODULE_FSI_SPH=ON \
  -DCH_ENABLE_MODULE_PYTHON=ON \
  -DCH_ENABLE_MODULE_CORE=ON \
  -DPYTHON_EXECUTABLE="$(which python3)"

echo "Building PyChrono bindings..."
ninja -C "${BUILD}" -j"$(nproc)"

echo "Build complete. Verifying import on GPU node..."

export PYTHONPATH="${PY_BIN}:${PYTHONPATH:-}"
python3 -c "import pychrono.core as ch; import pychrono.fsi as f; print('PyChrono FSI OK')"

touch "${MARKER}"
echo "PyChrono ready: PYTHONPATH=${PY_BIN}"
