//! Empire personality (personality.gd): seven traits that weight the planner, drift yearly back toward the regime's
//! values, shift with events, and occasionally jump in a regime change. A 0.5 trait gives the neutral behaviour.

//!
//! Personalities are data: a `Book` of archetypes (a name, a weight, and a mean and spread per trait) plus the drift
//! rules, loaded from JSON so an in-game editor can create and change them. The seven traits themselves are fixed,
//! because each one is read by sim code; archetypes are any mix of them.

use crate::rng::Rng;
use crate::world::World;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// One trait's roll in an archetype: normal(mean, spread), clamped to 0.05..0.95.
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq)]
pub struct TraitRoll {
    pub mean: f64,
    pub spread: f64,
}

impl Default for TraitRoll {
    fn default() -> Self {
        TraitRoll { mean: 0.5, spread: 0.2 }
    }
}

/// A personality an empire can be founded with (or switch to in a regime change).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Archetype {
    pub name: String,
    pub description: String,
    /// Relative chance of being picked; 0 = never picked at random.
    pub weight: f64,
    /// Trait name -> roll. Traits left out roll the default (0.5 +- 0.2).
    pub traits: BTreeMap<String, TraitRoll>,
    /// Government stability range: low stability drifts more and is likelier to have a crisis regime change.
    pub stability: [f64; 2],
}

impl Default for Archetype {
    fn default() -> Self {
        Archetype { name: "New personality".into(), description: String::new(), weight: 1.0, traits: BTreeMap::new(), stability: [0.3, 0.9] }
    }
}

impl Archetype {
    pub fn roll(&self, t: usize) -> TraitRoll {
        self.traits.get(NAMES[t]).copied().unwrap_or_default()
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
    pub archetypes: Vec<Archetype>,
    pub rules: Rules,
}

impl Default for Book {
    fn default() -> Self {
        Book::builtin()
    }
}

fn arch(name: &str, desc: &str, weight: f64, stab: [f64; 2], t: &[(&str, f64)]) -> Archetype {
    Archetype {
        name: name.into(),
        description: desc.into(),
        weight,
        traits: t.iter().map(|&(n, m)| (n.to_string(), TraitRoll { mean: m, spread: 0.12 })).collect(),
        stability: stab,
    }
}

impl Book {
    pub fn builtin() -> Book {
        Book {
            archetypes: vec![
                arch("Balanced", "No strong leanings.", 2.0, [0.3, 0.9], &[]),
                arch("Warlike Expansionists", "Grab land, fight for it.", 1.0, [0.3, 0.8], &[("aggression", 0.75), ("expansion", 0.75), ("militarism", 0.7), ("caution", 0.3)]),
                arch("Merchant Republic", "Trade first; war is bad for business.", 1.0, [0.5, 0.9], &[("mercantile", 0.8), ("aggression", 0.3), ("xenophobia", 0.25), ("caution", 0.55)]),
                arch("Isolationists", "Keep to themselves and distrust outsiders.", 1.0, [0.4, 0.9], &[("xenophobia", 0.8), ("intervention", 0.15), ("expansion", 0.35), ("caution", 0.65)]),
                arch("Peacekeepers", "Mediate, guarantee the small, stop wars.", 1.0, [0.5, 0.9], &[("intervention", 0.8), ("aggression", 0.3), ("caution", 0.55)]),
                arch("Military Junta", "Armed to the teeth and unstable.", 0.7, [0.1, 0.5], &[("militarism", 0.85), ("aggression", 0.6), ("caution", 0.35)]),
                arch("Cautious Bureaucracy", "Slow, steady, risk-averse.", 0.8, [0.6, 0.95], &[("caution", 0.8), ("aggression", 0.3), ("expansion", 0.4)]),
            ],
            rules: Rules::default(),
        }
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
        for a in &self.archetypes {
            for k in a.traits.keys() {
                if !NAMES.contains(&k.as_str()) {
                    return Err(format!("{}: unknown trait '{}' (traits: {})", a.name, k, NAMES.join(", ")));
                }
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

    pub fn roll_traits(&self, i: usize, rng: &mut Rng) -> [f64; 7] {
        let a = &self.archetypes[i];
        let mut t = [0.5; 7];
        for (k, v) in t.iter_mut().enumerate() {
            let r = a.roll(k);
            *v = rng.normal(r.mean, r.spread).clamp(0.05, 0.95);
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
    w.empires[e].traits = book.roll_traits(a, &mut rng);
    w.empires[e].base_traits = w.empires[e].traits;
    let [lo, hi] = book.archetypes[a].stability;
    w.empires[e].stability = rng.range(lo.min(hi), hi.max(lo)).clamp(0.05, 0.95);
}

/// Strength ratio wanted before attacking: 1.0 for the most aggressive, 1.6 for the least.
pub fn attack_ratio(w: &World, e: usize) -> f64 {
    1.0 + 0.6 * (1.0 - w.empires[e].traits[0])
}

/// Exhaustion at which an empire wants out of a war: 30 for the most cautious, 70 for the least.
pub fn peace_exhaustion(w: &World, e: usize) -> f64 {
    30.0 + 40.0 * (1.0 - w.empires[e].traits[5])
}

pub fn label(w: &World, e: usize) -> String {
    let t = &w.empires[e].traits;
    let arch = w.cfg.personalities.archetypes.get(w.empires[e].archetype).map(|a| a.name.clone()).unwrap_or_default();
    let mut parts: Vec<String> = (0..7).filter(|&i| t[i] >= 0.65).map(|i| NAMES[i].to_string()).collect();
    parts.extend((0..7).filter(|&i| t[i] <= 0.3).map(|i| format!("not {}", NAMES[i])));
    let leanings = if parts.is_empty() { "balanced".to_string() } else { parts.join(" ") };
    format!("{} ({})", arch, leanings)
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
            let sd = rules.drift * (1.0 - w.empires[e].stability);
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
        let chance = rules.regime_base + if crisis { rules.regime_crisis } else { 0.0 };
        if year >= w.empires[e].regime_year + rules.regime_cooldown.round() as i64 && w.prng.randf() < chance {
            // The new regime's values are the old regime's plus its own jumps; the accumulated drift is not locked in
            // (resetting the base to the drifted traits made every empire ratchet toward the same profile).
            if w.prng.randf() < rules.regime_switch {
                // A new kind of regime: roll its values from a (possibly different) archetype.
                let a = book.pick(&mut w.prng);
                let nb = book.roll_traits(a, &mut w.prng);
                w.empires[e].archetype = a;
                w.empires[e].base_traits = nb;
                w.empires[e].traits = nb;
            } else {
                for t in 0..7 {
                    if w.prng.randf() >= 0.4 {
                        continue;
                    }
                    let j = w.prng.range(-rules.regime_jump, rules.regime_jump);
                    let nb = (w.empires[e].base_traits[t] + j).clamp(0.0, 1.0);
                    w.empires[e].base_traits[t] = nb;
                    w.empires[e].traits[t] = nb;
                }
            }
            w.empires[e].regime_year = year;
            let s = w.empires[e].stability + w.prng.range(-0.2, 0.2);
            w.empires[e].stability = s.clamp(0.1, 0.95);
            let txt = format!("REGIME CHANGE in {}{}: now {}", w.empires[e].name, if crisis { " (crisis)" } else { "" }, label(w, e));
            w.event(txt);
        }
    }
}
