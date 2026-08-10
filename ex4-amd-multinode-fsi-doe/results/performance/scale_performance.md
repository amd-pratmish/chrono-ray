# ChronoRay FSI-SPH Scale Performance

Throughput and per-trial latency for PASS runs (`sim_tend=1.0`, FSI angle-of-repose DoE).

| GPUs | Job | Trials | DoE (min) | Avg sec/trial | Throughput (trials/hr) | Partition |
|------|-----|--------|-----------|---------------|------------------------|-----------|
| 1 | 19114 | 2/2 | 7.9 | 236.2 | 15.2 | ? |
| 2 | 19117 | 4/4 | 9.5 | 142.5 | 25.3 | rad |
| 8 | 19120 | 16/16 | 42.5 | 159.2 | 22.6 | rad |
| 16 | 19203 | 32/32 | 42.9 | 80.4 | 44.8 | rad |
| 24 | 19292 | 48/48 | 55.5 | 69.4 | 51.9 | rad |
| 32 | 19279 | 64/64 | 42.1 | 39.4 | 91.3 | rad-burst |
| 64 | 19456 | 128/128 | 50.9 | 23.8 | 151.0 | rad-burst |
| 72 | 19481 | 144/144 | 50.3 | 21.0 | 171.8 | rad-burst |

Avg sec/trial ≈ 3600 / throughput when the cluster is fully utilized.

## Extended metrics (PASS runs)

| GPUs | Job | GPU-hrs | Trials/GPU-hr | Speedup vs 1 GPU | Parallel eff. |
|------|-----|---------|---------------|------------------|---------------|
| 1 | 19114 | 0.13 | 15.24 | 1.00 | 100.0% |
| 2 | 19117 | 0.32 | 12.63 | 1.66 | 82.9% |
| 8 | 19120 | 5.66 | 2.83 | 1.48 | 18.5% |
| 16 | 19203 | 11.43 | 2.80 | 2.94 | 18.4% |
| 24 | 19292 | 22.21 | 2.16 | 3.40 | 14.2% |
| 32 | 19279 | 22.43 | 2.85 | 5.99 | 18.7% |
| 64 | 19456 | 54.24 | 2.36 | 9.92 | 15.5% |
| 72 | 19481 | 60.35 | 2.39 | 11.25 | 15.6% |

## All runs (including partial/failed)

- **scale1gpu_19114** [PASS]: 2/2 trials, DoE 7.9 min, avg 236.2 s/trial, throughput 15.2 trials/hr, partition=?
- **scale2gpu_19117** [PASS]: 4/4 trials, DoE 9.5 min, avg 142.5 s/trial, throughput 25.3 trials/hr, partition=rad
- **scale8gpu_19120** [PASS]: 16/16 trials, DoE 42.5 min, avg 159.2 s/trial, throughput 22.6 trials/hr, partition=rad
- **scale16gpu_19203** [PASS]: 32/32 trials, DoE 42.9 min, avg 80.4 s/trial, throughput 44.8 trials/hr, partition=rad
- **scale24gpu_19292** [PASS]: 48/48 trials, DoE 55.5 min, avg 69.4 s/trial, throughput 51.9 trials/hr, partition=rad
- **scale32gpu_19279** [PASS]: 64/64 trials, DoE 42.1 min, avg 39.4 s/trial, throughput 91.3 trials/hr, partition=rad-burst
- **scale64gpu_19456** [PASS]: 128/128 trials, DoE 50.9 min, avg 23.8 s/trial, throughput 151.0 trials/hr, partition=rad-burst
- **scale72gpu_19481** [PASS]: 144/144 trials, DoE 50.3 min, avg 21.0 s/trial, throughput 171.8 trials/hr, partition=rad-burst
- **scale16gpu_19070** [FAIL]: 0/32 trials, DoE  min, avg  s/trial, throughput  trials/hr, partition=?
- **scale16gpu_19071** [FAIL]: 0/32 trials, DoE  min, avg  s/trial, throughput  trials/hr, partition=?
- **scale16gpu_19072** [FAIL]: 0/32 trials, DoE  min, avg  s/trial, throughput  trials/hr, partition=?
- **scale16gpu_19073** [FAIL]: 0/32 trials, DoE  min, avg  s/trial, throughput  trials/hr, partition=?
- **scale16gpu_19074** [FAIL]: 0/32 trials, DoE  min, avg  s/trial, throughput  trials/hr, partition=?
- **scale16gpu_19075** [FAIL]: 0/32 trials, DoE  min, avg  s/trial, throughput  trials/hr, partition=?
- **scale16gpu_19201** [FAIL]: 0/32 trials, DoE  min, avg  s/trial, throughput  trials/hr, partition=?
- **scale16gpu_19202** [FAIL]: 0/32 trials, DoE  min, avg  s/trial, throughput  trials/hr, partition=?
- **scale32gpu_19254** [FAIL]: 0/64 trials, DoE  min, avg  s/trial, throughput  trials/hr, partition=?
- **scale32gpu_19270** [PARTIAL]: 32/64 trials, DoE  min, avg  s/trial, throughput  trials/hr, partition=?
