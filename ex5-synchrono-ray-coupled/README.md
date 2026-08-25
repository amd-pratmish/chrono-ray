# ex5-synchrono-ray-coupled

**Ray + MPI coupled Chrono simulations** — multi-rank jobs with **GPU/node synchronization** (SynChrono heartbeat), contrasted with ex4’s embarrassingly parallel GPU trials.

## Two workload classes in Chrono

| Class | Example | Sync mechanism | Ray role | ex |
|-------|---------|----------------|----------|-----|
| **Independent GPU trials** | FSI-SPH angle-of-repose DoE | None (1 GPU = 1 sim) | Schedule N remote tasks | **ex4** |
| **Coupled MPI simulation** | SynChrono HMMWV fleet on SCM terrain | `syn_manager.Synchronize()` + MPI | Launch 1 `mpirun`/`srun` job per trial | **ex5** |
| **Hybrid MPI + GPU** | Vehicle cosim + SPH terrain rank | MPI between ranks; GPU on terrain rank only | Same as coupled; reserve `gpu=1` | **ex5** (documented) |

Chrono **does not** split one FSI-SPH simulation across multiple GPUs. Multi-GPU/multi-node **physics synchronization** uses **SynChrono (MPI)** or **vehicle cosimulation (MPI)**, not Ray allreduce.

---

## Architecture

```
Slurm batch job
  └─ Ray head (driver)
       └─ ChRDoE.run()
            └─ @ray.remote(num_cpus=R×cpus_per_rank)  [per trial]
                 └─ srun/mpirun -n R  demo_SYN_scm  --params...
                      └─ R MPI ranks
                           └─ syn_manager.Synchronize() each heartbeat
                                (vehicle + SCM terrain agents exchange state)
```

**Granularity of network traffic:**

| Layer | What crosses the network | When |
|-------|--------------------------|------|
| **Ray** | Trial dispatch, small config dict | Once per trial |
| **SynChrono / MPI** | Agent state at heartbeat interval | Every heartbeat during integration |
| **FSI-SPH (ex4)** | None during timestep loop | N/A |

---

## Quick start (GPU + MPI coupled FSI — default)

**PyChrono FSI-SPH on 1 GPU rank** + CPU MPI coupling ranks (vehicle cosim analog):

```bash
export CHR_RAY_MODE=gpu_fsi_mpi
bash ex5-synchrono-ray-coupled/submit_coupled_scale.sh 8
# Full independent ladder (one worker per tier, retry until pass):
bash ex5-synchrono-ray-coupled/run_coupled_independent_ladder.sh
```

### Run on a different cluster

1. Copy or clone this repo on the target system.
2. Add a profile under `cluster_profiles/` (copy `example_generic.sh` or `rad_mi355x.sh`).
3. Set partition names, GRES string, PyChrono path, ranks/node, and max tier:

```bash
export CHR_CLUSTER=my_cluster          # loads cluster_profiles/my_cluster.sh
export CHR_PYCHRONO_BIN=/path/to/build/bin
export CHR_SLURM_GRES_GPU=gpu:1        # or gpu:amd_instinct_mi355_oam:1
export CHR_RAY_PARTITION_SMALL=gpu
export CHR_RAY_PARTITION_LARGE=gpu-large
export CHR_MPI_RANKS_PER_NODE=8
export CHR_COUPLED_MAX_TIER=96
```

4. Submit one tier or the full ladder:

```bash
source ex5-synchrono-ray-coupled/cluster_profiles/load_cluster.sh
bash ex5-synchrono-ray-coupled/submit_coupled_scale.sh 16
bash ex5-synchrono-ray-coupled/run_coupled_independent_ladder.sh
```

See also `CLUSTER_COMPARISON_RUNBOOK.md` for cross-cluster performance comparison.

Each trial: `srun -n R --gres=gpu:1 python3 gpu_mpi_fsi_coupled.py`  
GPU rank (last) runs HIP SPH; other ranks sync via MPI Bcast/Allreduce each heartbeat.

Metrics: `gpu_bw_util_pct`, `gpu_sph_steps_per_sec`, `mpi_sync_bandwidth_mbps`.

---

## Smoke test (CPU-only MPI proxy — optional)

```bash
export CHR_RAY_MODE=smoke
bash ex5-synchrono-ray-coupled/submit_coupled.sh smoke
```

---

## SynChrono SCM fleet (CPU-only, optional)

### 1. Build SynChrono on amd-chronos

```bash
bash ex5-synchrono-ray-coupled/setup_synchrono_amd.sh
export CHRONO_BUILD_BIN=/home/pratmish/amd-chronos/build-mi355x-synchrono/bin
```

Builds `demo_SYN_scm` — MPI ranks each run an HMMWV + deformable SCM terrain agent, coupled via **SynChronoManager**.

### 2. Submit DoE

```bash
export CHR_MPI_RANKS=4          # MPI processes per trial (= coupled agents)
export CHR_RAY_NUM_TRIALS=8
export CHR_RAY_MAX_CONCURRENT=1 # each trial needs R ranks worth of CPUs
bash ex5-synchrono-ray-coupled/submit_coupled.sh synchrono
```

Parameters swept: `end_time`, `heartbeat`, `step_size`, soil grid (`dpu`), terrain size, bulldozing, terrain type.

---

## Scaling coupled trials vs ex4

| Quantity | ex4 (FSI DoE) | ex5 (SynChrono) |
|----------|---------------|-----------------|
| Unit of work | 1 GPU, 1 sim | **R MPI ranks**, 1 coupled sim |
| Ray `gpu` | 1 | 0 (CPU) or 1 (cosim terrain) |
| Ray `cpu` | 2 | **R × cpus_per_rank** |
| `max_concurrent` | ≈ # GPUs | ≈ `floor(total_cpus / (R × cpus_per_rank))` |
| Inter-rank sync | None | **MPI heartbeat** |

Example: 32 CPUs, `CHR_MPI_RANKS=4`, `cpus_per_rank=4` → **2 concurrent coupled trials** max.

Multi-node: increase `#SBATCH --nodes` and set `CHR_MPI_RANKS` so Slurm can place ranks across nodes; `srun --ntasks=R` spans the allocation.

---

## Vehicle cosim + GPU SPH (hybrid)

For `demo_VEH_Cosim_WheeledVehicle_SPH` (6 MPI ranks: vehicle, tires, SPH terrain):

```python
from ChronoRay.ChR_MpiCoupled import make_mpi_simulate_fn, recommended_resources_coupled

resources = recommended_resources_coupled(
    "vehicle_cosim_mpi", mpi_ranks=6, cpus_per_rank=4, gpus_for_terrain=1
)
# doe.set_resources_per_trial(cpu=resources["cpu"], gpu=resources["gpu"])
```

GPU SPH runs on the **terrain MPI rank only**; other ranks are CPU MBS. Ray reserves 1 GPU on the node hosting that rank.

---

## Files

| File | Purpose |
|------|---------|
| `ChronoRay/ChR_MpiCoupled.py` | `run_mpi_coupled_trial()`, `make_mpi_simulate_fn()` |
| `doe_coupled_scale.py` | Ray DoE driver for GPU+MPI scaling ladder |
| `gpu_mpi_fsi_coupled.py` | Per-trial MPI workload (GPU SPH + CPU coupling ranks) |
| `cluster_profiles/` | Per-cluster Slurm/GPU paths (`load_cluster.sh` selects profile) |
| `scale_profiles_coupled.sh` | Tier → nodes, ranks, trials, partitions |
| `submit_coupled_scale.sh` | Submit one scaling tier |
| `launch_coupled_scale.sbatch` | Slurm batch: Ray head + DoE driver |
| `run_coupled_independent_ladder.sh` | Parallel per-tier workers (retry until pass) |
| `coupled_tier_worker.sh` | Single-tier retry loop |
| `coupled_tier_heal.sh` | Failure diagnosis + env fixes before resubmit |
| `measure_coupled_performance.py` | Aggregate `scale_summary.txt` into report |
| `doe_mpi_smoke.py` | Ray DoE over mpi4py smoke |
| `doe_synchrono_scm.py` | Ray DoE over `demo_SYN_scm` |
| `mpi_sync_smoke.py` | MPI Allreduce heartbeat smoke test |
| `setup_synchrono_amd.sh` | Build SynChrono + vehicle demos |
| `launch_coupled.sbatch` | Slurm + Ray + MPI launcher (smoke/synchrono) |
| `submit_coupled.sh` | Submit smoke or synchrono mode |

---

## Comparison with NVIDIA NVL72-style workloads

NVL72’s NVLink domain helps **single jobs** that span many GPUs (LLM training, decomposed PDEs). This ex5 pattern maps to:

- **Coupled CPU fleet sims** → SynChrono MPI (similar to multi-node CPU HPC)
- **Not** NVLink-accelerated single-GPU-domain SPH (Chrono doesn’t offer that)

For parameter sweeps of **coupled** fleets, Ray still orchestrates **independent MPI jobs** in parallel — the same outer pattern as ex4, with **MPI sync inside** each trial instead of isolated GPU sims.

---

## See also

- [ex4 README](../ex4-amd-multinode-fsi-doe/README.md) — embarrassingly parallel FSI-SPH scaling
- amd-chronos: `src/demos/synchrono/mpi/demo_SYN_scm.cpp`
- amd-chronos: `src/demos/vehicle/cosimulation/demo_VEH_Cosim_WheeledVehicle_SPH.cpp`
