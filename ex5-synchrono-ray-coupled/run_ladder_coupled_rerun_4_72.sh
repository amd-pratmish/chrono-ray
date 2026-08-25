#!/usr/bin/env bash
# Re-run coupled tiers 4–72 (metrics rerun); tiers 1–2 skip if already passed.
export CHR_LADDER_TIERS="4 8 16 24 32 64 72"
export CHR_GPU_MPI_RANK=0
exec bash "$(dirname "$0")/run_ladder_coupled_scale.sh"
