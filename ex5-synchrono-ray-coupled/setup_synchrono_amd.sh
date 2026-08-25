#!/usr/bin/env bash
# Build amd-chronos with SynChrono + Vehicle for coupled MPI demos (ex5).
set -euo pipefail

ROOT="/home/pratmish/amd-chronos"
BUILD="${ROOT}/build-mi355x-synchrono"
MARKER="${BUILD}/.synchrono_ready"

export PATH="/home/pratmish/micromamba/envs/build-tools/bin:/opt/rocm/bin:/opt/rocm/llvm/bin:${PATH}"
HIP_CLANG="/opt/rocm/llvm/bin/clang++"

if [[ ! -x "${HIP_CLANG}" ]]; then
  echo "ERROR: ROCm HIP compiler not found. Run on a cluster node with ROCm."
  exit 1
fi

echo "Configuring SynChrono build at ${BUILD} ..."
cmake -S "${ROOT}" -B "${BUILD}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_HIP_COMPILER="${HIP_CLANG}" \
  -DCHRONO_GPU_BACKEND=HIP \
  -DCHRONO_HIP_ARCHITECTURES=gfx950 \
  -DCH_ENABLE_MODULE_CORE=ON \
  -DCH_ENABLE_MODULE_VEHICLE=ON \
  -DCH_ENABLE_MODULE_SYNCHRONO=ON \
  -DCH_ENABLE_MPI=ON \
  -DCH_ENABLE_MODULE_FSI=ON \
  -DCH_ENABLE_MODULE_FSI_SPH=ON \
  -DCH_ENABLE_MODULE_PYTHON=OFF \
  -DEigen3_DIR=/home/pratmish/micromamba/envs/build-tools/share/eigen3/cmake

echo "Building demo_SYN_scm and vehicle cosim demos ..."
ninja -C "${BUILD}" -j"$(nproc)" demo_SYN_scm demo_VEH_Cosim_WheeledVehicle_SPH

test -x "${BUILD}/bin/demo_SYN_scm"
echo "SynChrono ready: ${BUILD}/bin/demo_SYN_scm"
touch "${MARKER}"

echo ""
echo "Export for ex5:"
echo "  export CHRONO_BUILD_BIN=${BUILD}/bin"
