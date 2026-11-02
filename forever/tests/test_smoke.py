"""End-to-end smoke test: runs a whole play session of Forever Guide in a stand-in WoW client.

Loads every file in the order of ForeverGuide.toc, fires the events the game fires, runs every
slash command, opens every window and walks through the auction house. Any Lua error fails the test.

Run from the forever/ folder:  python -m unittest tests.test_smoke
"""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADDON = ROOT / "addon" / "ForeverGuide"

try:
    from lupa import lua51 as lupa
except ImportError:  # pragma: no cover
    lupa = None

COMMANDS = ["", "read", "stop", "auto on", "gossip on", "mode both", "rate 2", "volume 80", "voices", "voice female 1",
            "variety on", "sim", "export", "options", "ah", "bank", "find linen", "prof", "quick", "privacy", "selftest",
            "report", "atlas", "atlas export", "route", "talents", "talents export", "bags", "queue", "queue on",
            "house neutral", "tooltip on", "target 3", "sp off", "legacy off", "queue off", "bags off", "bags on"]


@unittest.skipIf(lupa is None, "pip install lupa to run the smoke test")
class SmokeTest(unittest.TestCase):
    def setUp(self):
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute((ROOT / "tests" / "wow_mock.lua").read_text(encoding="utf-8"))
        self.mock = self.lua.eval("MOCK")
        self.ns = self.lua.eval("{}")
        load = self.lua.eval("function(src, name) return assert(loadstring(src, name)) end")
        toc = (ADDON / "ForeverGuide.toc").read_text(encoding="utf-8")
        files = [l.strip() for l in toc.splitlines() if l.strip().endswith(".lua")]
        self.assertGreater(len(files), 10)
        for name in files:
            load((ADDON / name).read_text(encoding="utf-8"), name)("ForeverGuide", self.ns)
        self.fire("ADDON_LOADED", "ForeverGuide")
        self.fire("PLAYER_LOGIN")
        self.run_timers()

    def fire(self, event, *args):
        self.mock.Fire(event, *args)

    def run_timers(self):
        self.mock.RunTimers(50)

    def called(self, name):
        return self.mock.Called(name)

    def errors(self):
        printed = [str(m) for m in self.mock.printed.values()]
        logged = self.ns.db.errors
        return [m for m in printed if "Error in" in m] + ([str(e.msg) for e in logged.values()] if logged else [])

    def slash(self, text):
        self.lua.eval("SlashCmdList.FOREVERGUIDE")(text)
        self.run_timers()

    def test_login_and_every_command(self):
        self.assertTrue(any("loaded" in str(m) for m in self.mock.printed.values()))
        for cmd in COMMANDS:
            self.slash(cmd)
        self.assertEqual(self.errors(), [])
        self.assertGreater(self.called("SetCVar"), 0)  # smart spell queue applied
        selftest = self.ns.db.selftest
        self.assertEqual(len(selftest.missing), 0)

    def test_quests_gossip_books_and_voice(self):
        for event in ("QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE", "GOSSIP_SHOW", "QUEST_GREETING", "ITEM_TEXT_READY"):
            self.fire(event)
            self.run_timers()
        self.assertEqual(self.errors(), [])
        self.assertGreater(self.called("SpeakText"), 0)
        queue = self.ns.db.voiceQueue
        self.assertIn("d783", list(queue.keys()))
        self.assertIn("$N", queue["d783"].text)  # your name is stored as $N
        self.assertNotIn("Oskar", queue["d783"].text)

    def test_bags_bank_mail_trainer_professions_talents(self):
        self.lua.eval("ToggleAllBags")()
        self.run_timers()
        bags = self.ns.Bags
        self.assertTrue(bags.frame.shown)
        button = bags.buttons[0][1]
        self.assertEqual(button.GetBagID(button), 0)  # set through the attribute, as Blizzard does
        self.assertIn("Worth", str(bags.frame.footer.text))
        bags.query = "ah"
        bags.Refresh(bags)
        for event in ("BAG_UPDATE_DELAYED", "BANKFRAME_OPENED", "PLAYERBANKSLOTS_CHANGED", "BANKFRAME_CLOSED",
                      "MAIL_INBOX_UPDATE", "TRAINER_SHOW", "SKILL_LINES_CHANGED", "PLAYER_LEVEL_UP", "TRAIT_CONFIG_UPDATED",
                      "PLAYER_EQUIPMENT_CHANGED", "MERCHANT_SHOW"):
            self.fire(event)
            self.run_timers()
        self.assertEqual(self.errors(), [])
        me = self.ns.db.characters["Oskar Stormbringer"]
        self.assertEqual(me.bags[2589], 27)
        self.assertEqual(me.bank[2589], 40)
        self.assertEqual(len(self.ns.db.auction.sales), 1)
        trainer = self.ns.db.trainer.MAGE.spells
        self.assertEqual((trainer[2].name, trainer[2].level, trainer[2].known), ("Frost Nova", 22, False))
        talents = self.ns.Talents.Read(self.ns.Talents)
        self.assertEqual(len(talents.talents), 3)
        nxt = self.ns.Talents.Next(self.ns.Talents)
        self.assertEqual((nxt.name, nxt.rank), ("Improved Frostbolt", 3))
        self.assertTrue(str(self.ns.Talents.Export(self.ns.Talents)).startswith("FGT1&class=MAGE"))
        self.assertEqual(self.ns.Sim.Cooldown(102), 8)  # read from the spell tooltip
        # The merchant button sells grey items.
        self.ns.Auction.SellToVendor(self.ns.Auction)
        self.assertGreater(self.called("UseContainerItem"), 0)

    def test_auction_house_session(self):
        self.fire("AUCTION_HOUSE_SHOW")
        self.run_timers()
        market = self.ns.Market
        self.assertTrue(market.panel.shown)
        # Full scan, read in batches.
        self.ns.Auction.FullScan(self.ns.Auction)
        self.fire("REPLICATE_ITEM_LIST_UPDATE")
        self.run_timers()
        price = self.ns.Auction.Price(self.ns.Auction, 2589)
        self.assertIsNotNone(price)
        # Quick scan.
        self.ns.Auction.QuickScan(self.ns.Auction)
        self.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        self.run_timers()
        # Sell: Market searched the first item; answer it and post.
        market.SetTab(market, "sell")
        self.assertGreater(self.called("SendSearchQuery"), 0)
        self.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
        row = market.sell[1]
        # The scan says the market is 100, but someone lists at 31: Market holds the floor (70) and advises against it.
        self.assertEqual((row.price, row.reason, row.ok), (70, "dumped", False))
        # When the cheapest other seller is at 121, Market undercuts by 1 copper.
        self.mock.lowest = 120
        market.SetTab(market, "sell")
        self.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
        row = market.sell[1]
        self.assertEqual((row.price, row.reason, row.ok), (120, "under", True))
        market.Main(market)
        self.assertEqual(self.called("PostCommodity"), 1)
        args = self.mock.LastArgs("PostCommodity")
        self.assertEqual((args[2], args[3], args[4]), (3, 27, 120))  # 24 hours, all 27 in the bags, unit price
        # Market moved on to the next item (Tough Jerky) and asked for its price.
        self.assertEqual(market.sell[1].itemID, 117)
        self.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 117)
        self.mock.lowest = 30
        # Cancel: my auction at 40 is undercut by 31.
        market.SetTab(market, "cancel")
        self.fire("OWNED_AUCTIONS_UPDATED")
        self.fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
        self.assertEqual(len(market.undercut), 1)
        market.Main(market)
        self.assertEqual(self.called("CancelAuction"), 1)
        self.fire("AUCTION_HOUSE_CLOSED")
        self.assertEqual(self.errors(), [])

    def test_tooltips(self):
        post = self.mock.tooltipPost
        tip = self.lua.eval("GameTooltip")
        tip.GetItem = self.lua.eval("function() return 'Band of Wisdom', '|Hitem:1001::|h[Band of Wisdom]|h' end")
        post(tip, self.lua.table_from({"id": 1001}))
        post(tip, self.lua.table_from({"id": 2589}))
        self.assertEqual(self.errors(), [])


if __name__ == "__main__":
    unittest.main()
