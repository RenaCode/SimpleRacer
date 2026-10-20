#!/usr/bin/env python3
"""Usuwa szkielet animacji (UsdSkel) z modelu USDZ — dla aut pobranych ze Sketchfaba.

Eksport Sketchfaba często wiąże siatki ze szkieletem (kości kół). RealityKit skleja wtedy wszystkie
powiązane siatki w jedną encję `skin0`: nie da się wybrać części lakieru (`paint`) ani kół (`wheels`)
po nazwach z `cars.json`, a koła się nie kręcą. Gra nie używa animacji modelu, więc szkielet
usuwamy: siatki zostają w pozie spoczynkowej jako osobne prim.

Użycie: unskin-usdz.py <wejście.usdz> <wyjście.usdz>
Wymaga /usr/bin/usdcat i /usr/bin/usdzip (macOS).
"""
import pathlib
import re
import subprocess
import sys
import tempfile
import zipfile

# Atrybuty i relacje powiązania ze szkieletem (z ewentualnym blokiem metadanych w nawiasach).
SKEL_PROP = re.compile(r"^\s*(uniform\s+)?(rel|[\w\[\]]+(\s+[\w\[\]]+)?)\s+(primvars:)?skel:\w+")


def unskin(text: str) -> tuple[str, int]:
    out, removed, skip_depth = [], 0, 0
    for line in text.split("\n"):
        if skip_depth:
            skip_depth += line.count("(") - line.count(")")
            continue
        if SKEL_PROP.match(line):
            removed += 1
            depth = line.count("(") - line.count(")")
            if depth > 0:
                skip_depth = depth
            continue
        if "SkelBindingAPI" in line:
            line = re.sub(r'"SkelBindingAPI",?\s*', "", line)
            if re.search(r"apiSchemas = \[\s*\]", line):
                continue
        line = line.replace('def SkelRoot "', 'def Xform "')
        out.append(line)
    return "\n".join(out), removed


def main(src: pathlib.Path, dst: pathlib.Path) -> int:
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        with zipfile.ZipFile(src) as z:
            z.extractall(work)
            names = z.namelist()
        layer = next(n for n in names if n.endswith((".usdc", ".usda", ".usd")))
        usda = work / "unskin.usda"
        subprocess.run(["usdcat", str(work / layer), "-o", str(usda)], check=True)
        text, removed = unskin(usda.read_text())
        if removed == 0:
            print(f"{src.name}: brak szkieletu — bez zmian")
            return 0
        usda.write_text(text)
        out_layer = work / "scene.usdc"
        (work / layer).unlink()
        subprocess.run(["usdcat", str(usda), "-o", str(out_layer)], check=True)
        usda.unlink()
        assets = [n for n in names if n != layer and not n.endswith("/")]
        dst.unlink(missing_ok=True)
        subprocess.run(["usdzip", str(dst.resolve()), "scene.usdc", *assets], cwd=work, check=True)
        print(f"{src.name}: usunięto {removed} powiązań ze szkieletem → {dst}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])))
