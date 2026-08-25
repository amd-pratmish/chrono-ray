#!/usr/bin/env bash
# Source cluster-specific Slurm/GPU paths for ex5 coupled scaling.
# Usage: export CHR_CLUSTER=rad_mi355x   (default)
#        source ex5-synchrono-ray-coupled/cluster_profiles/load_cluster.sh

_EX5_CLUSTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_EX5_ROOT="$(cd "${_EX5_CLUSTER_DIR}/.." && pwd)"
_CHR_REPO_ROOT="$(cd "${_EX5_ROOT}/.." && pwd)"

export CHR_CLUSTER="${CHR_CLUSTER:-rad_mi355x}"
export CHR_RAY_REPO_ROOT="${CHR_RAY_REPO_ROOT:-${_CHR_REPO_ROOT}}"
export CHR_EX5_DIR="${CHR_EX5_DIR:-${_EX5_ROOT}}"

_PROFILE="${_EX5_CLUSTER_DIR}/${CHR_CLUSTER}.sh"
if [[ ! -f "${_PROFILE}" ]]; then
  echo "ERROR: Unknown CHR_CLUSTER=${CHR_CLUSTER} (missing ${_PROFILE})" >&2
  echo "Available profiles:" >&2
  ls -1 "${_EX5_CLUSTER_DIR}"/*.sh 2>/dev/null | grep -v load_cluster.sh | xargs -n1 basename | sed 's/.sh$//' >&2
  return 1 2>/dev/null || exit 1
fi

# shellcheck source=/dev/null
source "${_PROFILE}"

export CHR_EX5_DIR CHR_RAY_REPO_ROOT CHR_CLUSTER
export CHR_VENV="${CHR_VENV:-${CHR_RAY_REPO_ROOT}/.venv}"
export CHR_EX4_DIR="${CHR_EX4_DIR:-${CHR_RAY_REPO_ROOT}/ex4-amd-multinode-fsi-doe}"

unset _EX5_CLUSTER_DIR _EX5_ROOT _CHR_REPO_ROOT _PROFILE
