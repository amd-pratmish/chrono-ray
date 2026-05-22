"""
Render Project Chrono pressure plate simulation in Blender — stdlib-only version.

Loads:
- SPH fluid CSV files (granular terrain particles, subsampled for memory)
- Plate VTK files (rigid pressure plate, baked as keyframes for stability)

into a single MP4 animation.

CSV columns: x, y, z, v_x, v_y, v_z, |U|, acc, rho, pressure
VTK plate:   8 vertices + 12 triangle faces (box, parsed for centroid/extent)

HOW TO USE
----------
1. Edit the CONFIG block below — at minimum set CSV_DIR, PLATE_DIR, OUTPUT_PATH.
2. Headless:    blender -b -P blender_render_plate.py
   GUI:         open in Blender's Scripting workspace, Alt-P.
3. For headless rendering, set RENDER_NOW=True. For GUI, just press Ctrl-F12.
"""

import bpy
import os
import re
import glob
import math
from array import array
from mathutils import Vector

# ============================================================
# CONFIG — edit these
# ============================================================
CSV_DIR        = "./d1824_E3.84e+05_nu0.43_mu0.47_k0.209_lam0.171/sph_particles"
PLATE_DIR      = "./d1824_E3.84e+05_nu0.43_mu0.47_k0.209_lam0.171/plate"
CSV_GLOB       = "fluid*.csv"
PLATE_GLOB     = "plate_*.vtk"
SCALE          = 10.0                        # world scale (sim units -> Blender units)
SUBSAMPLE      = 2                           # render every Nth particle (1=all, 2=half, 4=quarter)
PARTICLE_RADIUS = 0.0015                     # sphere radius in sim units (pre-scale)
ICO_SUBDIV     = 1                           # 1 is fastest; 2 looks rounder
COLOR_BY       = "speed"                     # "speed" | "pressure" | "density" | "accel"
COLOR_MIN      = None                        # None = auto (from first frame)
COLOR_MAX      = None                        # None = auto (from first frame)
PLATE_COLOR    = (0.15, 0.55, 0.20, 1.0)     # plate base color (RGBA)
USE_EEVEE      = False                       # False -> Cycles
RESOLUTION     = (1920, 1080)
SAMPLES        = 64                          # render samples (Cycles) / TAA samples (Eevee)
ADD_GROUND     = True
ADD_CAMERA     = True
ADD_LIGHT      = True

# Camera framing (tweak to taste)
CAM_DIST_FACTOR   = 1.6
CAM_HEIGHT_FACTOR = 0.30
CAM_LENS_MM       = 50

# Output settings
OUTPUT_FORMAT  = "MP4"                       # "MP4" or "PNG"
OUTPUT_PATH    = "/home/khai/dev/chrono-ray/ksc-pp/movies/plate_run.mp4"
FPS            = 20
RENDER_NOW     = True
# ============================================================

COL = {
    "x": 0, "y": 1, "z": 2,
    "vx": 3, "vy": 4, "vz": 5,
    "speed": 6, "accel": 7, "density": 8, "pressure": 9,
}

OBJECT_NAME = "ChronoFluid"
MESH_NAME   = "ChronoFluidMesh"
MAT_NAME    = "ChronoFluidMaterial"
NG_NAME     = "ChronoFluidNodes"
ATTR_NAME   = "color_value"

PLATE_OBJECT_NAME = "ChronoPlate"
PLATE_MAT_NAME    = "ChronoPlateMaterial"


# ------------------------------------------------------------
# Frame discovery & file loading (stdlib only)
# ------------------------------------------------------------
def discover_frames(dir_path, pattern):
    files = glob.glob(os.path.join(dir_path, pattern))
    if not files:
        raise FileNotFoundError(
            f"No files matched {pattern!r} in {dir_path!r}. "
            "Edit CONFIG paths at the top of the script.")
    rx = re.compile(r"(\d+)")
    out = []
    for f in files:
        m = rx.findall(os.path.basename(f))
        n = int(m[-1]) if m else 0
        out.append((n, f))
    out.sort(key=lambda t: t[0])
    return out


def load_csv(path, color_col_idx):
    """Load one fluid CSV with optional subsampling.
    Returns (positions_flat, scalars, n).
    """
    positions = array('f')
    scalars   = array('f')
    pos_extend = positions.extend
    sc_append  = scalars.append

    with open(path, 'r') as f:
        f.readline()  # skip header
        for i, line in enumerate(f):
            if SUBSAMPLE > 1 and i % SUBSAMPLE != 0:
                continue
            if len(line) < 3:
                continue
            parts = line.split(',')
            if len(parts) < 10:
                continue
            pos_extend((float(parts[0]), float(parts[1]), float(parts[2])))
            sc_append(float(parts[color_col_idx]))

    return positions, scalars, len(scalars)


def load_plate_vtk(path):
    """Parse plate VTK. Returns (center, half_extent) — both 3-tuples in sim units."""
    xs, ys, zs = [], [], []

    with open(path, 'r') as f:
        lines = f.readlines()

    i = 0
    n = len(lines)
    while i < n:
        line = lines[i].strip()
        if line.startswith("POINTS"):
            n_verts = int(line.split()[1])
            for _ in range(n_verts):
                i += 1
                a, b, c = lines[i].split()[:3]
                xs.append(float(a))
                ys.append(float(b))
                zs.append(float(c))
            break  # only need POINTS for centroid/extent
        i += 1

    center = ((min(xs) + max(xs)) / 2,
              (min(ys) + max(ys)) / 2,
              (min(zs) + max(zs)) / 2)
    half   = ((max(xs) - min(xs)) / 2,
              (max(ys) - min(ys)) / 2,
              (max(zs) - min(zs)) / 2)
    return center, half


def compute_bbox(positions_flat):
    xmin = ymin = zmin = float('inf')
    xmax = ymax = zmax = float('-inf')
    for i in range(0, len(positions_flat), 3):
        x = positions_flat[i]
        y = positions_flat[i+1]
        z = positions_flat[i+2]
        if x < xmin: xmin = x
        if x > xmax: xmax = x
        if y < ymin: ymin = y
        if y > ymax: ymax = y
        if z < zmin: zmin = z
        if z > zmax: zmax = z
    return (xmin, ymin, zmin), (xmax, ymax, zmax)


def percentile(values, q):
    n = len(values)
    if n == 0:
        return 0.0
    s = sorted(values)
    idx = int(n * q / 100.0)
    if idx >= n: idx = n - 1
    if idx < 0:  idx = 0
    return s[idx]


def diag_len(cmin, cmax):
    return math.sqrt(sum((a - b) ** 2 for a, b in zip(cmax, cmin)))


def scale_in_place(positions_flat, s):
    if s == 1.0:
        return
    for i in range(len(positions_flat)):
        positions_flat[i] *= s


def scale_tuple(t, s):
    return (t[0] * s, t[1] * s, t[2] * s)


# ------------------------------------------------------------
# Scene / object setup
# ------------------------------------------------------------
def clear_scene():
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)
    for block in (bpy.data.meshes, bpy.data.materials,
                  bpy.data.node_groups, bpy.data.lights, bpy.data.cameras):
        for item in list(block):
            if item.users == 0:
                block.remove(item)


def make_particle_mesh(num_points):
    mesh = bpy.data.meshes.new(MESH_NAME)
    mesh.vertices.add(num_points)
    mesh.attributes.new(name=ATTR_NAME, type='FLOAT', domain='POINT')
    obj = bpy.data.objects.new(OBJECT_NAME, mesh)
    bpy.context.collection.objects.link(obj)
    return obj


def update_particle_mesh(obj, positions_flat, scalars, n):
    mesh = obj.data
    if len(mesh.vertices) != n:
        mesh.clear_geometry()
        mesh.vertices.add(n)
        if ATTR_NAME not in mesh.attributes:
            mesh.attributes.new(name=ATTR_NAME, type='FLOAT', domain='POINT')
    mesh.vertices.foreach_set("co", positions_flat)
    mesh.attributes[ATTR_NAME].data.foreach_set("value", scalars)
    mesh.update()


def make_plate_cube(center, half_extent):
    """Add a cube primitive sized to the plate; same pattern as add_ground."""
    bpy.ops.mesh.primitive_cube_add(size=2.0, location=center)
    cube = bpy.context.active_object
    cube.name = PLATE_OBJECT_NAME
    cube.scale = half_extent
    return cube


def setup_plate_animation(obj, plate_frames):
    """Pre-bake plate position as keyframes on the location property.

    This avoids per-frame handler updates for the plate, leaving the
    frame handler to only update the fluid mesh — matches the working
    angle-of-repose pattern, which only mutates one object per frame.
    """
    for frame_idx, (_, vtk_path) in enumerate(plate_frames):
        center, _ = load_plate_vtk(vtk_path)
        obj.location = scale_tuple(center, SCALE)
        obj.keyframe_insert(data_path="location", frame=frame_idx + 1)
    # Step-wise interpolation (no smoothing between sampled frames)
    if obj.animation_data and obj.animation_data.action:
        for fc in obj.animation_data.action.fcurves:
            for kp in fc.keyframe_points:
                kp.interpolation = 'CONSTANT'


# ------------------------------------------------------------
# Materials
# ------------------------------------------------------------
def make_material(cmin, cmax):
    """Attribute-driven color ramp for fluid particles."""
    mat = bpy.data.materials.new(MAT_NAME)
    mat.use_nodes = True
    nt = mat.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)

    out  = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    attr = nt.nodes.new("ShaderNodeAttribute")
    mapn = nt.nodes.new("ShaderNodeMapRange")
    ramp = nt.nodes.new("ShaderNodeValToRGB")

    out.location  = (600, 0)
    bsdf.location = (300, 0)
    ramp.location = (0, 0)
    mapn.location = (-250, 0)
    attr.location = (-500, 0)

    attr.attribute_name = ATTR_NAME
    attr.attribute_type = 'GEOMETRY'

    mapn.inputs["From Min"].default_value = float(cmin)
    mapn.inputs["From Max"].default_value = float(cmax)
    mapn.inputs["To Min"].default_value   = 0.0
    mapn.inputs["To Max"].default_value   = 1.0
    mapn.clamp = True

    elts = ramp.color_ramp.elements
    elts[0].position = 0.0
    elts[0].color    = (0.02, 0.08, 0.35, 1.0)
    elts[1].position = 1.0
    elts[1].color    = (1.0, 1.0, 1.0, 1.0)
    mid = elts.new(0.5)
    mid.color = (0.15, 0.6, 0.95, 1.0)

    bsdf.inputs["Roughness"].default_value = 0.25
    if "Specular IOR Level" in bsdf.inputs:
        bsdf.inputs["Specular IOR Level"].default_value = 0.5

    nt.links.new(attr.outputs["Fac"],    mapn.inputs["Value"])
    nt.links.new(mapn.outputs["Result"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"],  bsdf.inputs["Base Color"])
    nt.links.new(bsdf.outputs["BSDF"],   out.inputs["Surface"])
    return mat


def make_plate_material():
    """Solid-color material for the plate."""
    mat = bpy.data.materials.new(PLATE_MAT_NAME)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = PLATE_COLOR
    bsdf.inputs["Roughness"].default_value = 0.4
    if "Metallic" in bsdf.inputs:
        bsdf.inputs["Metallic"].default_value = 0.6
    return mat


# ------------------------------------------------------------
# Geometry Nodes: instance a small sphere on each fluid vertex
# ------------------------------------------------------------
def make_geo_nodes(obj, material, radius):
    ng = bpy.data.node_groups.new(NG_NAME, 'GeometryNodeTree')
    ng.interface.new_socket(name="Geometry", in_out='INPUT',
                            socket_type='NodeSocketGeometry')
    ng.interface.new_socket(name="Geometry", in_out='OUTPUT',
                            socket_type='NodeSocketGeometry')

    nodes = ng.nodes
    links = ng.links

    gin  = nodes.new("NodeGroupInput");                gin.location  = (-600, 0)
    gout = nodes.new("NodeGroupOutput");               gout.location = (800, 0)
    m2p  = nodes.new("GeometryNodeMeshToPoints");      m2p.location  = (-380, 0)
    ico  = nodes.new("GeometryNodeMeshIcoSphere");     ico.location  = (-380, -250)
    iop  = nodes.new("GeometryNodeInstanceOnPoints");  iop.location  = (-150, 0)
    smat = nodes.new("GeometryNodeSetMaterial");       smat.location = (350, 0)

    ico.inputs["Subdivisions"].default_value = ICO_SUBDIV
    ico.inputs["Radius"].default_value       = radius * SCALE
    smat.inputs["Material"].default_value    = material

    links.new(gin.outputs[0],            m2p.inputs["Mesh"])
    links.new(m2p.outputs["Points"],     iop.inputs["Points"])
    links.new(ico.outputs["Mesh"],       iop.inputs["Instance"])
    links.new(iop.outputs["Instances"],  smat.inputs["Geometry"])
    links.new(smat.outputs["Geometry"],  gout.inputs[0])

    mod = obj.modifiers.new(name="ChronoFluidGN", type='NODES')
    mod.node_group = ng
    return mod


# ------------------------------------------------------------
# Camera / light / world / render
# ------------------------------------------------------------
def setup_world():
    world = bpy.context.scene.world or bpy.data.worlds.new("World")
    bpy.context.scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs["Color"].default_value = (0.02, 0.025, 0.04, 1.0)
        bg.inputs["Strength"].default_value = 1.0


def setup_camera(bbox):
    cmin, cmax = bbox
    center = tuple(0.5 * (a + b) for a, b in zip(cmin, cmax))
    diag   = diag_len(cmin, cmax)
    cam_data = bpy.data.cameras.new("ChronoCam")
    cam_data.lens = float(CAM_LENS_MM)
    cam_obj  = bpy.data.objects.new("ChronoCam", cam_data)
    bpy.context.collection.objects.link(cam_obj)
    cam_obj.location = Vector((center[0] + diag * CAM_DIST_FACTOR,
                               center[1] - diag * CAM_DIST_FACTOR * 1.1,
                               center[2] + diag * CAM_HEIGHT_FACTOR))
    direction = Vector(center) - cam_obj.location
    cam_obj.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
    bpy.context.scene.camera = cam_obj


def setup_lights(bbox):
    cmin, cmax = bbox
    center = tuple(0.5 * (a + b) for a, b in zip(cmin, cmax))
    diag   = diag_len(cmin, cmax)

    sun_data = bpy.data.lights.new("Sun", type='SUN')
    sun_data.energy = 3.0
    sun = bpy.data.objects.new("Sun", sun_data)
    sun.rotation_euler = (0.6, 0.2, 0.8)
    bpy.context.collection.objects.link(sun)

    area_data = bpy.data.lights.new("Fill", type='AREA')
    area_data.energy = 200.0 * diag
    area_data.size = diag * 1.5
    area = bpy.data.objects.new("Fill", area_data)
    area.location = (center[0], center[1] - diag, center[2] + diag)
    area.rotation_euler = (1.0, 0, 0)
    bpy.context.collection.objects.link(area)


def add_ground(bbox):
    cmin, cmax = bbox
    size = float(max(cmax[0] - cmin[0], cmax[1] - cmin[1])) * 4.0
    bpy.ops.mesh.primitive_plane_add(
        size=size,
        location=(0.5 * (cmin[0] + cmax[0]),
                  0.5 * (cmin[1] + cmax[1]),
                  cmin[2] - 0.001))
    plane = bpy.context.active_object
    plane.name = "Ground"
    m = bpy.data.materials.new("GroundMat")
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.08, 0.08, 0.09, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.9
    plane.data.materials.append(m)


def setup_render(num_frames):
    sc = bpy.context.scene
    sc.render.resolution_x, sc.render.resolution_y = RESOLUTION
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    sc.render.fps = FPS
    sc.frame_start = 1
    sc.frame_end   = num_frames

    raw = OUTPUT_PATH.rstrip()
    abs_path = os.path.abspath(os.path.expanduser(raw))
    has_ext = bool(os.path.splitext(abs_path)[1])
    looks_like_dir = raw.endswith(("/", os.sep)) or (not has_ext)
    if looks_like_dir:
        os.makedirs(abs_path, exist_ok=True)
        abs_path = os.path.join(abs_path, "plate")
    else:
        parent = os.path.dirname(abs_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
    sc.render.filepath = abs_path
    print(f"[Chrono] Output filepath: {abs_path}")
    if OUTPUT_FORMAT.upper() == "MP4":
        print(f"[Chrono] (For MP4, Blender will append "
              f"frame range, producing {abs_path}0001-{num_frames:04d}.mp4)")

    if OUTPUT_FORMAT.upper() == "MP4":
        sc.render.image_settings.file_format = 'FFMPEG'
        sc.render.ffmpeg.format = 'MPEG4'
        sc.render.ffmpeg.codec = 'H264'
        sc.render.ffmpeg.constant_rate_factor = 'MEDIUM'
        sc.render.ffmpeg.ffmpeg_preset = 'GOOD'
        sc.render.ffmpeg.audio_codec = 'NONE'
    else:
        sc.render.image_settings.file_format = 'PNG'
        sc.render.image_settings.color_mode = 'RGBA'
        sc.render.image_settings.compression = 15

    if USE_EEVEE:
        for engine in ('BLENDER_EEVEE_NEXT', 'BLENDER_EEVEE'):
            try:
                sc.render.engine = engine
                break
            except TypeError:
                continue
        if hasattr(sc, "eevee"):
            try:
                sc.eevee.taa_render_samples = SAMPLES
            except AttributeError:
                pass
    else:
        sc.render.engine = 'CYCLES'
        sc.cycles.samples = SAMPLES
        sc.cycles.device  = 'GPU'


# ------------------------------------------------------------
# Frame handler — updates fluid mesh only (plate uses keyframes)
# ------------------------------------------------------------
_FLUID_FRAMES   = []
_OBJ_NAME       = OBJECT_NAME
_COLOR_COL_IDX  = COL[COLOR_BY]


def _on_frame_change(scene, depsgraph=None):
    obj = bpy.data.objects.get(_OBJ_NAME)
    if obj is None or not _FLUID_FRAMES:
        return
    idx = min(max(scene.frame_current - 1, 0), len(_FLUID_FRAMES) - 1)
    path = _FLUID_FRAMES[idx][1]
    try:
        pos, sc, n = load_csv(path, _COLOR_COL_IDX)
    except Exception as e:
        print(f"[ChronoFluid] failed to load {path}: {e}")
        return
    scale_in_place(pos, SCALE)
    update_particle_mesh(obj, pos, sc, n)


def install_handler():
    for h in list(bpy.app.handlers.frame_change_pre):
        if getattr(h, "__name__", "") == "_on_frame_change":
            bpy.app.handlers.frame_change_pre.remove(h)
    bpy.app.handlers.frame_change_pre.append(_on_frame_change)


# ------------------------------------------------------------
# Build everything
# ------------------------------------------------------------
def build_scene():
    global _FLUID_FRAMES

    fluid_frames = discover_frames(CSV_DIR, CSV_GLOB)
    plate_frames = discover_frames(PLATE_DIR, PLATE_GLOB)
    print(f"[ChronoFluid] found {len(fluid_frames)} CSV frames")
    print(f"[ChronoPlate] found {len(plate_frames)} VTK frames")

    _FLUID_FRAMES = fluid_frames

    num_frames = min(len(fluid_frames), len(plate_frames))
    if len(fluid_frames) != len(plate_frames):
        print(f"[warn] frame count mismatch — animating {num_frames} frames")

    # load first frames
    pos0, sc0, n0 = load_csv(fluid_frames[0][1], _COLOR_COL_IDX)
    scale_in_place(pos0, SCALE)
    print(f"[ChronoFluid] frame 0: {n0} particles (subsample={SUBSAMPLE})")

    plate_center0, plate_half0 = load_plate_vtk(plate_frames[0][1])
    plate_center0 = scale_tuple(plate_center0, SCALE)
    plate_half0   = scale_tuple(plate_half0,   SCALE)

    # combined bbox for camera/light framing
    cmin_f, cmax_f = compute_bbox(pos0)
    cmin_p = tuple(c - h for c, h in zip(plate_center0, plate_half0))
    cmax_p = tuple(c + h for c, h in zip(plate_center0, plate_half0))
    cmin = tuple(min(a, b) for a, b in zip(cmin_f, cmin_p))
    cmax = tuple(max(a, b) for a, b in zip(cmax_f, cmax_p))
    print(f"[Chrono] scene bbox {cmin} -> {cmax}")

    vmin = COLOR_MIN if COLOR_MIN is not None else percentile(sc0, 1)
    vmax = COLOR_MAX if COLOR_MAX is not None else percentile(sc0, 99)
    if vmax <= vmin:
        vmax = vmin + 1e-6
    print(f"[ChronoFluid] coloring by '{COLOR_BY}' in [{vmin:.4g}, {vmax:.4g}]")

    clear_scene()

    # fluid particles
    obj = make_particle_mesh(n0)
    update_particle_mesh(obj, pos0, sc0, n0)
    mat = make_material(vmin, vmax)
    make_geo_nodes(obj, mat, PARTICLE_RADIUS)

    # plate cube + animation baked as keyframes (no handler update)
    plate_obj = make_plate_cube(plate_center0, plate_half0)
    plate_mat = make_plate_material()
    plate_obj.data.materials.append(plate_mat)
    print(f"[ChronoPlate] baking {len(plate_frames)} keyframes...")
    setup_plate_animation(plate_obj, plate_frames)
    print(f"[ChronoPlate] keyframes baked.")

    if ADD_GROUND: add_ground((cmin, cmax))
    if ADD_LIGHT:  setup_lights((cmin, cmax))
    if ADD_CAMERA: setup_camera((cmin, cmax))
    setup_world()
    setup_render(num_frames=num_frames)

    install_handler()
    bpy.context.scene.frame_set(1)
    print("[Chrono] scene ready.")

    if RENDER_NOW:
        print("[Chrono] starting animation render...")
        bpy.ops.render.render(animation=True)
        print(f"[Chrono] done. Output: {bpy.context.scene.render.filepath}")


if __name__ == "__main__":
    build_scene()