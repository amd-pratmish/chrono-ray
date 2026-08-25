#!/usr/bin/env bash
# Wait until a Slurm job appears, then until it finishes.
wait_for_slurm_job() {
  local JOB="$1"
  local APPEAR_WAIT="${2:-600}"
  local POLL="${3:-45}"
  local MAX_RUNTIME="${4:-0}"

  [[ -z "${JOB}" ]] && return 1

  echo "Waiting for job ${JOB} to appear in squeue (up to ${APPEAR_WAIT}s)..."
  local waited=0
  while ! squeue -j "${JOB}" -h 2>/dev/null | grep -q "${JOB}"; do
    if sacct -j "${JOB}" --format=State -n -h 2>/dev/null | grep -qE 'COMPLETED|FAILED|CANCELLED|TIMEOUT'; then
      echo "Job ${JOB} already finished before appearing in squeue."
      sleep 5
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
    if [[ "${waited}" -ge "${APPEAR_WAIT}" ]]; then
      echo "ERROR: job ${JOB} never appeared in squeue within ${APPEAR_WAIT}s"
      return 1
    fi
  done

  echo "Job ${JOB} is active — polling until complete${MAX_RUNTIME:+ (max ${MAX_RUNTIME}s)}..."
  waited=0
  while squeue -j "${JOB}" -h 2>/dev/null | grep -q "${JOB}"; do
    if [[ "${MAX_RUNTIME}" -gt 0 && "${waited}" -ge "${MAX_RUNTIME}" ]]; then
      echo "Job ${JOB} exceeded max runtime ${MAX_RUNTIME}s — cancelling (likely stuck)"
      scancel "${JOB}" 2>/dev/null || true
      sleep 15
      return 1
    fi
    sleep "${POLL}"
    waited=$((waited + POLL))
  done
  sleep 10
  return 0
}
