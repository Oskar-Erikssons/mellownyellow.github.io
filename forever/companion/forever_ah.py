#!/usr/bin/env python3
"""Exports the addon's auction house data to prices.json for the web page.

The addon collects prices from your own scans (Forever has no public auction API).
They are saved in ForeverGuide.lua when you log out. This script turns them into a
JSON file that you open on the web page's "Auktionshus" tab.

    python forever_ah.py --wow "C:/Program Files (x86)/World of Warcraft/_forever_" --out prices.json
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import lua_table


def collect(files: list[Path]) -> dict:
    out = {"generated": int(time.time()), "houses": {}, "sales": [], "soldByHour": {}}
    for f in files:
        db = lua_table.load(f).get("ForeverGuideDB") or {}
        a = db.get("auction") or {}
        for house, h in (a.get("houses") or {}).items():
            items = out["houses"].setdefault(house, {})
            for item_id, e in (h.get("items") or {}).items():
                old = items.get(str(item_id))
                if old and old.get("updated", 0) >= e.get("t", 0):
                    continue
                items[str(item_id)] = {
                    "id": int(item_id), "name": e.get("name"), "vendor": e.get("v"),
                    "market": e.get("m"), "min": e.get("min"), "historical": e.get("h"),
                    "quantity": e.get("q"), "listings": e.get("n"), "saleRate": e.get("sr"),
                    "observed": e.get("srN"), "updated": e.get("t"),
                }
        for s in (a.get("sales") or {}).values():
            out["sales"].append(s)
        for hour, n in (a.get("soldByHour") or {}).items():
            out["soldByHour"][str(hour)] = out["soldByHour"].get(str(hour), 0) + n
    for house in out["houses"]:
        out["houses"][house] = sorted(out["houses"][house].values(), key=lambda x: -(x.get("market") or 0))
    out["sales"].sort(key=lambda s: -s.get("t", 0))
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wow", type=Path, help="Game folder")
    ap.add_argument("--saved", type=Path, nargs="*", help="ForeverGuide.lua file(s)")
    ap.add_argument("--out", type=Path, default=Path("prices.json"))
    args = ap.parse_args(argv)
    files = args.saved or (sorted(args.wow.glob("WTF/Account/*/SavedVariables/ForeverGuide.lua")) if args.wow else [])
    if not files:
        ap.error("give --wow or --saved")
    data = collect(files)
    args.out.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    n = sum(len(v) for v in data["houses"].values())
    print(f"Wrote {n} item prices and {len(data['sales'])} sales to {args.out}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
