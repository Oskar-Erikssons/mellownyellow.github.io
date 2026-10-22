// Run from the forever/ folder: node --test tests/app.test.js
const test = require("node:test");
const assert = require("node:assert");
const FG = require("../app.js");

const MAGE = "FG1&class=MAGE&race=Gnome&lvl=20&str=20&agi=25&sta=40&int=90&spi=70&hp=600&mana=1200&crit=3.00&scrit=5.00&sp=20&heal=0&hit=0&shit=0&mh=10.0-20.0@2.50&spells=Fireball:d:100:130:8:8:3:0:110;Fire Blast:d:60:75:0:0:0:8:75";
const WARRIOR = "FG1&class=WARRIOR&race=Human&lvl=60&str=300&agi=150&sta=250&int=30&spi=50&ap=900&crit=20&hit=5&mh=150.0-250.0@3.60&spells=";

test("parses the addon export", () => {
  const s = FG.parseExport(MAGE);
  assert.equal(s.class, "MAGE");
  assert.equal(s.level, 20);
  assert.equal(s.spellCrit, 5);
  assert.deepEqual(s.mh, { min: 10, max: 20, speed: 2.5 });
  assert.equal(s.spells.length, 2);
  assert.equal(s.spells[0].cast, 3);
});

test("Undead from the Battle.net API maps to the Scourge token", () => {
  assert.equal(FG.parseExport("FG1&class=MAGE&race=Undead").race, "Scourge");
});

test("rejects text that is not an export", () => {
  assert.throws(() => FG.parseExport("hello"));
});

test("simulator ranks Fireball first and gives positive stat weights", () => {
  const r = FG.runSim(FG.parseExport(MAGE));
  assert.equal(r.results[0].spell.name, "Fireball");
  assert.ok(r.weights.sp10 > 0 && r.weights.crit1 > 0);
});

test("hit and crit help melee, bosses hurt it", () => {
  const s = FG.parseExport(WARRIOR);
  const even = FG.meleeDPS(s);
  // 5 % hit is already the cap vs. an equal-level target, so test hit against a boss.
  assert.equal(FG.meleeDPS(s, { extraHit: 1 }), even);
  assert.ok(FG.meleeDPS(s, { extraHit: 1, targetDiff: 3 }) > FG.meleeDPS(s, { targetDiff: 3 }));
  assert.ok(FG.meleeDPS(s, { targetDiff: 3 }) < even);
});

test("race comparison lists only allowed races and marks the current one", () => {
  const cmp = FG.compareRaces(FG.parseExport(WARRIOR), { weapon: "sword", targetDiff: 3 });
  assert.equal(cmp.source, "melee");
  assert.equal(cmp.rows.length, 8);
  const human = cmp.rows.find((r) => r.id === "Human");
  assert.ok(human.current);
  assert.ok(Math.abs(human.change) < 1e-9);
  // Sword specialization should make Human beat Night Elf with a sword against a boss.
  assert.ok(human.value > cmp.rows.find((r) => r.id === "NightElf").value);
  const mage = FG.compareRaces(FG.parseExport(MAGE), {});
  assert.deepEqual(mage.rows.map((r) => r.id).sort(), ["Gnome", "Human", "Scourge", "Troll"]);
});

test("advisor respects faction and role", () => {
  const list = FG.scoreClasses({ role: "heal", faction: "Horde", focus: "pve", solo: "any", ease: "any", style: "any", hardcore: "no" });
  assert.ok(!list.some((c) => c.id === "PALADIN"));
  assert.equal(list[0].roles.includes("heal"), true);
  const races = FG.scoreRaces("SHAMAN", { faction: "Horde", focus: "pvp" });
  assert.deepEqual(races.map((r) => r.id).sort(), ["Orc", "Tauren", "Troll"]);
});

test("AH advice matches the shared cases", () => {
  for (const c of require("./ah_cases.json")) {
    assert.equal(FG.decideSale(c.item, { house: c.house }).action, c.action, c.name);
  }
});

test("vendor flips and money formatting", () => {
  const flips = FG.vendorFlips([{ id: 1, vendor: 500, min: 300 }, { id: 2, vendor: 100, min: 400 }, { id: 3, vendor: 900, min: 100 }]);
  assert.deepEqual(flips.map((x) => x.id), [3, 1]);
  assert.equal(FG.money(123456), "12g 34s 56c");
  assert.equal(FG.money(-250), "-2s 50c");
});

test("generated gamedata.js is in sync with data/gamedata.json", () => {
  const data = require("../gamedata.js");
  const src = JSON.parse(require("fs").readFileSync(__dirname + "/../data/gamedata.json", "utf8"));
  assert.deepEqual({ ...data, changelog: undefined }, { ...src, changelog: undefined });
});

// A small made-up tree: tier 2 needs 5 points, "Deep" needs "Base" maxed.
const TREE = "FGT1&class=MAGE&tabs=Arcane|Fire|Frost&t=" + [
  "3:1:1:5:0:0:0:Base", "3:1:2:3:0:0:0:Side", "3:2:1:2:1:1:0:Deep", "3:2:2:1:0:0:0:Other", "1:1:1:2:0:0:1:Arc",
].join(";");

test("route covers every level once and stays in the faction", () => {
  for (const race of Object.keys(FG.RACES)) {
    const steps = FG.planRoute(race, FG.RACES[race].classes[0]);
    let next = 1;
    for (const st of steps) { assert.equal(st.from, next, race); next = st.to + 1; assert.ok(st.zones.length > 0, `${race} ${st.from}`); }
    assert.equal(next, 61);
    const fac = FG.RACES[race].faction;
    for (const st of steps) for (const z of st.zones) assert.ok(z.faction === "Both" || z.faction === fac);
  }
  assert.equal(FG.planRoute("Tauren", "DRUID")[0].zones[0].name, "Mulgore");
  assert.ok(FG.planRoute("Orc", "WARLOCK").some((s) => s.milestones.some((m) => m.text.includes("Voidwalker"))));
});

test("talent tree parsing and rules", () => {
  const t = FG.parseTalents(TREE);
  assert.deepEqual(t.tabs, ["Arcane", "Fire", "Frost"]);
  assert.equal(t.ranks.Arc, 1);
  const deep = t.talents.find((x) => x.name === "Deep");
  assert.match(FG.canAdd(t, {}, deep), /Kräver 5 poäng/);
  assert.match(FG.canAdd(t, { Side: 3, Base: 2 }, deep), /Base fullt/);
  assert.equal(FG.canAdd(t, { Base: 5 }, deep), null);
  assert.equal(FG.canRemove(t, { Base: 5, Deep: 1 }, t.talents[0]), false);
  assert.equal(FG.canRemove(t, { Base: 5, Side: 1, Deep: 1 }, t.talents[1]), true);
});

test("template schedule and problems", () => {
  const t = FG.parseTalents(TREE);
  const res = FG.applyTemplate(t, { picks: [["Base", 5], ["Deep", 2], ["Missing", 1], ["Other", 1]] }, 60);
  assert.deepEqual(res.schedule.map((p) => p.level), [10, 11, 12, 13, 14, 15, 16, 17]);
  assert.equal(res.ranks.Deep, 2);
  assert.deepEqual(res.problems, ["Missing finns inte i trädet"]);
  assert.equal(FG.applyTemplate(t, { picks: [["Base", 5]] }, 12).schedule.length, 3);
  for (const [cls, list] of Object.entries(FG.DATA.talentTemplates)) {
    const pts = list[0].picks.reduce((a, p) => a + p[1], 0);
    assert.ok(pts <= 51, `${cls} template uses ${pts} points`);
  }
});
