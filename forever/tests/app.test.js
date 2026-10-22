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
