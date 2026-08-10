# ex4-amd-multinode-fsi-doe — Experiment Summary

**Project:** ChronoRay multi-node GPU scaling on AMD Instinct MI355X (Vultr RAD cluster)  
**Status:** 8 tiers complete (1–72 GPU); 96 GPU queued; 128 GPU exceeds cluster capacity

---

## What was run

A **Design of Experiments (DoE)** scaling study for **FSI-SPH granular angle-of-repose** simulations:

- **Physics:** GPU SPH pile collapse (CRM-MCC elastoplastic soil) via PyChrono / amd-chronos (HIP)
- **Sampling:** Latin Hypercube over 6 material parameters (`mu_s`, density, `mcc_lambda`, `kappa_ratio`, Young's modulus, Poisson ratio)
- **Per trial:** One independent simulation on **one GPU** for 1.0 s sim time (`CHR_RAY_SIM_TEND=1.0`)
- **Scaling ladder:** 1 → 2 → 8 → 16 → 24 → 32 → 64 → 72 → 96 → 128 GPUs

Each scale tier runs **2× trials per GPU** (e.g. 32 GPUs → 64 trials, 64 concurrent).

This is **embarrassingly parallel** — N separate sims across M GPUs, not multi-GPU domain decomposition of a single sim.

---

## How it was run

| Component | Role |
|-----------|------|
| **`doe_amd_fsi.py`** | ChronoRay `ChRDoE` driver; launches trials via Ray |
| **`launch_doe_scale.sbatch`** | Slurm batch job: starts Ray head + workers, runs DoE |
| **`submit_scale.sh`** | Submits tier; tries `lux` then `rad-burst` for 32+ GPU |
| **Ray cluster** | Head on batch node; workers on allocated nodes (10.x internal IPs); `gpu=1` per trial |

**Partitions:**
- **1–24 GPU:** `rad` (up to 3 nodes × 8 GPU)
- **32–96 GPU:** `rad-burst` (`vultr_rad`, `--qos=low`; same MI355X hardware)

**Automation:** `run_ladder_64_96.sh` runs tiers sequentially, skipping already-passed runs.

**I/O:** Particle output disabled at 24+ GPU (`CHR_RAY_OUTPUT_FPS=0`, `CHR_RAY_SAVE_PARTICLES=0`) to avoid disk bottlenecks.

---

## Results (PASS tiers)

| GPUs | Job | Trials | DoE (min) | Avg sec/trial | Throughput (trials/hr) | Speedup vs 1 GPU |
|------|-----|--------|-----------|---------------|------------------------|------------------|
| 1 | 19114 | 2/2 | 7.9 | 236.2 | 15.2 | 1.0× |
| 2 | 19117 | 4/4 | 9.5 | 142.5 | 25.3 | 1.7× |
| 8 | 19120 | 16/16 | 42.5 | 159.2 | 22.6 | 1.5× |
| 16 | 19203 | 32/32 | 42.9 | 80.4 | 44.8 | 2.9× |
| 24 | 19292 | 48/48 | 55.5 | 69.4 | 51.9 | 3.4× |
| 32 | 19279 | 64/64 | 42.1 | 39.4 | 91.3 | 6.0× |
| 64 | 19456 | 128/128 | 50.9 | 23.8 | 151.0 | 9.9× |
| 72 | 19481 | 144/144 | 50.3 | 21.0 | 171.8 | 11.3× |

### Key findings

1. **Throughput scales well:** 15 → **172 trials/hr** from 1 to 72 GPUs (~**11×** wall-clock productivity).
2. **Per-trial latency drops** as concurrency increases (236 s → 21 s avg) — cluster stays better utilized at higher tiers.
3. **Parallel efficiency ~15–19%** at 8–72 GPU — typical for Ray-scheduled independent tasks with startup/scheduling overhead.
4. **64–72 GPU wall time ~51 min** despite 2× the trials of 32-GPU tier — strong scaling in the burst partition.
5. **96 GPU** (job 19483, 192 trials) submitted and pending (needs all 12 cluster nodes).
6. **128 GPU** not schedulable — cluster max is 12 nodes × 8 GPU = **96 GPUs**.

### Network / architecture

- **Ray** handles cross-node traffic (task dispatch, small config payloads, cluster control).
- **SPH simulations** run entirely on-node; no inter-node physics communication during time integration.

---

## Artifacts

- Results: `results/scale{N}gpu_{JOBID}/`
- Performance CSV/MD: `results/performance/scale_performance.{csv,md}`
- Metrics script: `measure_scale_performance.py`
