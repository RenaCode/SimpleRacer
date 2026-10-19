#!/usr/bin/env python3
"""Bramka licencji dla wydania (Release): przerywa build, gdy do paczki trafiłby model bez licencji
pozwalającej na płatną grę. Sprawdza LocalModels/Commercial: każdy model aut w cars.json musi mieć
"commercial": true, a żadna licencja (auta, scenografia) nie może być niekomercyjna (NC), redakcyjna
(editorial) ani bez dzieł zależnych (ND). Każdy plik .usdz w katalogu musi mieć wpis z licencją.

Użycie: check-licenses.py <katalog LocalModels/Commercial>
"""
import json
import pathlib
import re
import sys

BAD = re.compile(r"\b(NC|ND|non[- ]?commercial|editorial)\b", re.IGNORECASE)


def main(root: pathlib.Path) -> int:
    errors = []
    listed = set()
    for name in ("cars.json", "scenery.json"):
        path = root / name
        if not path.exists():
            continue
        for entry in json.loads(path.read_text()):
            file = entry.get("file", "?")
            listed.add(pathlib.Path(file).name)
            license = entry.get("license", "")
            if not license:
                errors.append(f"{name}: {file} — brak licencji")
            elif BAD.search(license):
                errors.append(f"{name}: {file} — licencja niedozwolona w płatnej grze: {license}")
            if name == "cars.json" and entry.get("commercial") is not True:
                errors.append(f"{name}: {file} — brak \"commercial\": true")
    for usdz in root.glob("*.usdz"):
        if usdz.name not in listed:
            errors.append(f"{usdz.name} — model bez wpisu i licencji w cars.json")
    for usdz in (root / "scenery").glob("*.usdz") if (root / "scenery").exists() else []:
        if usdz.name not in listed:
            errors.append(f"scenery/{usdz.name} — model bez wpisu i licencji w scenery.json")
    for e in errors:
        print(f"error: licencje: {e}")
    if not errors:
        print(f"licencje: OK ({len(listed)} modeli)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(pathlib.Path(sys.argv[1])))
