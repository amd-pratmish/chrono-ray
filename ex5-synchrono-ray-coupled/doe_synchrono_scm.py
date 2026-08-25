"""Ray DoE driver for SynChrono MPI SCM fleet (demo_SYN_scm).

Requires amd-chronos built with SynChrono — see setup_synchrono_amd.sh.
"""

import os
import time

from ChronoRay import ChRDoE, init_ray
from ChronoRay.ChR_MpiCoupled import make_mpi_simulate_fn, recommended_resources_coupled

BUILD_BIN = os.environ.get(
    "CHRONO_BUILD_BIN",
    "/home/pratmish/amd-chronos/build-mi355x/bin",
)
SYN_SCM_BINARY = os.path.join(BUILD_BIN, "demo_SYN_scm")

# Maps DoE config keys → demo_SYN_scm CLI flags (see AddCommandLineOptions in demo_SYN_scm.cpp)
SYNCHRONO_SCM_FLAGS = {
    "end_time": "end_time",
    "heartbeat": "heartbeat",
    "step_size": "step_size",
    "dpu": "dpu",
    "size_x": "sizeX",
    "size_y": "sizeY",
    "bulldozing": "bulldozing",
    "terrain_type": "terrain_type",
}

param_sample_space = {
    "end_time": ChRDoE.ChR_Distr.uniform(2.0, 8.0),
    "heartbeat": ChRDoE.ChR_Distr.uniform(0.01, 0.05),
    "step_size": ChRDoE.ChR_Distr.uniform(0.002, 0.005),
    "dpu": ChRDoE.ChR_Distr.randint(10, 25),
    "size_x": ChRDoE.ChR_Distr.uniform(60.0, 120.0),
    "size_y": ChRDoE.ChR_Distr.uniform(30.0, 60.0),
    "bulldozing": ChRDoE.ChR_Distr.choice([False, True]),
    "terrain_type": ChRDoE.ChR_Distr.choice(["Flat", "Hmap"]),
}


def main() -> None:
    mpi_ranks = int(os.environ.get("CHR_MPI_RANKS", "4"))
    num_trials = int(os.environ.get("CHR_RAY_NUM_TRIALS", "8"))
    max_concurrent = int(os.environ.get("CHR_RAY_MAX_CONCURRENT", "1"))
    cpus_per_rank = int(os.environ.get("CHR_MPI_CPUS_PER_RANK", "4"))

    if not os.path.isfile(SYN_SCM_BINARY):
        raise FileNotFoundError(
            f"SynChrono binary not found: {SYN_SCM_BINARY}\n"
            "Build with: bash ex5-synchrono-ray-coupled/setup_synchrono_amd.sh"
        )

    simulate_fn = make_mpi_simulate_fn(
        binary=SYN_SCM_BINARY,
        flag_map=SYNCHRONO_SCM_FLAGS,
        mpi_ranks=mpi_ranks,
        extra_args=["--contact_method", "SMC"],
    )

    resources = recommended_resources_coupled(
        "synchrono_mpi", mpi_ranks=mpi_ranks, cpus_per_rank=cpus_per_rank
    )

    print("=== ChronoRay ex5: SynChrono SCM MPI DoE ===", flush=True)
    print(f"  Binary:           {SYN_SCM_BINARY}", flush=True)
    print(f"  MPI ranks/trial:  {mpi_ranks}", flush=True)
    print(f"  Trials:           {num_trials}", flush=True)
    print(f"  Max concurrent:   {max_concurrent}", flush=True)
    print(f"  Ray resources:    {resources}", flush=True)
    print("==========================================", flush=True)

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
    print(f"SynChrono DoE completed in {elapsed:.1f}s ({elapsed / 60:.1f} min)")


if __name__ == "__main__":
    main()
