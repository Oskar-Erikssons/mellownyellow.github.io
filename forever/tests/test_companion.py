"""Tests for patch_watch.py, quest_db.py, forever_ah.py and the zone-pack parts of forever_voice.py.

Run from the forever/ folder:  python -m unittest discover tests
"""

import json
import shutil
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "companion"))

import forever_ah  # noqa: E402
import forever_voice  # noqa: E402
import patch_watch  # noqa: E402
import quest_db  # noqa: E402

NOTES = """Hotfixes for WoW: Forever

Auction House
- The auction house cut at neutral auction houses has been reduced from 15% to 10%.

Racials
- Troll Berserking now grants 15% haste at full health, up from 10%.

Retail
- Delves now award more coffer keys.
"""


class FakeLLM:
    """Local stand-in for Ollama's /api/chat."""

    def __init__(self, answer):
        self.answer = answer
        self.requests = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                outer.requests.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                body = json.dumps({"message": {"content": "<think>hmm</think>```json\n" + json.dumps(outer.answer) + "\n```"}})
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body.encode())

            def log_message(self, *args):
                pass

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()


ANSWER = {
    "relevant": True,
    "summary_sv": "Neutrala auktionshus tar mindre avgift och Berserking blir starkare.",
    "changes": [
        {"op": "replace", "path": "/auction/cut/neutral", "old": 0.15, "value": 0.10,
         "quote": "The auction house cut at neutral auction houses has been reduced from 15% to 10%."},
        {"op": "replace", "path": "/combat/berserkingHaste", "old": 0.10, "value": 0.15,
         "quote": "Troll Berserking now grants 15% haste at full health, up from 10%."},
        # Invented: the quote is not in the notes.
        {"op": "replace", "path": "/auction/cut/faction", "old": 0.05, "value": 0.02,
         "quote": "The faction auction house cut is now 2%."},
        # Stale: the old value is wrong.
        {"op": "replace", "path": "/combat/gcd", "old": 1.0, "value": 1.2,
         "quote": "Troll Berserking now grants 15% haste at full health"},
    ],
    "code_notes": [{"file": "addon/ForeverGuide/Narrator.lua", "problem": "x", "suggestion": "y"}],
}


class PatchWatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        shutil.copy(ROOT / "data" / "gamedata.json", self.tmp / "gamedata.json")
        shutil.copy(ROOT / "data" / "changelog.json", self.tmp / "changelog.json")
        (self.tmp / "notes.txt").write_text(NOTES, encoding="utf-8")
        self.patches = [
            mock.patch.object(patch_watch, "DATA", self.tmp / "gamedata.json"),
            mock.patch.object(patch_watch, "CHANGELOG", self.tmp / "changelog.json"),
            mock.patch.object(patch_watch, "STATE", self.tmp / "state.json"),
            mock.patch.object(patch_watch, "REPORTS", self.tmp / "reports"),
            mock.patch.object(patch_watch, "rebuild", lambda: None),
        ]
        for p in self.patches:
            p.start()
        self.llm = FakeLLM(ANSWER)

    def tearDown(self):
        self.llm.close()
        for p in self.patches:
            p.stop()
        shutil.rmtree(self.tmp)

    def run_watch(self, *extra):
        return patch_watch.main(["--file", str(self.tmp / "notes.txt"), "--llm-url", self.llm.url, *extra])

    def data(self):
        return json.loads((self.tmp / "gamedata.json").read_text(encoding="utf-8"))

    def test_dry_run_changes_nothing_but_writes_report(self):
        with mock.patch.object(patch_watch, "run_tests", lambda: (True, "")):
            self.assertEqual(self.run_watch(), 0)
        self.assertEqual(self.data()["auction"]["cut"]["neutral"], 0.15)
        report = next((self.tmp / "reports").glob("*.md")).read_text(encoding="utf-8")
        self.assertIn("/auction/cut/neutral", report)
        self.assertIn("the quote is not in the patch notes", report)
        self.assertIn("does not match current", report)
        self.assertIn("Narrator.lua", report)

    def test_only_relevant_paragraphs_reach_the_model(self):
        with mock.patch.object(patch_watch, "run_tests", lambda: (True, "")):
            self.run_watch()
        prompt = self.llm.requests[0]["messages"][1]["content"]
        self.assertIn("Berserking", prompt)
        self.assertNotIn("Delves", prompt)

    def test_apply_writes_verified_changes_and_changelog(self):
        with mock.patch.object(patch_watch, "run_tests", lambda: (True, "")):
            self.run_watch("--apply")
        d = self.data()
        self.assertEqual(d["auction"]["cut"]["neutral"], 0.10)
        self.assertEqual(d["combat"]["berserkingHaste"], 0.15)
        self.assertEqual(d["auction"]["cut"]["faction"], 0.05)  # invented change rejected
        self.assertEqual(d["combat"]["gcd"], 1.5)  # stale change rejected
        log = json.loads((self.tmp / "changelog.json").read_text(encoding="utf-8"))
        self.assertEqual(len(log[0]["changes"]), 2)
        self.assertIn("Berserking", log[0]["summary"])

    def test_failing_tests_roll_back(self):
        before = (self.tmp / "gamedata.json").read_text(encoding="utf-8")
        with mock.patch.object(patch_watch, "run_tests", lambda: (False, "boom")):
            self.run_watch("--apply")
        self.assertEqual((self.tmp / "gamedata.json").read_text(encoding="utf-8"), before)

    def test_validate_guards(self):
        data = self.data()
        self.assertEqual(patch_watch.validate({"op": "replace", "path": "/schema", "value": 2, "quote": NOTES[:40]}, data, NOTES), "protected field")
        self.assertIn("type changes", patch_watch.validate(
            {"op": "replace", "path": "/combat/gcd", "value": "fast", "quote": "Troll Berserking now grants"}, data, NOTES))
        self.assertIn("sane range", patch_watch.validate(
            {"op": "replace", "path": "/combat/gcd", "value": 100, "quote": "Troll Berserking now grants"}, data, NOTES))
        self.assertIsNone(patch_watch.validate(
            {"op": "add", "path": "/races/Troll/racials/-", "value": "New racial", "quote": "Troll Berserking now grants"}, data, NOTES))

    def test_rss_and_html_helpers(self):
        rss = "<rss><item><title>Hotfixes</title><link>https://x/y</link><description><![CDATA[<p>A</p><p>B</p>]]></description></item></rss>"
        items = patch_watch.rss_items(rss)
        self.assertEqual(items[0]["title"], "Hotfixes")
        self.assertEqual(items[0]["link"], "https://x/y")
        text = patch_watch.html_to_text("<script>x()</script><p>One</p><p>Two</p>")
        self.assertNotIn("x()", text)
        self.assertEqual(text.split(), ["One", "Two"])


SQL = r"""
CREATE TABLE `quest_template` (
  `entry` mediumint(8) unsigned NOT NULL default '0',
  `ZoneOrSort` smallint(6) NOT NULL default '0',
  `MinLevel` tinyint(3) unsigned NOT NULL default '0',
  `QuestLevel` tinyint(3) unsigned NOT NULL default '0',
  `Title` text,
  `Details` text,
  `Objectives` text,
  `OfferRewardText` text,
  `RequestItemsText` text
) ENGINE=MyISAM;
INSERT INTO `quest_template` VALUES (783,12,1,1,'A Threat Within','I hope you strike quickly, $N. It\'s dangerous.$B$BGo.','Speak with Marshal McBride.','Ah, $C. You made it.',''),
(7,12,1,2,'Kobold Camp Cleanup','Kill them!','Kill 10 Kobold Vermin.','Good work, $Gsir:madam;.','How goes the hunt?');
INSERT INTO `quest_template` VALUES (100,40,10,12,'Elsewhere','x','y',NULL,NULL);
"""


class QuestDbTests(unittest.TestCase):
    def test_parse_dump(self):
        quests = quest_db.to_quests(quest_db.parse_dump(SQL))
        self.assertEqual([q["id"] for q in quests], [7, 100, 783])
        q = next(q for q in quests if q["id"] == 783)
        self.assertEqual(q["details"], "I hope you strike quickly, $N. It's dangerous.$B$BGo.")
        self.assertEqual(q["zone"], 12)
        self.assertIsNone(next(q for q in quests if q["id"] == 100)["complete"])

    def test_zone_pack_entries_use_addon_keys(self):
        tmp = Path(tempfile.mkdtemp())
        try:
            path = tmp / "quests.json"
            path.write_text(json.dumps(quest_db.to_quests(quest_db.parse_dump(SQL))), encoding="utf-8")
            entries = forever_voice.quest_entries(path, zone=12, min_level=1, max_level=10)
            self.assertEqual(sorted(entries), ["c7", "c783", "d7", "d783", "p7"])
            self.assertTrue(entries["d783"]["text"].startswith("A Threat Within. I hope"))
        finally:
            shutil.rmtree(tmp)

    def test_placeholders(self):
        self.assertEqual(forever_voice.tts_text("Hello $N.$B$BThanks, $Gsir:madam;!"), "Hello adventurer. Thanks, sir!")
        self.assertEqual(forever_voice.tts_text("Hi $n", player="friend"), "Hi friend")


class AuctionExportTests(unittest.TestCase):
    def test_collect_from_saved_variables(self):
        tmp = Path(tempfile.mkdtemp())
        try:
            sv = tmp / "ForeverGuide.lua"
            sv.write_text('''ForeverGuideDB = {
["auction"] = {
["houses"] = { ["faction"] = { ["items"] = {
[2589] = { ["name"] = "Linen Cloth", ["v"] = 13, ["m"] = 85, ["min"] = 70, ["h"] = 90, ["q"] = 400, ["n"] = 20, ["sr"] = 0.42, ["srN"] = 50, ["t"] = 1700000000 },
[2770] = { ["name"] = "Copper Ore", ["v"] = 5, ["m"] = 140, ["t"] = 1700000000 },
}, ["prev"] = {} } },
["sales"] = { { ["item"] = "Linen Cloth", ["price"] = 1700, ["net"] = 1615, ["t"] = 1700000000 }, },
["soldByHour"] = { [19] = 4, [20] = 2 },
},
}''', encoding="utf-8")
            data = forever_ah.collect([sv])
            items = data["houses"]["faction"]
            self.assertEqual([x["id"] for x in items], [2770, 2589])
            self.assertEqual(items[1]["saleRate"], 0.42)
            self.assertEqual(data["sales"][0]["net"], 1615)
            self.assertEqual(data["soldByHour"]["19"], 4)
        finally:
            shutil.rmtree(tmp)


if __name__ == "__main__":
    unittest.main()
