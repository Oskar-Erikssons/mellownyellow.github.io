#!/usr/bin/env python3
"""Builds quests.json from a quest database, so voices can be made before you play.

With quests.json, forever_voice.py can voice a whole zone in advance ("zone packs"),
so the AI voice plays the very first time you meet a quest giver.

Supported input: a MySQL dump with the 1.12 `quest_template` table, for example from
the open-source cMaNGOS classic-db project. Quest texts belong to Blizzard; use the
result for your own play and do not publish the generated audio.

    python quest_db.py --sql classicdb.sql --out quests.json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

FIELDS = {
    "id": "entry", "title": "Title", "details": "Details", "objectives": "Objectives",
    "progress": "RequestItemsText", "complete": "OfferRewardText",
    "zone": "ZoneOrSort", "level": "QuestLevel", "minLevel": "MinLevel",
}


def _read_value(s: str, i: int):
    """Reads one SQL literal starting at s[i]. Returns (value, next index)."""
    if s[i] == "'":
        out, i = [], i + 1
        while True:
            c = s[i]
            if c == "\\":
                nxt = s[i + 1]
                out.append({"n": "\n", "r": "\r", "t": "\t", "0": "\0"}.get(nxt, nxt))
                i += 2
            elif c == "'" and s[i + 1:i + 2] == "'":
                out.append("'")
                i += 2
            elif c == "'":
                return "".join(out), i + 1
            else:
                out.append(c)
                i += 1
    m = re.compile(r"NULL|-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?", re.I).match(s, i)
    if not m:
        raise ValueError(f"unexpected SQL at {s[i:i + 30]!r}")
    text = m.group()
    if text.upper() == "NULL":
        return None, m.end()
    return (float(text) if any(ch in text for ch in ".eE") else int(text)), m.end()


def parse_tuples(s: str, i: int):
    """Yields each (...) row of a VALUES list starting at s[i]."""
    n = len(s)
    while i < n:
        while i < n and s[i] in " \t\r\n,":
            i += 1
        if i >= n or s[i] != "(":
            return
        i += 1
        row = []
        while True:
            while s[i] in " \t\r\n":
                i += 1
            value, i = _read_value(s, i)
            row.append(value)
            while s[i] in " \t\r\n":
                i += 1
            if s[i] == ",":
                i += 1
            elif s[i] == ")":
                i += 1
                break
        yield row


def parse_dump(sql: str, table: str = "quest_template") -> list[dict]:
    create = re.search(rf"CREATE TABLE `{table}` \((.*?)\n\)", sql, flags=re.S)
    columns = re.findall(r"^\s*`(\w+)`", create.group(1), flags=re.M) if create else None
    rows = []
    for m in re.finditer(rf"INSERT INTO `{table}`\s*(\(([^)]*)\))?\s*VALUES\s*", sql):
        cols = re.findall(r"`(\w+)`", m.group(2)) if m.group(2) else columns
        if not cols:
            raise ValueError("No column names: the dump needs CREATE TABLE or column lists.")
        for row in parse_tuples(sql, m.end()):
            rows.append(dict(zip(cols, row)))
    return rows


def to_quests(rows: list[dict]) -> list[dict]:
    quests = []
    for r in rows:
        q = {k: r.get(col) for k, col in FIELDS.items()}
        if q["id"] and q["title"]:
            quests.append(q)
    return sorted(quests, key=lambda q: q["id"])


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sql", type=Path, required=True)
    ap.add_argument("--out", type=Path, default=Path("quests.json"))
    args = ap.parse_args(argv)
    quests = to_quests(parse_dump(args.sql.read_text(encoding="utf-8", errors="replace")))
    args.out.write_text(json.dumps(quests, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"Wrote {len(quests)} quests to {args.out}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
