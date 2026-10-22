#!/usr/bin/env python3
"""Fetch class, race and character data from the Battle.net API.

Keep the client secret on your own computer: set it as an environment
variable and never put it in the web page, since everything on GitHub Pages
is public.

    export BLIZZARD_CLIENT_ID=...      (Windows: set BLIZZARD_CLIENT_ID=...)
    export BLIZZARD_CLIENT_SECRET=...

    python blizzard_fetch.py classes
    python blizzard_fetch.py races
    python blizzard_fetch.py character --realm my-realm --name Oskar

The default namespace is Classic Era ("classic1x"). Blizzard has not said
which namespace WoW: Forever will use, so change --flavor when it is known.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import requests

TOKEN_URL = "https://oauth.battle.net/token"


def api_host(region: str) -> str:
    return "https://gateway.battlenet.com.cn" if region == "cn" else f"https://{region}.api.blizzard.com"


def get_token() -> str:
    cid, secret = os.environ.get("BLIZZARD_CLIENT_ID"), os.environ.get("BLIZZARD_CLIENT_SECRET")
    if not cid or not secret:
        sys.exit("Set BLIZZARD_CLIENT_ID and BLIZZARD_CLIENT_SECRET first.")
    r = requests.post(TOKEN_URL, data={"grant_type": "client_credentials"}, auth=(cid, secret), timeout=20)
    r.raise_for_status()
    return r.json()["access_token"]


class Client:
    def __init__(self, region: str, flavor: str, locale: str):
        self.region, self.flavor, self.locale = region, flavor, locale
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {get_token()}"

    def get(self, path: str, kind: str = "static"):
        params = {"namespace": f"{kind}-{self.flavor}-{self.region}", "locale": self.locale}
        r = self.session.get(api_host(self.region) + path, params=params, timeout=20)
        if r.status_code == 404:
            return None
        r.raise_for_status()
        return r.json()


def cmd_index(client: Client, what: str):
    index = client.get(f"/data/wow/playable-{what}/index")
    key = "classes" if what == "class" else "races"
    out = []
    for item in index.get(key, []):
        detail = client.get(f"/data/wow/playable-{what}/{item['id']}") or {}
        out.append({
            "id": item["id"],
            "name": item.get("name"),
            "faction": (detail.get("faction") or {}).get("name"),
            "power": (detail.get("power_type") or {}).get("name"),
            "classes": [c.get("name") for c in detail.get("playable_classes", [])],
            "races": [r.get("name") for r in detail.get("playable_races", [])],
        })
    return out


def _val(stats: dict, *keys):
    for k in keys:
        v = stats.get(k)
        if isinstance(v, dict):
            v = v.get("effective", v.get("value"))
        if v is not None:
            return v
    return None


def to_export(profile: dict, stats: dict) -> str:
    """Build the same FG1 string as /fg export, so the web simulator can read it."""
    fields = {
        "class": ((profile.get("character_class") or {}).get("name") or "").upper(),
        "race": (profile.get("race") or {}).get("name", "").replace(" ", ""),
        "lvl": profile.get("level"),
        "str": _val(stats, "strength"), "agi": _val(stats, "agility"), "sta": _val(stats, "stamina"),
        "int": _val(stats, "intellect"), "spi": _val(stats, "spirit"),
        "hp": _val(stats, "health"), "mana": _val(stats, "power"),
        "ap": _val(stats, "attack_power"),
        "crit": _val(stats, "melee_crit"), "scrit": _val(stats, "spell_crit"),
        "sp": _val(stats, "spell_power", "bonus_damage"),
    }
    return "&".join(["FG1"] + [f"{k}={v:.2f}" if isinstance(v, float) else f"{k}={v}"
                              for k, v in fields.items() if v not in (None, "")])


def cmd_character(client: Client, realm: str, name: str):
    base = f"/profile/wow/character/{realm.lower()}/{name.lower()}"
    profile = client.get(base, "profile")
    if not profile:
        sys.exit("Character not found. Check realm slug, name, region and --flavor.")
    stats = client.get(base + "/statistics", "profile") or {}
    equipment = client.get(base + "/equipment", "profile") or {}
    return {
        "profile": profile,
        "statistics": stats,
        "equipment": [
            {"slot": (i.get("slot") or {}).get("name"), "name": i.get("name"), "id": (i.get("item") or {}).get("id")}
            for i in equipment.get("equipped_items", [])
        ],
        "export": to_export(profile, stats),
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", choices=["classes", "races", "character"])
    ap.add_argument("--region", default="eu", choices=["us", "eu", "kr", "tw", "cn"])
    ap.add_argument("--flavor", default="classic1x", help="Namespace flavor, e.g. classic1x, classic")
    ap.add_argument("--locale", default="en_GB")
    ap.add_argument("--realm")
    ap.add_argument("--name")
    ap.add_argument("--out", help="Write JSON to this file instead of printing it")
    args = ap.parse_args(argv)

    client = Client(args.region, args.flavor, args.locale)
    if args.what == "character":
        if not (args.realm and args.name):
            ap.error("character needs --realm and --name")
        data = cmd_character(client, args.realm, args.name)
    else:
        data = cmd_index(client, "class" if args.what == "classes" else "race")

    text = json.dumps(data, indent=2, ensure_ascii=False)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
    else:
        print(text)
    if args.what == "character":
        print("\nPaste this into the web simulator:\n" + data["export"], file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
