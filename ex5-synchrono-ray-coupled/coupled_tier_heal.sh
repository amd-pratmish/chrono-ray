#!/usr/bin/env bash
# Diagnose coupled tier failures and apply env fixes before resubmit.
coupled_tier_heal() {
  local SCALE="$1"
  local MODE="${2:-width}"
  local JOB="${3:-}"
  local EX5="${CHR_EX5_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

  local TAG=""
  [[ "${MODE}" == "multigpu" ]] && TAG="mg"
  local JOB_GLOB="chr-coupled-${TAG}${SCALE}r"

  echo "=== Heal tier ${SCALE} mode=${MODE} job=${JOB} $(date) ==="

  # Always apply stable MPI transport on multi-node width tiers.
  if [[ "${MODE}" == "width" && "${SCALE}" -ge 16 ]]; then
    export OMPI_MCA_pml="${OMPI_MCA_pml:-ob1}"
    export OMPI_MCA_btl="${OMPI_MCA_btl:-self,tcp}"
    export UCX_TLS="${UCX_TLS:-sm,self,tcp}"
    export CHR_SRUN_DISTRIBUTION="${CHR_SRUN_DISTRIBUTION:-block}"
    export CHR_SRUN_GPU_BIND="${CHR_SRUN_GPU_BIND:-1}"
  fi

  local OUT="" ERR="" MPIERR=""
  if [[ -n "${JOB}" ]]; then
    OUT="${EX5}/logs/coupled_scale_${JOB_GLOB}_${JOB}.out"
    ERR="${EX5}/logs/coupled_scale_${JOB_GLOB}_${JOB}.err"
    MPIERR=$(find "${EX5}/results/${TAG:+mg}${SCALE:+}${TAG}${SCALE}rank_${JOB}" -name mpi_stderr.log 2>/dev/null | head -1)
    [[ -z "${MPIERR}" ]] && MPIERR=$(find "${EX5}/results/coupled${TAG}${SCALE}rank_${JOB}" -name mpi_stderr.log 2>/dev/null | head -1)
  fi

  if [[ -n "${JOB}" ]]; then
    local STATE
    STATE=$(sacct -j "${JOB}" --format=State -n -h 2>/dev/null | head -1 | tr -d ' ')
    case "${STATE}" in
      TIMEOUT|TIMEOUT*)
        echo "Heal: Slurm TIMEOUT — extending wall clock"
        export CHR_RAY_TIME="08:00:00"
        if [[ "${SCALE}" -gt 24 ]]; then
          export CHR_RAY_PARTITION="${CHR_RAY_PARTITION_LARGE:-rad-burst}"
          export CHR_RAY_QOS="${CHR_RAY_QOS_LARGE:-low}"
          export CHR_RAY_PARTITION_CANDIDATES="${CHR_RAY_PARTITION_LARGE} ${CHR_RAY_PARTITION_LARGE_FALLBACK:-lux}"
        fi
        ;;
      CANCELLED*|FAILED*)
        if [[ -f "${MPIERR}" ]] && grep -qE 'SIGNAL Killed|Out of memory|oom' "${MPIERR}"; then
          echo "Heal: OOM/SIGKILL on MPI step — increasing memory"
          export CHR_SLURM_MEM_PER_NODE="512G"
        fi
        if [[ -f "${MPIERR}" ]] && grep -q 'pmix\|Connection reset' "${MPIERR}"; then
          echo "Heal: PMIx/UCX errors — forcing TCP BTL"
          export OMPI_MCA_pml=ob1
          export OMPI_MCA_btl=self,tcp
          export UCX_TLS=sm,self,tcp
        fi
        if [[ -f "${OUT}" ]] && grep -q 'ray.get failed\|RayTaskError' "${OUT}"; then
          echo "Heal: Ray trial timeout — bumping MPI/ray get timeout"
          export CHR_MPI_TRIAL_TIMEOUT=$((3600 + SCALE * 900))
          export CHR_RAY_GET_TIMEOUT="${CHR_MPI_TRIAL_TIMEOUT}"
        fi
        ;;
    esac
  fi

  if [[ -f "${OUT}" ]] && grep -q 'mem-per-node' "${OUT}"; then
    echo "Heal: stale mem-per-node in submit — using --mem only"
    export CHR_SLURM_USE_MEM_PER_NODE=1
  fi

  # Large tiers: prefer burst partition if rad keeps rejecting.
  if [[ "${SCALE}" -ge 32 ]]; then
    export CHR_RAY_PARTITION="${CHR_RAY_PARTITION_LARGE:-rad-burst}"
    export CHR_RAY_QOS="${CHR_RAY_QOS_LARGE:-low}"
    export CHR_RAY_PARTITION_CANDIDATES="${CHR_RAY_PARTITION_LARGE} ${CHR_RAY_PARTITION_LARGE_FALLBACK:-lux}"
    export CHR_RAY_TIME="${CHR_RAY_TIME_LARGE:-08:00:00}"
  fi

  return 0
}
