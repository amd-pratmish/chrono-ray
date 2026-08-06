"""AMD Instinct multi-node FSI-SPH DoE driver (ChronoRay + Ray cluster)."""

import os
import time

from ChronoRay import ChRDoE, recommended_resources, detect_gpu_backend
from fsi_angle_repose_sim import simulate_fn

param_sample_space = {
    "mu_s": ChRDoE.ChR_Distr.uniform(0.35, 0.90),
    "density": ChRDoE.ChR_Distr.uniform(1200, 2000),
    "mcc_lambda": ChRDoE.ChR_Distr.uniform(0.02, 0.22),
    "kappa_ratio": ChRDoE.ChR_Distr.uniform(0.05, 0.25),
    "Young_modulus": ChRDoE.ChR_Distr.loguniform(5e4, 1e7),
    "Poisson_ratio": ChRDoE.ChR_Distr.uniform(0.2, 0.45),
}


def main():
    scale = os.environ.get("CHR_RAY_SCALE", "local")
    num_trials = int(os.environ.get("CHR_RAY_NUM_TRIALS", "32"))
    max_concurrent = int(os.environ.get("CHR_RAY_MAX_CONCURRENT", "4"))
    sim_tend = os.environ.get("CHR_RAY_SIM_TEND", "1.0")

    print("=== ChronoRay AMD FSI-SPH DoE ===", flush=True)
    print(f"  Scale profile:    {scale} GPU", flush=True)
    print(f"  GPU backend:      {detect_gpu_backend()}", flush=True)
    print(f"  Trials:           {num_trials}", flush=True)
    print(f"  Max concurrent:   {max_concurrent}", flush=True)
    print(f"  Sim t_end:        {sim_tend}s", flush=True)
    print(f"  RAY_ADDRESS:      {os.environ.get('RAY_ADDRESS', '(local)')}", flush=True)
    print("=================================", flush=True)

    resources = recommended_resources("fsi_sph")

    doe = ChRDoE(
        simulate_fn,
        param_sample_space,
        sampling_design=ChRDoE.SamplingDesign.LATIN_HYPERCUBE,
        num_trials=num_trials,
        max_concurrent_trials=max_concurrent,
        FLAG_log_to_file=False,
        FLAG_auto_run=False,
    )
    doe.set_resources_per_trial(cpu=resources["cpu"], gpu=resources["gpu"])
    doe._build()

    t0 = time.time()
    doe.run()
    elapsed = time.time() - t0

    print(f"DoE completed in {elapsed:.1f}s ({elapsed / 60:.1f} min)")
    if num_trials > 0 and elapsed > 0:
        print(f"  Avg per trial: {elapsed / num_trials:.1f}s")
        print(f"  Throughput:    {num_trials / elapsed * 3600:.1f} trials/hour")


if __name__ == "__main__":
    main()
