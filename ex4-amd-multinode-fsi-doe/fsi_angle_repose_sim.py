"""Pickle-safe FSI angle-of-repose simulation for Ray remote workers."""

import math
import os
from pathlib import Path

import pychrono as chrono
import pychrono.fsi as fsi

TIME_STEP = 2e-5
OUTPUT_FPS = 100


def _make_run_dir(config):
    output_root = os.environ.get("CHR_RAY_OUTPUT_DIR", os.getcwd())
    name = (
        f"d{config['density']:.0f}"
        f"_E{config['Young_modulus']:.2e}"
        f"_nu{config['Poisson_ratio']:.2f}"
        f"_mu{config['mu_s']:.2f}"
        f"_k{config['kappa_ratio']:.3f}"
        f"_lam{config['mcc_lambda']:.3f}"
    )
    run_dir = os.path.join(output_root, "particles", name)
    Path(run_dir).mkdir(parents=True, exist_ok=True)
    return run_dir


def _write_log(run_dir, config):
    with open(os.path.join(run_dir, "log.txt"), "w") as f:
        f.write("=== Angle of Repose Simulation Parameters ===\n\n")
        for k, v in config.items():
            f.write(f"{k}: {v}\n")


def simulate_fn(config):
    print(f"[trial] mu_s={config['mu_s']:.2f} density={config['density']:.0f}", flush=True)

    sys_mbs = chrono.ChSystemNSC()
    sys_sph = fsi.ChFsiFluidSystemSPH()
    sys_fsi = fsi.ChFsiSystemSPH(sys_mbs, sys_sph)

    sys_fsi.SetStepSizeCFD(TIME_STEP)
    sys_fsi.SetStepsizeMBD(TIME_STEP)

    mat_props = fsi.ElasticMaterialProperties()
    sph_params = fsi.SPHParameters()

    mat_props.density = config["density"]
    mat_props.Young_modulus = config["Young_modulus"]
    mat_props.Poisson_ratio = config["Poisson_ratio"]
    mat_props.rheology_model = fsi.RheologyCRM_MCC
    angle_mus = math.atan(config["mu_s"])
    mat_props.mcc_M = (6.0 * math.sin(angle_mus)) / (3.0 - math.sin(angle_mus))
    kappa_ratio = config["kappa_ratio"]
    mat_props.mcc_kappa = kappa_ratio * config["mcc_lambda"]
    mat_props.mcc_lambda = config["mcc_lambda"]
    sys_sph.SetElasticSPH(mat_props)

    sph_params.integration_scheme = fsi.IntegrationScheme_RK2
    sph_params.initial_spacing = 0.001
    sph_params.d0_multiplier = 1.3
    sph_params.artificial_viscosity = 0.2
    sph_params.shifting_method = fsi.ShiftingMethod_PPST_XSPH
    sph_params.shifting_xsph_eps = 0.5
    sph_params.shifting_ppst_pull = 1.0
    sph_params.shifting_ppst_push = 3.0
    sph_params.free_surface_threshold = 2.0
    sph_params.num_proximity_search_steps = 1
    sph_params.kernel_type = fsi.KernelType_CUBIC_SPLINE
    sph_params.boundary_method = fsi.BoundaryMethod_ADAMI
    sph_params.viscosity_method = fsi.ViscosityMethod_ARTIFICIAL_BILATERAL
    sph_params.use_variable_time_step = True
    sys_sph.SetSPHParameters(sph_params)

    g = 9.81
    sys_sph.SetGravitationalAcceleration(chrono.ChVector3d(0, 0, -g))
    sys_mbs.SetGravitationalAcceleration(sys_sph.GetGravitationalAcceleration())
    sys_fsi.SetVerbose(False)

    spacing = sph_params.initial_spacing
    floor_width = 0.4
    floor_length = 0.4
    floor_thickness = 0.01

    cMin = chrono.ChVector3d(-floor_width / 2 * 1.2, -floor_length / 2 * 1.2, -floor_thickness * 1.2)
    cMax = chrono.ChVector3d(floor_width / 2 * 1.2, floor_length / 2 * 1.2, 0.25 * 1.2)
    sys_sph.SetComputationalDomain(chrono.ChAABB(cMin, cMax), fsi.BC_NONE)

    floor_body = chrono.ChBody()
    floor_body.SetPos(chrono.ChVector3d(0, 0, 0))
    floor_body.SetFixed(True)
    sys_mbs.AddBody(floor_body)

    floor_bce = sys_sph.CreatePointsBoxContainer(
        chrono.ChVector3d(floor_width, floor_length, floor_thickness),
        chrono.ChVector3i(0, 0, -1),
    )
    sys_fsi.AddFsiBody(
        floor_body,
        floor_bce,
        chrono.ChFramed(chrono.ChVector3d(0, 0, floor_thickness / 2), chrono.QUNIT),
        True,
    )

    pile_half_width = 0.02
    pile_half_length = 0.02
    pile_height = 0.08

    sampler = chrono.ChGridSamplerd(spacing)
    col_center = chrono.ChVector3d(0, 0, floor_thickness + pile_height / 2)
    col_half = chrono.ChVector3d(
        pile_half_width - spacing,
        pile_half_length - spacing,
        pile_height / 2 - spacing,
    )
    points = sampler.SampleBox(col_center, col_half)

    gz = abs(sys_sph.GetGravitationalAcceleration().z)
    rho_ini = sys_sph.GetDensity()

    for p in points:
        pre_ini = rho_ini * gz * (floor_thickness + pile_height - p.z)
        preconsolidation_pressure = pre_ini * 2.0
        sys_sph.AddSPHParticle(
            p,
            rho_ini,
            pre_ini,
            sys_sph.GetViscosity(),
            chrono.ChVector3d(0, 0, 0),
            chrono.ChVector3d(-pre_ini, -pre_ini, -pre_ini),
            chrono.ChVector3d(0, 0, 0),
            preconsolidation_pressure,
        )

    sys_fsi.Initialize()

    run_dir = _make_run_dir(config)
    _write_log(run_dir, config)
    sph_dir = os.path.join(run_dir, "sph_particles")
    Path(sph_dir).mkdir(exist_ok=True)

    t_end = float(os.environ.get("CHR_RAY_SIM_TEND", "1.5"))
    sim_time = 0.0
    dt = sys_fsi.GetStepSizeCFD()
    out_frame = 0

    while sim_time < t_end:
        if sim_time >= out_frame / OUTPUT_FPS:
            sys_sph.SaveParticleData(sph_dir)
            out_frame += 1
        sys_fsi.DoStepDynamics(dt)
        sim_time += dt

    print(f"[trial done] {run_dir}", flush=True)
