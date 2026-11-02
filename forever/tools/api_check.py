#!/usr/bin/env python3
"""Checks every game API the addon uses against WoW: Forever's own client code.

Reads Blizzard's generated API documentation and UI source from the "forever" branch of
github.com/Gethe/wow-ui-source (a mirror of the game client's interface files) and reports:
  * C_ functions that do not exist, or are called with more arguments than they take
  * events that do not exist
  * Enum values that do not exist
  * frame templates that do not exist
  * global functions and constants that the client neither documents nor defines

    python tools/api_check.py                      # fetches the source on first run
    python tools/api_check.py --source /path/to/wow-ui-source

Exit code 1 when something is wrong, so it can run in CI.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addon" / "ForeverGuide"
CACHE = ROOT / ".cache" / "wow-ui-source-forever"
REPO = "https://github.com/Gethe/wow-ui-source"

# Functions Blizzard does not document, used only behind an existence check. /fg selftest
# confirms them in the game.
OPTIONAL = {"PlaySoundFile": "AI voice clips", "StopSound": "stopping clips",
            "GetSpellBaseCooldown": "spell cooldowns (tooltip used when missing)"}

# Lua and WoW library names that are not game API.
LUA_BUILTINS = set("""assert error ipairs next pairs pcall print rawequal rawget rawset select setmetatable
getmetatable tonumber tostring type unpack xpcall string table math bit coroutine date time wipe tinsert
tremove strsplit strtrim strjoin strmatch format floor ceil abs min max issecretvalue hooksecurefunc
debugstack geterrorhandler securecall loadstring""".split())


def fetch(dest: Path) -> Path:
    if (dest / "Interface").exists():
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "clone", "-q", "--depth", "1", "--branch", "forever", "--filter=blob:none",
                    "--no-checkout", REPO, str(dest)], check=True)
    subprocess.run(["git", "-C", str(dest), "sparse-checkout", "set", "--no-cone", "*.lua", "*.xml", "*.toc"], check=True)
    subprocess.run(["git", "-C", str(dest), "checkout", "-q", "forever"], check=True)
    return dest


def load_docs(source: Path) -> dict:
    """Runs the generated documentation files in a sandbox and collects their tables."""
    from lupa import lua51
    lua = lua51.LuaRuntime(register_eval=False)
    # Sandbox: no files, no OS, nothing to load more code with.
    lua.execute("io, os, require, dofile, loadfile, package, debug = nil, nil, nil, nil, nil, nil, nil")
    lua.execute("DOCS = {}; APIDocumentation = { AddDocumentationTable = function(_, t) table.insert(DOCS, t) end }")
    run = lua.eval("function(src, name) local f = assert(loadstring(src, name)); setfenv(f, _G); f() end")
    folder = source / "Interface" / "AddOns" / "Blizzard_APIDocumentationGenerated"
    for f in sorted(folder.glob("*.lua")):
        try:
            run(f.read_text(encoding="utf-8", errors="replace"), f.name)
        except Exception:
            pass
    funcs, events, enums = {}, set(), {}
    docs = lua.eval("DOCS")
    for i in range(1, len(docs) + 1):
        t = docs[i]
        ns = t["Namespace"]
        for fn in (t["Functions"] or {}).values():
            args = fn["Arguments"]
            n = len(args) if args else 0
            name = f"{ns}.{fn['Name']}" if ns else fn["Name"]
            funcs[name] = n
        for ev in (t["Events"] or {}).values():
            if ev["LiteralName"]:
                events.add(ev["LiteralName"])
        for tb in (t["Tables"] or {}).values():
            if tb["Type"] == "Enumeration" and tb["Fields"]:
                enums[tb["Name"]] = {f["Name"] for f in tb["Fields"].values()}
    return {"funcs": funcs, "events": events, "enums": enums}


def client_index(source: Path) -> dict:
    """Every name the client's own UI code uses or defines, and every template it declares."""
    names, defined, templates = set(), set(), set()
    for f in (source / "Interface").rglob("*"):
        if f.suffix not in (".lua", ".xml") or "APIDocumentation" in str(f):
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        names.update(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", text))
        if f.suffix == ".lua":
            defined.update(re.findall(r"(?:function\s+|^\s*)((?:C_\w+)\.\w+)\s*(?:=|\()", text, flags=re.M))
        else:
            for tag in re.findall(r"<\w+\s[^>]*virtual=\"true\"[^>]*>", text):
                m = re.search(r'name="(\w+)"', tag)
                if m:
                    templates.add(m.group(1))
    return {"names": names, "defined": defined, "templates": templates}


def strip_comments(code: str) -> str:
    code = re.sub(r"--\[\[.*?\]\]", "", code, flags=re.S)
    return re.sub(r"--[^\n]*", "", code)


def strip_strings(code: str) -> str:
    code = re.sub(r"\[\[.*?\]\]", '""', code, flags=re.S)
    return re.sub(r'"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'', '""', code)


def addon_usage(files: list[Path]) -> dict:
    use = {"c": {}, "events": {}, "enums": {}, "templates": {}, "globals": {}}
    defined = set()
    for f in files:
        raw = f.read_text(encoding="utf-8")
        code = strip_comments(raw)
        bare = strip_strings(code)
        for m in re.finditer(r"\b(C_\w+)\.(\w+)\s*(\()?", code):
            name = f"{m.group(1)}.{m.group(2)}"
            argc = None
            if m.group(3):
                depth, i, args, cur = 1, m.end(), 0, ""
                while i < len(code) and depth:
                    ch = code[i]
                    if ch in "({[":
                        depth += 1
                    elif ch in ")}]":
                        depth -= 1
                    elif ch == "," and depth == 1:
                        args += 1
                    if depth:
                        cur += ch
                    i += 1
                argc = 0 if not cur.strip() else args + 1
            use["c"].setdefault(name, []).append((f.name, argc))
        for m in re.finditer(r'FG:On\("([A-Z_]+)"', raw):
            use["events"].setdefault(m.group(1), []).append(f.name)
        for m in re.finditer(r"\bEnum\.(\w+)\.(\w+)", code):
            use["enums"].setdefault((m.group(1), m.group(2)), []).append(f.name)
        for m in re.finditer(r'CreateFrame\(\s*"\w+"\s*,[^,]*,[^,]*,\s*"(\w+)"', raw):
            use["templates"].setdefault(m.group(1), []).append(f.name)
        for m in re.finditer(r'pcall\(CreateFrame,\s*"\w+",\s*\w+,\s*\w+,\s*"(\w+)"', raw):
            use["templates"].setdefault(m.group(1), []).append(f.name)
        for m in re.finditer(r"(?:local\s+function|function)\s+([\w.:]+)", code):
            defined.add(m.group(1).split(".")[0].split(":")[0])
        for m in re.finditer(r"\blocal\s+([\w,\s]+?)\s*=", code):
            for n in m.group(1).split(","):
                defined.add(n.strip())
        if f.name != "GameData.lua":  # generated data, no API calls
            for m in re.finditer(r"(?<![.:\w])([A-Z][A-Za-z0-9_]+)\b", bare):
                use["globals"].setdefault(m.group(1), set()).add(f.name)
    use["defined"] = defined
    return use


def check(source: Path) -> list[str]:
    docs = load_docs(source)
    client = client_index(source)
    files = sorted(f for f in ADDON.glob("*.lua") if f.name != "ApiList.lua")
    use = addon_usage(files)
    problems = []

    for name, calls in sorted(use["c"].items()):
        if name not in docs["funcs"]:
            # Some C_ tables are partly defined in Lua by the client itself.
            if name not in client["defined"]:
                problems.append(f"missing function {name} (used in {', '.join(sorted({c[0] for c in calls}))})")
            continue
        most = docs["funcs"][name]
        for fname, argc in calls:
            if argc is not None and argc > most:
                problems.append(f"{name} takes {most} arguments, called with {argc} in {fname}")
    for ev, where in sorted(use["events"].items()):
        if ev not in docs["events"]:
            problems.append(f"unknown event {ev} (in {', '.join(sorted(set(where)))})")
    for (enum, field), where in sorted(use["enums"].items()):
        fields = docs["enums"].get(enum)
        if fields is None:
            problems.append(f"unknown Enum.{enum} (in {', '.join(sorted(set(where)))})")
        elif field not in fields:
            problems.append(f"Enum.{enum} has no {field} (in {', '.join(sorted(set(where)))})")
    for tpl, where in sorted(use["templates"].items()):
        if tpl not in client["templates"]:
            problems.append(f"unknown template {tpl} (in {', '.join(sorted(set(where)))})")
    ignore = LUA_BUILTINS | use["defined"] | {"FG", "Enum", "ForeverGuideDB", "ForeverGuideVoices", "ForeverGuide",
                                              "SlashCmdList", "SLASH_FOREVERGUIDE1", "SLASH_FOREVERGUIDE2", "WOW_PROJECT_ID"}
    warnings = []
    for g, where in sorted(use["globals"].items()):
        # ITEM_MOD_* are the stat names C_Item.GetItemStats returns, used as table keys.
        if g in ignore or g.startswith("C_") or g.startswith("ITEM_MOD_") or g in docs["funcs"]:
            continue
        if g in OPTIONAL:
            warnings.append(f"undocumented {g} ({OPTIONAL[g]}), guarded in {', '.join(sorted(where))}")
        elif g not in client["names"]:
            problems.append(f"global {g} is not in the client (in {', '.join(sorted(where))})")
    return problems, warnings


def write_api_list(path: Path) -> str:
    """Lua file listing what the addon uses, so /fg selftest can check it in the real game."""
    use = addon_usage(sorted(f for f in ADDON.glob("*.lua") if f.name != "ApiList.lua"))
    funcs = sorted(use["c"]) + sorted(OPTIONAL)
    lines = ["-- Generated by tools/api_check.py --write-list. Do not edit by hand.",
             "local _, FG = ...", "FG.API_USED = {",
             "    functions = {" + ", ".join(f'"{f}"' for f in funcs) + "},",
             "    optional = {" + ", ".join(f'"{f}"' for f in sorted(OPTIONAL)) + "},",
             "    events = {" + ", ".join(f'"{e}"' for e in sorted(use["events"])) + "},",
             "    templates = {" + ", ".join(f'"{t}"' for t in sorted(use["templates"])) + "},",
             "}"]
    text = "\n".join(lines) + "\n"
    path.write_text(text, encoding="utf-8")
    return text


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", type=Path, help="A checkout of wow-ui-source on the forever branch")
    ap.add_argument("--write-list", action="store_true", help="Write addon/ForeverGuide/ApiList.lua for /fg selftest")
    args = ap.parse_args(argv)
    if args.write_list:
        write_api_list(ADDON / "ApiList.lua")
        print("Wrote addon/ForeverGuide/ApiList.lua.")
        return 0
    source = args.source or fetch(CACHE)
    problems, warnings = check(source)
    for p in problems:
        print("  ERROR " + p)
    for w in warnings:
        print("  note  " + w)
    print(f"{len(problems)} problem(s), {len(warnings)} note(s) against the WoW: Forever client code.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
