# Experiment status

**Last updated:** 2026-08-06 (UTC)

## Summary

| Tier | Job | Status | Trials | Partition | Notes |
|------|-----|--------|--------|-----------|-------|
| 1 GPU | 19114 | PASS* | 2/2 | rad | *Slurm exit 1; DoE completed |
| 2 GPU | 19117 | **PASS** | 4/4 | rad | ~10 min |
| 8 GPU | 19120 | **PASS** | 16/16 | rad | ~43 min |
| 16 GPU | 19203 | **PASS** | 32/32 | rad | 16 GPUs, 2 nodes, ~44 min |
| 32 GPU | 19270 | PARTIAL | 32/64 | rad-burst | Batch 1 done; job failed ~26 min into run |
| 64 GPU | 19275 | **PENDING** | — | rad-burst | 8 nodes, 128 trials queued |
| 72–128 GPU | — | Not started | — | — | Ladder continues after 64 |

## Performance (PASS tiers)

See [`results/performance/scale_performance.md`](results/performance/scale_performance.md).

| GPUs | Throughput | DoE wall | Speedup vs 1 GPU |
|------|------------|----------|------------------|
| 1 | 15.2 trials/hr | 7.9 min | 1.0× |
| 2 | 25.3 trials/hr | 9.5 min | 1.7× |
| 8 | 22.6 trials/hr | 42.5 min | 1.5× |
| 16 | **44.8 trials/hr** | 42.9 min | **2.9×** |

## Active automation

- **Background ladder:** `run_scale_extended_background.sh` (PID may vary)
- **Tiers:** 16 → 32 → 64 → 72 → 96 → 128 (skips passed tiers, 8 h wall clock)
- **32 GPU:** 6 submit attempts failed or partial; latest 19270 reached 32/64 trials before failure
- **64 GPU:** job **19275** pending resources on `rad-burst`

## Persist to GitHub

```bash
bash scripts/persist_experiment_status.sh
```

Updates performance CSV/MD, refreshes this file timestamp, commits and pushes (requires `gh auth`).

## Example

**FSI-SPH angle-of-repose** DoE — see [README.md](README.md).

Each trial = independent GPU SPH sim (ChronoRay + Ray), not multi-GPU domain decomposition.
