"""Ray DoE driver for MPI coupled smoke trials (validates ex5 orchestration)."""

import os
import time

from ChronoRay import ChRDoE, init_ray
from ChronoRay.ChR_MpiCoupled import make_mpi_simulate_fn, recommended_resources_coupled

# Wrapper script invoked as: python3 mpi_sync_smoke.py (under mpirun/srun)
EX5 = os.path.dirname(os.path.abspath(__file__))
SMOKE_SCRIPT = os.path.join(EX5, "mpi_sync_smoke.py")

SYNCHRONO_SCM_FLAGS = {
    "steps": "steps",
    "heartbeat_interval": "heartbeat",
    "dt": "dt",
    "seed": "seed",
}

param_sample_space = {
    "steps": ChRDoE.ChR_Distr.randint(80, 200),
    "heartbeat_interval": ChRDoE.ChR_Distr.choice([10, 20, 40]),
    "dt": ChRDoE.ChR_Distr.uniform(0.005, 0.02),
    "seed": ChRDoE.ChR_Distr.uniform(0.5, 2.0),
}


def main() -> None:
    mpi_ranks = int(os.environ.get("CHR_MPI_RANKS", "4"))
    num_trials = int(os.environ.get("CHR_RAY_NUM_TRIALS", "8"))
    max_concurrent = int(os.environ.get("CHR_RAY_MAX_CONCURRENT", "2"))

    # Python MPI script: invoke via mpirun/srun with python interpreter
    binary = os.environ.get("CHR_MPI_PYTHON", os.environ.get("PYTHON", "python3"))
    extra = [SMOKE_SCRIPT]

    simulate_fn = make_mpi_simulate_fn(
        binary=binary,
        flag_map=SYNCHRONO_SCM_FLAGS,
        mpi_ranks=mpi_ranks,
        extra_args=extra,
    )

    resources = recommended_resources_coupled("synchrono_mpi", mpi_ranks=mpi_ranks, cpus_per_rank=2)

    print("=== ChronoRay ex5: MPI coupled smoke DoE ===", flush=True)
    print(f"  MPI ranks/trial:  {mpi_ranks}", flush=True)
    print(f"  Trials:           {num_trials}", flush=True)
    print(f"  Max concurrent:   {max_concurrent}", flush=True)
    print(f"  Ray resources:    {resources}", flush=True)
    print("===========================================", flush=True)

    init_ray(log_to_driver=True)

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
    print(f"Smoke DoE completed in {elapsed:.1f}s ({elapsed / 60:.1f} min)")


if __name__ == "__main__":
    main()
