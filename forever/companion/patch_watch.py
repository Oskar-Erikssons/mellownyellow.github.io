#!/usr/bin/env python3
"""Reads patch notes and hotfixes with a local language model and updates the game data.

How it stays safe:
  1. Only data/gamedata.json is changed automatically, never code. The web page and the
     addon read their rules from it (through build_data.py).
  2. Every change must quote the exact sentence from the patch notes. A change whose quote
     is not in the text is thrown away, so the model cannot invent changes.
  3. A change must match the current value ("old"), keep the same type and stay within a
     sane range.
  4. After applying, the tests run. If any test fails, everything is rolled back.
  5. Code changes the model suggests (for example a renamed API) go into a report for you
     to review, since a wrong code edit could break the addon.

Runs with any local model server:
  Ollama:     python patch_watch.py --file notes.txt --model qwen3:14b
  LM Studio / llama.cpp / vLLM (OpenAI-style):
              python patch_watch.py --file notes.txt --api openai --llm-url http://localhost:1234/v1 --model local

Add --apply to write the changes and --commit to commit them with git.
Use --fetch to read the sources in patch_sources.json (only new texts are analysed).
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
import re
import shutil
import subprocess
import sys
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data" / "gamedata.json"
CHANGELOG = ROOT / "data" / "changelog.json"
STATE = ROOT / "data" / ".patch_state.json"
REPORTS = ROOT / "reports"
SOURCES = Path(__file__).resolve().parent / "patch_sources.json"

PROTECTED = ("/schema", "/notes")
BASE_KEYWORDS = [
    "forever", "classic", "auction", "deposit", "racial", "glancing", "hit chance", "critical",
    "spell power", "spell damage", "attack power", "weapon skill", "specialization", "interface",
    "addon", "api", "text to speech", "texttospeech", "voice", "hotfix", "vendor", "sell price",
]

SYSTEM_PROMPT = """You maintain the game data for a World of Warcraft: Forever helper app.
You get the current data as JSON and a piece of patch notes or hotfixes.
Decide if anything in the notes changes the data. Only WoW: Forever (or Classic Era when
the notes say it also applies to Forever) counts. Retail-only changes do not count.

Answer with JSON only, in this exact shape:
{
  "relevant": true or false,
  "summary_sv": "one or two sentences in Swedish about what changed for the player",
  "changes": [
    {"op": "replace" | "add" | "remove",
     "path": "JSON Pointer into the data, e.g. /auction/cut/neutral",
     "old": current value (for replace and remove),
     "value": new value (for replace and add),
     "quote": "the exact sentence from the notes that proves the change",
     "reason": "short explanation"}
  ],
  "code_notes": [
    {"file": "addon/ForeverGuide/...", "problem": "...", "suggestion": "..."}
  ]
}
Rules: never guess numbers that are not in the notes. Copy "quote" word for word.
If nothing applies, return relevant=false and empty lists."""


# --- Fetching ----------------------------------------------------------------

class _TextExtractor(HTMLParser):
    SKIP = {"script", "style", "nav", "header", "footer", "noscript"}
    BLOCK = {"p", "li", "h1", "h2", "h3", "h4", "br", "div", "tr"}

    def __init__(self):
        super().__init__()
        self.parts, self.skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip += 1
        elif tag in self.BLOCK:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in self.SKIP and self.skip:
            self.skip -= 1

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def html_to_text(html: str) -> str:
    p = _TextExtractor()
    p.feed(html)
    text = "".join(p.parts)
    return re.sub(r"\n\s*\n+", "\n\n", re.sub(r"[ \t]+", " ", text)).strip()


def rss_items(xml: str) -> list[dict]:
    items = []
    for block in re.findall(r"<item\b.*?</item>", xml, flags=re.S | re.I):
        def tag(name):
            m = re.search(rf"<{name}\b[^>]*>(.*?)</{name}>", block, flags=re.S | re.I)
            if not m:
                return ""
            return re.sub(r"^<!\[CDATA\[|\]\]>$", "", m.group(1).strip())
        items.append({"title": tag("title"), "link": tag("link"), "description": html_to_text(tag("description"))})
    return items


def fetch_sources(limit: int) -> list[dict]:
    import requests
    sources = json.loads(SOURCES.read_text(encoding="utf-8")) if SOURCES.exists() else []
    texts = []
    for src in sources:
        try:
            r = requests.get(src["url"], timeout=30, headers={"User-Agent": "ForeverGuide patch_watch"})
            r.raise_for_status()
        except Exception as exc:
            print(f"Could not read {src['name']}: {exc}")
            continue
        if src.get("type") == "rss":
            for item in rss_items(r.text)[:limit]:
                body = item["description"]
                if item["link"] and src.get("follow_links", True):
                    try:
                        page = requests.get(item["link"], timeout=30, headers={"User-Agent": "ForeverGuide patch_watch"})
                        body = html_to_text(page.text)
                    except Exception:
                        pass
                texts.append({"source": f"{src['name']}: {item['title']}", "url": item["link"], "text": body})
        else:
            texts.append({"source": src["name"], "url": src["url"], "text": html_to_text(r.text)})
    return texts


# --- Pre-filter --------------------------------------------------------------

def keywords(data: dict) -> list[str]:
    words = set(BASE_KEYWORDS)
    for cid in data.get("classes", {}):
        words.add(cid.lower())
    for rid, race in data.get("races", {}).items():
        words.add(rid.lower())
        for racial in race.get("racials", []):
            words.add(racial.split(":")[0].strip().lower())
    return sorted(w for w in words if len(w) > 2)


def relevant_excerpt(text: str, data: dict, max_chars: int = 12000) -> str:
    """Keeps only paragraphs that mention something the app knows about."""
    words = keywords(data)
    keep = [p.strip() for p in re.split(r"\n\s*\n|\n(?=[-•*])", text)
            if p.strip() and any(w in p.lower() for w in words)]
    return "\n\n".join(keep)[:max_chars]


# --- Language model ----------------------------------------------------------

def ask_llm(api: str, url: str, model: str, data: dict, notes: str) -> dict:
    import requests
    user = ("CURRENT DATA:\n" + json.dumps(data, ensure_ascii=False, separators=(",", ":"))
            + "\n\nPATCH NOTES:\n" + notes)
    messages = [{"role": "system", "content": SYSTEM_PROMPT}, {"role": "user", "content": user}]
    if api == "ollama":
        r = requests.post(url.rstrip("/") + "/api/chat", timeout=900, json={
            "model": model, "messages": messages, "stream": False, "format": "json",
            "options": {"temperature": 0, "num_ctx": 32768}})
        r.raise_for_status()
        content = r.json()["message"]["content"]
    else:
        r = requests.post(url.rstrip("/") + "/chat/completions", timeout=900, json={
            "model": model, "messages": messages, "temperature": 0,
            "response_format": {"type": "json_object"}})
        r.raise_for_status()
        content = r.json()["choices"][0]["message"]["content"]
    return parse_json_answer(content)


def parse_json_answer(content: str) -> dict:
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.S)  # reasoning models
    content = re.sub(r"^```(?:json)?|```$", "", content.strip(), flags=re.M).strip()
    start, end = content.find("{"), content.rfind("}")
    if start < 0 or end < 0:
        raise ValueError("The model did not answer with JSON.")
    return json.loads(content[start:end + 1])


# --- Validation and applying -----------------------------------------------------

def _tokens(path: str) -> list[str]:
    if not path.startswith("/"):
        raise ValueError("path must start with /")
    return [t.replace("~1", "/").replace("~0", "~") for t in path[1:].split("/")]


def _walk(doc, tokens):
    cur = doc
    for t in tokens:
        if isinstance(cur, list):
            cur = cur[int(t)]
        elif isinstance(cur, dict):
            cur = cur[t]
        else:
            raise KeyError(t)
    return cur


def get_path(doc, path):
    return _walk(doc, _tokens(path))


def set_path(doc, path, value, op):
    tokens = _tokens(path)
    parent = _walk(doc, tokens[:-1])
    key = tokens[-1]
    if isinstance(parent, list):
        if op == "add" and key == "-":
            parent.append(value)
        elif op == "add":
            parent.insert(int(key), value)
        elif op == "remove":
            parent.pop(int(key))
        else:
            parent[int(key)] = value
    else:
        if op == "remove":
            del parent[key]
        else:
            parent[key] = value


def _norm(s: str) -> str:
    s = s.replace("’", "'").replace("“", '"').replace("”", '"').replace("–", "-").replace("—", "-")
    return re.sub(r"\s+", " ", s).strip().lower()


def _same_type(a, b) -> bool:
    num = (int, float)
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool)
    if isinstance(a, num) and isinstance(b, num):
        return True
    return type(a) is type(b)


def validate(change: dict, data: dict, notes: str) -> str | None:
    """Returns why a change is rejected, or None when it is safe to apply."""
    op, path = change.get("op"), change.get("path", "")
    if op not in ("replace", "add", "remove"):
        return f"unknown op {op!r}"
    if any(path == p or path.startswith(p + "/") for p in PROTECTED):
        return "protected field"
    quote = change.get("quote") or ""
    if len(quote) < 8 or _norm(quote) not in _norm(notes):
        return "the quote is not in the patch notes"
    try:
        tokens = _tokens(path)
        if op == "add":
            _walk(data, tokens[:-1])
        else:
            current = _walk(data, tokens)
    except (KeyError, IndexError, ValueError, TypeError):
        return "the path does not exist"
    if op in ("replace", "remove") and "old" in change and change["old"] != current:
        return f"old value {change['old']!r} does not match current {current!r}"
    if op == "replace":
        new = change.get("value")
        if not _same_type(current, new):
            return f"type changes from {type(current).__name__} to {type(new).__name__}"
        if isinstance(current, (int, float)) and not isinstance(current, bool) and current:
            ratio = new / current
            if not (0.2 <= ratio <= 5):
                return f"{current} -> {new} is outside the sane range"
    return None


def run_tests() -> tuple[bool, str]:
    out = []
    py = subprocess.run([sys.executable, "-m", "unittest", "discover", "tests"], cwd=ROOT, capture_output=True, text=True)
    out.append(py.stderr[-2000:])
    ok = py.returncode == 0
    if shutil.which("node"):
        js = subprocess.run(["node", "--test", "tests/app.test.js"], cwd=ROOT, capture_output=True, text=True)
        out.append(js.stdout[-2000:])
        ok = ok and js.returncode == 0
    return ok, "\n".join(out)


def rebuild():
    subprocess.run([sys.executable, str(Path(__file__).resolve().parent / "build_data.py")], check=True, cwd=ROOT)


def apply(changes: list[dict], answer: dict, source: str, data: dict, commit: bool) -> bool:
    backup_data, backup_log = DATA.read_text(encoding="utf-8"), CHANGELOG.read_text(encoding="utf-8")
    new = copy.deepcopy(data)
    for c in changes:
        set_path(new, c["path"], c.get("value"), c["op"])
    new["updated"] = dt.date.today().isoformat()
    DATA.write_text(json.dumps(new, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    log = json.loads(backup_log)
    log.insert(0, {
        "date": new["updated"], "source": source, "summary": answer.get("summary_sv", ""),
        "changes": [{k: c.get(k) for k in ("op", "path", "old", "value", "quote")} for c in changes],
    })
    CHANGELOG.write_text(json.dumps(log, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    rebuild()

    ok, output = run_tests()
    if not ok:
        DATA.write_text(backup_data, encoding="utf-8")
        CHANGELOG.write_text(backup_log, encoding="utf-8")
        rebuild()
        print("Tests failed, so nothing was changed:\n" + output)
        return False
    print(f"Applied {len(changes)} change(s). Tests pass.")
    if commit:
        files = ["data/gamedata.json", "data/changelog.json", "gamedata.js", "addon/ForeverGuide/GameData.lua"]
        subprocess.run(["git", "add", *files], cwd=ROOT, check=True)
        subprocess.run(["git", "commit", "-m", f"Update game data from {source}\n\n{answer.get('summary_sv', '')}"], cwd=ROOT, check=True)
    return True


def write_report(source: str, answer: dict, accepted: list, rejected: list) -> Path:
    REPORTS.mkdir(exist_ok=True)
    slug = re.sub(r"[^a-z0-9]+", "-", source.lower()).strip("-")[:50] or "notes"
    path = REPORTS / f"{dt.date.today().isoformat()}-{slug}.md"
    lines = [f"# Patchnoter: {source}", "", answer.get("summary_sv", "") or "Ingen sammanfattning.", ""]
    lines += ["## Ändringar i speldatan", ""]
    lines += [f"- `{c['path']}`: {json.dumps(c.get('old'), ensure_ascii=False)} → {json.dumps(c.get('value'), ensure_ascii=False)}  \n  > {c.get('quote')}" for c in accepted] or ["Inga."]
    if rejected:
        lines += ["", "## Avvisade förslag", ""]
        lines += [f"- `{c.get('path')}`: {why}" for c, why in rejected]
    notes = answer.get("code_notes") or []
    if notes:
        lines += ["", "## Förslag på kodändringar (granska själv)", ""]
        lines += [f"- **{n.get('file', '?')}**: {n.get('problem', '')} Förslag: {n.get('suggestion', '')}" for n in notes]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


# --- Main --------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", type=Path, nargs="*", default=[], help="Patch notes as text or HTML files")
    ap.add_argument("--fetch", action="store_true", help="Read the sources in patch_sources.json")
    ap.add_argument("--api", choices=["ollama", "openai"], default="ollama")
    ap.add_argument("--llm-url", default="http://localhost:11434")
    ap.add_argument("--model", default="qwen3:14b")
    ap.add_argument("--apply", action="store_true", help="Write accepted changes (otherwise only show them)")
    ap.add_argument("--commit", action="store_true", help="Commit applied changes with git")
    ap.add_argument("--limit", type=int, default=5, help="Max items per RSS source")
    args = ap.parse_args(argv)

    data = json.loads(DATA.read_text(encoding="utf-8"))
    texts = []
    for f in args.file:
        raw = f.read_text(encoding="utf-8")
        texts.append({"source": f.name, "url": "", "text": html_to_text(raw) if "<" in raw[:500] else raw})
    if args.fetch:
        texts += fetch_sources(args.limit)
    if not texts:
        ap.error("give --file or --fetch")

    state = json.loads(STATE.read_text(encoding="utf-8")) if STATE.exists() else {"seen": []}
    for t in texts:
        digest = hashlib.sha256(t["text"].encode("utf-8")).hexdigest()
        if digest in state["seen"] and args.fetch and not args.file:
            continue
        excerpt = relevant_excerpt(t["text"], data)
        print(f"\n== {t['source']}")
        if not excerpt:
            print("Nothing here touches the app's data.")
        else:
            answer = ask_llm(args.api, args.llm_url, args.model, data, excerpt)
            accepted, rejected = [], []
            for c in answer.get("changes") or []:
                why = validate(c, data, excerpt)
                (rejected.append((c, why)) if why else accepted.append(c))
            print(answer.get("summary_sv") or "(no summary)")
            for c in accepted:
                print(f"  OK  {c['op']} {c['path']}: {c.get('old')!r} -> {c.get('value')!r}")
            for c, why in rejected:
                print(f"  NO  {c.get('op')} {c.get('path')}: {why}")
            report = write_report(t["source"], answer, accepted, rejected)
            print(f"Report: {report}")
            if accepted and args.apply:
                if not apply(accepted, answer, t["source"], data, args.commit):
                    continue
                data = json.loads(DATA.read_text(encoding="utf-8"))
            elif accepted:
                print("Dry run. Add --apply to write these changes.")
        state["seen"].append(digest)
    STATE.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
