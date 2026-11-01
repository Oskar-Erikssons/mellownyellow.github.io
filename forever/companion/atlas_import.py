#!/usr/bin/env python3
"""Adds the zones and dungeons the game itself reports (/fg atlas export) to data/gamedata.json.

The game is the best source for new Forever content: it knows every zone's name,
continent and (where the client tells) level range. This script:
  * fills in map IDs and continents for zones the data already has,
  * corrects level ranges that differ from the game's, and marks them verified,
  * adds zones and dungeons the data does not have yet.

Shows the proposal by default. --apply writes it, runs the tests and rolls back if
any test fails, the same way patch_watch.py does.

    python atlas_import.py --file atlas.txt
    python atlas_import.py --file atlas.txt --apply
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import sys
from pathlib import Path

import patch_watch

TYPE_CONTINENT, TYPE_ZONE, TYPE_DUNGEON = 2, 3, 4
CONTINENT_CODES = {1414: "KAL", 1415: "EK"}
SOURCE = "Spelklienten (/fg atlas export)"


def parse(text: str) -> dict:
    text = text.strip()
    if not text.startswith("FGZ1"):
        raise ValueError("The text should start with FGZ1. Make it with /fg atlas export in the game.")
    out = {"build": "", "maps": {}}
    for part in text.split("&")[1:]:
        key, _, value = part.partition("=")
        if key == "build":
            out["build"] = value
        elif key == "m":
            for row in filter(None, value.split(";")):
                mid, mtype, parent, lo, hi, *name = row.split(":")
                out["maps"][int(mid)] = {"type": int(mtype), "parent": int(parent), "min": int(lo) or None,
                                         "max": int(hi) or None, "name": ":".join(name)}
    return out


def norm(name: str) -> str:
    name = (name or "").lower().strip()
    return name[4:] if name.startswith("the ") else name


def continent_of(maps: dict, m: dict) -> str | None:
    parent = m["parent"]
    seen = set()
    # Walk up until a continent: a dungeon's parent can be a zone.
    while parent and parent not in seen:
        seen.add(parent)
        if parent in CONTINENT_CODES:
            return CONTINENT_CODES[parent]
        p = maps.get(parent)
        if not p:
            return None
        if p["type"] == TYPE_CONTINENT:
            return p["name"]
        parent = p["parent"]
    return None


def propose(atlas: dict, data: dict) -> tuple[dict, list[str], list[str]]:
    """Returns the new data, a list of changes in words, and maps skipped (no levels)."""
    new = copy.deepcopy(data)
    maps = atlas["maps"]
    lists = {TYPE_ZONE: new["zones"], TYPE_DUNGEON: new["dungeons"]}
    by_name = {}
    for kind, items in lists.items():
        for item in items:
            by_name[norm(item["name"])] = item
    for item in new.get("raids", []):
        by_name.setdefault(norm(item["name"]), item)
    ignore = {norm(n) for n in new.get("otherMaps", [])}
    changes, skipped = [], []
    for mid, m in sorted(maps.items()):
        if m["type"] not in lists or norm(m["name"]) in ignore:
            continue
        cont = continent_of(maps, m)
        item = by_name.get(norm(m["name"]))
        if item is not None:
            what = []
            if item.get("uiMap") != mid:
                item["uiMap"] = mid
                what.append(f"karta {mid}")
            if cont and not item.get("continent"):
                item["continent"] = cont
                what.append(f"kontinent {cont}")
            if m["min"] and "min" in item and (item.get("min"), item.get("max")) != (m["min"], m["max"]):
                what.append(f"nivå {item.get('min')}–{item.get('max')} → {m['min']}–{m['max']}")
                item["min"], item["max"] = m["min"], m["max"]
            if m["min"] and item.get("verified") is False:
                item["verified"] = True
                item["source"] = SOURCE
                what.append("bekräftad av spelet")
            if what:
                changes.append(f"{m['name']}: " + ", ".join(what))
        elif m["min"]:
            entry = {"name": m["name"], "min": m["min"], "max": m["max"], "faction": "Both", "continent": cont,
                     "uiMap": mid, "new": True, "verified": True, "source": SOURCE}
            lists[m["type"]].append(entry)
            by_name[norm(m["name"])] = entry
            kind = "zon" if m["type"] == TYPE_ZONE else "dungeon"
            changes.append(f"Ny {kind}: {m['name']} {m['min']}–{m['max']} ({cont or 'okänd kontinent'}, karta {mid})")
        else:
            skipped.append(f"{m['name']} (karta {mid})")
    return new, changes, skipped


def apply(new: dict, changes: list[str], build: str) -> bool:
    data_path, log_path = patch_watch.DATA, patch_watch.CHANGELOG
    backup_data, backup_log = data_path.read_text(encoding="utf-8"), log_path.read_text(encoding="utf-8")
    new["updated"] = dt.date.today().isoformat()
    data_path.write_text(json.dumps(new, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    log = json.loads(backup_log)
    log.insert(0, {"date": new["updated"], "source": f"{SOURCE}, build {build}".strip(", "),
                   "summary": f"{len(changes)} zoner och dungeons uppdaterade från spelet.",
                   "changes": [{"op": "game", "path": c, "old": None, "value": None, "quote": c} for c in changes]})
    log_path.write_text(json.dumps(log, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    patch_watch.rebuild()
    ok, output = patch_watch.run_tests()
    if not ok:
        data_path.write_text(backup_data, encoding="utf-8")
        log_path.write_text(backup_log, encoding="utf-8")
        patch_watch.rebuild()
        print("Tests failed, so nothing was changed:\n" + output)
        return False
    print(f"Applied {len(changes)} change(s). Tests pass.")
    return True


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", type=Path, required=True, help="Text file with the /fg atlas export")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args(argv)
    atlas = parse(args.file.read_text(encoding="utf-8"))
    data = json.loads(patch_watch.DATA.read_text(encoding="utf-8"))
    new, changes, skipped = propose(atlas, data)
    print(f"The game lists {len(atlas['maps'])} maps (build {atlas['build'] or '?'}).")
    for c in changes:
        print("  " + c)
    if skipped:
        print(f"{len(skipped)} maps without level ranges were left out: " + ", ".join(skipped[:15]))
    if not changes:
        print("The data already matches the game.")
    elif args.apply:
        apply(new, changes, atlas["build"])
    else:
        print("Dry run. Add --apply to write these changes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
