//! Monte Carlo "lite" forecasting: before a decision that bets on how a war would go, an empire plays the war out a
//! few dozen times on a cheap abstract model, using what it *believes* (noisy estimates of others' strength, guesses
//! about who would join), and decides by the share of rollouts it wins against a threshold set by its risk
//! tolerance (traits).
//!
//! - Beliefs: another empire's strength is seen with an error that depends on how well the two know each other (a
//!   pact or trade treaty sees clearly; a stranger is a guess). The error is fixed per (viewer, target, year), so an
//!   empire's view is consistent within a year.
//! - Joiners: third parties are sampled per rollout: pact partners and guarantors of the defender (by their
//!   call-to-arms chance), pact partners of the attacker (less often).
//! - Model: monthly Lanchester attrition with noise, war exhaustion from months and losses, occupation pressure for
//!   the side ahead. A side gives up when its leader's exhaustion passes its peace threshold. Ten years without a
//!   result is a draw.
//! - Randomness: rollouts use their own streams (hashed from the seed, the month, the viewer and the question), so
//!   forecasts never disturb the simulation's own random numbers and don't depend on the thread count.
//!
//! Used for: starting a war or crisis, joining a war (also when allies call), suing for peace, proposing pacts and
//! guarantees, and how much force an operation commits.

use crate::rng::Rng;
use crate::world::{World, TRAIT_AGGRESSION, TRAIT_CAUTION};
use rayon::prelude::*;

pub const ROLLOUTS: usize = 32;
pub const MAX_MONTHS: u32 = 120;
const RATE: f64 = 0.03; // abstract monthly attrition (forces are only partly engaged at any time)
const BATTLE_RATE: f64 = crate::forces::BATTLE_RATE;

#[derive(Clone, Copy, Debug, Default)]
pub struct Outlook {
    /// Share of rollouts the viewer's side wins (draws count half).
    pub p_win: f64,
    /// Mean months until it ends.
    pub months: f64,
}

fn mix(mut h: u64, v: u64) -> u64 {
    h ^= v.wrapping_add(0x9e37_79b9_7f4a_7c15).wrapping_add(h << 6).wrapping_add(h >> 2);
    h
}

impl World {
    fn fc_seed(&self, viewer: usize, salt: u64) -> u64 {
        mix(mix(mix(self.cfg.seed ^ 0xF0F0_1234, self.tick as u64), viewer as u64), salt)
    }

    /// Risk tolerance 0..1 from the traits: aggression and recklessness raise it.
    pub fn risk_tolerance(&self, e: usize) -> f64 {
        let em = &self.empires[e];
        let base = 0.5 * em.t(TRAIT_AGGRESSION) + 0.5 * (1.0 - em.t(TRAIT_CAUTION));
        // Blocks that lower the attack threshold (Militarist, Reckless) make it bolder too.
        (base / em.fx(crate::personality::FX_ATTACK_RATIO).max(0.3)).clamp(0.0, 1.0)
    }

    /// Win chance an empire wants before starting or joining a war: 0.75 for the most careful, 0.4 for the boldest.
    pub fn war_threshold(&self, e: usize) -> f64 {
        0.75 - 0.35 * self.risk_tolerance(e)
    }

    /// How strong viewer believes x to be.
    pub fn believed_strength(&self, viewer: usize, x: usize) -> f64 {
        let s = self.empires[x].strength;
        if viewer == x {
            return s;
        }
        let r = self.rel(viewer, x);
        let sd = if crate::alliances::has_pact(self, viewer, x) || r.trade_treaty {
            0.08
        } else if r.met {
            0.2
        } else {
            0.4
        };
        let mut rng = Rng::new(mix(mix(mix(self.cfg.seed ^ 0xBE11_EF, self.year() as u64), viewer as u64), x as u64));
        s * rng.normal(1.0, sd).clamp(0.4, 1.8)
    }

    /// Possible joiners for each side, with their join chance (as viewer sees it): those not already listed.
    fn likely_joiners(&self, side_a: &[usize], side_b: &[usize]) -> Vec<(usize, usize, f64)> {
        let mut out = vec![];
        for y in 0..self.empires.len() {
            if side_a.contains(&y) || side_b.contains(&y) || self.in_any_war(y) {
                continue;
            }
            // Defender's allies first: they are the ones a treaty obliges.
            let bound_b = side_b.iter().any(|&b| crate::alliances::has_pact(self, y, b) || self.empires[y].guarantees_(b));
            let bound_a = side_a.iter().any(|&a| crate::alliances::has_pact(self, y, a));
            if bound_b && !bound_a {
                let p = (0.6 * self.empires[y].fx(crate::personality::FX_CALL_TO_ARMS)).min(0.95);
                out.push((y, 1, p));
            } else if bound_a && !bound_b {
                out.push((y, 0, 0.25));
            } else if !bound_a {
                // No treaty, but sympathy for the defender or fear of the attacker can bring an empire in.
                let friendly = side_b.iter().any(|&b| self.rel(y, b).stance == crate::world::Stance::Friendly);
                let fears = side_a.iter().any(|&a| self.empires[y].main_threat == Some(a) || self.empires[y].threat[a] >= 1.5);
                let p = 0.06 * friendly as i32 as f64 + 0.12 * fears as i32 as f64 * (0.5 + self.empires[y].t(crate::world::TRAIT_INTERVENTION));
                if p > 0.0 {
                    out.push((y, 1, p.min(0.3)));
                }
            }
        }
        out
    }

    /// Forecast a war between side_a and side_b (index 0 is each side's leader), from viewer's beliefs.
    /// `viewer_side` is 0 or 1. Third parties may join per rollout when `joiners` is set.
    pub fn forecast_war(&self, viewer: usize, side_a: &[usize], side_b: &[usize], viewer_side: usize, joiners: bool, salt: u64) -> Outlook {
        // Members other than the two leaders, and possible joiners, count only as far as their forces can reach the war.
        let (la, lb) = (side_a[0], side_b[0]);
        let reach = |y: usize| if y == la || y == lb { 1.0 } else { crate::alliances::reach(self, y, lb, la) };
        let str_a: Vec<f64> = side_a.iter().map(|&x| self.believed_strength(viewer, x) * reach(x)).collect();
        let str_b: Vec<f64> = side_b.iter().map(|&x| self.believed_strength(viewer, x) * reach(x)).collect();
        let extra: Vec<(usize, usize, f64, f64)> = if joiners {
            self.likely_joiners(side_a, side_b).into_iter().map(|(y, s, p)| (y, s, p, self.believed_strength(viewer, y) * reach(y))).collect()
        } else {
            vec![]
        };
        let lead = [side_a[0], side_b[0]];
        let give_up = [crate::personality::peace_exhaustion(self, lead[0]).max(25.0), crate::personality::peace_exhaustion(self, lead[1]).max(25.0)];
        let exh0 = [self.empires[lead[0]].exhaustion, self.empires[lead[1]].exhaustion];
        let seed = self.fc_seed(viewer, salt);
        let results: Vec<(f64, f64)> = (0..ROLLOUTS)
            .into_par_iter()
            .map(|k| {
                let mut rng = Rng::new(mix(seed, k as u64));
                let mut s = [0.0f64; 2];
                for v in &str_a {
                    s[0] += v * rng.normal(1.0, 0.12).max(0.5);
                }
                for v in &str_b {
                    s[1] += v * rng.normal(1.0, 0.12).max(0.5);
                }
                for &(_, side, p, st) in &extra {
                    if rng.randf() < p {
                        s[side] += st * rng.normal(1.0, 0.12).max(0.5);
                    }
                }
                let peak = s;
                let mut exh = exh0;
                for m in 1..=MAX_MONTHS {
                    let (a, b) = (s[0], s[1]);
                    s[0] = (a - RATE * b * rng.range(0.6, 1.4)).max(0.0);
                    s[1] = (b - RATE * a * rng.range(0.6, 1.4)).max(0.0);
                    for i in 0..2 {
                        exh[i] += 0.4 + 60.0 * (if i == 0 { a - s[0] } else { b - s[1] }) / peak[i].max(1.0);
                    }
                    // The side ahead takes ground, which wears the other down.
                    let ratio = (s[0] + 1.0) / (s[1] + 1.0);
                    if ratio > 1.2 && rng.randf() < 0.25 * ((ratio - 1.2) / ratio).min(1.0) {
                        exh[1] += 4.0;
                    } else if ratio < 1.0 / 1.2 && rng.randf() < 0.25 * ((1.0 / ratio - 1.2) * ratio).min(1.0) {
                        exh[0] += 4.0;
                    }
                    let out = [exh[0] >= give_up[0] || s[0] <= 0.0, exh[1] >= give_up[1] || s[1] <= 0.0];
                    if out[0] || out[1] {
                        let win_a = if out[0] && out[1] { 0.5 } else if out[1] { 1.0 } else { 0.0 };
                        return (win_a, m as f64);
                    }
                }
                (0.5, MAX_MONTHS as f64)
            })
            .collect();
        let pa = results.iter().map(|r| r.0).sum::<f64>() / ROLLOUTS as f64;
        let months = results.iter().map(|r| r.1).sum::<f64>() / ROLLOUTS as f64;
        Outlook { p_win: if viewer_side == 0 { pa } else { 1.0 - pa }, months }
    }

    /// The war viewer is in, as (its side's members, the other side's members, viewer's side index), leaders first.
    pub fn war_sides(&self, viewer: usize) -> Option<(Vec<usize>, Vec<usize>)> {
        let w = self.wars.iter().find(|w| w.side_of(viewer).is_some())?;
        let s = w.side_of(viewer)?;
        Some((w.sides[s].clone(), w.sides[1 - s].clone()))
    }

    /// Battle forecast for an operation: own strength `mine` against `theirs` (beliefs), `theirs_bonus` for a
    /// defender in its own system. Returns the share of rollouts won.
    pub fn forecast_battle(&self, viewer: usize, mine: f64, theirs: f64, theirs_bonus: f64, salt: u64) -> f64 {
        if theirs <= 0.0 {
            return 1.0;
        }
        let seed = self.fc_seed(viewer, salt ^ 0xBA77);
        let wins: f64 = (0..ROLLOUTS)
            .map(|k| {
                let mut rng = Rng::new(mix(seed, k as u64));
                let mut a = mine;
                let mut b = theirs * rng.normal(1.0, 0.25).clamp(0.5, 1.8); // the enemy may be stronger than seen
                for _ in 0..24 {
                    let (pa, pb) = (a, b);
                    a -= BATTLE_RATE * pb * theirs_bonus * rng.range(0.7, 1.3);
                    b -= BATTLE_RATE * pa * rng.range(0.7, 1.3);
                    if b <= 0.0 {
                        return 1.0;
                    }
                    if a <= mine * 0.35 {
                        return 0.0; // the operation would break off
                    }
                }
                0.5
            })
            .sum();
        wins / ROLLOUTS as f64
    }

    /// Smallest multiple of the believed enemy strength an operation should bring, by forecast: the first commitment
    /// in a ladder whose win chance clears the empire's operational threshold (bolder empires accept thinner
    /// margins).
    pub fn op_commitment(&self, e: usize, believed_enemy: f64, defender_bonus: f64, salt: u64) -> f64 {
        if believed_enemy <= 0.0 {
            return 1.0;
        }
        let want = 0.85 - 0.3 * self.risk_tolerance(e);
        for (i, m) in [1.0, 1.25, 1.5, 2.0, 2.5, 3.0].iter().enumerate() {
            if self.forecast_battle(e, believed_enemy * m, believed_enemy, defender_bonus, salt.wrapping_add(i as u64)) >= want {
                return *m;
            }
        }
        3.0
    }
}
