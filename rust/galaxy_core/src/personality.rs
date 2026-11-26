//! Empire personality (personality.gd): seven traits that weight the planner, drift yearly back toward the regime's
//! values, shift with events, and occasionally jump in a regime change. A 0.5 trait gives the neutral behaviour.

use crate::rng::Rng;
use crate::world::World;

pub const NAMES: [&str; 7] = ["aggression", "expansion", "mercantile", "xenophobia", "militarism", "caution", "intervention"];
pub const DRIFT: f64 = 0.03;
pub const REGIME_BASE: f64 = 0.01;
pub const REGIME_CRISIS: f64 = 0.06;
pub const REGIME_JUMP: f64 = 0.35;
pub const REGIME_COOLDOWN: i64 = 10;
pub const REVERT: f64 = 0.04;

pub fn generate(w: &mut World, e: usize) {
    let mut rng = Rng::new(w.cfg.seed.wrapping_mul(7919).wrapping_add(e as u64 * 104_729));
    for t in 0..7 {
        w.empires[e].traits[t] = rng.normal(0.5, 0.2).clamp(0.05, 0.95);
    }
    w.empires[e].base_traits = w.empires[e].traits;
    w.empires[e].stability = rng.range(0.3, 0.9);
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
    let mut parts: Vec<String> = (0..7).filter(|&i| t[i] >= 0.65).map(|i| NAMES[i].to_string()).collect();
    parts.extend((0..7).filter(|&i| t[i] <= 0.3).map(|i| format!("not {}", NAMES[i])));
    if parts.is_empty() {
        "balanced".into()
    } else {
        parts.join(" ")
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
    for e in 0..w.empires.len() {
        for t in 0..7 {
            let sd = DRIFT * (1.0 - w.empires[e].stability);
            let pull = REVERT * (w.empires[e].base_traits[t] - w.empires[e].traits[t]);
            let n = w.prng.normal(0.0, sd);
            shift(w, e, t, n + pull, "");
        }
        if w.empires[e].treasury < 0.0 {
            shift(w, e, 5, 0.03, "");
        }
        if crate::diplomacy::land_hungry(w, e) {
            shift(w, e, 1, 0.02, "");
        }
        for x in 0..w.empires.len() {
            if x != e && w.rel(e, x).trade_treaty {
                shift(w, e, 2, 0.01, "");
                shift(w, e, 3, -0.01, "");
            }
        }
        let crisis = w.empires[e].exhaustion >= 60.0 || w.empires[e].treasury < 0.0;
        let chance = REGIME_BASE + if crisis { REGIME_CRISIS } else { 0.0 };
        if year >= w.empires[e].regime_year + REGIME_COOLDOWN && w.prng.randf() < chance {
            for t in 0..7 {
                if w.prng.randf() < 0.4 {
                    let j = w.prng.range(-REGIME_JUMP, REGIME_JUMP);
                    shift(w, e, t, j, "");
                }
            }
            w.empires[e].regime_year = year;
            w.empires[e].base_traits = w.empires[e].traits;
            let s = w.empires[e].stability + w.prng.range(-0.2, 0.2);
            w.empires[e].stability = s.clamp(0.1, 0.95);
            let txt = format!("REGIME CHANGE in {}{}: now {}", w.empires[e].name, if crisis { " (crisis)" } else { "" }, label(w, e));
            w.event(txt);
        }
    }
}
