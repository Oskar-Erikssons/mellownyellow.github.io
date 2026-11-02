#!/usr/bin/env python3
"""Builds the release zip: ForeverGuide and ForeverGuide_Voices, ready for Interface/AddOns.

Checks before packing that every file the TOC lists exists, that the TOC version matches
FG.VERSION in Core.lua, and that the generated files are current.

    python tools/package.py            # writes dist/ForeverGuide-<version>.zip
"""

from __future__ import annotations

import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDONS = ROOT / "addon"


def version() -> str:
    toc = (ADDONS / "ForeverGuide" / "ForeverGuide.toc").read_text(encoding="utf-8")
    core = (ADDONS / "ForeverGuide" / "Core.lua").read_text(encoding="utf-8")
    v_toc = re.search(r"## Version: (\S+)", toc).group(1)
    v_core = re.search(r'FG.VERSION = "([^"]+)"', core).group(1)
    if v_toc != v_core:
        raise SystemExit(f"Version mismatch: TOC {v_toc}, Core.lua {v_core}")
    return v_toc


def check_toc(folder: Path) -> list[str]:
    toc = next(folder.glob("*.toc"))
    files = [l.strip() for l in toc.read_text(encoding="utf-8").splitlines() if l.strip() and not l.startswith("#")]
    missing = [f for f in files if not (folder / f).exists()]
    if missing:
        raise SystemExit(f"{toc.name} lists missing files: {', '.join(missing)}")
    return files


def main() -> int:
    v = version()
    for folder in ("ForeverGuide", "ForeverGuide_Voices"):
        check_toc(ADDONS / folder)
    sys.path.insert(0, str(ROOT / "tools"))
    sys.path.insert(0, str(ROOT / "companion"))
    import api_check
    import build_data
    if build_data.main(["--check"]) != 0:
        raise SystemExit("Run companion/build_data.py first.")
    current = (ADDONS / "ForeverGuide" / "ApiList.lua").read_text(encoding="utf-8")
    tmp = ROOT / ".cache" / "ApiList.check.lua"
    tmp.parent.mkdir(exist_ok=True)
    if api_check.write_api_list(tmp) != current:
        raise SystemExit("ApiList.lua is out of date. Run python tools/api_check.py --write-list.")
    out = ROOT / "dist" / f"ForeverGuide-{v}.zip"
    out.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for folder in ("ForeverGuide", "ForeverGuide_Voices"):
            for f in sorted((ADDONS / folder).rglob("*")):
                if f.is_file() and f.name != ".gitkeep" and f.suffix != ".json":
                    z.write(f, f.relative_to(ADDONS))
    print(f"Wrote {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
