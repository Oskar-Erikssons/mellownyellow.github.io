"""Tests for the Forever Guide addon logic and the companion app.

Run from the forever/ folder:  python -m unittest discover tests
The Lua tests need `pip install lupa` (an embedded Lua runtime).
"""

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addon" / "ForeverGuide"
sys.path.insert(0, str(ROOT / "companion"))

import lua_table  # noqa: E402

SAVED = r'''
ForeverGuideDB = {
["settings"] = {
["autoRead"] = true,
["rate"] = -2,
["mode"] = "both",
},
["voiceQueue"] = {
["d1a2b3c4d"] = {
["kind"] = "detail",
["text"] = "Kill 10 \"Kobold\" Vermin.\nReturn to me, $N.",
["npc"] = "Marshal McBride",
["sex"] = 2,
["quest"] = 7,
},
["g0000beef"] = {
["kind"] = "gossip",
["text"] = "Ah, a traveler! <She smiles.> Welcome to Goldshire.",
["npc"] = "Innkeeper Farley",
["sex"] = 3,
},
},
["snapshots"] = {
"first", -- [1]
"second", -- [2]
},
}
'''


class LuaTableTests(unittest.TestCase):
    def test_parses_saved_variables(self):
        db = lua_table.loads(SAVED)["ForeverGuideDB"]
        self.assertEqual(db["settings"]["rate"], -2)
        self.assertIs(db["settings"]["autoRead"], True)
        q = db["voiceQueue"]["d1a2b3c4d"]
        self.assertEqual(q["text"], 'Kill 10 "Kobold" Vermin.\nReturn to me, $N.')
        self.assertEqual(q["sex"], 2)
        self.assertEqual(db["snapshots"], {1: "first", 2: "second"})

    def test_decimal_escape_and_utf8(self):
        db = lua_table.loads('X = { ["a"] = "caf\\195\\169", ["b"] = "Ström" }')
        self.assertEqual(db["X"]["a"], "café")
        self.assertEqual(db["X"]["b"], "Ström")

    def test_lua_string_round_trip(self):
        s = 'He said "hi"\\ and\nleft'
        self.assertEqual(lua_table.loads("X = " + lua_table.lua_string(s))["X"], s)


class CompanionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        sv = self.tmp / "WTF" / "Account" / "TEST" / "SavedVariables"
        sv.mkdir(parents=True)
        (sv / "ForeverGuide.lua").write_text(SAVED, encoding="utf-8")
        (self.tmp / "Interface" / "AddOns" / "ForeverGuide_Voices").mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_end_to_end_with_test_engine(self):
        import forever_voice
        self.assertEqual(forever_voice.main(["--wow", str(self.tmp), "--engine", "test"]), 0)
        addon = self.tmp / "Interface" / "AddOns" / "ForeverGuide_Voices"
        self.assertTrue((addon / "sounds" / "d1a2b3c4d.ogg").exists())
        manifest = lua_table.load(addon / "Manifest.lua")["ForeverGuideVoices"]
        self.assertEqual(set(manifest), {"d1a2b3c4d", "g0000beef"})
        self.assertGreater(manifest["g0000beef"], 0)

    def test_http_engine_with_prefix(self):
        import io
        import json
        import threading
        from http.server import BaseHTTPRequestHandler, HTTPServer

        import numpy as np
        import soundfile as sf
        import forever_voice

        seen = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                seen.append((self.path, json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
                buf = io.BytesIO()
                sf.write(buf, np.zeros(16000, dtype=np.float32), 16000, format="WAV")
                self.send_response(200)
                self.end_headers()
                self.wfile.write(buf.getvalue())

            def log_message(self, *args):
                pass

        server = HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        voices = self.tmp / "voices.json"
        voices.write_text(json.dumps({"http": {"prefix": {"gossip": "[warm]"}}}), encoding="utf-8")
        try:
            code = forever_voice.main(["--wow", str(self.tmp), "--engine", "http", "--voices", str(voices),
                                       "--url", f"http://127.0.0.1:{server.server_port}/v1", "--model", "drama-3"])
        finally:
            server.shutdown()
        self.assertEqual(code, 0)
        self.assertEqual(seen[0][0], "/v1/audio/speech")
        bodies = {b["input"][:6]: b for _, b in seen}
        self.assertIn("[warm]", bodies)
        self.assertEqual(bodies["[warm]"]["model"], "drama-3")
        clip = self.tmp / "Interface" / "AddOns" / "ForeverGuide_Voices" / "sounds" / "g0000beef.ogg"
        self.assertAlmostEqual(sf.info(str(clip)).duration, 1.0, places=1)

    def test_voice_choice_is_stable_per_npc(self):
        import forever_voice
        d = forever_voice.KOKORO_VOICES
        e = {"npc": "Innkeeper Farley", "sex": 3, "kind": "gossip"}
        self.assertEqual(forever_voice.choose_voice(e, {}, d), forever_voice.choose_voice(e, {}, d))
        self.assertIn(forever_voice.choose_voice(e, {}, d), d["female"])
        self.assertEqual(forever_voice.choose_voice({"kind": "log"}, {}, d), d["narrator"])
        self.assertEqual(forever_voice.choose_voice(e, {"npc": {"Innkeeper Farley": "x"}}, d), "x")

    def test_emotes_removed(self):
        import forever_voice
        self.assertEqual(forever_voice.tts_text("Hi! <She smiles.>  Welcome."), "Hi! Welcome.")


try:
    # WoW runs Lua 5.1, so prefer that runtime when lupa ships it.
    from lupa import lua51 as lupa
except ImportError:  # pragma: no cover
    try:
        import lupa
    except ImportError:
        lupa = None


# Just enough of the WoW API for the addon's pure logic to run.
WOW_STUBS = r'''
local frames = {}
function CreateFrame() local f = {}; function f:RegisterEvent() end; function f:SetScript() end; return f end
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
SlashCmdList = {}
UISpecialFrames = {}
function strsplit(sep, s) local t = {}; for p in (s .. sep):gmatch("(.-)" .. sep) do t[#t + 1] = p end; return unpack(t) end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
unpack = unpack or table.unpack
tinsert = table.insert
'''


@unittest.skipIf(lupa is None, "pip install lupa to run the Lua tests")
class AddonLuaTests(unittest.TestCase):
    def setUp(self):
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(WOW_STUBS)
        self.fg = self.lua.eval("{}")
        for name in ("Core.lua", "Narrator.lua", "Sim.lua", "UI.lua"):
            chunk = self.lua.execute("return function(src, name) return assert((loadstring or load)(src, name)) end")(
                (ADDON / name).read_text(encoding="utf-8"), name)
            chunk("ForeverGuide", self.fg)
        self.fg.settings = self.lua.eval("{ targetLevelDiff = 0, tooltipIncludesSP = false }")

    def test_hash_matches_python_djb2(self):
        def djb2(s):
            h = 5381
            for b in s.encode("utf-8"):
                h = (h * 33 + b) % 2**32
            return f"{h:08x}"
        for s in ["", "Hello", "Ström över fjället", "x" * 5000]:
            self.assertEqual(self.fg.Hash(s), djb2(s))

    def test_normalize(self):
        self.assertEqual(self.fg.Normalize("  |cffff0000Red|r\n\n text  "), "Red text")

    def test_parse_direct_damage(self):
        kind, lo, hi, dot, dur = self.fg.Sim.ParseDescription(
            "Hurls a fiery ball that causes 1,018 to 1,296 Fire damage and an additional 76 Fire damage over 8 sec.")
        self.assertEqual((kind, lo, hi, dot, dur), ("damage", 1018, 1296, 76, 8))

    def test_parse_heal(self):
        kind, lo, hi, _, _ = self.fg.Sim.ParseDescription("Heals a friendly target for 47 to 58.")
        self.assertEqual((kind, lo, hi), ("heal", 47, 58))

    def test_parse_dot_only(self):
        kind, lo, hi, dot, dur = self.fg.Sim.ParseDescription(
            "A word of darkness that causes 30 Shadow damage over 18 sec.")
        self.assertEqual((kind, lo, hi, dot, dur), ("damage", 0, 0, 30, 18))

    def test_parse_utility_returns_nil(self):
        self.assertIsNone(self.fg.Sim.ParseDescription("Increases your movement speed by 40%."))

    def test_run_and_export(self):
        snap = self.lua.eval('''{
            level = 20, class = "MAGE", race = "Gnome", className = "Mage", raceName = "Gnome",
            str = 20, agi = 25, sta = 40, int = 90, spi = 70, mana = 1200, hp = 600,
            spellCrit = 5, sp = 20, healing = 0, spellHit = 0, crit = 3, hit = 0,
            mh = { min = 10, max = 20, speed = 2.5 },
            spells = {
                { name = "Fireball", kind = "damage", min = 100, max = 130, dot = 8, dur = 8, cast = 3.0, cd = 0, cost = 110 },
                { name = "Fire Blast", kind = "damage", min = 60, max = 75, dot = 0, dur = 0, cast = 0, cd = 8, cost = 75 },
            },
        }''')
        results, melee, weights = self.fg.Sim.Run(self.fg.Sim, snap)
        self.assertEqual(results[1].spell.name, "Fireball")
        self.assertGreater(results[1].dps, results[2].dps)
        self.assertGreater(melee, 0)
        self.assertGreater(weights.sp10, 0)
        self.assertGreater(weights.crit1, 0)
        export = self.fg.Sim.Export(self.fg.Sim, snap)
        self.assertTrue(export.startswith("FG1&class=MAGE&race=Gnome&lvl=20"))
        # Lua 5.1 (WoW) prints 3.0 as "3", the Lua 5.4 test runtime as "3.0".
        self.assertRegex(export, r"spells=Fireball:d:100:130:8:8:3(\.0)?:0:110;Fire Blast:d:60:75:0:0:0:8:75$")
        self.assertNotIn("|", export)

    def test_ui_sim_text_renders(self):
        snap = self.lua.eval('''{ level = 10, class = "WARRIOR", race = "Orc", className = "Warrior",
            raceName = "Orc", crit = 5, hit = 0, ap = 120, mh = { min = 20, max = 35, speed = 3.0 }, spells = {} }''')
        text = self.fg.UI.SimText(self.fg.UI, snap)
        self.assertIn("Orc Warrior, level 10", text)
        self.assertIn("Auto attack", text)


if __name__ == "__main__":
    unittest.main()
