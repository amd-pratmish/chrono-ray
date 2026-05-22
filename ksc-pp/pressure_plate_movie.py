import pychrono as chrono 
import pychrono.fsi as fsi
import math
import os
import csv
from pathlib import Path
from ChronoRay import ChRDoE


class MarkerVisibilityCallback(fsi.MarkerVisibilityCallback):
    def __init__(self):
        pass  # skip abstract parent __init__
    
    def get(self, n):
        return self.pos[n].y > 0

## SIMULATION CONFIG 
TIME_STEP = 2e-5
FLAG_VISUALIZE = True
OUTPUT_FPS = 100 
TRIAL_NUM = 0 

## CONTAINER CONFIG 
CONTAINER_Z = 0.15 
CONTAINER_X = 0.12
CONTAINER_Y = 0.12

## PRESSURE PLATE CONFIG 
PLATE_Z = 0.01
PLATE_X = 0.03
PLATE_Y = 0.03
PLATE_DENSITY = 7.8e3 #steel plate 
PLATE_MASS = PLATE_DENSITY * PLATE_X * PLATE_Y * PLATE_Z 

##TERRAIN CONFIG 
PRE_PRESSURE_SCALE = 2.0


## PARAMETER SAMPLE SPACE
param_sample_space = {
    # ---------------------------------------------------------------
    # mu_s = static friction coefficient of the granular material.
    # Think of it as "how grippy the grains are against each other."
    # It relates to the angle of repose — the steepest slope a pile
    # of the material can hold before collapsing: angle = atan(mu_s).
    #   - mu_s = 0.35  →  ~19°  (very loose, slippery, like dry rice)
    #   - mu_s = 0.70  →  ~35°  (typical dry sand)
    #   - mu_s = 1.20  →  ~50°  (unrealistically steep for loose soil;
    #                            you'd need cohesion or interlocking grains)
    # The old upper bound (1.2) was sampling physically unrealistic soils,
    # so we tighten it to 0.9.
    "mu_s":          ChRDoE.ChR_Distr.uniform(0.35, 0.90),   # was (0.4, 1.2)

    # ---------------------------------------------------------------
    # density = mass per unit volume of the granular material (kg/m³).
    # This captures how tightly the grains are packed together:
    #   - ~1200 kg/m³  →  very loose fill (freshly poured, lots of air gaps)
    #   - ~1500 kg/m³  →  loose-to-medium sand
    #   - ~1800 kg/m³  →  dense, well-compacted sand
    #   - ~2000 kg/m³  →  heavily compacted (e.g. road base)
    # The old range (1520–1780) only covered medium densities — about
    # 17% spread. Widening to 1200–2000 lets us study both very loose
    # and very dense soils, which behave quite differently under impact.
    "density":       ChRDoE.ChR_Distr.uniform(1200, 2000),   # was (1520, 1780)

    # ---------------------------------------------------------------
    # mcc_lambda = "plastic compressibility" in the Modified Cam-Clay
    # soil model. It's the slope of the line describing how much the
    # soil *permanently* squishes down as you load it harder.
    # Higher lambda  →  soil compresses a lot under load (soft, squishy)
    # Lower lambda   →  soil barely compresses (stiff, dense)
    # Typical values:
    #   - 0.02–0.05  →  stiff/dense sands
    #   - 0.05–0.10  →  medium soils
    #   - 0.10–0.25  →  soft clays and loose fill (collapses dramatically)
    # The old range stopped at 0.10 — only stiff soils. Expanding to 0.22
    # lets us see the very different behavior of soft, collapsible soils.
    "mcc_lambda":    ChRDoE.ChR_Distr.uniform(0.02, 0.22),   # was (0.02, 0.10)

    # ---------------------------------------------------------------
    # kappa = "elastic compressibility" — the slope of the *recoverable*
    # (spring-back) part of compression in the Cam-Clay model.
    # Physical rule: kappa MUST be much smaller than lambda, because
    # the elastic spring-back is always smaller than the total squish.
    #
    # Instead of sampling kappa directly (which could accidentally
    # violate kappa << lambda), we sample it as a *fraction* of lambda.
    # A ratio of 0.05–0.25 means kappa is 5–25% of lambda, which is the
    # physically realistic range. The actual kappa value is computed
    # later as: kappa = kappa_ratio * mcc_lambda.
    "kappa_ratio":   ChRDoE.ChR_Distr.uniform(0.05, 0.25),

    # ---------------------------------------------------------------
    # Young_modulus (E) = stiffness of the material, measured in Pascals.
    # It tells you how much stress is needed to deform the material by
    # a given fraction of its length. Higher E = stiffer.
    # For granular soils:
    #   - 5e4 Pa  (50 kPa)   →  very soft, loose, easily deformed
    #   - 5e5 Pa  (500 kPa)  →  medium-stiff soil
    #   - 5e6 Pa  (5 MPa)    →  stiff, dense soil
    #   - 1e7 Pa  (10 MPa)   →  very stiff, near-rocky
    # We use loguniform (sample evenly in *log* space) because the range
    # spans more than 2 orders of magnitude — uniform sampling would
    # over-represent the high-stiffness end.
    "Young_modulus": ChRDoE.ChR_Distr.loguniform(5e4, 1e7),  # was (5e5, 5e6)

    # ---------------------------------------------------------------
    # Poisson_ratio = how much the material bulges sideways when you
    # squeeze it from the top. Imagine squishing a marshmallow — it
    # gets shorter AND wider. Poisson ratio quantifies that sideways
    # bulge relative to the vertical squish.
    #   - 0.0   →  no sideways bulge at all (like cork)
    #   - 0.2   →  typical for dry sand
    #   - 0.3   →  steel, most metals
    #   - 0.45  →  near-incompressible (like rubber)
    #   - 0.5   →  perfectly incompressible (theoretical limit; e.g. water)
    # The range 0.2–0.45 covers the realistic span for soils, so we
    # leave it alone.
    "Poisson_ratio": ChRDoE.ChR_Distr.uniform(0.2, 0.45),
}


def _make_run_dir(config):
    name = f"trial_{TRIAL_NUM}"
    trial_dir = os.path.join(os.getcwd(), "movie_trials", name)
    Path(trial_dir).mkdir(parents=True, exist_ok=True)

    # plate_dir = os.path.join(trial_dir, "plate")
    # Path(plate_dir).mkdir(parents=True, exist_ok=True)

    return trial_dir#, plate_dir


def _write_log(run_dir, config):
    with open(os.path.join(run_dir, "terrain_config_log.txt"), "w") as f:
        f.write("=== Pressure Plate Terrain Simulation Parameters ===\n\n")
        for k, v in config.items():
            f.write(f"{k}: {v}\n")


def simulate_fn(config):

    global TRIAL_NUM 
    TRIAL_NUM += 1 

    #1. physics systems 
    sys_mbs = chrono.ChSystemSMC()
    sys_sph = fsi.ChFsiFluidSystemSPH()
    sys_fsi = fsi.ChFsiSystemSPH(sys_mbs, sys_sph)

    sys_fsi.SetStepSizeCFD(TIME_STEP)
    sys_fsi.SetStepsizeMBD(TIME_STEP)

    #2. set material properties and sph parameters 
    mat_props = fsi.ElasticMaterialProperties()
    sph_params = fsi.SPHParameters()

    mat_props.density = config["density"]
    mat_props.Young_modulus = config["Young_modulus"]
    mat_props.Poisson_ratio = config["Poisson_ratio"]
    mat_props.rheology_model = fsi.RheologyCRM_MCC
    angle_mus = math.atan(config["mu_s"])
    mat_props.mcc_M = (6.0 * math.sin(angle_mus)) / (3.0 - math.sin(angle_mus))
    kappa_ratio = config["kappa_ratio"]
    mat_props.mcc_kappa = kappa_ratio * config["mcc_lambda"] #config["mcc_kappa"]
    mat_props.mcc_lambda = config["mcc_lambda"]
    sys_sph.SetElasticSPH(mat_props)

    sph_params.integration_scheme = fsi.IntegrationScheme_RK2
    sph_params.initial_spacing = 0.002
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

    #3. gravity and verbose
    g = 9.81
    sys_sph.SetGravitationalAcceleration(chrono.ChVector3d(0, 0, -g))
    sys_mbs.SetGravitationalAcceleration(sys_sph.GetGravitationalAcceleration())
    sys_fsi.SetVerbose(True)


    #4. container and SPH computational domain setup 

    #container dimensions 
    clearance = 0.2 * CONTAINER_Z
    container_x = CONTAINER_X
    container_y = CONTAINER_Y
    container_z = CONTAINER_Z + clearance 

    #SPH computational domain 
    min_corner = chrono.ChVector3d(-container_x / 2 * 1.2, -container_y / 2 * 1.2, -container_z * 1.2)
    max_corner = chrono.ChVector3d(container_x / 2 * 1.2, container_y / 2 * 1.2, (container_z + 0.05 + sph_params.initial_spacing) * 1.2)
    sys_sph.SetComputationalDomain(chrono.ChAABB(min_corner, max_corner), fsi.BC_NONE)
        #ChAABB = Chrono's Axis-Aligned Bounding Box.
        #box aligned with chrono sys coordframe, makes compuations quicker/easier 

    #container body 
    box = chrono.ChBody()
    box.SetPos(chrono.ChVector3d(0, 0, 0))
    box.SetFixed(True)
    sys_mbs.AddBody(box)

    #solid-on-solid contact material
    ss_c_material = chrono.ChContactMaterialSMC()
    ss_c_material.SetYoungModulus(193e9)
    ss_c_material.SetFriction(0.7)
    ss_c_material.SetRestitution(0.05)
    ss_c_material.SetAdhesion(0)

    #collision geometry for container 
    chrono.AddBoxContainer(
        box,
        ss_c_material,
        chrono.ChFramed(chrono.ChVector3d(0, 0, container_z / 2), chrono.QUNIT),
        chrono.ChVector3d(container_x, container_y, container_z),
        0.1,
        chrono.ChVector3i(2, 2, -1),
        False,
    )
    box.EnableCollision(False)

    #add (boundary type) BCE markers to container walls 
    box_bce = sys_sph.CreatePointsBoxContainer(
        chrono.ChVector3d(container_x, container_y, container_z),
        chrono.ChVector3i(2, 2, -1)
    )

    # Manually shift markers to their intended world position
    # (frame arg to AddFsiBoundary isn't being applied — known PyChrono quirk)
    shifted_bce = [chrono.ChVector3d(p.x, p.y, p.z + container_z / 2) for p in box_bce]

    sys_fsi.AddFsiBoundary(
        shifted_bce,
        chrono.ChFramed(chrono.VNULL, chrono.QUNIT)
    )

    # DEBUG: where are the BCE markers actually placed?
    # xs = [p.x for p in box_bce]
    # ys = [p.y for p in box_bce]
    # zs = [p.z for p in box_bce]
    # print(f"  Box BCE count: {len(box_bce)}")
    # print(f"  Box BCE X range: {min(xs):.4f} to {max(xs):.4f}  (expected ±{container_x/2})")
    # print(f"  Box BCE Y range: {min(ys):.4f} to {max(ys):.4f}  (expected ±{container_y/2})")
    # print(f"  Box BCE Z range: {min(zs):.4f} to {max(zs):.4f}  (expected 0 to {container_z})")

    #5. set up SPH nodes/(sampling) points/particles for granular (terrain) material 
    #NOTE: SPH particles are not physical terrain particles, they are a computational tool 

    #SPH node locations 
    sampler = chrono.ChGridSamplerd(sph_params.initial_spacing)
    box_center_loc = chrono.ChVector3d(0, 0, CONTAINER_Z / 2)
    box_half_dim = chrono.ChVector3d(
        container_x / 2 - sph_params.initial_spacing,
        container_y / 2 - sph_params.initial_spacing,
        CONTAINER_Z / 2 - sph_params.initial_spacing,
    )
    points = sampler.SampleBox(box_center_loc, box_half_dim)



    # DEBUG: confirm soil actually fills the bin
    # xs = [p.x for p in points]
    # ys = [p.y for p in points]
    # zs = [p.z for p in points]
    # print(f"  SPH count: {len(points)}")
    # print(f"  SPH X range: {min(xs):.4f} to {max(xs):.4f}  (container ±{container_x/2})")
    # print(f"  SPH Y range: {min(ys):.4f} to {max(ys):.4f}  (container ±{container_y/2})")
    # print(f"  SPH Z range: {min(zs):.4f} to {max(zs):.4f}  (container 0 to {container_z})")

    #add SPH nodes to the fluid system 
    gz_mag =  abs(sys_sph.GetGravitationalAcceleration().z)
    rho_init = sys_sph.GetDensity()
    for p in points:
        pressure_init = rho_init * gz_mag * (CONTAINER_Z - p.z)
        max_pressure_init_memory = pressure_init * PRE_PRESSURE_SCALE
        sys_sph.AddSPHParticle(
            p,
            rho_init,
            pressure_init,
            sys_sph.GetViscosity(),
            chrono.ChVector3d(0, 0, 0),
            chrono.ChVector3d(-pressure_init, -pressure_init, -pressure_init),
            chrono.ChVector3d(0, 0, 0),
            max_pressure_init_memory,
        )
    
    #6. create pressure plate (pp)

    #body 
    pp = chrono.ChBody()
    plate_z_pos = container_z - clearance + PLATE_Z/2 
    pp.SetPos(chrono.ChVector3d(0, 0, plate_z_pos))
    pp.SetRot(chrono.ChQuaterniond(1, 0, 0, 0))
    pp.SetMass(PLATE_MASS)
    I = PLATE_MASS * (PLATE_X**2 + PLATE_Y**2) / 12
    pp.SetInertiaXX(chrono.ChVector3d(I, I, I))
    sys_mbs.AddBody(pp)
    pp_vis_shape = chrono.ChVisualShapeBox(PLATE_X, PLATE_Y, PLATE_Z)
    pp_vis_shape.SetColor(chrono.ChColor(0.2, 0.7, 0.3))
    pp.AddVisualShape(pp_vis_shape)

    #collision geometery 
    vis_material = chrono.ChVisualMaterial()
    chrono.AddBoxGeometry(pp, ss_c_material, 
                          chrono.ChVector3d(PLATE_X, PLATE_Y, PLATE_Z),
                          chrono.ChVector3d(0,0,0), 
                          chrono.ChQuaterniond(1,0,0,0),
                          True,
                          vis_material) 
    
    #add (collision type) BCE markers to pp 
    pp_bce = sys_sph.CreatePointsPlate(chrono.ChVector2d(PLATE_X, PLATE_Y))
    sys_fsi.AddFsiBody(pp, pp_bce, chrono.ChFramed(chrono.ChVector3d(0, 0, 0), chrono.QUNIT), False)

    #7. motor to move pp 
    penetration_velocity = 2e-3 
    motor = chrono.ChLinkMotorLinearSpeed()
    motor.SetMotorFunction(chrono.ChFunctionConst(-penetration_velocity))
    motor.Initialize(pp, box, chrono.ChFramed(chrono.ChVector3d(0, 0, 0), chrono.QUNIT))
    sys_mbs.AddLink(motor)

    #8. init fsi 
    sys_sph.SetOutputLevel(fsi.OutputLevel_CRM_FULL) 
    sys_fsi.Initialize()

    #9. output setup
    trial_dir = _make_run_dir(config)
    _write_log(trial_dir, config)
    print(f"Saving output to: {trial_dir}")

    #7. visualization
    frame_dir = None

    if FLAG_VISUALIZE:
        import pychrono.vsg3d as vsg3d

        frame_dir = os.path.join(trial_dir, "frames")
        Path(frame_dir).mkdir(parents=True, exist_ok=True)

        vis_fsi = fsi.ChSphVisualizationVSG(sys_fsi)
        vis_fsi.EnableFluidMarkers(True)
        vis_fsi.EnableBoundaryMarkers(True)
        vis_fsi.EnableRigidBodyMarkers(True)

        # pressure coloring instead of velocity
        vis_fsi.SetSPHColorCallback(fsi.ParticlePressureColorCallback(0, 30000, False))
        
        vis = vsg3d.ChVisualSystemVSG()
        vis.AttachPlugin(vis_fsi)
        vis.AttachSystem(sys_mbs)
        vis.SetWindowTitle("Pressure Plate w/ MCC Rheology Terrain")
        vis.SetWindowSize(1280, 720)

        # side view camera matching the C++ version
        vis.AddCamera(
            chrono.ChVector3d(0, -2 * CONTAINER_Z, 0.75 * CONTAINER_Z),  # position
            chrono.ChVector3d(0,  0,               0.55 * CONTAINER_Z),  # look-at
        )
        vis.SetLightIntensity(0.9)
        vis.SetLightDirection(-math.pi / 2, math.pi / 6)
        vis.Initialize()
    else:
        vis = None

    #8. setting up csv logging 
    Path(os.path.join(trial_dir, "sph_particles")).mkdir(parents=True, exist_ok=True)

    csv_path = os.path.join(trial_dir, "pressure_sinkage_log.csv")
    csv_file = open(csv_path, "w", newline="")
    csv_writer = csv.writer(csv_file)

    csv_writer.writerow([
        "time",
        "sinkage",
        "plate_bottom_z",
        "motor_force_z_signed",
        "motor_force_z_abs",
        "motor_force_z_signed_offset",
        "pressure_positive",
    ])

    # Estimate fixed initial terrain surface height from generated SPH node positions
    # Use top-layer mean rather than single max for less noise
    zs = [p.z for p in points]
    zmax = max(zs)
    top_layer = [z for z in zs if z > zmax - 2.0 * sph_params.initial_spacing]
    terrain_surface_z0 = sum(top_layer) / len(top_layer)

    plate_area = PLATE_X * PLATE_Y

    #9. sim loop
    target_sinkage = 0.015
    t_end = 1.1 * (target_sinkage / penetration_velocity)
    sim_time = 0.0
    dt = sys_fsi.GetStepSizeCFD()
    log_steps = 500
    step = 0
    motor_force_z_signed_offset = 0.0
    frame_idx = 0
    frame_interval = 1.0 / OUTPUT_FPS  # seconds between captured frames
    next_frame_time = 0.0

    while sim_time < t_end:
        if vis is not None:
            if not vis.Run():
                break
            vis.Render()

            # capture frame at OUTPUT_FPS rate
            if sim_time >= next_frame_time:
                frame_path = os.path.join(frame_dir, f"frame_{frame_idx:05d}.png")
                vis.WriteImageToFile(frame_path)
                frame_idx += 1
                next_frame_time += frame_interval

        if step == 5:
            motor_force_z_signed_offset = motor.GetMotorForce()

        if step % log_steps == 0:
            pos = pp.GetPos()
            plate_bottom_z = pos.z - PLATE_Z / 2.0
            sinkage = terrain_surface_z0 - plate_bottom_z

            if sinkage >= target_sinkage:
                break

            motor_force_z_signed = motor.GetMotorForce() - motor_force_z_signed_offset
            motor_force_z_abs = abs(motor_force_z_signed)
            pressure_positive = motor_force_z_abs / plate_area

            csv_writer.writerow([
                sim_time, sinkage, plate_bottom_z,
                motor_force_z_signed, motor_force_z_abs,
                motor_force_z_signed_offset, pressure_positive,
            ])

            sys_sph.SaveParticleData(os.path.join(trial_dir, "sph_particles"))

        sys_fsi.DoStepDynamics(dt)
        sim_time += dt
        step += 1

    csv_file.close()


if FLAG_VISUALIZE:
    chrdoe = ChRDoE(simulate_fn, 
                    param_sample_space, 
                    sampling_design=ChRDoE.SamplingDesign.LATIN_HYPERCUBE, 
                    num_trials=5, 
                    max_concurrent_trials=1, 
                    FLAG_log_to_file=True, 
                    FLAG_auto_run=True)

else: 
    chrdoe = ChRDoE(simulate_fn, 
                    param_sample_space, 
                    sampling_design=ChRDoE.SamplingDesign.LATIN_HYPERCUBE, 
                    num_trials=25, 
                    max_concurrent_trials=2, 
                    FLAG_log_to_file=True, 
                    FLAG_auto_run=True)