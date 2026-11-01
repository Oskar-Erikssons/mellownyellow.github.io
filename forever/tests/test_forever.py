"""Tests for the Forever Guide addon logic and the companion app.

Run from the forever/ folder:  python -m unittest discover tests
The Lua tests need `pip install lupa` (an embedded Lua runtime).
"""

import json
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
function GetBuildInfo() return "1.6.0", "70338", "Oct 1 2026", 16001 end
WOW_PROJECT_ID = 18
function UnitName() return "Oskar" end
function issecretvalue() return false end
C_VoiceChat = { GetTtsVoices = function() return {
    { voiceID = 0, name = "Microsoft David" }, { voiceID = 1, name = "Microsoft Zira" },
    { voiceID = 2, name = "Microsoft Mark" }, { voiceID = 3, name = "Microsoft Hazel" } } end }
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
        for name in ("Core.lua", "GameData.lua", "Theme.lua", "Narrator.lua", "Sim.lua", "Auction.lua", "Inventory.lua", "Gear.lua", "Professions.lua", "Route.lua", "Atlas.lua", "QoL.lua", "UI.lua", "Bags.lua", "Market.lua"):
            chunk = self.lua.execute("return function(src, name) return assert((loadstring or load)(src, name)) end")(
                (ADDON / name).read_text(encoding="utf-8"), name)
            chunk("ForeverGuide", self.fg)
        self.fg.settings = self.lua.eval("{ targetLevelDiff = 0, tooltipIncludesSP = false, theme = 'orgrimmar', voiceVariety = true }")

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


class AuctionLuaTests(AddonLuaTests):
    def listings(self, rows):
        return self.lua.table_from([self.lua.table_from(r) for r in rows])

    def test_market_value_ignores_overpriced_listings(self):
        rows = [{"unit": 100, "count": 5}, {"unit": 110, "count": 5}, {"unit": 120, "count": 10},
                {"unit": 5000, "count": 1}, {"unit": 130, "count": 20}]
        market, low, qty, n = self.fg.Auction.Aggregate(self.listings(rows))
        self.assertEqual((low, qty, n), (100, 41, 5))
        self.assertTrue(100 <= market <= 120)
        self.assertIsNone(self.fg.Auction.Aggregate(self.listings([])))

    def test_sale_estimate(self):
        prev = self.listings([{"unit": 100, "count": 1, "tl": 4, "owner": "A"}, {"unit": 100, "count": 1, "tl": 4, "owner": "A"},
                              {"unit": 120, "count": 5, "tl": 1, "owner": "B"}, {"unit": 150, "count": 2, "tl": 3, "owner": "C"}])
        cur = self.listings([{"unit": 100, "count": 1, "tl": 4, "owner": "A"}, {"unit": 150, "count": 2, "tl": 3, "owner": "C"}])
        sold, total = self.fg.Auction.SaleEstimate(prev, cur)
        # One of the two identical listings vanished (sold), the expiring one counts as half.
        self.assertEqual((sold, total), (1.5, 4))

    def test_listing_pack_round_trip(self):
        s = "100:5:4:Bob;250:1:2:"
        rows = self.fg.Auction.UnpackListings(s)
        self.assertEqual(rows[1].owner, "Bob")
        self.assertIsNone(rows[2].owner)
        self.assertEqual(rows[2].unit, 250)

    def test_decide_matches_web_cases(self):
        cases = json.loads((ROOT / "tests" / "ah_cases.json").read_text(encoding="utf-8"))
        for c in cases:
            d = self.fg.Auction.Decide(self.lua.table_from(c["item"]), c["house"])
            self.assertEqual(d.action, c["action"], c["name"])

    def test_money(self):
        self.assertEqual(self.fg.Auction.Money(123456), "12g 34s 56c")
        self.assertEqual(self.fg.Auction.Money(42), "42c")

    def test_quest_keys_and_player_name(self):
        N = self.fg.Narrator
        self.assertEqual(N.Key("detail", "x", 176), "d176")
        self.assertEqual(N.Key("gossip", "Hello", None), "g" + self.fg.Hash("Hello"))

    def test_npc_keeps_same_voice_and_sex(self):
        N = self.fg.Narrator
        v1, r1 = N.PickVoice(N, 3, "Innkeeper Farley")
        v2, r2 = N.PickVoice(N, 3, "Innkeeper Farley")
        self.assertEqual((v1, r1), (v2, r2))
        self.assertIn(v1, (1, 3))  # female voices only
        self.assertTrue(-2 <= r1 <= 2)
        males = {N.PickVoice(N, 2, name)[0] for name in ("Thrall", "Marshal Dughan", "Gryan Stoutmantle", "Hogger", "Bob")}
        self.assertTrue(males <= {0, 2})

    def test_theme_colors(self):
        T = self.fg.Theme
        self.assertEqual(T.Hex(T, "title"), "ffffcc59")
        T.Set(T, "stormwind")
        T.SetColor(T, "accent", 1, 0, 0)
        self.assertEqual(T.Hex(T, "accent"), "ffff0000")
        T.Reset(T)
        self.assertNotEqual(T.Hex(T, "accent"), "ffff0000")


class RouteLuaTests(AddonLuaTests):
    def test_zones_for_level(self):
        zones, dungeons = self.fg.Route.ForLevel(22, "Alliance", "Human", "EK")
        names = [zones[i + 1].name for i in range(len(zones))]
        self.assertIn("Duskwood", names)
        self.assertNotIn("The Barrens", names)
        self.assertEqual(zones[1].continent, "EK")
        start = self.fg.Route.ForLevel(3, "Horde", "Scourge", None)
        self.assertEqual(start[0][1].name, "Tirisfal Glades")

    def test_milestones_for_class(self):
        ms = self.fg.Route.Milestones(8, "WARLOCK", 5)
        self.assertEqual([ms[i + 1].text for i in range(len(ms))][:2], ["Första talangpoängen. Öppna talangplaneraren.", "Klassquest: Voidwalker."])

    def test_next_talent_from_template(self):
        tpl = self.lua.eval('{ picks = { { "A", 2 }, { "B", 1 }, { "A", 1 } } }')
        nxt = self.fg.Talents.NextFromTemplate
        self.assertEqual(nxt(tpl, self.lua.eval("{}")).name, "A")
        n = nxt(tpl, self.lua.eval("{ A = 2 }"))
        self.assertEqual((n.name, n.rank), ("B", 1))
        n = nxt(tpl, self.lua.eval("{ A = 2, B = 1 }"))
        self.assertEqual((n.name, n.rank), ("A", 3))
        self.assertIsNone(nxt(tpl, self.lua.eval("{ A = 3, B = 1 }")))


class NewModulesLuaTests(AddonLuaTests):
    def t(self, py):
        """Python dicts and lists to Lua tables, all the way down."""
        if isinstance(py, dict):
            return self.lua.table_from({k: self.t(v) for k, v in py.items()})
        if isinstance(py, list):
            return self.lua.table_from([self.t(v) for v in py])
        return py

    def test_inventory_key_and_count(self):
        Inv = self.fg.Inventory
        self.assertEqual(Inv.Key("Oskar", "Stormbringer", None, True), "Oskar Stormbringer")
        self.assertEqual(Inv.Key("Oskar", None, "Firemaw", False), "Oskar-Firemaw")
        chars = self.t({"A": {"bags": {2589: 20}, "bank": {2589: 5}}, "B": {"bags": {2589: 12}, "equip": {999: 1}}})
        total, rows = Inv.Count(chars, 2589)
        self.assertEqual(total, 37)
        self.assertEqual((rows[1].key, rows[1].where), ("A", "20 bags, 5 bank"))
        worth, items = Inv.Worth(self.t({"money": 1000, "bags": {1: 2}, "bank": {2: 3}}),
                                 self.lua.eval("function(id, n) return id * n * 10 end"))
        self.assertEqual((worth, items), (1080, 80))

    def test_gear_values_and_score(self):
        G = self.fg.Gear
        v = G.StatValues(self.t({"ap14": 1.4, "meleeCrit1": 2.0, "hit1": 1.0}), self.t({"apStr": 2, "apAgi": 0, "agiCrit": 20}))
        self.assertAlmostEqual(v.ap, 0.1)
        self.assertAlmostEqual(v.str, 0.2)
        self.assertAlmostEqual(v.agi, 0.1)
        score = G.Score(self.t({"ITEM_MOD_STRENGTH_SHORT": 10, "ITEM_MOD_AGILITY_SHORT": 5, "ITEM_MOD_STAMINA_SHORT": 20}), v)
        self.assertAlmostEqual(score, 2.5)
        self.assertEqual(G.SLOTS["INVTYPE_FINGER"][2], 12)

    def test_profession_rank_and_nodes(self):
        P = self.fg.Professions
        ranks = self.fg.Data.professionRanks
        r, ready = P.NextRank(130, 150, 22, ranks)
        self.assertEqual((r.name, ready), ("Expert", True))
        r, ready = P.NextRank(130, 150, 15, ranks)
        self.assertEqual((r.name, ready), ("Expert", False))
        self.assertIsNone(P.NextRank(300, 300, 60, ranks))
        can, new = P.Gatherable(self.fg.Data.gatherNodes.Mining, 130, 100)
        self.assertEqual([new[i + 1].name for i in range(len(new))], ["Iron Deposit"])
        self.assertEqual(len(can), 4)

    def test_trainer_plan(self):
        spells = self.t([{"name": "A", "level": 10, "cost": 100, "known": True},
                         {"name": "B", "level": 12, "cost": 300}, {"name": "C", "level": 14, "cost": 500},
                         {"name": "D", "level": 14, "cost": 700}, {"name": "E", "level": 30, "cost": 9}])
        plan = self.fg.Trainer.Plan(spells, 12, 4)
        self.assertEqual((plan.costNow, plan.nextLevel, plan.costNext, plan.countNext), (300, 14, 1200, 2))

    def test_full_scan_reads_in_batches_and_skips_unknown_items(self):
        n = 1000
        self.lua.execute("""
            local N = ... 
            FG_TEST_N = N
        """, n)
        self.lua.execute("""
            GetNumAuctionItems = function() return FG_TEST_N end
            GetAuctionItemInfo = function(_, i)
                local id = (i % 3 == 0) and 666 or (100 + i % 5)
                return nil, nil, 2, nil, nil, nil, nil, nil, nil, 200 + i, nil, nil, nil, "Seller", nil, nil, id
            end
            GetAuctionItemTimeLeft = function() return 4 end
            C_Item = { DoesItemExistByID = function(id) return id ~= 666 end }
        """)
        steps = self.lua.eval("{ n = 0 }")
        self.fg.Defer = self.lua.eval("function(fn) FG_STEPS = (FG_STEPS or 0) + 1; fn() end")
        A = self.fg.Auction
        A.scanning = "full"
        got = {}
        A.ReadFullScan(A, lambda byItem, total: got.update(byItem=byItem, total=total))
        self.assertEqual(got["total"], n)
        ids = sorted(k for k in got["byItem"].keys())
        self.assertNotIn(666, ids)
        self.assertEqual(sum(len(got["byItem"][k]) for k in ids), n - n // 3)
        self.assertGreaterEqual(self.lua.eval("FG_STEPS"), 2)  # more than one frame
        # Closing the AH mid-scan stops reading.
        A.scanning = False
        stopped = {}
        A.ReadFullScan(A, lambda *a: stopped.update(done=True))
        self.assertEqual(stopped, {})


class AtlasLuaTests(NewModulesLuaTests):
    def test_diff_finds_new_maps_and_level_changes(self):
        maps = self.t({
            1415: {"name": "Eastern Kingdoms", "type": 2},
            1429: {"name": "Elwynn Forest", "type": 3, "parent": 1415, "min": 1, "max": 10},
            1437: {"name": "Wetlands", "type": 3, "parent": 1415, "min": 21, "max": 30},
            2521: {"name": "The Riverglades", "type": 3, "parent": 1415, "min": 36, "max": 44},
            2600: {"name": "Gilded Hollow", "type": 3, "parent": 1415, "min": 30, "max": 35},
            1453: {"name": "Stormwind City", "type": 3, "parent": 1415},
            2700: {"name": "Brand New Crypt", "type": 4, "parent": 1415, "min": 50, "max": 55},
        })
        missing, changed = self.fg.Atlas.Diff(maps, self.fg.Data)
        names = sorted(missing[i + 1].m.name for i in range(len(missing)))
        self.assertEqual(names, ["Brand New Crypt", "Gilded Hollow"])
        changes = sorted(changed[i + 1].m.name for i in range(len(changed)))
        self.assertEqual(changes, ["The Riverglades", "Wetlands"])
        export = self.fg.Atlas.Export(maps)
        self.assertTrue(export.startswith("FGZ1&build=70338&m="))
        self.assertIn("2521:3:1415:36:44:The Riverglades", export)

    def test_route_includes_level_60_zones(self):
        zones, _ = self.fg.Route.ForLevel(60, "Alliance", "Human", "KAL")
        self.assertIn("Mount Hyjal", [zones[i + 1].name for i in range(len(zones))])


class BagsMarketLuaTests(NewModulesLuaTests):
    def test_bag_search(self):
        m = self.fg.Bags.Matches
        linen = self.t({"name": "Linen Cloth", "quality": 1, "action": "ah"})
        junk = self.t({"name": "Broken Fang", "quality": 0, "action": "vendor", "vendor": 5})
        ring = self.t({"name": "Band of Thorns", "quality": 2, "action": "vendor", "upgrade": 1.2, "bound": True})
        self.assertTrue(m("", linen))
        self.assertTrue(m("linen", linen))
        self.assertTrue(m("ah", linen))
        self.assertFalse(m("ah", junk))
        self.assertTrue(m("junk", junk))
        self.assertTrue(m("skräp", junk))
        self.assertTrue(m("upgrade bound", ring))
        self.assertFalse(m("upgrade thorns ah", ring))
        self.assertTrue(m("THORNS", ring))

    def test_other_bag_addons_win(self):
        other = self.fg.Bags.OtherBagAddon
        self.assertEqual(other(self.lua.eval("function(n) return n == 'Bagnon' end")), "Bagnon")
        self.assertIsNone(other(self.lua.eval("function() return false end")))

    def test_bag_layout_and_badges(self):
        rows, w, h = self.fg.Bags.Layout(16 + 4 * 14, 10)
        self.assertEqual(rows, 8)
        self.assertGreater(w, 10 * 37)
        self.assertEqual(self.fg.Bags.Badge(self.t({"quality": 0, "vendor": 5}))[0], "junk")
        self.assertEqual(self.fg.Bags.Badge(self.t({"quality": 1, "action": "ah"}))[0], "AH")
        self.assertEqual(self.fg.Bags.Badge(self.t({"quality": 1, "action": "vendor", "vendor": 5, "market": 3}))[0], "V")
        self.assertIsNone(self.fg.Bags.Badge(self.t({"quality": 1, "action": "keep"})))

    def test_lowest_other_skips_own(self):
        rows = self.t([{"unit": 90, "own": True}, {"unit": 100}, {"unit": 120}])
        self.assertEqual(self.fg.Market.LowestOther(rows), 100)
        self.assertIsNone(self.fg.Market.LowestOther(self.t([{"unit": 90, "own": True}])))

    def test_pick_price(self):
        pick = self.fg.Market.PickPrice
        opt = self.t({"undercut": 1, "floorShare": 0.7})
        self.assertEqual(pick(500, 600, 50, opt)[:3], (499, "under", True))
        # Someone dumps at 300 while the market is 600: the floor is 420, so Market advises to wait.
        self.assertEqual(pick(300, 600, 50, opt)[:3], (420, "dumped", False))
        self.assertEqual(pick(None, 600, 50, opt)[:3], (600, "market", True))
        self.assertEqual(pick(None, None, 50, opt)[:3], (150, "guess", True))
        self.assertEqual(pick(None, None, 0, opt)[1:3], ("nodata", False))
        # Never below the vendor price plus 10 %.
        self.assertEqual(pick(60, None, 100, opt)[:3], (110, "dumped", False))
        self.assertEqual([self.fg.Market.DurationIndex(h) for h in ("2", "8", "24", "x")], [1, 2, 3, 3])

    def test_query_queue_waits_and_recovers(self):
        self.lua.execute("QREADY, QNOW, QLOG = true, 0, {}")
        q = self.fg.Market.NewQueue(self.lua.eval("function() return QREADY end"), self.lua.eval("function() return QNOW end"), 5)
        push = self.lua.eval("function(q, name) q:Push(function() table.insert(QLOG, name) end) end")
        push(q, "a"); push(q, "b")
        self.assertEqual(list(self.lua.eval("QLOG").values()), ["a"])  # one at a time
        q.Done(q)
        self.assertEqual(list(self.lua.eval("QLOG").values()), ["a", "b"])
        push(q, "c")  # "b" never answered...
        self.lua.execute("QNOW = 6")
        q.Pump(q)  # ...so after the timeout the queue moves on
        self.assertEqual(list(self.lua.eval("QLOG").values()), ["a", "b", "c"])
        self.lua.execute("QREADY = false")
        q.Done(q); push(q, "d")
        self.assertEqual(len(self.lua.eval("QLOG")), 3)  # throttled: waits

    def test_spell_queue(self):
        f = self.fg.QoL.SpellQueueFor
        self.assertEqual(f(42, "ROGUE"), 140)
        self.assertEqual(f(42, "MAGE"), 190)
        self.assertEqual(f(0, "WARRIOR"), 100)
        self.assertEqual(f(900, "PRIEST"), 400)


class PrivacyTests(unittest.TestCase):
    """The addon must never send data: no chat, whispers, addon messages, mail or friends API."""

    FORBIDDEN = ["SendAddonMessage", "SendChatMessage", "C_ChatInfo", "BNSendWhisper", "BNSendGameData",
                 "C_BattleNet", "SendMail", "C_Club", "C_Social", "DoEmote", "PerformEmote", "C_VoiceChat.SendChat"]

    def test_addon_sends_nothing(self):
        for f in sorted((ROOT / "addon").rglob("*.lua")):
            code = f.read_text(encoding="utf-8")
            for word in self.FORBIDDEN:
                self.assertNotIn(word, code, f"{f.name} uses {word}")

    def test_web_page_loads_nothing_from_other_sites(self):
        import re
        html = (ROOT / "index.html").read_text(encoding="utf-8")
        external = re.findall(r'<(?:script|link|img|iframe)[^>]+(?:src|href)="(https?:)?//[^"]+"', html)
        self.assertEqual(external, [])
        self.assertNotIn("fetch(", html)
        self.assertNotIn("XMLHttpRequest", html)

    def test_tools_ask_before_sending_elsewhere(self):
        import privacy
        self.assertTrue(privacy.is_local("http://localhost:11434"))
        self.assertTrue(privacy.is_local("http://192.168.1.20:8080/v1"))
        self.assertTrue(privacy.is_local("http://gpu-box.local/v1"))
        self.assertFalse(privacy.is_local("https://openrouter.ai/api/v1"))
        with self.assertRaises(SystemExit):
            privacy.require_consent("https://openrouter.ai/api/v1", False, "Quest texts")
        privacy.require_consent("https://openrouter.ai/api/v1", True, "Quest texts")


class GeneratedDataTests(unittest.TestCase):
    def test_generated_files_are_current(self):
        import build_data
        self.assertEqual(build_data.main(["--check"]), 0)


if __name__ == "__main__":
    unittest.main()
