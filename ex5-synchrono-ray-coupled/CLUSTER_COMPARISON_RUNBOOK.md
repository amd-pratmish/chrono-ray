# ex5 GPU+MPI Coupled Scaling — Cross-Cluster Comparison Runbook

Use this document to reproduce the **same coupled scaling experiment** on a second cluster and compare results against `rad_mi355x`.

## Experiment definition (fixed across clusters)

| Item | Value |
|------|--------|
| Workload | `gpu_fsi_mpi` — PyChrono FSI-SPH on last MPI rank + CPU ranks with MPI Bcast/Allreduce each heartbeat |
| Ladder tiers | `1 2 4 8 16 24 32 64 72 96 128` (tier N → N MPI ranks/trial, min 2) |
| Trials per tier | `2 × tier` (tier 1 → 2 trials) |
| Ray concurrency | `1` trial at a time (1 GPU per batch job) |
| Slurm MPI | `ntasks = MPI ranks`, nested `srun --overlap --mpi=pmix` |
| DoE sampling | Latin hypercube on `sim_tend`, `heartbeat`, soil params (see `doe_coupled_scale.py`) |

## Quick start on a new cluster

```bash
git clone <chrono-ray-repo> && cd chrono-ray
python3 -m venv .venv && source .venv/bin/activate
pip install ray mpi4py numpy

# 1. Copy and edit cluster profile
cp ex5-synchrono-ray-coupled/cluster_profiles/example_generic.sh \
   ex5-synchrono-ray-coupled/cluster_profiles/MYCLUSTER.sh
# Edit: CHR_SLURM_ACCOUNT, CHR_SLURM_GRES_GPU, CHR_PYCHRONO_BIN, partitions

# 2. Build PyChrono FSI on a GPU node (same as ex4)
# bash ex4-amd-multinode-fsi-doe/setup_pychrono_amd.sh

# 3. Run full ladder
export CHR_CLUSTER=MYCLUSTER
cd ex5-synchrono-ray-coupled
nohup bash run_ladder_coupled_scale.sh >> logs/ladder_coupled_nohup.out 2>&1 &
```

## Environment variables

| Variable | Purpose |
|----------|---------|
| `CHR_CLUSTER` | Profile name → loads `cluster_profiles/${CHR_CLUSTER}.sh` |
| `CHR_RAY_REPO_ROOT` | Repo root (auto-detected if unset) |
| `CHR_PYCHRONO_BIN` | PyChrono + FSI `.so` path on compute nodes |
| `CHR_RESUME_EX4_AFTER_LADDER` | `0` on comparison clusters (default in template) |
| `CHR_RAY_MODE` | `gpu_fsi_mpi` (default) |

## Submit single tier (smoke test)

```bash
export CHR_CLUSTER=MYCLUSTER
source ex5-synchrono-ray-coupled/cluster_profiles/load_cluster.sh
bash ex5-synchrono-ray-coupled/submit_coupled_scale.sh 1
# PASS: results/coupled1rank_<jobid>/scale_summary.txt with exit_code=0
```

## Results layout (for comparison)

Each tier writes:

```
results/coupled{N}rank_{JOBID}/scale_summary.txt
results/coupled{N}rank_{JOBID}/t_*/gpu_coupled_summary.json
results/performance/coupled_scale_performance.csv   # aggregated
```

Key fields for cross-cluster tables:

- `cluster_name`, `scale_tier`, `mpi_ranks`, `mpi_unique_nodes_max`, `trials_completed`
- `throughput_trials_per_hr`, `avg_gpu_sph_steps_per_sec`, `avg_gpu_sph_fraction_of_heartbeat`
- **MPI sync (comm-only):** `mpi_comm_bytes_total`, `avg_mpi_comm_bandwidth_mbps`, `avg_mpi_bcast_latency_us`, `avg_mpi_allreduce_latency_us`, `mpi_cross_node_trials`
- **GPU fabric (1 GPU/trial):** `gpu_link_type`, `xgmi_link_count_max`, `gpu_bw_util_pct`, `gpu_mem_util_pct`
- Legacy alias: `avg_mpi_sync_bandwidth_mbps` (= comm-only bandwidth after Aug 2026 instrumentation fix)
- `elapsed_seconds`, `partition`, `job_id`

## Merge results from two clusters

Copy `results/coupled*rank_*` from the second cluster into a tagged folder or set `CHR_CLUSTER_NAME` before runs. Re-aggregate:

```bash
python3 ex5-synchrono-ray-coupled/measure_coupled_performance.py
```

The CSV includes a `cluster_name` column when summaries contain it.

## rad_mi355x reference (in progress)

| Tier | Status | Job | Throughput (trials/hr) | GPU SPH steps/s |
|------|--------|-----|------------------------|-----------------|
| 1 | PASS | 19639 | 32.2 | 272 |
| 2 | PASS | 19640 | 36.3 | 258 |
| 4 | PASS | 19641 | — | 289 |
| 8+ | running | — | — | — |

Monitor: `tail -f ex5-synchrono-ray-coupled/logs/ladder_coupled_*.log`

## Troubleshooting (both clusters)

| Symptom | Fix |
|---------|-----|
| `More processors requested than permitted` | Ensure submit uses `--ntasks=${CHR_MPI_RANKS}` (not 1) |
| MPI `size=1` per rank | Use `srun --mpi=pmix` (`CHR_SRUN_MPI=pmix`) |
| Ray GPU deadlock | `CHR_RAY_MAX_CONCURRENT=1` (already enforced) |
| FSI hash/domain crash | Fixed in `gpu_mpi_fsi_coupled.py` (computational domain + ex4 SPH params) |
| PyChrono import on login node | Expected failure; jobs run on GPU nodes |

## Agent checklist

1. Create `cluster_profiles/<name>.sh` from template
2. Verify PyChrono FSI on one GPU node: `python3 -c "import pychrono.fsi"`
3. Submit tier 1 → confirm `scale_summary.txt` PASS
4. Run `run_ladder_coupled_scale.sh` with `CHR_CLUSTER=<name>`
5. Export `results/performance/coupled_scale_performance.csv` for comparison
