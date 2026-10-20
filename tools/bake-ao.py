# Zapieka ambient occlusion realistycznego auta w Blenderze (bez okna): cienie w nadkolach, progach,
# szczelinach i między szprychami felg — tego nie da oświetlenie z panoramy ani mapa cieni słońca.
#
# Tekstury modeli ze Sketchfaba mają UV nakładające się i powtarzane (jedna felga na cztery koła,
# kafelki), więc AO nie da się zapisać w ich UV. Dlatego:
# 1. każda siatka dostaje drugi zestaw UV („AO”, Smart UV Project) — wspólny atlas całego auta; ściany,
#    których UV nachodzą na inne, dostają osobne wyspy,
# 2. Cycles zapieka AO do atlasu: nadwozie razem z kołami (opona zasłania nadkole), a koła osobno,
#    bez nadwozia — koła się obracają, cień nadkola kręciłby się razem z nimi; siatka nie zasłania się
#    leżącymi na niej nakładkami (naklejki, znaczki, druga warstwa lakieru); obie strony ścian, jaśniejsza
#    wygrywa (fragmenty modeli są na lewą stronę),
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

import bmesh
import bpy
import numpy as np
from mathutils import Matrix
from mathutils.bvhtree import BVHTree
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


def reverse_faces(me, faces):
    """Odwraca kolejność narożników wskazanych ścian (z danymi narożników, np. UV); dwa razy = bez zmian."""
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.faces.ensure_lookup_table()
    bmesh.ops.reverse_faces(bm, faces=[bm.faces[int(i)] for i in faces])
    bm.to_mesh(me)
    bm.free()


def weld(o):
    """Skleja wierzchołki o tym samym położeniu, nie ruszając kolejności ścian i narożników.

    Siatki z glTF mają osobne wierzchołki dla każdego trójkąta (szwy UV i twarde krawędzie) — Smart UV
    Project robił wtedy z każdego trójkąta osobną wyspę i atlas był niemal pusty.

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
    co = co.reshape(-1, 3)
    step = max(1e-9, float(np.abs(co).max()) * 1e-6)
    _, first, inverse = np.unique(np.round(co / step).astype(np.int64), axis=0, return_index=True, return_inverse=True)
    sizes = np.empty(len(me.polygons), dtype=np.int32)
    me.polygons.foreach_get("loop_total", sizes)
    starts = np.concatenate(([0], np.cumsum(sizes)[:-1])).astype(np.int32)
    points = co[first]
    corners = inverse.ravel()[corner_vert]
    # Ściana, której narożniki skleiły się w jeden wierzchołek (zdegenerowany trójkąt z pliku), zostaje
    # na własnych wierzchołkach — Blender padał na takiej siatce (concept-car-037).
    extra = []
    for f in np.nonzero(sizes > 0)[0]:
        ring = corners[starts[f]:starts[f] + sizes[f]]
        if len(set(ring.tolist())) < len(ring):
            for k in range(starts[f], starts[f] + sizes[f]):
                extra.append(co[corner_vert[k]])
                corners[k] = len(points) + len(extra) - 1
    if extra:
        points = np.concatenate([points, np.array(extra, dtype=np.float32)])
    welded = bpy.data.meshes.new(me.name)
    welded.vertices.add(len(points))
    welded.vertices.foreach_set("co", (points * scale).ravel())
    welded.loops.add(len(corners))
    welded.loops.foreach_set("vertex_index", corners)
    welded.polygons.add(len(sizes))
    welded.polygons.foreach_set("loop_start", starts)
    welded.update(calc_edges=True)
    # Gładkie cieniowanie z ostrymi krawędziami wg kąta — bez normalnych własnych z pliku: przy
    # zapiekaniu obu stron ścian (niżej) kłóciłyby się z odwróconym nawinięciem i koło wychodziło czarne.
    welded.shade_smooth()
    welded.set_sharp_from_angle(angle=math.radians(40))
    o.data = welded
    o.matrix_world = mw @ Matrix.Scale(1 / scale, 4)


for o in mapped:
    weld(o)
view_layer = bpy.context.view_layer
view_layer.objects.active = mapped[0]
# Cała geometria auta w układzie świata — do rozpoznania ścian ukrytych pod innymi (`select_overlapping`).
reach = max(max(v[i] for o in mapped for v in o.bound_box) - min(v[i] for o in mapped for v in o.bound_box)
            for i in range(3)) * 0.05
_verts, _faces = [], []
for o in objects:
    base = len(_verts)
    _verts += [o.matrix_world @ v.co for v in o.data.vertices]
    _faces += [tuple(base + i for i in p.vertices) for p in o.data.polygons]
world_bvh = BVHTree.FromPolygons(_verts, _faces)
del _verts, _faces
for o in mapped:
    o.data.uv_layers.active = o.data.uv_layers.new(name="AO")
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
# Wyspy bez marginesu, potem jedno pakowanie wszystkich siatek z marginesem jako ułamkiem atlasu
# (~3 px przy 2048): margines Smart UV Project liczy się per wyspa i przy tysiącach drobnych wysp
# (wnętrze, śrubki) zjadał większość atlasu.
bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.0, area_weight=0.0, correct_aspect=True)


def pack_all():
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.select_all(action="SELECT")
    # Jedna gęstość tekseli dla wszystkich wysp — wyspy z naprawy nakładek (`uv.unwrap`) mają własną skalę
    # i wychodziły mniejsze od piksela: czarne listwy szyb i progów.
    bpy.ops.uv.average_islands_scale()
    bpy.ops.uv.pack_islands(rotate=True, margin_method="FRACTION", margin=0.0015, shape_method="CONCAVE")


def select_overlapping():
    """Zaznacza (w siatce) ściany, których UV nachodzą na inne; zwraca ich liczbę.

    Smart UV Project nie sprawdza nakładania w obrębie wyspy: krawędź drzwi zawinięta do środka i na
    lewą stronę (Plymouth) rzutowała się na poszycie błotnika i ciemna warstwa wewnętrzna zapisywała
    się w jego tekselach — ciemny pas przed drzwiami."""
    bpy.ops.uv.select_all(action="DESELECT")
    bpy.ops.uv.select_overlap(extend=False)
    count = hidden = 0
    for o in mapped:
        bm = bmesh.from_edit_mesh(o.data)
        mw = o.matrix_world
        nm = mw.to_3x3().inverted().transposed()
        for f in bm.faces:
            f.select = all(l.uv_select_vert for l in f.loops)
            if f.select:
                count += 1
                # Z pary zostawiamy w miejscu ścianę widoczną: ukryta ma geometrię blisko po obu stronach.
                c, n = mw @ f.calc_center_median(), (nm @ f.normal).normalized()
                f.select = all(world_bvh.ray_cast(c + d * n * reach * 1e-3, d * n, reach)[0] is not None
                               for d in (1, -1))
                hidden += f.select
        bmesh.update_edit_mesh(o.data)
    return count, hidden


pack_all()
for attempt in range(4):
    overlapping, hidden = select_overlapping()
    print(f"UV nachodzące na siebie: {overlapping} ścian, z tego ukrytych: {hidden}")
    if not overlapping:
        break
    if not hidden:
        # Zostały same widoczne (np. cienka blacha z jedną stroną na lewą stronę) — też osobno.
        bpy.ops.uv.select_all(action="DESELECT")
        bpy.ops.uv.select_overlap(extend=False)
        for o in mapped:
            bm = bmesh.from_edit_mesh(o.data)
            for f in bm.faces:
                f.select = all(l.uv_select_vert for l in f.loops)
            bmesh.update_edit_mesh(o.data)
    # Ściany ukryte: każda osobną wyspą (obszar z obiema warstwami fałdy dalej nachodziłby sam na siebie,
    # a brzegów ukrytych ścian nie widać). Widoczne: spójne obszary — szew tylko na granicy zaznaczenia,
    # bo pojedyncze trójkąty zostawiały ciemne kreski na brzegach. Potem cały atlas pakowany od nowa.
    for o in mapped:
        bm = bmesh.from_edit_mesh(o.data)
        for e in bm.edges:
            n = sum(f.select for f in e.link_faces)
            if n == 1 or (n and hidden):
                e.seam = True
        bmesh.update_edit_mesh(o.data)
    bpy.ops.uv.unwrap(method="CONFORMAL", margin=0.0)
    pack_all()
else:
    # Resztki to w większości trójkąty mniejsze od piksela — liczy się ich pole w atlasie, nie liczba.
    bpy.ops.uv.select_all(action="DESELECT")
    bpy.ops.uv.select_overlap(extend=False)
    bad = good = 0.0
    for o in mapped:
        bm = bmesh.from_edit_mesh(o.data)
        lay = bm.loops.layers.uv["AO"]
        for f in bm.faces:
            u = [l[lay].uv for l in f.loops]
            a = sum(abs((u[k] - u[0]).cross(u[k + 1] - u[0])) for k in range(1, len(u) - 1)) / 2
            if all(l.uv_select_vert for l in f.loops):
                bad += a
            else:
                good += a
    share = bad / max(bad + good, 1e-12)
    # Rozproszone pojedyncze trójkąty (lakier SLS ~1% pola) dają co najwyżej drobne kreseczki, a duże
    # ściany ukryte w oponie (obręcz felgi Concept 001, 2,1%) nic; obejrzane na modelach. Ponad 3% przerywamy.
    if share > 0.03:
        sys.exit(f"UV wciąż nachodzą na siebie ({overlapping} ścian, {share:.2%} pola atlasu) — AO zapisałoby się w cudzych tekselach")
    print(f"UWAGA: {overlapping} ścian wciąż nachodzi, {share:.2%} pola atlasu (próg przerwania 3%)")
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
    # Margines wypiekania mniejszy niż pół odstępu między wyspami (~3 px przy 2048) — większy nadpisywał
    # sąsiednie wyspy i na krawędziach zostawały ciemne kreski.
    bpy.ops.object.bake(type="AO", uv_layer="AO", margin=1, margin_type="EXTEND", use_clear=clear)


def overlapping_layers():
    """Pary siatek leżących jedna na drugiej (naklejki, znaczki, nakładki lamp, druga warstwa lakieru).

    Modele z gier mają takie warstwy co krok — przy zapiekaniu nakładka zasłania całkowicie powierzchnię
    pod sobą i ta wychodzi czarna (cały lakier Citroëna, bagażnik Audi). Siatka pomija więc swoje
    nakładki jako przesłonę. Para: ≥30% próbek środków ścian jednej leży w odległości ≤0,1% długości auta
    od drugiej; relacja symetryczna."""
    eps = length * 0.001
    trees, samples, boxes = {}, {}, {}
    rng = np.random.default_rng(1)
    for o in objects:
        me, mw = o.data, o.matrix_world
        if not me.polygons:
            continue
        verts = [mw @ v.co for v in me.vertices]
        trees[o] = BVHTree.FromPolygons(verts, [tuple(p.vertices) for p in me.polygons])
        pick = rng.choice(len(me.polygons), size=min(300, len(me.polygons)), replace=False)
        samples[o] = [mw @ me.polygons[int(i)].center for i in pick]
        boxes[o] = (np.min(verts, axis=0) - eps, np.max(verts, axis=0) + eps)
    excl = {o: set() for o in objects}
    for a in samples:
        for b in trees:
            if a is b or np.any(boxes[a][1] < boxes[b][0]) or np.any(boxes[b][1] < boxes[a][0]):
                continue
            near = sum(1 for p in samples[a] if trees[b].find_nearest(p, eps)[0] is not None)
            if near >= 0.3 * len(samples[a]):
                excl[a].add(b)
                excl[b].add(a)
    pairs = sum(len(v) for v in excl.values()) // 2
    print(f"nakładki: {pairs} par nakładających się siatek")
    return excl


def bake_groups(targets, occluders, clear):
    """Jeden przebieg na każdy zbiór wykluczonych nakładek (większość siatek nie ma żadnej)."""
    groups = {}
    for o in targets:
        groups.setdefault(frozenset(excl[o] & set(occluders)), []).append(o)
    for skip, group in sorted(groups.items(), key=lambda kv: len(kv[0])):
        bake(group, [o for o in occluders if o not in skip], clear)
        clear = False
    return len(groups)


excl = overlapping_layers()
body = [o for o in mapped if o.name not in wheels]
wheel_objs = [o for o in mapped if o.name in wheels]


def bake_all():
    passes = 0
    if body:
        passes += bake_groups(body, objects, True)
    if wheel_objs:
        passes += bake_groups(wheel_objs, [o for o in objects if o.name in wheels], not body)
    n = img.size[0]
    px = np.empty(n * n * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    return passes, px


# Obie strony ścian, jaśniejsza wygrywa. Cycles liczy AO od strony nawinięcia, a modele mają fragmenty
# na lewą stronę (lewe koła odbite lustrzanie, pas na błotniku Plymoutha — tam nawet normalne z pliku
# patrzą do środka, więc nie da się ich wykryć porównaniem). Gra rysuje je dwustronnie. Strona do wnętrza
# auta jest zawsze ciemniejsza, więc dla poprawnych ścian nic się nie zmienia.
passes, front = bake_all()
for o in mapped:
    reverse_faces(o.data, range(len(o.data.polygons)))
more, back = bake_all()
img.pixels.foreach_set(np.maximum(front, back))
for o in mapped:
    reverse_faces(o.data, range(len(o.data.polygons)))
    if not same_topology(o):
        sys.exit(f"{o.name}: po odwróceniu narożniki nie wróciły do kolejności z pliku")
print(f"zapiekanie: {passes + more} przebiegów (obie strony ścian)")

def report_dark(img):
    """Średnie AO każdej siatki — całkiem czarna część z zewnątrz auta to zwykle nakładka, której
    `overlapping_layers` nie wykryło."""
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
