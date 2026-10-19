# Renderuje impostory roślinności w Blenderze (bez okna): zdjęcie z przodu i z boku z przezroczystym tłem.
# SceneKit źle czyta materiały USD z Poly Haven (białe liście), Blender czyta je poprawnie.
#
# Użycie:
#   Blender -b --factory-startup --python tools/render-impostors.py -- <folder ze scenery.json> [<folder wyjściowy>]
# Wynik: <wyjście>/impostors/*.png i <wyjście>/impostors.json (format jak tools/make-impostors.swift).
import json
import math
import os
import sys

import bpy
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1:]
folder = os.path.abspath(args[0])
out_root = os.path.abspath(args[1]) if len(args) > 1 else folder
out_dir = os.path.join(out_root, "impostors")
os.makedirs(out_dir, exist_ok=True)
entries = json.load(open(os.path.join(folder, "scenery.json")))
PIXELS = 512


def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    try:
        scene.render.engine = "BLENDER_EEVEE"
    except TypeError:
        scene.render.engine = "BLENDER_EEVEE_NEXT"
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("sky")
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.75, 0.82, 0.95, 1)
    bg.inputs[1].default_value = 0.9
    scene.world = world
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3.2
    sun.rotation_euler = (math.radians(50), 0, math.radians(-35))
    scene.collection.objects.link(sun)
    return scene


def descendants(obj):
    out = [obj]
    for c in obj.children:
        out += descendants(c)
    return out


def cluster(objs):
    boxes = [bounds(descendants(o)) for o in objs]
    parent = list(range(len(objs)))

    def root(i):
        while parent[i] != i:
            i = parent[i]
        return i

    for i in range(len(objs)):
        for j in range(i + 1, len(objs)):
            (alo, ahi), (blo, bhi) = boxes[i], boxes[j]
            if alo.x < bhi.x and blo.x < ahi.x and alo.y < bhi.y and blo.y < ahi.y:
                parent[root(i)] = root(j)
    groups = {}
    for i, o in enumerate(objs):
        groups.setdefault(root(i), []).extend(descendants(o))
    return list(groups.values())


def low_lod(o):
    """Obiekt należy do niższego poziomu szczegółów (…_LOD1, …_LOD2)."""
    while o is not None:
        if "_LOD" in o.name and not o.name.endswith("_LOD0"):
            return True
        o = o.parent
    return False


def bounds(objs):
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in objs:
        if o.type != "MESH":
            continue
        for corner in o.bound_box:
            w = o.matrix_world @ Vector(corner)
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
    return lo, hi


def render(scene, center, width, height, direction, path):
    cam_data = bpy.data.cameras.new("cam")
    cam_data.type = "ORTHO"
    cam_data.ortho_scale = max(width, height) * 1.02
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    cam.location = center + direction * 500
    cam_data.clip_end = 2000
    cam.rotation_euler = (-direction).to_track_quat("-Z", "Y").to_euler()
    scene.camera = cam
    aspect = width / height
    scene.render.resolution_x = max(8, int(PIXELS * min(1, aspect)))
    scene.render.resolution_y = max(8, int(PIXELS * min(1, 1 / aspect)))
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    bpy.data.objects.remove(cam)


result = []
for e in entries:
    scene = reset_scene()
    path = os.path.join(folder, e["file"])
    bpy.ops.wm.usd_import(filepath=path)
    imported = [o for o in scene.objects if o.type not in ("LIGHT", "CAMERA")]
    # Warianty Poly Haven: …_a_LOD0, …_b_LOD0; niższe poziomy szczegółów chowamy.
    variants = [o for o in imported if o.name.endswith("_LOD0")]
    if not variants:
        # Import spłaszcza hierarchię: warianty to osobne siatki stojące obok siebie. Łączymy siatki,
        # których obrysy w rzucie z góry nachodzą na siebie (pień i liście jednego drzewa), resztę rozdzielamy.
        groups = cluster([o for o in imported if o.parent is None and o.type == "MESH"])
    else:
        groups = [descendants(v) for v in variants]
    base = os.path.splitext(os.path.basename(e["file"]))[0].replace("_1k", "").replace("_", "-")
    for i, group in enumerate(groups):
        members = set(o for o in group if not low_lod(o))
        for o in imported:
            o.hide_render = o not in members
        lo, hi = bounds(members)
        size = hi - lo
        if size.z < 0.01:
            continue
        center = (lo + hi) / 2
        name = base if len(groups) == 1 else f"{base}-{i}"
        front = os.path.join(out_dir, f"{name}-front.png")
        side = os.path.join(out_dir, f"{name}-side.png")
        # Blender: Z w górę. Przód = patrzymy wzdłuż +Y (kamera od -Y), bok = od +X.
        render(scene, center, size.x, size.z, Vector((0, -1, 0)), front)
        render(scene, center, size.y, size.z, Vector((1, 0, 0)), side)
        result.append({
            "name": name, "kind": e["kind"], "regions": e["regions"], "height": e["height"],
            "max": e.get("max"), "size": [size.x, size.z, size.y],
            "front": f"impostors/{name}-front.png", "side": f"impostors/{name}-side.png",
        })
        print(f"IMPOSTOR {name}: {size.x:.1f} x {size.z:.1f} x {size.y:.1f}")

json.dump(result, open(os.path.join(out_root, "impostors.json"), "w"), indent=1, sort_keys=True)
print(f"IMPOSTOR zapisano {len(result)}")
