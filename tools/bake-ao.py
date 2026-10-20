# Zapieka ambient occlusion realistycznego auta w Blenderze (bez okna): cienie w nadkolach, progach,
# szczelinach i między szprychami felg — tego nie da oświetlenie z panoramy ani mapa cieni słońca.
#
# Tekstury modeli ze Sketchfaba mają UV nakładające się i powtarzane (jedna felga na cztery koła,
# kafelki), więc AO nie da się zapisać w ich UV. Dlatego:
# 1. każda siatka dostaje drugi zestaw UV („AO”, Smart UV Project) — wspólny atlas całego auta,
# 2. Cycles zapieka AO do atlasu: nadwozie razem z kołami (opona zasłania nadkole), a koła osobno,
#    bez nadwozia — koła się obracają, cień nadkola kręciłby się razem z nimi,
# 3. do USDZ dopisujemy `primvars:st1` (faceVarying, kolejność narożników jak w pliku) — RealityKit
#    wczytuje je jako bufor „UV1”; reszta pliku zostaje bez zmian,
# 4. atlas zapisujemy obok modelu (<nazwa>-ao.png); gra podpina go w `PhysicallyBasedMaterial.ambientOcclusion`
#    z `uvIndex = 1` (App/Render/CarAO.swift).
#
# Koła rozpoznajemy tą samą regułą co gra (`CarEntity.realisticWheelGroups`: nazwy, ćwiartki auta,
# okrągłe części na osi). Gdy nie wychodzą cztery koła, gra ich nie obraca — wtedy jeden przebieg.
#
# Użycie:
#   Blender -b --factory-startup --python tools/bake-ao.py -- <wejście.usdz> <wyjście.usdz> <atlas.png>
#           [--size 2048] [--samples 128] [--distance 0.1] [--strength 1.0] [--yaw 0] [--wheels Object_1,Object_2] [--gpu]
# --distance: zasięg AO jako ułamek długości auta; --strength: 1 = pełne AO, 0 = brak (mieszanie z bielą);
# --yaw i --wheels: jak „yaw” i „wheels” w cars.json.
# Wejściem ma być model oryginalny (bez st1); wyjście można od razu podmienić w LocalModels.
import argparse
import math
import os
import re
import shutil
import sys
import tempfile
import zipfile

import bpy
import numpy as np
from mathutils import Matrix
from pxr import Gf, Sdf, Usd, UsdGeom, UsdUtils

parser = argparse.ArgumentParser()
parser.add_argument("src")
parser.add_argument("dst")
parser.add_argument("atlas")
parser.add_argument("--size", type=int, default=2048)
parser.add_argument("--samples", type=int, default=128)
parser.add_argument("--distance", type=float, default=0.1)
parser.add_argument("--strength", type=float, default=1.0)
parser.add_argument("--yaw", type=float, default=0.0)
parser.add_argument("--wheels", default="")
parser.add_argument("--gpu", action="store_true")
args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:])
src, dst, atlas = (os.path.abspath(p) for p in (args.src, args.dst, args.atlas))

# Pas wzdłuż prawej i górnej krawędzi atlasu zostaje biały: tam trafiają części, których UV
# nie dało się przenieść (gra podstawia im UV1 = (1, 1)), żeby nie dostały cudzego cienia.
ATLAS_FILL = 0.97

# --- 1. Koła wg reguły z gry (USD: pełne nazwy prim, granice w układzie auta po obrocie „yaw”) ---

WHEEL_RX = re.compile(r"wheel|tire|tyre|(?<![a-z])rims?(?![a-z])|disc|disk|reifen|felge", re.I)
SKIP_RX = re.compile(r"steering|calip|brake|interior|INT_", re.I)


def wheel_names(stage):
    """Nazwy siatek kół (zbiór) albo pusty zbiór, gdy gra nie rozpozna czterech kół."""
    extra = set(filter(None, args.wheels.split(",")))
    cache = UsdGeom.BBoxCache(Usd.TimeCode.Default(), ["default", "render"])
    yaw = math.radians(args.yaw)
    rot = Gf.Matrix4d().SetRotate(Gf.Rotation(Gf.Vec3d(0, 1, 0), args.yaw)) if yaw else None

    def bounds(prim):
        box = cache.ComputeWorldBound(prim)
        if rot:
            box.Transform(rot)
        r = box.ComputeAlignedRange()
        return Gf.Vec3d(r.GetMin()), Gf.Vec3d(r.GetMax())

    meshes = []  # (prim, nazwa, pasuje z nazwy, pominięta)

    def walk(prim, matched, skipped):
        name = prim.GetName() + ("_wheel" if prim.IsA(UsdGeom.Mesh) and prim.GetName() in extra else "")
        m = matched or bool(WHEEL_RX.search(name))
        s = skipped or bool(SKIP_RX.search(name))
        if prim.IsA(UsdGeom.Mesh) and UsdGeom.Imageable(prim).ComputeVisibility() != UsdGeom.Tokens.invisible:
            meshes.append((prim, prim.GetName(), m, s))
        for c in prim.GetChildren():
            walk(c, m, s)

    walk(stage.GetPseudoRoot(), False, False)
    lo = Gf.Vec3d(math.inf, math.inf, math.inf)
    hi = -lo
    boxes = {}
    for prim, *_ in meshes:
        a, b = bounds(prim)
        boxes[prim] = (a, b)
        lo = Gf.Vec3d(*(min(x, y) for x, y in zip(lo, a)))
        hi = Gf.Vec3d(*(max(x, y) for x, y in zip(hi, b)))
    ext = hi - lo
    center = (lo + hi) / 2
    groups, gboxes, taken = {}, {}, set()
    for prim, name, m, s in meshes:
        if not m or s:
            continue
        a, b = boxes[prim]
        e = b - a
        if e[0] < ext[0] * 0.45 and e[2] < ext[2] * 0.35:
            c = (a + b) / 2
            key = (1 if c[0] > center[0] else 0) + (2 if c[2] > center[2] else 0)
            groups.setdefault(key, []).append(name)
            ga, gb = gboxes.get(key, (a, b))
            gboxes[key] = (Gf.Vec3d(*map(min, ga, a)), Gf.Vec3d(*map(max, gb, b)))
            taken.add(prim)
    if len(groups) != 4:
        print(f"koła: nie rozpoznano czterech ({len(groups)} grup) — jeden przebieg zapiekania")
        return set()
    # Części okrągłe na osi koła (opona bez „wheel” w nazwie) — jak `adopt` w grze.
    for prim, name, m, s in meshes:
        if s or prim in taken:
            continue
        a, b = boxes[prim]
        e, c = b - a, (a + b) / 2
        for key, (ga, gb) in gboxes.items():
            ge, gc = gb - ga, (ga + gb) / 2
            r = max(ge[1], ge[2]) / 2
            d = c - gc
            if (r > 0.01 and abs(d[1]) < r * 0.12 and abs(d[2]) < r * 0.12 and abs(d[0]) < r
                    and abs(e[1] - e[2]) < max(e[1], e[2]) * 0.12 and r * 0.6 < e[1] < r * 3 and e[0] < r * 1.5):
                groups[key].append(name)
                break
    names = {n for g in groups.values() for n in g}
    print(f"koła: {len(names)} siatek w 4 grupach")
    return names


# --- 2. Import do Blendera i drugi zestaw UV ---

work = tempfile.mkdtemp(prefix="bake-ao-")
with zipfile.ZipFile(src) as z:
    z.extractall(work)
    root_name = next(n for n in z.namelist() if n.endswith((".usdc", ".usda", ".usd")))
root_path = os.path.join(work, root_name)
stage = Usd.Stage.Open(root_path)
wheels = wheel_names(stage)
usd_meshes = {p.GetName(): p for p in stage.Traverse() if p.IsA(UsdGeom.Mesh)}

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.usd_import(filepath=src, import_materials=False, validate_meshes=False)
objects = [o for o in bpy.data.objects if o.type == "MESH" and o.name in usd_meshes]
print(f"siatki: {len(objects)} z {len(usd_meshes)} w pliku")


def same_topology(o):
    """Narożniki Blendera w tej samej kolejności co faceVertexIndices w USD (inaczej st1 trafi nie tam)."""
    m = UsdGeom.Mesh(usd_meshes[o.name])
    counts = m.GetFaceVertexCountsAttr().Get() or []
    fvi = m.GetFaceVertexIndicesAttr().Get() or []
    pts = m.GetPointsAttr().Get() or []
    me = o.data
    if len(counts) != len(me.polygons) or len(fvi) != len(me.loops):
        return False
    if any(p.loop_total != c for p, c in zip(me.polygons, counts)):
        return False
    # Blender może skleić zdublowane wierzchołki — porównujemy położenia, nie indeksy (z tolerancją skali importu).
    scale = None
    for k in range(0, len(fvi), max(1, len(fvi) // 2000)):
        a = Gf.Vec3d(pts[fvi[k]])
        b = me.vertices[me.loops[k].vertex_index].co
        if scale is None and a.GetLength() > 1e-6:
            scale = b.length / a.GetLength()
        s = scale or 1.0
        if (Gf.Vec3d(b[0], b[1], b[2]) - a * s).GetLength() > 1e-4 * max(1.0, a.GetLength() * s):
            return False
    return True


mapped = [o for o in objects if same_topology(o)]
for o in objects:
    if o not in mapped:
        print(f"  {o.name}: inna topologia niż w USD — bez AO")
for o in bpy.data.objects:
    o.select_set(o in mapped)
if not mapped:
    sys.exit("żadna siatka nie pasuje do USD")


def weld(o):
    """Skleja wierzchołki o tym samym położeniu, nie ruszając kolejności ścian i narożników.

    Siatki z glTF mają osobne wierzchołki dla każdego trójkąta (szwy UV i twarde krawędzie) — Smart UV
    Project robił wtedy z każdego trójkąta osobną wyspę i atlas był niemal pusty. Oryginalne normalne
    narożników przechodzą jako normalne własne, żeby AO liczyło się od prawdziwej powierzchni.

    Przy okazji wierzchołki dostają skalę świata (obiekt — odwrotną): Smart UV Project liczy wyspy
    we współrzędnych lokalnych, a część siatek ma je w centymetrach — dostawały wyspy 100× większe,
    a koła mniejsze od piksela. Mnożnik dodatni, więc kolejność narożników się nie zmienia
    (`transform_apply` przy ujemnej skali odwraca ściany)."""
    me = o.data
    mw = o.matrix_world.copy()
    scale = abs(mw.to_3x3().determinant()) ** (1 / 3) or 1.0
    co = np.empty(len(me.vertices) * 3, dtype=np.float32)
    me.vertices.foreach_get("co", co)
    corner_vert = np.empty(len(me.loops), dtype=np.int32)
    me.loops.foreach_get("vertex_index", corner_vert)
    normals = np.empty(len(me.loops) * 3, dtype=np.float32)
    me.corner_normals.foreach_get("vector", normals)
    co = co.reshape(-1, 3)
    step = max(1e-9, float(np.abs(co).max()) * 1e-6)
    _, first, inverse = np.unique(np.round(co / step).astype(np.int64), axis=0, return_index=True, return_inverse=True)
    sizes = np.empty(len(me.polygons), dtype=np.int32)
    me.polygons.foreach_get("loop_total", sizes)
    welded = bpy.data.meshes.new(me.name)
    welded.vertices.add(len(first))
    welded.vertices.foreach_set("co", (co[first] * scale).ravel())
    welded.loops.add(len(corner_vert))
    welded.loops.foreach_set("vertex_index", inverse.ravel()[corner_vert])
    welded.polygons.add(len(sizes))
    welded.polygons.foreach_set("loop_start", np.concatenate(([0], np.cumsum(sizes)[:-1])).astype(np.int32))
    welded.update(calc_edges=True)
    welded.normals_split_custom_set(normals.reshape(-1, 3))
    o.data = welded
    o.matrix_world = mw @ Matrix.Scale(1 / scale, 4)


for o in mapped:
    weld(o)
view_layer = bpy.context.view_layer
view_layer.objects.active = mapped[0]
for o in mapped:
    o.data.uv_layers.active = o.data.uv_layers.new(name="AO")
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
# Wyspy bez marginesu, potem jedno pakowanie wszystkich siatek z marginesem jako ułamkiem atlasu
# (~3 px przy 2048): margines Smart UV Project liczy się per wyspa i przy tysiącach drobnych wysp
# (wnętrze, śrubki) zjadał większość atlasu.
bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.0, area_weight=0.0, correct_aspect=True)
bpy.ops.uv.select_all(action="SELECT")
bpy.ops.uv.pack_islands(rotate=True, margin_method="FRACTION", margin=0.0015, shape_method="CONCAVE")
bpy.ops.object.mode_set(mode="OBJECT")
covered = 0.0
for o in mapped:
    me = o.data
    uv = np.empty(len(me.loops) * 2, dtype=np.float32)
    me.uv_layers["AO"].data.foreach_get("uv", uv)
    uv *= ATLAS_FILL
    me.uv_layers["AO"].data.foreach_set("uv", uv)
    uv = uv.reshape(-1, 2)
    starts = np.empty(len(me.polygons), dtype=np.int32)
    sizes = np.empty(len(me.polygons), dtype=np.int32)
    me.polygons.foreach_get("loop_start", starts)
    me.polygons.foreach_get("loop_total", sizes)
    for k in range(1, int(sizes.max()) - 1):
        f = sizes > k + 1
        a, b, c = uv[starts[f]], uv[starts[f] + k], uv[starts[f] + k + 1]
        u, v = b - a, c - a
        covered += float(np.abs(u[:, 0] * v[:, 1] - u[:, 1] * v[:, 0]).sum()) / 2
print(f"atlas: wyspy zajmują {covered * 100:.0f}% powierzchni")

# --- 3. Zapiekanie AO w Cycles ---

scene = bpy.context.scene
scene.render.engine = "CYCLES"
# GPU (Metal) tylko na życzenie: Blender 5.2 w trybie bez okna pada przy zapisie skompilowanych jąder.
if args.gpu:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    scene.cycles.device = "GPU"
scene.cycles.samples = args.samples
lo = [min(v[i] for o in mapped for v in o.bound_box) for i in range(3)]
hi = [max(v[i] for o in mapped for v in o.bound_box) for i in range(3)]
length = max(h - l for h, l in zip(hi, lo))
scene.world = scene.world or bpy.data.worlds.new("world")
scene.world.light_settings.distance = length * args.distance

# Obraz 8-bitowy jako dane (bez krzywej sRGB): zapisujemy dokładnie zapieczone wartości.
img = bpy.data.images.new("AO", args.size, args.size, alpha=False, float_buffer=False)
img.colorspace_settings.is_data = True
mat = bpy.data.materials.new("bake")
node = mat.node_tree.nodes.new("ShaderNodeTexImage")
node.image = img
mat.node_tree.nodes.active = node
for o in objects:
    o.data.materials.clear()
    o.data.materials.append(mat)


def bake(targets, occluders, clear):
    for o in objects:
        o.hide_render = o not in occluders
    # Zaznaczone mają być tylko cele (import zostawia zaznaczone też puste węzły).
    for o in bpy.data.objects:
        o.select_set(o in targets)
    view_layer.objects.active = targets[0]
    bpy.ops.object.bake(type="AO", uv_layer="AO", margin=6, margin_type="EXTEND", use_clear=clear)


body = [o for o in mapped if o.name not in wheels]
wheel_objs = [o for o in mapped if o.name in wheels]
if body:
    bake(body, objects, True)
if wheel_objs:
    bake(wheel_objs, [o for o in objects if o.name in wheels], not body)



def report_dark(img):
    """Średnie AO każdej siatki — całkiem czarna część zwykle znaczy zdublowaną geometrię w pliku."""
    n = img.size[0]
    px = np.empty(n * n * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    lum = px.reshape(n, n, 4)[:, :, 0]
    out = []
    for o in mapped:
        uv = np.empty(len(o.data.loops) * 2, dtype=np.float32)
        o.data.uv_layers["AO"].data.foreach_get("uv", uv)
        ij = np.clip((uv.reshape(-1, 2) * n).astype(int), 0, n - 1)
        out.append((float(lum[ij[:, 1], ij[:, 0]].mean()), o.name, o.name in wheels))
    if os.environ.get("BAKE_AO_DEBUG"):
        print("AO-DEBUG", sorted(out))
    for mean, name, wheel in sorted(out)[:12]:
        print(f"  AO {mean:.2f} {name}" + (" (koło)" if wheel else ""))
    return out


report_dark(img)

# Siła i biały pas na brzegu.
n = args.size
px = np.empty(n * n * 4, dtype=np.float32)
img.pixels.foreach_get(px)
px = px.reshape(n, n, 4)
v = 1.0 - args.strength * (1.0 - px[:, :, 0])
edge = int(n * ATLAS_FILL) + 2
v[edge:, :] = 1.0
v[:, edge:] = 1.0
px[:, :, 0] = px[:, :, 1] = px[:, :, 2] = v
img.pixels.foreach_set(px.ravel())
img.filepath_raw = atlas
img.file_format = "PNG"
img.save()

# --- 4. st1 do USDZ ---

for o in mapped:
    uv = o.data.uv_layers["AO"].data
    pv = UsdGeom.PrimvarsAPI(usd_meshes[o.name]).CreatePrimvar(
        "st1", Sdf.ValueTypeNames.TexCoord2fArray, UsdGeom.Tokens.faceVarying)
    pv.Set([Gf.Vec2f(d.uv[0], d.uv[1]) for d in uv])
stage.GetRootLayer().Save()
tmp_out = os.path.join(work, "out.usdz")
if not UsdUtils.CreateNewUsdzPackage(Sdf.AssetPath(root_path), tmp_out):
    sys.exit("nie udało się spakować USDZ")
shutil.move(tmp_out, dst)
shutil.rmtree(work)
print(f"gotowe: {dst} ({len(mapped)} siatek z st1, koła osobno: {len(wheel_objs)}), atlas {atlas}")
