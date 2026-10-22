// Forever Guide web: data and calculations. UI code lives in index.html.
// All numbers follow 2004-era (patch 1.12) rules. Treat results as estimates.
(function (root) {
  "use strict";

  // Game rules come from data/gamedata.json (via gamedata.js), so patch notes can update them without code changes.
  const DATA = typeof module !== "undefined" && module.exports ? require("./gamedata.js") : root.FOREVER_DATA;
  const { classes: CLASSES, races: RACES, raceFit: RACE_FIT, rates: RATES, combat: C, auction: AH } = DATA;

  const RACE_ALIASES = { Undead: "Scourge", "Night Elf": "NightElf" };

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

  function spellResult(spell, s, opt = {}) {
    const diff = opt.targetDiff || 0;
    const sp = (spell.kind === "heal" ? s.healing || 0 : s.sp || 0) + (opt.extraSP || 0);
    const crit = ((s.spellCrit || 0) + (opt.extraCrit || 0)) / 100;
    const hit = spell.kind === "heal" ? 1 : Math.min(0.99, 1 - Math.max(1, C.spellMiss[diff] - (s.spellHit || 0)) / 100);
    const cast = Math.max(spell.cast, C.gcd) / (opt.haste || 1);
    const direct = (spell.min + spell.max) / 2;
    let cDirect = Math.min(1, Math.max(spell.cast, C.gcd) / 3.5);
    let cDot = Math.min(1, (spell.dur || 0) / 15);
    if (direct > 0 && spell.dot > 0) { cDirect *= 0.5; cDot *= 0.5; }
    if (opt.tooltipIncludesSP) { cDirect = 0; cDot = 0; }
    let perCast = 0;
    if (direct > 0) perCast = (direct + sp * cDirect) * (1 + crit * (C.spellCritMult - 1));
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
    const miss = Math.max(0, C.meleeMiss[diff] + (dualWield ? C.dualWieldMiss : 0) - (s.hit || 0) - hitBonus) / 100;
    const dodge = (5 + diff * 0.5) / 100;
    const gc = C.glanceChance[diff];
    const gm = opt.glanceMult ?? C.glanceMult[diff];
    const landed = Math.max(0, 1 - miss - dodge - gc);
    const crit = Math.min(critPct / 100, landed);
    return (landed - crit) + C.meleeCritMult * crit + gc * gm;
  }

  function meleeDPS(s, opt = {}) {
    if (!s.mh) return 0;
    const apBonus = (opt.extraAP || 0) / C.apPerDps;
    const mult = attackTable(s, opt, (s.crit || 0) + (opt.extraCrit || 0), opt.extraHit || 0, !!s.oh) * (opt.haste || 1);
    const hand = (h, m) => h ? ((h.min + h.max) / 2 + apBonus * h.speed) / h.speed * m * mult : 0;
    return hand(s.mh, 1) + hand(s.oh, 0.5);
  }

  function rangedDPS(s, opt = {}) {
    if (!s.ranged) return 0;
    const h = s.ranged;
    const crit = (s.rangedCrit ?? s.crit ?? 0) + (opt.extraCrit || 0) + (opt.rangedCritBonus || 0);
    const diff = opt.targetDiff || 0;
    const miss = Math.max(0, C.meleeMiss[diff] - (s.hit || 0) - (opt.extraHit || 0)) / 100;
    const landed = 1 - miss;
    const c = Math.min(crit / 100, landed);
    const avg = (h.min + h.max) / 2 + (opt.extraRAP || 0) / C.apPerDps * h.speed;
    return avg / h.speed * ((landed - c) + C.meleeCritMult * c) * (opt.haste || 1);
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
      o.extraHit = C.weaponSkillHit[diff];
      if (diff >= 3) o.glanceMult = C.weaponSkillBossGlanceMult;
    }
    if ((r.rangedCrit || []).includes(opt.rangedWeapon)) o.rangedCritBonus = 1;
    return o;
  }

  // Cooldown racials averaged over a long fight.
  function racialFactor(s, r, classId, source, opt) {
    let f = 1;
    if (r.berserking) f *= 1 + C.berserkingHaste * C.berserkingUptime;
    if (r.bloodFury && source !== "spell") {
      const baseAP = (s.level || 60) * RATES[classId].baseAP;
      const total = Math.max(1, source === "ranged" ? (s.rap || s.ap || 1) : (s.ap || 1));
      // More base AP part of the time; AP is roughly a third of melee damage.
      f *= 1 + (C.bloodFuryBaseAP * baseAP / total) * C.bloodFuryUptime * 0.35;
    }
    return f;
  }

  // ---------- Auction house: sell to a vendor or on the AH? ----------

  // item: { vendor, market, saleRate, count, bound } in copper per item.
  // opt: { house: "faction" | "neutral", duration: "2" | "8" | "24" }
  function decideSale(item, opt = {}) {
    const house = opt.house || "faction";
    const duration = opt.duration || AH.defaultDuration;
    const count = item.count || 1;
    const vendorTotal = (item.vendor || 0) * count;
    if (item.bound) {
      return { action: vendorTotal > 0 ? "vendor" : "keep", vendorTotal, reason: "Bundet till dig, kan inte säljas på AH." };
    }
    if (!item.market) {
      return { action: vendorTotal > 0 ? "vendor" : "keep", vendorTotal, reason: "Inget AH-pris ännu. Skanna auktionshuset." };
    }
    const sr = item.saleRate ?? AH.defaultSaleRate;
    const deposit = (item.vendor || 0) * count * AH.deposit[house][duration];
    const net = item.market * count * (1 - AH.cut[house]);
    // List up to AH.relists times. Each failed listing loses the deposit; if it never sells, vendor it.
    const fail = 1 - sr;
    let lost = 0;
    for (let i = 1; i <= AH.relists; i++) lost += fail ** i;
    const ahEV = (1 - fail ** AH.relists) * net - lost * deposit + fail ** AH.relists * vendorTotal;
    const gain = ahEV - vendorTotal;
    const needed = Math.max(AH.minProfitCopper, vendorTotal * AH.ahMargin);
    const action = gain > needed ? "ah" : vendorTotal > 0 ? "vendor" : "ah";
    const reason = action === "ah"
      ? `AH ger i snitt ${money(gain)} mer än handlaren.`
      : vendorTotal > 0 ? "Handlaren ger mer eller nästan lika mycket, utan risk." : "Handlaren köper den inte.";
    return { action, ahEV, vendorTotal, gain, deposit, net, saleRate: sr, reason };
  }

  // Auctions you can buy and sell straight to a vendor at a profit.
  function vendorFlips(items) {
    return items
      .filter((x) => x.vendor > 0 && x.min > 0 && x.min < x.vendor)
      .map((x) => ({ ...x, profit: x.vendor - x.min }))
      .sort((a, b) => b.profit - a.profit);
  }

  function money(copper) {
    const c = Math.round(Math.abs(copper || 0));
    const g = Math.floor(c / 10000), s = Math.floor((c % 10000) / 100), k = c % 100;
    const parts = [];
    if (g) parts.push(`${g}g`);
    if (s || g) parts.push(`${s}s`);
    parts.push(`${k}c`);
    return (copper < 0 ? "-" : "") + parts.join(" ");
  }

  const api = { DATA, CLASSES, RACES, RACE_FIT, RATES, decideSale, vendorFlips, money, scoreClasses, scoreRaces, parseExport, runSim, compareRaces, spellResult, meleeDPS, rangedDPS };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.ForeverGuide = api;
})(typeof window !== "undefined" ? window : globalThis);
