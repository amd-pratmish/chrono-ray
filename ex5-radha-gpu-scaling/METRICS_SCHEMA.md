# ex5 metrics schema — Radha Ray vs Vultr coupled MPI

## Primary ladder columns (both systems)

| Column | ex5 (Ray/ChronoRay) | Coupled MPI workload |
|--------|---------------------|----------------------|
| Tier | `scale_tier` / GPUs | Tier |
| Parallel width | `max_concurrent` (= GPU actors) | MPI ranks |
| Job | `slurm_job_id` | Job |
| Trials | `trials_completed` / `trials_requested` | Trials |
| DoE time | `doe_elapsed_s` / min | DoE time |
| Throughput | `throughput_trials_per_hr` | Throughput |
| GPU SPH steps/s | `aggregate_gpu_sph_steps_per_s` | GPU SPH steps/s |

## Interconnect / network (aligned field names)

| Field | Source (ex5) | Coupled MPI |
|-------|--------------|-------------|
| `gpu_link_type` | `rocm-smi --showtopo` | same |
| `xgmi_link_count` | topo parse | same |
| `gpu_link_speed_gts` | topo parse | same |
| `gpu_topo_summary` | topo parse | same |
| `gpu_mem_util_pct` | `rocm-smi --showmeminfo` | same |
| `gpu_bw_util_pct` | `rocm-smi --showbw` | same |
| `mpi_unique_nodes` | Slurm nodelist count | MPI unique nodes |
| `mpi_gpu_node` | First Slurm node | GPU rank node |
| `mpi_cross_node_traffic` | `slurm_unique_nodes > 1` | CPU/GPU split across nodes |
| `ray_unique_nodes` | `ray.nodes()` | — |
| `ray_cross_node_traffic` | multi-node Ray cluster | — |

## MPI sync (coupled only) vs Ray scheduling (ex5)

Coupled workload records `mpi_bcast_wall_seconds`, `mpi_allreduce_wall_seconds`, etc.

ex5 **Ray analogue** (no MPI in this ladder):

| Coupled field | ex5 analogue |
|---------------|--------------|
| `mpi_bcast_wall_seconds` | `ray_scheduling_overhead_s` (DoE wall − Σ trial GPU wall) |
| `mpi_comm_bandwidth_mbps` | not applicable (Ray object store; document N/A) |
| `heartbeat_wall_seconds` | mean `trial_wall_seconds` per trial |
| `gpu_sph_fraction_of_heartbeat` | `gpu_sph_fraction_of_doe` = Σ trial GPU / DoE wall |

Per-trial files: `particles/*/trial_metrics.json` with `gpu_sph_steps`, `gpu_sph_wall_seconds`, `gpu_sph_steps_per_s`.
