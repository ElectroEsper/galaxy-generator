//! Empire personality: seven trait axes (aggression ... intervention, 0..1, 0.5 = neutral) that weight the planner,
//! drift yearly back toward the regime's values, shift with events, and occasionally jump in a regime change.
//!
//! Personalities are data, built from pluggable **trait blocks**. A block (e.g. Militarist, Xenophile, Revanchist)
//! pushes the axes (which feed every decision that reads them: war goals, treaties, crises, trade, alliances,
//! drift) and multiplies named **effects** at specific decisions (attack threshold, crisis spine, backing, honouring
//! pacts, grudges, tariffs, army budget, regime stability...). A personality (archetype) is a set of blocks.
//! Blocks in the same `group` are mutually exclusive (Xenophobe / Xenophile), and a block can list others it
//! `excludes`. Everything loads from JSON, so the in-game editor can build new blocks and personalities.

use crate::rng::Rng;
use crate::world::World;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Named decision modifiers a trait block can scale (all multiplicative, 1.0 = no change).
pub const EFFECTS: [&str; 13] = [
    "attack_ratio",     // strength ratio wanted before attacking
    "peace_exhaustion", // war exhaustion at which it wants peace
    "spine",            // how outmatched it must be before conceding a demand
    "backing",          // chance to back a side in someone else's crisis
    "call_to_arms",     // chance to honour a pact or guarantee when a partner is attacked
    "mediation",        // willingness to mediate crises
    "pact_trust",       // trust it requires before signing a pact
    "tariff",           // tariffs it charges on imports
    "army_budget",      // share of income spent on the army
    "grudge",           // revanchism gained from a lost war
    "grudge_fade",      // how fast revanchism fades
    "drift",            // yearly random drift of its axes
    "regime_change",    // chance of a regime change
];
pub const FX_ATTACK_RATIO: usize = 0;
pub const FX_PEACE_EXHAUSTION: usize = 1;
pub const FX_SPINE: usize = 2;
pub const FX_BACKING: usize = 3;
pub const FX_CALL_TO_ARMS: usize = 4;
pub const FX_MEDIATION: usize = 5;
pub const FX_PACT_TRUST: usize = 6;
pub const FX_TARIFF: usize = 7;
pub const FX_ARMY_BUDGET: usize = 8;
pub const FX_GRUDGE: usize = 9;
pub const FX_GRUDGE_FADE: usize = 10;
pub const FX_DRIFT: usize = 11;
pub const FX_REGIME: usize = 12;
pub const NFX: usize = 13;

/// A pluggable trait block.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct TraitBlock {
    /// Stable identifier used by personalities (e.g. "militarist").
    pub id: String,
    pub name: String,
    pub description: String,
    /// At most one block per group in a personality ("" = no group).
    pub group: String,
    /// Other block ids it cannot be combined with.
    pub excludes: Vec<String>,
    /// Axis name -> amount added to the neutral 0.5.
    pub axes: BTreeMap<String, f64>,
    /// Effect name -> multiplier.
    pub effects: BTreeMap<String, f64>,
    /// Relative chance of being adopted in a regime reform (0 = never).
    pub weight: f64,
}

impl Default for TraitBlock {
    fn default() -> Self {
        TraitBlock { id: "new_trait".into(), name: "New trait".into(), description: String::new(), group: String::new(), excludes: vec![], axes: BTreeMap::new(), effects: BTreeMap::new(), weight: 1.0 }
    }
}

/// A personality an empire can be founded with (or switch to in a regime change): a set of trait blocks.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Archetype {
    pub name: String,
    pub description: String,
    /// Relative chance of being picked; 0 = never picked at random.
    pub weight: f64,
    /// Trait block ids.
    pub blocks: Vec<String>,
    /// Random spread of each axis around the blocks' values (empires of one personality still differ).
    pub spread: f64,
    /// Government stability range: low stability drifts more and is likelier to have a crisis regime change.
    pub stability: [f64; 2],
}

impl Default for Archetype {
    fn default() -> Self {
        Archetype { name: "New personality".into(), description: String::new(), weight: 1.0, blocks: vec![], spread: 0.1, stability: [0.3, 0.9] }
    }
}

/// Drift and regime-change rules (all editable).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Rules {
    pub drift: f64,
    pub revert: f64,
    pub regime_base: f64,
    pub regime_crisis: f64,
    pub regime_jump: f64,
    /// Years (a float, since JSON from Godot has no integers).
    pub regime_cooldown: f64,
    /// Chance that a regime change adopts a new archetype (otherwise the old regime's values jump).
    pub regime_switch: f64,
    pub trade_drift: f64,
    pub incident_drift: f64,
}

impl Default for Rules {
    fn default() -> Self {
        Rules {
            drift: DRIFT,
            revert: REVERT,
            regime_base: REGIME_BASE,
            regime_crisis: REGIME_CRISIS,
            regime_jump: REGIME_JUMP,
            regime_cooldown: REGIME_COOLDOWN as f64,
            regime_switch: 0.5,
            trade_drift: TRADE_DRIFT,
            incident_drift: INCIDENT_DRIFT,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Book {
    pub blocks: Vec<TraitBlock>,
    pub archetypes: Vec<Archetype>,
    pub rules: Rules,
}

impl Default for Book {
    fn default() -> Self {
        Book::builtin()
    }
}

fn block(id: &str, name: &str, group: &str, desc: &str, axes: &[(&str, f64)], fx: &[(&str, f64)]) -> TraitBlock {
    TraitBlock {
        id: id.into(),
        name: name.into(),
        description: desc.into(),
        group: group.into(),
        excludes: vec![],
        axes: axes.iter().map(|&(n, v)| (n.to_string(), v)).collect(),
        effects: fx.iter().map(|&(n, v)| (n.to_string(), v)).collect(),
        weight: 1.0,
    }
}

fn arch(name: &str, desc: &str, weight: f64, stab: [f64; 2], blocks: &[&str]) -> Archetype {
    Archetype { name: name.into(), description: desc.into(), weight, blocks: blocks.iter().map(|b| b.to_string()).collect(), spread: 0.1, stability: stab }
}

impl Book {
    pub fn builtin() -> Book {
        let mut blocks = vec![
            block("militarist", "Militarist", "war", "Glory in arms; spends heavily on the army.", &[("aggression", 0.2), ("militarism", 0.3)], &[("army_budget", 1.3), ("attack_ratio", 0.9)]),
            block("pacifist", "Pacifist", "war", "War is a last resort and quickly regretted.", &[("aggression", -0.25), ("militarism", -0.2)], &[("attack_ratio", 1.3), ("peace_exhaustion", 0.7), ("army_budget", 0.8)]),
            block("expansionist", "Expansionist", "expansion", "Always looking for new land.", &[("expansion", 0.3)], &[]),
            block("consolidator", "Consolidator", "expansion", "Develops what it has.", &[("expansion", -0.25), ("caution", 0.1)], &[]),
            block("xenophobe", "Xenophobe", "xeno", "Distrusts and taxes outsiders.", &[("xenophobia", 0.35)], &[("pact_trust", 1.3), ("tariff", 1.5)]),
            block("xenophile", "Xenophile", "xeno", "Curious about and open to others.", &[("xenophobia", -0.3)], &[("pact_trust", 0.8), ("tariff", 0.7)]),
            block("mercantile", "Mercantile", "trade", "Trade is the lifeblood of the state.", &[("mercantile", 0.3)], &[("tariff", 0.8), ("grudge_fade", 1.3)]),
            block("autarkic", "Autarkic", "trade", "Self-reliance first; protects its markets.", &[("mercantile", -0.3)], &[("tariff", 1.3)]),
            block("interventionist", "Interventionist", "intervention", "Keeps the galactic peace, by force if needed.", &[("intervention", 0.35)], &[("backing", 1.4), ("mediation", 1.5), ("call_to_arms", 1.2)]),
            block("isolationist", "Isolationist", "intervention", "Other empires' quarrels are not its business.", &[("intervention", -0.3)], &[("backing", 0.5), ("call_to_arms", 0.7), ("mediation", 0.5)]),
            block("cautious", "Cautious", "risk", "Weighs every risk twice.", &[("caution", 0.3)], &[("spine", 0.9)]),
            block("reckless", "Reckless", "risk", "Acts first, counts later.", &[("caution", -0.3)], &[("attack_ratio", 0.85), ("spine", 1.15)]),
            block("honourable", "Honourable", "", "Keeps its word to allies.", &[], &[("call_to_arms", 1.3)]),
            block("opportunist", "Opportunist", "", "Joins whichever side is winning.", &[("aggression", 0.05)], &[("backing", 1.2), ("call_to_arms", 0.7)]),
            block("revanchist", "Revanchist", "memory", "Never forgets a lost province.", &[], &[("grudge", 1.6), ("grudge_fade", 0.6)]),
            block("forgiving", "Forgiving", "memory", "Lets old wounds heal.", &[], &[("grudge", 0.6), ("grudge_fade", 1.5)]),
            block("stable", "Stable", "government", "Steady institutions.", &[], &[("drift", 0.5), ("regime_change", 0.5)]),
            block("unstable", "Unstable", "government", "Coups, purges and sudden turns.", &[], &[("drift", 1.6), ("regime_change", 2.0)]),
        ];
        // Ungrouped exclusions (grouped blocks already exclude each other).
        blocks.iter_mut().find(|b| b.id == "honourable").unwrap().excludes = vec!["opportunist".into()];
        blocks.iter_mut().find(|b| b.id == "opportunist").unwrap().excludes = vec!["honourable".into()];
        Book {
            blocks,
            archetypes: vec![
                arch("Balanced", "No strong leanings.", 2.0, [0.3, 0.9], &[]),
                arch("Warlike Expansionists", "Grab land, fight for it.", 1.0, [0.3, 0.8], &["militarist", "expansionist", "reckless"]),
                arch("Merchant Republic", "Trade first; war is bad for business.", 1.0, [0.5, 0.9], &["mercantile", "xenophile", "pacifist"]),
                arch("Isolationists", "Keep to themselves and distrust outsiders.", 1.0, [0.4, 0.9], &["xenophobe", "isolationist", "consolidator", "cautious"]),
                arch("Peacekeepers", "Mediate, guarantee the small, stop wars.", 1.0, [0.5, 0.9], &["interventionist", "honourable", "pacifist"]),
                arch("Military Junta", "Armed to the teeth and unstable.", 0.7, [0.1, 0.5], &["militarist", "unstable", "opportunist"]),
                arch("Cautious Bureaucracy", "Slow, steady, risk-averse.", 0.8, [0.6, 0.95], &["cautious", "stable", "consolidator"]),
                arch("Wounded Empire", "Remembers every humiliation.", 0.5, [0.3, 0.7], &["revanchist", "militarist", "xenophobe"]),
            ],
            rules: Rules::default(),
        }
    }

    pub fn block_index(&self, id: &str) -> Option<usize> {
        self.blocks.iter().position(|b| b.id == id)
    }

    /// Can block `i` join the set `set` (block indices)? Same group or an exclusion in either direction says no.
    pub fn compatible(&self, i: usize, set: &[usize]) -> bool {
        let b = &self.blocks[i];
        set.iter().all(|&j| {
            let o = &self.blocks[j];
            j != i && (b.group.is_empty() || b.group != o.group) && !b.excludes.contains(&o.id) && !o.excludes.contains(&b.id)
        })
    }

    /// Why a set of block ids can't form one personality, if it can't.
    pub fn conflict(&self, ids: &[String]) -> Option<String> {
        let mut set: Vec<usize> = vec![];
        for id in ids {
            let i = self.block_index(id).ok_or_else(|| format!("unknown trait block '{}'", id)).ok()?;
            if !self.compatible(i, &set) {
                let other = set.iter().map(|&j| &self.blocks[j]).find(|o| !self.compatible(i, &[self.block_index(&o.id).unwrap()])).unwrap();
                return Some(format!("{} and {} cannot be combined", self.blocks[i].name, other.name));
            }
            set.push(i);
        }
        None
    }

    /// Axis values (0.5 + the blocks' pushes) and effect multipliers of a block set.
    pub fn profile(&self, set: &[usize]) -> ([f64; 7], [f64; NFX]) {
        let mut ax = [0.5; 7];
        let mut fx = [1.0; NFX];
        for &i in set {
            let b = &self.blocks[i];
            for (k, v) in &b.axes {
                if let Some(t) = NAMES.iter().position(|n| n == k) {
                    ax[t] += v;
                }
            }
            for (k, v) in &b.effects {
                if let Some(f) = EFFECTS.iter().position(|n| n == k) {
                    fx[f] *= v;
                }
            }
        }
        (ax, fx)
    }

    pub fn from_json(s: &str) -> Result<Book, String> {
        let b: Book = serde_json::from_str(s).map_err(|e| e.to_string())?;
        b.validate()?;
        Ok(b)
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap()
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.archetypes.is_empty() {
            return Err("at least one personality is needed".into());
        }
        if self.archetypes.iter().all(|a| a.weight <= 0.0) {
            return Err("at least one personality needs a weight above 0".into());
        }
        let mut seen = std::collections::BTreeSet::new();
        for b in &self.blocks {
            if !seen.insert(b.id.clone()) {
                return Err(format!("two trait blocks share the id '{}'", b.id));
            }
            for k in b.axes.keys() {
                if !NAMES.contains(&k.as_str()) {
                    return Err(format!("{}: unknown axis '{}' (axes: {})", b.name, k, NAMES.join(", ")));
                }
            }
            for k in b.effects.keys() {
                if !EFFECTS.contains(&k.as_str()) {
                    return Err(format!("{}: unknown effect '{}' (effects: {})", b.name, k, EFFECTS.join(", ")));
                }
            }
        }
        for a in &self.archetypes {
            for id in &a.blocks {
                if self.block_index(id).is_none() {
                    return Err(format!("{}: unknown trait block '{}'", a.name, id));
                }
            }
            if let Some(c) = self.conflict(&a.blocks) {
                return Err(format!("{}: {}", a.name, c));
            }
        }
        Ok(())
    }

    /// Weighted random pick.
    pub fn pick(&self, rng: &mut Rng) -> usize {
        let total: f64 = self.archetypes.iter().map(|a| a.weight.max(0.0)).sum();
        let mut x = rng.randf() * total;
        for (i, a) in self.archetypes.iter().enumerate() {
            x -= a.weight.max(0.0);
            if x < 0.0 && a.weight > 0.0 {
                return i;
            }
        }
        self.archetypes.iter().rposition(|a| a.weight > 0.0).unwrap_or(0)
    }

    /// Block indices of archetype i.
    pub fn arch_blocks(&self, i: usize) -> Vec<usize> {
        self.archetypes[i].blocks.iter().filter_map(|id| self.block_index(id)).collect()
    }

    /// Axes for a block set, each with its random spread, clamped to 0.05..0.95.
    pub fn roll_axes(&self, set: &[usize], spread: f64, rng: &mut Rng) -> [f64; 7] {
        let (ax, _) = self.profile(set);
        let mut t = [0.5; 7];
        for (k, v) in t.iter_mut().enumerate() {
            *v = rng.normal(ax[k], spread).clamp(0.05, 0.95);
        }
        t
    }
}

pub const NAMES: [&str; 7] = ["aggression", "expansion", "mercantile", "xenophobia", "militarism", "caution", "intervention"];
pub const DRIFT: f64 = 0.03;
pub const REGIME_BASE: f64 = 0.01;
pub const REGIME_CRISIS: f64 = 0.06;
pub const REGIME_JUMP: f64 = 0.35;
pub const REGIME_COOLDOWN: i64 = 10;
pub const REVERT: f64 = 0.04;
pub const TRADE_DRIFT: f64 = 0.004;
/// Xenophobia added to the victim of a claim-jumping incident.
pub const INCIDENT_DRIFT: f64 = 0.02;

pub fn generate(w: &mut World, e: usize) {
    let mut rng = Rng::new(w.cfg.seed.wrapping_mul(7919).wrapping_add(e as u64 * 104_729));
    let book = w.cfg.personalities.clone();
    let a = book.pick(&mut rng);
    w.empires[e].archetype = a;
    let set = book.arch_blocks(a);
    w.empires[e].traits = book.roll_axes(&set, book.archetypes[a].spread, &mut rng);
    w.empires[e].base_traits = w.empires[e].traits;
    set_blocks(w, e, set);
    let [lo, hi] = book.archetypes[a].stability;
    w.empires[e].stability = rng.range(lo.min(hi), hi.max(lo)).clamp(0.05, 0.95);
}

/// Strength ratio wanted before attacking: 1.0 for the most aggressive, 1.6 for the least.
pub fn attack_ratio(w: &World, e: usize) -> f64 {
    (1.0 + 0.6 * (1.0 - w.empires[e].traits[0])) * w.empires[e].fx(FX_ATTACK_RATIO)
}

/// Give empire e this block set (and the effect multipliers it implies).
pub fn set_blocks(w: &mut World, e: usize, set: Vec<usize>) {
    let (_, fx) = w.cfg.personalities.profile(&set);
    w.empires[e].fx = fx;
    w.empires[e].blocks = set;
}

/// The names of an empire's trait blocks.
pub fn block_names(w: &World, e: usize) -> Vec<String> {
    w.empires[e].blocks.iter().filter_map(|&i| w.cfg.personalities.blocks.get(i)).map(|b| b.name.clone()).collect()
}

/// Exhaustion at which an empire wants out of a war: 30 for the most cautious, 70 for the least.
pub fn peace_exhaustion(w: &World, e: usize) -> f64 {
    (30.0 + 40.0 * (1.0 - w.empires[e].traits[5])) * w.empires[e].fx(FX_PEACE_EXHAUSTION)
}

pub fn label(w: &World, e: usize) -> String {
    let arch = w.cfg.personalities.archetypes.get(w.empires[e].archetype).map(|a| a.name.clone()).unwrap_or_default();
    let b = block_names(w, e);
    if b.is_empty() {
        arch
    } else {
        format!("{} ({})", arch, b.join(", "))
    }
}

pub fn shift(w: &mut World, e: usize, t: usize, amount: f64, why: &str) {
    let before = w.empires[e].traits[t];
    w.empires[e].traits[t] = (before + amount).clamp(0.0, 1.0);
    if !why.is_empty() && amount.abs() >= 0.1 {
        let txt = format!("{} grows {} {} ({})", w.empires[e].name, if amount > 0.0 { "more" } else { "less" }, NAMES[t], why);
        w.event(txt);
    }
}

pub fn yearly(w: &mut World) {
    let year = w.year();
    let book = w.cfg.personalities.clone();
    let rules = &book.rules;
    for e in 0..w.empires.len() {
        for t in 0..7 {
            let sd = rules.drift * (1.0 - w.empires[e].stability) * w.empires[e].fx(FX_DRIFT);
            let pull = rules.revert * (w.empires[e].base_traits[t] - w.empires[e].traits[t]);
            let n = w.prng.normal(0.0, sd);
            shift(w, e, t, n + pull, "");
        }
        if w.empires[e].treasury < 0.0 {
            shift(w, e, 5, 0.03, "");
        }
        if crate::diplomacy::land_hungry(w, e) {
            shift(w, e, 1, 0.02, "");
        }
        // Trade breeds merchants and trust: one small nudge a year if the empire trades at all (not one per partner,
        // which made every well-connected empire converge). Against REVERT this settles about +0.1 above the regime's
        // own values.
        if (0..w.empires.len()).any(|x| x != e && w.rel(e, x).trade_treaty) {
            shift(w, e, 2, rules.trade_drift, "");
            shift(w, e, 3, -rules.trade_drift, "");
        }
        let crisis = w.empires[e].exhaustion >= 60.0 || w.empires[e].treasury < 0.0;
        let chance = (rules.regime_base + if crisis { rules.regime_crisis } else { 0.0 }) * w.empires[e].fx(FX_REGIME);
        if year >= w.empires[e].regime_year + rules.regime_cooldown.round() as i64 && w.prng.randf() < chance {
            // The new regime's values are the old regime's plus its own jumps; the accumulated drift is not locked in
            // (resetting the base to the drifted traits made every empire ratchet toward the same profile).
            if w.prng.randf() < rules.regime_switch {
                // A new kind of regime: roll its values from a (possibly different) archetype.
                let a = book.pick(&mut w.prng);
                let set = book.arch_blocks(a);
                let nb = book.roll_axes(&set, book.archetypes[a].spread, &mut w.prng);
                w.empires[e].archetype = a;
                w.empires[e].base_traits = nb;
                w.empires[e].traits = nb;
                set_blocks(w, e, set);
            } else {
                // A reform: the regime drops one of its trait blocks and/or adopts a compatible new one.
                let mut set = w.empires[e].blocks.clone();
                if !set.is_empty() && w.prng.randf() < 0.5 {
                    let i = (w.prng.randf() * set.len() as f64) as usize % set.len();
                    set.remove(i);
                }
                let cands: Vec<usize> = (0..book.blocks.len()).filter(|&i| book.blocks[i].weight > 0.0 && book.compatible(i, &set)).collect();
                let total: f64 = cands.iter().map(|&i| book.blocks[i].weight).sum();
                if total > 0.0 {
                    let mut x = w.prng.randf() * total;
                    for &i in &cands {
                        x -= book.blocks[i].weight;
                        if x < 0.0 {
                            set.push(i);
                            break;
                        }
                    }
                }
                // Keep this empire's own leanings (the old base minus the old blocks' pushes), plus the new blocks'.
                let (old_ax, _) = book.profile(&w.empires[e].blocks);
                let (new_ax, _) = book.profile(&set);
                for t in 0..7 {
                    let nb = (w.empires[e].base_traits[t] - old_ax[t] + new_ax[t]).clamp(0.05, 0.95);
                    w.empires[e].base_traits[t] = nb;
                    w.empires[e].traits[t] = nb;
                }
                set_blocks(w, e, set);
            }
            w.empires[e].regime_year = year;
            let s = w.empires[e].stability + w.prng.range(-0.2, 0.2);
            w.empires[e].stability = s.clamp(0.1, 0.95);
            let txt = format!("REGIME CHANGE in {}{}: now {}", w.empires[e].name, if crisis { " (crisis)" } else { "" }, label(w, e));
            w.event(txt);
        }
    }
}
