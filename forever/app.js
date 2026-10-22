// Forever Guide web: data and calculations. UI code lives in index.html.
// All numbers follow 2004-era (patch 1.12) rules. Treat results as estimates.
(function (root) {
  "use strict";

  const CLASSES = {
    WARRIOR: { name: "Krigare", roles: ["tank", "dps"], style: ["melee"], solo: 2, easy: 2, demand: 5, pvp: 3, survive: 2,
      about: "Bäst tank i spelet och toppar skadan i raider med bra utrustning. Långsam och sårbar att levla solo, beroende av utrustning." },
    PALADIN: { name: "Paladin", roles: ["heal", "tank", "dps"], style: ["melee"], solo: 3, easy: 4, demand: 4, pvp: 3, survive: 5, faction: "Alliance",
      about: "Tålig hybrid med auror och välsignelser som alla grupper vill ha. Divine Shield gör den mycket säker i Hardcore. Bara Alliance." },
    SHAMAN: { name: "Shaman", roles: ["heal", "dps"], style: ["melee", "caster"], solo: 4, easy: 3, demand: 4, pvp: 4, survive: 3, faction: "Horde",
      about: "Totemer, helning och stora Windfury-träffar. Stark i PvP och efterfrågad som helare. Bara Horde." },
    HUNTER: { name: "Jägare", roles: ["dps"], style: ["ranged", "pet"], solo: 5, easy: 5, demand: 2, pvp: 4, survive: 5,
      about: "Lättast att levla solo tack vare husdjuret. Feign Death räddar livet. Få platser i raider." },
    ROGUE: { name: "Rogue", roles: ["dps"], style: ["melee"], solo: 3, easy: 3, demand: 3, pvp: 5, survive: 4,
      about: "Smyger, väljer sina strider och dominerar PvP med stun-lås. Hög skada i raider." },
    PRIEST: { name: "Präst", roles: ["heal", "dps"], style: ["caster"], solo: 3, easy: 3, demand: 5, pvp: 4, survive: 3,
      about: "Spelets bästa helare och alltid efterfrågad. Shadow-inriktning gör levlingen enklare. Varje ras har egna prästformler." },
    MAGE: { name: "Magiker", roles: ["dps"], style: ["caster"], solo: 4, easy: 3, demand: 4, pvp: 4, survive: 4,
      about: "Hög skada, AoE-farmning och gratis mat, vatten och portaler. Bra för guld." },
    WARLOCK: { name: "Warlock", roles: ["dps"], style: ["caster", "pet"], solo: 5, easy: 2, demand: 3, pvp: 5, survive: 4,
      about: "Demoner, DoTs och fear. Mycket stark solo och i PvP, men kräver mer att spela väl." },
    DRUID: { name: "Druid", roles: ["heal", "tank", "dps"], style: ["melee", "caster"], solo: 4, easy: 2, demand: 3, pvp: 3, survive: 4,
      about: "Kan allt: tank, helare, katt och moonkin. Reseform från nivå 30 gör utforskning lätt." },
  };

  // Base stat offsets relative to Human (1.12) and multipliers from racials.
  const RACES = {
    Human: { name: "Människa", faction: "Alliance", classes: ["WARRIOR", "PALADIN", "ROGUE", "PRIEST", "MAGE", "WARLOCK"],
      offset: [0, 0, 0, 0, 0], mult: { spi: 1.05 }, weaponSkill: ["sword", "mace"],
      racials: ["Perception: ser smygande fiender", "Sword/Mace Specialization: +5 vapenskicklighet", "The Human Spirit: +5 % Spirit", "Diplomacy: +10 % rykte"] },
    Dwarf: { name: "Dvärg", faction: "Alliance", classes: ["WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST"],
      offset: [2, -4, 3, -1, -1], rangedCrit: ["gun"],
      racials: ["Stoneform: tar bort gift, sjukdom och blödning, +10 % rustning", "Gun Specialization: +1 % crit med gevär", "Frost Resistance +10", "Find Treasure"] },
    NightElf: { name: "Nattalf", faction: "Alliance", classes: ["WARRIOR", "HUNTER", "ROGUE", "PRIEST", "DRUID"],
      offset: [-3, 5, -1, 0, 0],
      racials: ["Shadowmeld: osynlig när du står still", "Quickness: +1 % dodge", "Nature Resistance +10", "Wisp Spirit: snabbare som ande"] },
    Gnome: { name: "Gnom", faction: "Alliance", classes: ["WARRIOR", "ROGUE", "MAGE", "WARLOCK"],
      offset: [-5, 3, -1, 3, 0], mult: { int: 1.05 },
      racials: ["Escape Artist: bryter rotar och snaror", "Expansive Mind: +5 % Intellect", "Arcane Resistance +10", "Engineering Specialization: +15 Engineering"] },
    Orc: { name: "Orc", faction: "Horde", classes: ["WARRIOR", "HUNTER", "ROGUE", "SHAMAN", "WARLOCK"],
      offset: [3, -3, 2, -3, 2], weaponSkill: ["axe"], bloodFury: true,
      racials: ["Blood Fury: +25 % bas-AP i 15 s", "Hardiness: +25 % motstånd mot stun", "Command: +5 % skada för husdjur", "Axe Specialization: +5 vapenskicklighet"] },
    Scourge: { name: "Odöd", faction: "Horde", classes: ["WARRIOR", "ROGUE", "PRIEST", "MAGE", "WARLOCK"],
      offset: [-1, -2, 1, -2, 5],
      racials: ["Will of the Forsaken: bryter fear, charm och sleep", "Cannibalize: helar på lik", "Shadow Resistance +10", "Andas under vatten 4 gånger längre"] },
    Tauren: { name: "Tauren", faction: "Horde", classes: ["WARRIOR", "HUNTER", "SHAMAN", "DRUID"],
      offset: [5, -5, 2, -4, 2], mult: { hp: 1.05 },
      racials: ["War Stomp: stun på alla runt dig i 2 s", "Endurance: +5 % hälsa", "Nature Resistance +10", "Cultivation: +15 Herbalism"] },
    Troll: { name: "Troll", faction: "Horde", classes: ["WARRIOR", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE"],
      offset: [1, 2, 1, -4, 1], berserking: true, rangedCrit: ["bow", "thrown"],
      racials: ["Berserking: 10-30 % snabbare attacker och kast i 10 s", "Regeneration: +10 % hälsoåterhämtning", "Beast Slaying: +5 % skada mot djur", "Bow/Throwing Specialization: +1 % crit"] },
  };

  // How much each race helps a class, per goal (0-5). Missing = 3.
  const RACE_FIT = {
    WARRIOR: { pve: { Human: 5, Orc: 5, Troll: 4, Dwarf: 4, Tauren: 3, NightElf: 3, Scourge: 3, Gnome: 2 },
               pvp: { Orc: 5, Scourge: 5, Human: 4, Tauren: 4, Gnome: 4, Dwarf: 4, Troll: 3, NightElf: 2 } },
    PALADIN: { pve: { Human: 5, Dwarf: 4 }, pvp: { Dwarf: 5, Human: 4 } },
    HUNTER: { pve: { Troll: 5, Orc: 5, Dwarf: 4, NightElf: 4, Tauren: 3 }, pvp: { NightElf: 5, Orc: 5, Dwarf: 4, Troll: 4, Tauren: 4 } },
    ROGUE: { pve: { Human: 5, Orc: 5, Troll: 4, Gnome: 3, Dwarf: 4, NightElf: 3, Scourge: 3 }, pvp: { Scourge: 5, Human: 5, Gnome: 4, Orc: 4, NightElf: 4, Dwarf: 4, Troll: 3 } },
    PRIEST: { pve: { Dwarf: 5, Human: 4, Troll: 4, Scourge: 4, NightElf: 3 }, pvp: { Scourge: 5, Dwarf: 5, Human: 4, Troll: 4, NightElf: 3 } },
    SHAMAN: { pve: { Troll: 5, Orc: 4, Tauren: 4 }, pvp: { Orc: 5, Tauren: 5, Troll: 4 } },
    MAGE: { pve: { Troll: 5, Gnome: 5, Human: 4, Scourge: 4 }, pvp: { Scourge: 5, Gnome: 5, Human: 4, Troll: 4 } },
    WARLOCK: { pve: { Gnome: 5, Human: 4, Orc: 5, Scourge: 4 }, pvp: { Scourge: 5, Orc: 5, Gnome: 5, Human: 4 } },
    DRUID: { pve: { Tauren: 4, NightElf: 4 }, pvp: { Tauren: 5, NightElf: 4 } },
  };

  // Level 60 conversion rates (1.12). Lower levels need fewer points per %, so this understates there.
  const RATES = {
    WARRIOR: { apStr: 2, apAgi: 0, rapAgi: 1, agiCrit: 20, intCrit: 0, baseAP: 3 },
    PALADIN: { apStr: 2, apAgi: 0, rapAgi: 0, agiCrit: 20, intCrit: 54, baseAP: 3 },
    SHAMAN: { apStr: 2, apAgi: 0, rapAgi: 0, agiCrit: 20, intCrit: 59.5, baseAP: 3 },
    DRUID: { apStr: 2, apAgi: 0, rapAgi: 0, agiCrit: 20, intCrit: 60, baseAP: 3 },
    ROGUE: { apStr: 1, apAgi: 1, rapAgi: 1, agiCrit: 29, intCrit: 0, baseAP: 2 },
    HUNTER: { apStr: 1, apAgi: 1, rapAgi: 2, agiCrit: 53, intCrit: 0, baseAP: 2 },
    PRIEST: { apStr: 1, apAgi: 0, rapAgi: 0, agiCrit: 20, intCrit: 59.2, baseAP: 1 },
    MAGE: { apStr: 1, apAgi: 0, rapAgi: 0, agiCrit: 20, intCrit: 59.5, baseAP: 1 },
    WARLOCK: { apStr: 1, apAgi: 0, rapAgi: 0, agiCrit: 20, intCrit: 60.6, baseAP: 1 },
  };

  const RACE_ALIASES = { Undead: "Scourge", NightElf: "NightElf", "Night Elf": "NightElf" };

  // ---------- Class and race advisor ----------

  // answers: { role, style, solo, focus, ease, faction, hardcore }
  function scoreClasses(a) {
    const out = [];
    for (const [id, c] of Object.entries(CLASSES)) {
      if (a.faction && a.faction !== "any" && c.faction && c.faction !== a.faction) continue;
      let score = 0;
      const why = [];
      if (a.role && a.role !== "any") {
        if (c.roles.includes(a.role)) { score += 6; why.push("passar rollen du vill ha"); }
        else score -= 6;
      }
      if (a.style && a.style !== "any") {
        if (c.style.includes(a.style)) { score += 5; why.push("har spelstilen du gillar"); }
        else score -= 3;
      }
      if (a.solo === "high") { score += (c.solo - 3) * 2; if (c.solo >= 4) why.push("lätt att levla solo"); }
      if (a.solo === "group") { score += c.demand - 3; if (c.demand >= 4) why.push("alltid efterfrågad i grupp"); }
      if (a.focus === "pvp") { score += (c.pvp - 3) * 2; if (c.pvp >= 5) why.push("mycket stark i PvP"); }
      if (a.focus === "pve") { score += c.demand - 3; }
      if (a.focus === "explore") { score += c.solo - 3 + (id === "DRUID" ? 2 : 0); if (id === "DRUID") why.push("reseform gör utforskning lätt"); }
      if (a.ease === "easy") { score += (c.easy - 3) * 2; if (c.easy >= 4) why.push("förlåtande för nybörjare"); }
      if (a.ease === "hard") { score += (3 - c.easy); if (c.easy <= 2) why.push("mycket att bemästra"); }
      if (a.hardcore === "yes") { score += (c.survive - 3) * 2; if (c.survive >= 5) why.push("har livräddande förmågor för Hardcore"); }
      out.push({ id, ...c, score, why });
    }
    return out.sort((x, y) => y.score - x.score);
  }

  function scoreRaces(classId, a) {
    const fit = RACE_FIT[classId] || {};
    const out = [];
    for (const [id, r] of Object.entries(RACES)) {
      if (!r.classes.includes(classId)) continue;
      if (a.faction && a.faction !== "any" && r.faction !== a.faction) continue;
      const pve = (fit.pve || {})[id] ?? 3;
      const pvp = (fit.pvp || {})[id] ?? 3;
      let score = a.focus === "pvp" ? pvp * 2 + pve : a.focus === "pve" ? pve * 2 + pvp : pve + pvp;
      if (a.hardcore === "yes" && ["Scourge", "Dwarf", "Gnome", "Tauren", "NightElf", "Orc"].includes(id)) score += 1;
      out.push({ id, ...r, pve, pvp, score });
    }
    return out.sort((x, y) => y.score - x.score);
  }

  // ---------- Import ----------

  function parseHand(v) {
    const m = /^([\d.]+)-([\d.]+)@([\d.]+)$/.exec(v || "");
    return m ? { min: +m[1], max: +m[2], speed: +m[3] } : null;
  }

  function parseExport(text) {
    text = (text || "").trim();
    if (!text.startsWith("FG1")) throw new Error("Texten ska börja med FG1. Skapa den med /fg export i spelet.");
    const s = { spells: [] };
    for (const part of text.split("&").slice(1)) {
      const i = part.indexOf("=");
      if (i < 0) continue;
      const k = part.slice(0, i), v = part.slice(i + 1);
      if (k === "class") s.class = v.toUpperCase();
      else if (k === "race") s.race = RACE_ALIASES[v] || v;
      else if (k === "mh" || k === "oh" || k === "rng") s[k === "rng" ? "ranged" : k] = parseHand(v);
      else if (k === "spells") {
        s.spells = v.split(";").filter(Boolean).map((row) => {
          const [name, kind, min, max, dot, dur, cast, cd, cost] = row.split(":");
          return { name, kind: kind === "h" ? "heal" : "damage", min: +min, max: +max, dot: +dot, dur: +dur, cast: +cast, cd: +cd, cost: +cost };
        });
      } else {
        const key = { lvl: "level", scrit: "spellCrit", heal: "healing", shit: "spellHit" }[k] || k;
        s[key] = parseFloat(v);
      }
    }
    return s;
  }

  // ---------- Simulator (same rules as the addon's Sim.lua) ----------

  const GCD = 1.5;
  const SPELL_MISS = [4, 5, 6, 17];
  const MELEE_MISS = [5, 5.5, 6, 8];
  const GLANCE_CHANCE = [0.1, 0.2, 0.3, 0.4];
  const GLANCE_MULT = [0.95, 0.95, 0.85, 0.65];

  function spellResult(spell, s, opt = {}) {
    const diff = opt.targetDiff || 0;
    const sp = (spell.kind === "heal" ? s.healing || 0 : s.sp || 0) + (opt.extraSP || 0);
    const crit = ((s.spellCrit || 0) + (opt.extraCrit || 0)) / 100;
    const hit = spell.kind === "heal" ? 1 : Math.min(0.99, 1 - Math.max(1, SPELL_MISS[diff] - (s.spellHit || 0)) / 100);
    const cast = Math.max(spell.cast, GCD) / (opt.haste || 1);
    const direct = (spell.min + spell.max) / 2;
    let cDirect = Math.min(1, Math.max(spell.cast, GCD) / 3.5);
    let cDot = Math.min(1, (spell.dur || 0) / 15);
    if (direct > 0 && spell.dot > 0) { cDirect *= 0.5; cDot *= 0.5; }
    if (opt.tooltipIncludesSP) { cDirect = 0; cDot = 0; }
    let perCast = 0;
    if (direct > 0) perCast = (direct + sp * cDirect) * (1 + crit * 0.5);
    if (spell.dot > 0) perCast += spell.dot + sp * cDot;
    perCast *= hit;
    const time = Math.max(cast, spell.cd || 0);
    return {
      spell, perCast, dps: perCast / time,
      dpm: spell.cost > 0 ? perCast / spell.cost : null,
      castsToOOM: spell.cost > 0 && s.mana ? Math.floor(s.mana / spell.cost) : null,
    };
  }

  function attackTable(s, opt, critPct, hitBonus, dualWield) {
    const diff = opt.targetDiff || 0;
    const miss = Math.max(0, MELEE_MISS[diff] + (dualWield ? 19 : 0) - (s.hit || 0) - hitBonus) / 100;
    const dodge = (5 + diff * 0.5) / 100;
    const gc = GLANCE_CHANCE[diff];
    const gm = opt.glanceMult ?? GLANCE_MULT[diff];
    const landed = Math.max(0, 1 - miss - dodge - gc);
    const crit = Math.min(critPct / 100, landed);
    return (landed - crit) + 2 * crit + gc * gm;
  }

  function meleeDPS(s, opt = {}) {
    if (!s.mh) return 0;
    const apBonus = (opt.extraAP || 0) / 14;
    const mult = attackTable(s, opt, (s.crit || 0) + (opt.extraCrit || 0), opt.extraHit || 0, !!s.oh) * (opt.haste || 1);
    const hand = (h, m) => h ? ((h.min + h.max) / 2 + apBonus * h.speed) / h.speed * m * mult : 0;
    return hand(s.mh, 1) + hand(s.oh, 0.5);
  }

  function rangedDPS(s, opt = {}) {
    if (!s.ranged) return 0;
    const h = s.ranged;
    const crit = (s.rangedCrit ?? s.crit ?? 0) + (opt.extraCrit || 0) + (opt.rangedCritBonus || 0);
    const diff = opt.targetDiff || 0;
    const miss = Math.max(0, MELEE_MISS[diff] - (s.hit || 0) - (opt.extraHit || 0)) / 100;
    const landed = 1 - miss;
    const c = Math.min(crit / 100, landed);
    const avg = (h.min + h.max) / 2 + (opt.extraRAP || 0) / 14 * h.speed;
    return avg / h.speed * ((landed - c) + 2 * c) * (opt.haste || 1);
  }

  function runSim(s, opt = {}) {
    const results = (s.spells || []).map((sp) => spellResult(sp, s, opt)).sort((a, b) => b.dps - a.dps);
    const melee = meleeDPS(s, opt);
    const ranged = rangedDPS(s, opt);
    const weights = {};
    const top = results.find((r) => r.spell.kind === "damage");
    if (top) {
      weights.sp10 = spellResult(top.spell, s, { ...opt, extraSP: 10 }).dps - top.dps;
      weights.crit1 = spellResult(top.spell, s, { ...opt, extraCrit: 1 }).dps - top.dps;
    }
    if (melee > 0) {
      weights.ap14 = meleeDPS(s, { ...opt, extraAP: 14 }) - melee;
      weights.meleeCrit1 = meleeDPS(s, { ...opt, extraCrit: 1 }) - melee;
      weights.hit1 = meleeDPS(s, { ...opt, extraHit: 1 }) - melee;
    }
    return { results, melee, ranged, topSpell: top || null, weights };
  }

  // Which number a class is judged on in the race comparison.
  function primarySource(classId, sim) {
    if (classId === "HUNTER" && sim.ranged > 0) return "ranged";
    if (["MAGE", "WARLOCK", "PRIEST"].includes(classId) && sim.topSpell) return "spell";
    if (sim.melee > 0) return "melee";
    if (sim.topSpell) return "spell";
    return sim.ranged > 0 ? "ranged" : null;
  }

  function primaryValue(source, sim) {
    return source === "melee" ? sim.melee : source === "ranged" ? sim.ranged : source === "spell" ? (sim.topSpell ? sim.topSpell.dps : 0) : 0;
  }

  // Same gear, another race: swap base stats and racials, then re-run.
  // opt.weapon: sword|mace|axe|dagger|fist|other, opt.rangedWeapon: bow|gun|thrown|crossbow|other
  function compareRaces(s, opt = {}) {
    const classId = s.class;
    const rates = RATES[classId];
    const from = RACES[s.race];
    if (!rates || !from) return null;
    const source = primarySource(classId, runSim(s, opt));
    if (!source) return null;

    const keys = ["str", "agi", "sta", "int", "spi"];
    const raw = keys.map((k, i) => (s[k] || 0) / ((from.mult || {})[k] || 1) - from.offset[i]);

    const rows = [];
    for (const [id, r] of Object.entries(RACES)) {
      if (!r.classes.includes(classId)) continue;
      const t = { ...s, race: id };
      const d = {};
      keys.forEach((k, i) => {
        t[k] = (raw[i] + r.offset[i]) * ((r.mult || {})[k] || 1);
        d[k] = t[k] - (s[k] || 0);
      });
      t.ap = (s.ap || 0) + d.str * rates.apStr + d.agi * rates.apAgi;
      t.crit = (s.crit || 0) + d.agi / rates.agiCrit;
      if (s.rangedCrit != null) t.rangedCrit = s.rangedCrit + d.agi / rates.agiCrit;
      if (rates.intCrit) t.spellCrit = (s.spellCrit || 0) + d.int / rates.intCrit;
      if (s.mana) t.mana = s.mana + d.int * 15;
      const apDelta = t.ap - (s.ap || 0);
      const rapDelta = d.agi * rates.rapAgi;
      const sim = runSim(t, { ...opt, extraAP: apDelta, extraRAP: rapDelta, ...weaponSkillOpt(r, opt) });
      const value = primaryValue(source, sim) * racialFactor(t, r, classId, source, opt);
      rows.push({ id, name: r.name, faction: r.faction, value, racials: r.racials, current: id === s.race });
    }
    // Compare against the current race computed the same way, so both sides get their racials.
    const baseValue = rows.find((x) => x.current).value;
    for (const row of rows) row.change = baseValue ? (row.value / baseValue - 1) * 100 : 0;
    return { source, baseValue, rows: rows.sort((a, b) => b.value - a.value) };
  }

  function weaponSkillOpt(r, opt) {
    const o = {};
    const diff = opt.targetDiff || 0;
    if ((r.weaponSkill || []).includes(opt.weapon)) {
      // +5 skill: fewer misses and much milder glancing blows against bosses.
      o.extraHit = diff >= 3 ? 2 : 0.5;
      if (diff >= 3) o.glanceMult = 0.85;
    }
    if ((r.rangedCrit || []).includes(opt.rangedWeapon)) o.rangedCritBonus = 1;
    return o;
  }

  // Cooldown racials averaged over a long fight.
  function racialFactor(s, r, classId, source, opt) {
    let f = 1;
    if (r.berserking) f *= 1 + 0.10 * 10 / 180;
    if (r.bloodFury && source !== "spell") {
      const baseAP = (s.level || 60) * RATES[classId].baseAP;
      const total = Math.max(1, source === "ranged" ? (s.rap || s.ap || 1) : (s.ap || 1));
      // 25 % more base AP for 15 of every 120 seconds, AP is roughly a third of melee damage.
      f *= 1 + (0.25 * baseAP / total) * (15 / 120) * 0.35;
    }
    return f;
  }

  const api = { CLASSES, RACES, RACE_FIT, RATES, scoreClasses, scoreRaces, parseExport, runSim, compareRaces, spellResult, meleeDPS, rangedDPS };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.ForeverGuide = api;
})(typeof window !== "undefined" ? window : globalThis);
