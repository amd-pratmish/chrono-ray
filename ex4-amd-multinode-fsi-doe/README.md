# ex4-amd-multinode-fsi-doe

Multi-node **AMD Instinct MI355X** GPU scaling for Chrono **FSI-SPH** parameter sweeps via **ChronoRay + Ray**.

## What this example runs

Each Ray trial executes `fsi_angle_repose_sim.py` → **`simulate_fn()`**:

1. Builds a **GPU SPH granular pile** (CRM-MCC elastoplastic soil) on a fixed floor.
2. Releases a small **column of SPH particles** (~4 cm × 4 cm × 8 cm) under gravity.
3. Steps the **FSI-SPH solver** (PyChrono / amd-chronos, HIP backend) for `CHR_RAY_SIM_TEND` seconds.
4. Writes particle snapshots and a parameter log to  
   `results/scale{N}gpu_{JOBID}/particles/d{density}_E{Young}_.../`.

This is an **angle-of-repose / granular collapse** benchmark: friction (`mu_s`) maps to the MCC yield surface; six material parameters are swept per trial.

The DoE driver **`doe_amd_fsi.py`** uses **ChronoRay `ChRDoE`** with **Latin Hypercube** sampling over:

| Parameter | Range |
|-----------|--------|
| `mu_s` | 0.35 – 0.90 |
| `density` | 1200 – 2000 kg/m³ |
| `mcc_lambda` | 0.02 – 0.22 |
| `kappa_ratio` | 0.05 – 0.25 |
| `Young_modulus` | 5×10⁴ – 10⁷ Pa |
| `Poisson_ratio` | 0.2 – 0.45 |

## Scaling model

| Pattern | Supported? | Mechanism |
|---------|------------|-----------|
| N independent SPH trials across M GPU nodes | **Yes** | Ray `gpu=1` per trial |
| One SPH sim split across multiple GPUs | **No** | Chrono has no multi-GPU domain decomposition |
| SynChrono vehicle fleet across nodes | **Yes (CPU)** | Separate from ChronoRay |

Ray cluster layout (multi-node):

- **Head** starts on the Slurm batch node (first allocated node).
- **Workers** use `srun --block` in the background with internal **10.x** cluster IPs.
- **`ray_cluster_env.sh`** sets venv-first `PATH`, ROCm env, and GPU registration wait.

## Prerequisites

1. **amd-chronos** built with HIP + FSI-SPH + PyChrono (`build-mi355x`, `.pychrono_ready` marker).
2. **chrono-ray** venv with Ray 2.56+ and editable ChronoRay install.
3. **ROCm** on all nodes (`/opt/rocm`).

```bash
# One-time PyChrono build on cluster (if needed)
bash setup_pychrono_amd.sh
```

## Quick start — scale tiers

```bash
cd ex4-amd-multinode-fsi-doe
source ../.venv/bin/activate

# Submit a tier: 1, 2, 8, 16, 24, 32, 64, 72, 96, 128
bash submit_scale.sh 16
```

| GPUs | Nodes | Partition | Trials | Max concurrent | Wall clock |
|------|-------|-----------|--------|----------------|------------|
| 1–16 | 1–3 | `rad` | 2× GPUs | = GPUs | 8 h |
| 32–128 | 4–16 | `rad-burst` (qos=low) | 2× GPUs | = GPUs | 8 h |

**Note:** Cluster max on `rad-burst` is **12 nodes × 8 GPU = 96 GPUs**. Tier 128 requires 16 nodes and will fail submit until capacity exists.

### Background scale ladder

```bash
bash run_scale_extended_background.sh   # 16 → 32 → 64 → 72 → 96 → 128, retries on failure
```

## Performance measurement

After each run (and on demand):

```bash
python3 measure_scale_performance.py
```

Outputs:

- `results/performance/scale_performance.csv`
- `results/performance/scale_performance.md`

Metrics: wall clock, DoE elapsed, avg s/trial, throughput (trials/hr), GPU-hours, speedup vs 1-GPU baseline, parallel efficiency.

### Validated results (Aug 2026)

| GPUs | Job | Trials | DoE (min) | Throughput | Speedup vs 1 GPU |
|------|-----|--------|-----------|------------|------------------|
| 1 | 19114 | 2/2 | 7.9 | 15.2/hr | 1.0× |
| 2 | 19117 | 4/4 | 9.5 | 25.3/hr | 1.7× |
| 8 | 19120 | 16/16 | 42.5 | 22.6/hr | 1.5× |
| 16 | 19203 | 32/32 | 42.9 | **44.8/hr** | **2.9×** |

16 GPUs completed **32 trials in ~43 min** on 2× MI355X nodes (`rad-vultr-mi355x-[02-03]`), 16/16 Ray GPUs registered.

## File layout

| File | Purpose |
|------|---------|
| `fsi_angle_repose_sim.py` | Pickle-safe FSI-SPH sim (one trial) |
| `doe_amd_fsi.py` | ChronoRay DoE driver |
| `launch_doe_scale.sbatch` | Slurm + Ray cluster + DoE |
| `submit_scale.sh` | Submit scale tier |
| `scale_profiles.sh` | Tier definitions (GPUs, nodes, partition, time) |
| `ray_cluster_env.sh` | Shared Ray/ROCm/venv env |
| `measure_scale_performance.py` | Aggregate performance reports |
| `run_scale_extended_background.sh` | Auto ladder with retries |

## ChronoRay cluster module

`ChronoRay/ChR_Cluster.py` provides:

- `init_ray()` — connect via `RAY_ADDRESS` or local fallback
- `trial_runtime_env()` — propagate venv, ROCm, `PYTHONPATH` to workers
- `setup_trial_gpu_env()` — AMD GPU visibility (no hardcoded `CUDA_VISIBLE_DEVICES=0`)
- `recommended_resources("fsi_sph")` → `{cpu: 2, gpu: 1}`

## Related

- [amd-chronos FSI_SPH_AMD_TUNING.md](https://github.com/projectchrono/chrono) — ROCm tuning knobs
- **gym-chrono**: not integrated here; RL would use Ray RLlib or `@ray.remote` env rollouts separately
