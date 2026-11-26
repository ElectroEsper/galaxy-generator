//! Technology: each empire slowly advances five fields, which raise output and capacity across its colonies.
//!
//! - **Extraction**: ore output of extractors.
//! - **Agriculture**: food and water output of extractors (hydroponics, farming).
//! - **Industry**: metal and parts made per batch of inputs (better processes, less waste).
//! - **Habitation**: colonies' population ceiling.
//! - **Military**: strength gained per unit built (better ships and kit for the same cost).
//! - **Logistics**: freighters of the empire's corporations carry more per ship and make more trips a month.
//!
//! Each level adds a few percent (TECH_BONUS per level, Habitation and Military their own rates). Research points come
//! every month from a share of tax income plus a little per head of population. They are split across fields by
//! need and personality:
//! - shortages pull research toward the field that fixes them (food short → Agriculture, parts short → Industry);
//! - militarists favour Military, mercantile empires Industry, expansionists Habitation.
//!
//! Each level costs more than the last. Knowledge also spreads: met empires further ahead in a field speed up its
//! research (more with a trade treaty or a pact), so laggards catch up but never overtake by diffusion alone.

use crate::world::{World, TRAIT_EXPANSION, TRAIT_MERCANTILE, TRAIT_MILITARISM};
use galaxy_goods as goods;

pub const FIELDS: [&str; 6] = ["Extraction", "Agriculture", "Industry", "Habitation", "Military", "Logistics"];
pub const T_EXTRACTION: usize = 0;
pub const T_AGRICULTURE: usize = 1;
pub const T_INDUSTRY: usize = 2;
pub const T_HABITATION: usize = 3;
pub const T_MILITARY: usize = 4;
pub const T_LOGISTICS: usize = 5;
pub const NT: usize = 6;
/// Logistics: cargo per ship and trip time per level.
pub const LOG_CAP_BONUS: f64 = 0.08;
pub const LOG_SPEED_BONUS: f64 = 0.04;

/// Output bonus per level (Extraction, Agriculture, Industry).
pub const TECH_BONUS: f64 = 0.06;
pub const HAB_BONUS: f64 = 0.05;
pub const MIL_BONUS: f64 = 0.06;
/// Share of monthly tax income spent on research, plus points per head of population per month.
pub const RESEARCH_SHARE: f64 = 0.08;
pub const RESEARCH_PER_POP: f64 = 0.02;
/// Points for the first level; each further level costs LEVEL_GROWTH times more.
pub const LEVEL_COST: f64 = 3000.0;
pub const LEVEL_GROWTH: f64 = 1.5;
/// Research speed-up per level that a met empire is ahead (×2 with a trade treaty or pact), capped.
pub const DIFFUSION: f64 = 0.15;
pub const DIFFUSION_CAP: f64 = 1.0;

/// Points needed to go from level `l` to `l + 1`.
pub fn level_cost(l: u32) -> f64 {
    LEVEL_COST * LEVEL_GROWTH.powi(l as i32)
}

/// Output multiplier of good g for colonies at these tech levels.
pub fn good_mult(levels: &[u32; NT], g: usize) -> f64 {
    let field = match g {
        goods::ORE => T_EXTRACTION,
        goods::FOOD | goods::WATER => T_AGRICULTURE,
        _ => T_INDUSTRY,
    };
    1.0 + TECH_BONUS * levels[field] as f64
}

impl World {
    /// Monthly research for every empire; on a new level, the empire's colonies get their multipliers refreshed.
    /// Once a year every colony is refreshed (new settlements and systems that changed hands).
    pub fn research_monthly(&mut self) {
        let n = self.empires.len();
        if n == 0 {
            return;
        }
        if self.tick % 12 == 0 {
            for c in 0..self.colonies.len() {
                match self.colonies[c].owner {
                    Some(o) => {
                        let levels = self.empires[o].tech;
                        let col = &mut self.colonies[c];
                        for g in goods::ALL {
                            col.tech_mult[g] = good_mult(&levels, g);
                        }
                        col.pop_mult = 1.0 + HAB_BONUS * levels[T_HABITATION] as f64;
                    }
                    None => {
                        self.colonies[c].tech_mult = [1.0; goods::N];
                        self.colonies[c].pop_mult = 1.0;
                    }
                }
            }
        }
        // Shortage pressure per empire and field, from its colonies' prices (high price = short).
        let mut need = vec![[0.0f64; NT]; n];
        for &m in &self.markets {
            if let Some(o) = self.colonies[m].owner {
                let c = &self.colonies[m];
                let short = |g: usize| (c.price[g] / crate::market::BASE_PRICE - 1.0).max(0.0);
                need[o][T_EXTRACTION] += short(goods::ORE);
                need[o][T_AGRICULTURE] += short(goods::FOOD) + short(goods::WATER);
                need[o][T_INDUSTRY] += short(goods::METAL) + short(goods::PARTS);
                // Goods short here while cheap elsewhere is a distribution problem.
                need[o][T_LOGISTICS] += 0.5 * (short(goods::METAL) + short(goods::PARTS) + short(goods::FOOD));
                need[o][T_HABITATION] += (c.pop / (c.max_pop * c.pop_mult).max(1.0) - 0.8).max(0.0) * 5.0;
            }
        }
        for e in 0..n {
            let pop: f64 = self.markets.iter().filter(|&&m| self.colonies[m].owner == Some(e)).map(|&m| self.colonies[m].pop).sum();
            if pop <= 0.0 {
                continue;
            }
            let points = RESEARCH_SHARE * self.empires[e].avg_tax.max(0.0) + RESEARCH_PER_POP * pop;
            let em = &self.empires[e];
            let total_need: f64 = need[e].iter().sum::<f64>().max(1e-9);
            let mut weight = [1.0f64; NT];
            for f in 0..NT {
                weight[f] += 2.0 * need[e][f] / total_need;
            }
            weight[T_MILITARY] += 1.5 * em.t(TRAIT_MILITARISM) + if self.in_any_war(e) { 1.0 } else { 0.0 };
            weight[T_INDUSTRY] += 0.5 * em.t(TRAIT_MERCANTILE);
            weight[T_LOGISTICS] += em.t(TRAIT_MERCANTILE);
            weight[T_HABITATION] += em.t(TRAIT_EXPANSION);
            let wsum: f64 = weight.iter().sum();
            let mut leveled: Vec<usize> = vec![];
            for f in 0..NT {
                // Diffusion from met empires ahead in this field.
                let mut boost = 0.0;
                for x in 0..n {
                    if x == e || !self.rel(e, x).met {
                        continue;
                    }
                    let gap = self.empires[x].tech[f] as f64 - self.empires[e].tech[f] as f64;
                    if gap > 0.0 {
                        let close = self.rel(e, x).trade_treaty || self.rel(e, x).pact;
                        boost += DIFFUSION * gap * if close { 2.0 } else { 1.0 };
                    }
                }
                let gain = points * weight[f] / wsum * (1.0 + boost.min(DIFFUSION_CAP));
                let em = &mut self.empires[e];
                em.research[f] += gain;
                let cost = level_cost(em.tech[f]);
                if em.research[f] >= cost {
                    em.research[f] -= cost;
                    em.tech[f] += 1;
                    leveled.push(f);
                }
            }
            for f in leveled {
                let t = format!("{} advances in {} (level {})", self.empires[e].name, FIELDS[f], self.empires[e].tech[f]);
                self.event(t);
                self.apply_tech(e);
            }
        }
    }

    /// Refresh the tech multipliers of an empire's colonies (also called when colonies change hands).
    pub fn apply_tech(&mut self, e: usize) {
        let levels = self.empires[e].tech;
        for c in self.colonies.iter_mut().filter(|c| c.owner == Some(e)) {
            for g in goods::ALL {
                c.tech_mult[g] = good_mult(&levels, g);
            }
            c.pop_mult = 1.0 + HAB_BONUS * levels[T_HABITATION] as f64;
        }
    }

    /// Strength per unit built.
    pub fn military_tech(&self, e: usize) -> f64 {
        1.0 + MIL_BONUS * self.empires[e].tech[T_MILITARY] as f64
    }
}
