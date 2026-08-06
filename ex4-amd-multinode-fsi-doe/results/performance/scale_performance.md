# ChronoRay FSI-SPH Scale Performance

| GPUs | Job | Status | Trials | DoE (min) | Avg trial (s) | Throughput (trials/hr) | GPU-hrs | Trials/GPU-hr | Speedup | Par. eff. |
|------|-----|--------|--------|-----------|---------------|------------------------|---------|---------------|---------|-----------|
| 1 | 19114 | PASS | 2/2 | 7.9 | 236.2 | 15.2 | 0.13 | 15.24 | 1.00 | 100.0% |
| 2 | 19117 | PASS | 4/4 | 9.5 | 142.5 | 25.3 | 0.32 | 12.63 | 1.66 | 82.9% |
| 8 | 19120 | PASS | 16/16 | 42.5 | 159.2 | 22.6 | 5.66 | 2.83 | 1.48 | 18.5% |
| 16 | 19203 | PASS | 32/32 | 42.9 | 80.4 | 44.8 | 11.43 | 2.80 | 2.94 | 18.4% |

## All runs (including partial/failed)

- **scale1gpu_19114** [PASS]: 2/2 trials, DoE 7.9 min, throughput 15.2 trials/hr, partition=?
- **scale2gpu_19117** [PASS]: 4/4 trials, DoE 9.5 min, throughput 25.3 trials/hr, partition=rad
- **scale8gpu_19120** [PASS]: 16/16 trials, DoE 42.5 min, throughput 22.6 trials/hr, partition=rad
- **scale16gpu_19203** [PASS]: 32/32 trials, DoE 42.9 min, throughput 44.8 trials/hr, partition=rad
- **scale16gpu_19070** [FAIL]: 0/32 trials, DoE  min, throughput  trials/hr, partition=?
- **scale16gpu_19071** [FAIL]: 0/32 trials, DoE  min, throughput  trials/hr, partition=?
- **scale16gpu_19072** [FAIL]: 0/32 trials, DoE  min, throughput  trials/hr, partition=?
- **scale16gpu_19073** [FAIL]: 0/32 trials, DoE  min, throughput  trials/hr, partition=?
- **scale16gpu_19074** [FAIL]: 0/32 trials, DoE  min, throughput  trials/hr, partition=?
- **scale16gpu_19075** [FAIL]: 0/32 trials, DoE  min, throughput  trials/hr, partition=?
- **scale16gpu_19201** [FAIL]: 0/32 trials, DoE  min, throughput  trials/hr, partition=?
- **scale16gpu_19202** [FAIL]: 0/32 trials, DoE  min, throughput  trials/hr, partition=?
