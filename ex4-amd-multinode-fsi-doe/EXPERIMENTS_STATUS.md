# Experiment status

**Last updated:** 2026-08-10 16:58 UTC

## Summary

| Tier | Job | Status | Trials | Partition | Notes |
|------|-----|--------|--------|-----------|-------|
| 1 GPU | 19114 | PASS* | 2/2 | rad | *Slurm exit 1; DoE completed |
| 2 GPU | 19117 | **PASS** | 4/4 | rad | ~10 min |
| 8 GPU | 19120 | **PASS** | 16/16 | rad | ~43 min |
| 16 GPU | 19203 | **PASS** | 32/32 | rad | ~44 min |
| 24 GPU | 19292 | **PASS** | 48/48 | rad | 3 nodes, ~55 min |
| 32 GPU | 19279 | **PASS** | 64/64 | rad-burst | ~42 min |
| 64 GPU | 19456 | **PASS** | 128/128 | rad-burst | ~51 min, 151 trials/hr |
| 72 GPU | 19481 | **PASS** | 144/144 | rad-burst | ~50 min, 172 trials/hr |
| **96 GPU** | **19483** | **PENDING** | —/192 | rad-burst | Needs 12 nodes |
| 128 GPU | — | Not schedulable | — | — | Exceeds 12-node cluster max |

## Throughput (PASS tiers)

| GPUs | Job | Trials | DoE (min) | Avg sec/trial | Throughput (trials/hr) | Partition |
|------|-----|--------|-----------|---------------|------------------------|-----------|
| 1 | 19114 | 2/2 | 7.9 | 236.2 | 15.2 | rad |
| 2 | 19117 | 4/4 | 9.5 | 142.5 | 25.3 | rad |
| 8 | 19120 | 16/16 | 42.5 | 159.2 | 22.6 | rad |
| 16 | 19203 | 32/32 | 42.9 | 80.4 | 44.8 | rad |
| 24 | 19292 | 48/48 | 55.5 | 69.4 | 51.9 | rad |
| 32 | 19279 | 64/64 | 42.1 | 39.4 | 91.3 | rad-burst |
| 64 | 19456 | 128/128 | 50.9 | 23.8 | 151.0 | rad-burst |
| 72 | 19481 | 144/144 | 50.3 | 21.0 | 171.8 | rad-burst |

Full report: [`results/performance/scale_performance.md`](results/performance/scale_performance.md)  
Summary: [`EXPERIMENT_SUMMARY.md`](EXPERIMENT_SUMMARY.md)

## Partition policy (vultr_rad)

| Partition | 64+ GPU | Notes |
|-----------|---------|-------|
| `lux` | **Rejected** | Account not allowed on `lux` |
| `rad-burst` | **OK** | Requires `--qos=low`; uses lux MI355X nodes |
| `rad` | Max 24 GPU | 3 nodes only |

Submit tries **`lux` → `rad-burst`** automatically (`submit_scale.sh`).

## Active automation

- **Ladder:** `run_ladder_64_96.sh` — **64 → 72 → 96 → 128**
- **96 GPU:** job **19483** pending on `rad-burst`

## Persist to GitHub

```bash
bash scripts/persist_experiment_status.sh
```
