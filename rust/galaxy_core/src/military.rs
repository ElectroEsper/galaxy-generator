//! Abstract military (military.gd): strength bought toward a target from the treasury with goods from the empire's
//! colonies, upkeep, fronts, attrition, occupation, exhaustion, capitulation, and making peace.

use crate::goods;
use crate::market::dist;
use crate::treaties::Term;
use crate::world::{Stance, World, BORDER_RANGE, TRAIT_MILITARISM};

pub const SHARE_PEACE: f64 = 0.10;
pub const SHARE_ARMING: f64 = 0.25;
pub const SHARE_WAR: f64 = 0.40;
pub const THREAT_CAP: f64 = 2.0;
pub const BUILD_RATE: f64 = 0.05;
pub const DEMOBILIZE: f64 = 0.02;
pub const ARMING_YEARS: i64 = 5;
pub const UNIT_CASH: f64 = 20.0;
pub const UPKEEP_CASH: f64 = 0.5;
pub const WEALTH_YEARS: f64 = 10.0;
/// Military goods an empire lacks are imported at this markup, up to this share of each foreign market's stock.
pub const IMPORT_MARKUP: f64 = 1.4;
pub const IMPORT_SHARE: f64 = 0.05;
pub const WEALTH_SHARE: f64 = 0.25;
/// No suing for peace in a war's first months (it has barely begun).
pub const MIN_WAR_MONTHS: u32 = 6;
pub const UNPAID_DECAY: f64 = 0.02;
pub const ATTRITION: f64 = 0.01;
pub const COMMIT: f64 = 0.7;
pub const OCCUPY_RATE: f64 = 0.25;
pub const FRONT_OUTPUT: f64 = 0.8;
pub const OCCUPIED_OUTPUT: f64 = 0.5;
pub const OCCUPIED_POP_LOSS: f64 = 0.005;
pub const EXH_PER_MONTH: f64 = 0.4;
pub const EXH_LOSS_WEIGHT: f64 = 60.0;
pub const EXH_PER_OCCUPIED: f64 = 4.0;
pub const EXH_CAPITULATE: f64 = 100.0;
pub const EXH_RECOVER: f64 = 1.0;
pub const TRUCE_YEARS: i64 = 15;

/// A war between two sides. Side 0 attacked; each side's first member is its leader, who negotiates the peace.
/// Allies answering a call to arms, coalition members and opportunists join a side; minor members can leave early.
#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct War {
    pub id: usize,
    pub sides: [Vec<usize>; 2],
    pub start: u32,
    /// Peak strength per empire during this war (for exhaustion from losses).
    pub peak: Vec<f64>,
    /// The attacking leader's war goals.
    pub goals: Vec<Term>,
    pub first_strike_until: i64,
}

impl War {
    pub fn leader(&self, side: usize) -> usize {
        self.sides[side][0]
    }
    pub fn side_of(&self, e: usize) -> Option<usize> {
        (0..2).find(|&s| self.sides[s].contains(&e))
    }
    pub fn members(&self) -> impl Iterator<Item = usize> + '_ {
        self.sides[0].iter().chain(self.sides[1].iter()).cloned()
    }
}

impl World {
    pub fn year(&self) -> i64 {
        self.tick as i64 / 12
    }

    /// a and b are on opposite sides of some war.
    pub fn at_war(&self, a: usize, b: usize) -> bool {
        self.war_between(a, b).is_some()
    }

    pub fn war_between(&self, a: usize, b: usize) -> Option<usize> {
        self.wars.iter().find(|w| matches!((w.side_of(a), w.side_of(b)), (Some(x), Some(y)) if x != y)).map(|w| w.id)
    }

    pub fn in_any_war(&self, x: usize) -> bool {
        self.wars.iter().any(|w| w.side_of(x).is_some())
    }

    pub fn war_index(&self, id: usize) -> Option<usize> {
        self.wars.iter().position(|w| w.id == id)
    }

    /// Everyone e is at war with.
    pub fn enemies_of(&self, e: usize) -> Vec<usize> {
        let mut out = vec![];
        for w in &self.wars {
            if let Some(s) = w.side_of(e) {
                out.extend(w.sides[1 - s].iter().cloned());
            }
        }
        out
    }

    pub fn owned_systems(&self, e: usize) -> Vec<usize> {
        self.systems.iter().filter(|s| s.owner == Some(e)).map(|s| s.id).collect()
    }

    // ------------------------------------------------------------ Budget
    pub fn military_monthly(&mut self) {
        for e in 0..self.empires.len() {
            self.fund(e);
        }
        // Fleets and armies move, plan operations and fight (forces.rs).
        self.forces_monthly();
        let ids: Vec<usize> = self.wars.iter().map(|w| w.id).collect();
        for id in ids {
            if let Some(i) = self.war_index(id) {
                let members: Vec<usize> = self.wars[i].members().collect();
                for m in members {
                    self.empires[m].exhaustion += EXH_PER_MONTH;
                }
                self.check_capitulation(id);
            }
        }
        // A side left without members ends the war.
        for id in self.wars.iter().filter(|w| w.sides[0].is_empty() || w.sides[1].is_empty()).map(|w| w.id).collect::<Vec<_>>() {
            if let Some(i) = self.war_index(id) {
                self.wars.remove(i);
            }
        }
        self.reparations_monthly();
        for e in 0..self.empires.len() {
            if !self.in_any_war(e) {
                self.empires[e].exhaustion = (self.empires[e].exhaustion - EXH_RECOVER).max(0.0);
            }
        }
    }

    fn share(&self, e: usize) -> f64 {
        let m = (0.3 + 1.4 * self.empires[e].t(TRAIT_MILITARISM)) * self.empires[e].fx(crate::personality::FX_ARMY_BUDGET);
        if self.in_any_war(e) {
            return SHARE_WAR * m;
        }
        if self.year() < self.empires[e].arming_until {
            return SHARE_ARMING * m;
        }
        let met = (0..self.empires.len()).any(|x| x != e && self.rel(e, x).met);
        if met {
            SHARE_PEACE * m * (1.0 + self.empires[e].max_threat.min(THREAT_CAP))
        } else {
            0.0
        }
    }

    /// The army whose upkeep is the chosen share of smoothed income.
    pub fn target_strength(&self, e: usize) -> f64 {
        let cap = self.empires[e].capital;
        let upkeep_unit = UPKEEP_CASH + goods::MILITARY_UPKEEP.iter().map(|&(g, q)| q * self.colonies[cap].price[g]).sum::<f64>();
        let mut t = self.share(e) * self.empires[e].avg_tax / upkeep_unit;
        // Savings: an empire sitting on a fortune keeps an army it could pay for from its treasury for WEALTH_YEARS
        // (scaled by militarism), so rich empires stop being defenceless.
        let met = (0..self.empires.len()).any(|x| x != e && self.rel(e, x).met);
        if met && self.empires[e].treasury > 0.0 {
            let m = (0.3 + 1.4 * self.empires[e].t(TRAIT_MILITARISM)) * self.empires[e].fx(crate::personality::FX_ARMY_BUDGET);
            // Capped at the income-based target again (at least 50): savings fill a gap, they don't start an arms race.
            let extra = WEALTH_SHARE * m * self.empires[e].treasury / (upkeep_unit * 12.0 * WEALTH_YEARS);
            t += extra.min(t.max(50.0));
        }
        if self.empires[e].demilitarized_until > self.year() {
            t *= crate::treaties::DEMILITARIZE_CAP;
        }
        t
    }

    /// Stock of g an empire could import: markets of empires it is not at war with and that don't embargo it.
    fn import_sources(&self, e: usize, g: usize) -> Vec<usize> {
        self.markets
            .iter()
            .cloned()
            .filter(|&c| self.colonies[c].price[g] <= crate::market::BASE_PRICE * 1.2) // only markets with spare stock
            .filter(|&c| match self.colonies[c].owner {
                Some(o) if o != e => !self.at_war(e, o) && !matches!(self.rel(e, o).stance, crate::world::Stance::Embargo | crate::world::Stance::Hostile),
                _ => false,
            })
            .collect()
    }

    fn import_stock(&self, e: usize, g: usize) -> f64 {
        self.import_sources(e, g).iter().map(|&c| (self.colonies[c].stock[g] * IMPORT_SHARE).max(0.0)).sum()
    }

    /// For building units: buy from the empire's colonies first, then (for what is missing) from foreign markets with
    /// spare stock, at IMPORT_MARKUP over their price, taking at most IMPORT_SHARE of each market's stock.
    fn buy_for_units(&mut self, e: usize, g: usize, qty: f64) -> (f64, f64) {
        let (got, cost) = self.buy(e, g, qty);
        if got >= qty * 0.999 {
            return (got, cost);
        }
        let mut src = self.import_sources(e, g);
        src.sort_by(|&a, &b| self.colonies[a].price[g].partial_cmp(&self.colonies[b].price[g]).unwrap().then(a.cmp(&b)));
        let (mut got, mut cost) = (got, cost);
        for c in src {
            if got >= qty {
                break;
            }
            let take = (self.colonies[c].stock[g] * IMPORT_SHARE).min(qty - got);
            if take <= 0.0 {
                continue;
            }
            self.colonies[c].stock[g] -= take;
            got += take;
            let paid = take * self.colonies[c].price[g];
            cost += paid * IMPORT_MARKUP;
            // The seller's market is paid (its colony treasury isn't modelled; the owner empire collects customs).
            if let Some(o) = self.colonies[c].owner {
                self.empires[o].customs_collected += paid * (IMPORT_MARKUP - 1.0);
                self.empires[o].treasury += paid * (IMPORT_MARKUP - 1.0);
            }
        }
        (got, cost)
    }

    /// Buy up to qty of g from the empire's colonies, cheapest first. Returns (bought, cost).
    fn buy(&mut self, e: usize, g: usize, qty: f64) -> (f64, f64) {
        let mut own = self.empire_colonies(e);
        own.sort_by(|&a, &b| self.colonies[a].price[g].partial_cmp(&self.colonies[b].price[g]).unwrap().then(self.colonies[a].name.cmp(&self.colonies[b].name)));
        let (mut got, mut cost) = (0.0, 0.0);
        for c in own {
            if got >= qty {
                break;
            }
            let take = self.colonies[c].stock[g].min(qty - got);
            if take <= 0.0 {
                continue;
            }
            self.colonies[c].stock[g] -= take;
            got += take;
            cost += take * self.colonies[c].price[g];
        }
        (got, cost)
    }

    /// Register military demand across the empire, spread by population, so prices and producers respond.
    fn note_military(&mut self, e: usize, g: usize, qty: f64) {
        let own = self.empire_colonies(e);
        let pop: f64 = own.iter().map(|&c| self.colonies[c].pop).sum();
        if pop <= 0.0 {
            return;
        }
        for c in own {
            let p = self.colonies[c].pop;
            self.colonies[c].note_use(g, qty * p / pop);
        }
    }

    fn fund(&mut self, e: usize) {
        {
            let em = &mut self.empires[e];
            em.avg_tax = 0.95 * em.avg_tax + 0.05 * em.month_tax;
            em.month_tax = 0.0;
        }
        // Upkeep
        let strength = self.empires[e].strength;
        if strength > 0.0 {
            let mut short = false;
            let mut cost = strength * UPKEEP_CASH;
            for &(g, q) in goods::MILITARY_UPKEEP {
                let need = strength * q;
                self.note_military(e, g, need);
                let (got, c) = self.buy(e, g, need);
                cost += c;
                short |= got < need * 0.99;
            }
            let em = &mut self.empires[e];
            em.treasury -= cost;
            em.mil_spent += cost;
            if short || em.treasury < 0.0 {
                em.strength *= 1.0 - UNPAID_DECAY;
            }
        }
        let target = self.target_strength(e);
        self.empires[e].target_strength = target;
        let s = self.empires[e].strength;
        if s > target * 1.1 {
            self.empires[e].strength -= (s - target) * DEMOBILIZE;
            return;
        }
        if s >= target || self.empires[e].treasury <= 0.0 {
            return;
        }
        let cap = self.empires[e].capital;
        let unit_est = UNIT_CASH + goods::MILITARY_UNIT.iter().map(|&(g, q)| q * self.colonies[cap].price[g]).sum::<f64>();
        let mut n = (target - s).min((target * BUILD_RATE).max(1.0));
        n = n.min(self.empires[e].treasury * 0.1 / unit_est);
        for &(g, q) in goods::MILITARY_UNIT {
            // Own stock first, then imports from neutral and friendly markets (see buy).
            let avail: f64 = self.empire_colonies(e).iter().map(|&c| self.colonies[c].stock[g]).sum::<f64>() + self.import_stock(e, g);
            self.note_military(e, g, n * q);
            n = n.min(avail / q);
        }
        if n <= 0.0 {
            return;
        }
        let mut cost = n * UNIT_CASH;
        for &(g, q) in goods::MILITARY_UNIT {
            cost += self.buy_for_units(e, g, n * q).1;
        }
        let em = &mut self.empires[e];
        em.treasury -= cost;
        em.mil_spent += cost;
        em.strength += n;
    }

    // ------------------------------------------------------------ War
    /// Systems of `side` within border range of the enemy's (its front), excluding ones already occupied.
    pub fn fronts(&self, side: usize, enemy: usize) -> Vec<usize> {
        let theirs: Vec<usize> = self.owned_systems(enemy);
        self.systems
            .iter()
            .filter(|s| s.owner == Some(side) && s.occupier.is_none() && theirs.iter().any(|&t| dist(self.systems[t].pos, s.pos) <= BORDER_RANGE))
            .map(|s| s.id)
            .collect()
    }

    /// Two empires become enemies: embargo, treaties between them cancelled.
    fn set_enemies(&mut self, a: usize, b: usize) {
        let r = self.rel_mut(a, b);
        r.trade_treaty = false;
        r.passage = false;
        r.stance = Stance::Embargo;
    }

    pub fn declare(&mut self, a: usize, b: usize, goals: Vec<Term>) -> usize {
        self.set_enemies(a, b);
        let id = self.next_war_id;
        self.next_war_id += 1;
        let (sa, sb) = (self.empires[a].strength, self.empires[b].strength);
        let goal_value = crate::treaties::total(self, &goals);
        let desc = crate::treaties::describe_all(self, &goals);
        let mut peak = vec![0.0; self.empires.len()];
        peak[a] = sa;
        peak[b] = sb;
        self.wars.push(War { id, sides: [vec![a], vec![b]], start: self.tick, peak, goals, first_strike_until: -1 });
        self.war_started(id, a, b, desc.clone());
        let y = self.year();
        self.empires[a].wars_started.push(y);
        crate::alliances::adjust_trust(self, b, a, crate::alliances::TRUST_ATTACKED);
        let why = format!("attacked {}", self.empires[b].name);
        crate::alliances::adjust_reputation(self, a, crate::alliances::REP_WAR_OF_CHOICE - crate::treaties::REP_PER_GOAL_POINT * goal_value, &why);
        let t = format!("WAR: {} declares war on {} (strength {} vs {}){}", self.empires[a].name, self.empires[b].name, sa as i64, sb as i64, if desc.is_empty() { String::new() } else { format!(" - goals: {}", desc) });
        self.event(t);
        crate::alliances::call_to_arms(self, a, b, id);
        self.on_system_claimed();
        id
    }

    /// e joins a war on the given side.
    pub fn join_war(&mut self, war_id: usize, e: usize, side: usize, why: &str) {
        let wi = match self.war_index(war_id) {
            Some(i) => i,
            None => return,
        };
        if self.wars[wi].side_of(e).is_some() {
            return;
        }
        self.wars[wi].sides[side].push(e);
        self.war_joined(war_id, e, side);
        let s = self.empires[e].strength;
        self.wars[wi].peak[e] = s;
        for o in self.wars[wi].sides[1 - side].clone() {
            self.set_enemies(e, o);
        }
        let (lead_own, lead_enemy) = (self.wars[wi].leader(side), self.wars[wi].leader(1 - side));
        let t = format!("{} joins {}'s side against {} ({})", self.empires[e].name, self.empires[lead_own].name, self.empires[lead_enemy].name, why);
        self.event(t);
        self.on_system_claimed();
    }




    fn check_capitulation(&mut self, war_id: usize) {
        let w = match self.war_index(war_id) {
            Some(i) => self.wars[i].clone(),
            None => return,
        };
        for side in 0..2 {
            for &m in &w.sides[side] {
                if self.empires[m].exhaustion >= EXH_CAPITULATE {
                    if m == w.leader(side) {
                        crate::treaties::capitulate(self, war_id, side);
                    } else {
                        self.separate_peace(war_id, m, true);
                    }
                    return;
                }
            }
        }
    }

    /// A minor member leaves the war: it cedes what the other side occupies of it and gets back what it lost.
    pub fn separate_peace(&mut self, war_id: usize, m: usize, collapsed: bool) {
        let wi = match self.war_index(war_id) {
            Some(i) => i,
            None => return,
        };
        let note = format!("{} left ({})", self.empires[m].name, if collapsed { "collapsed" } else { "separate peace" });
        self.war_note(war_id, note, false);
        self.forces_after_peace(war_id);
        let side = match self.wars[wi].side_of(m) {
            Some(s) => s,
            None => return,
        };
        let enemies = self.wars[wi].sides[1 - side].clone();
        let mut terms = vec![];
        for s in 0..self.systems.len() {
            let sy = &self.systems[s];
            if sy.owner == Some(m) && sy.occupier.map_or(false, |o| enemies.contains(&o)) {
                terms.push(Term { kind: crate::treaties::TermKind::Cede, system: Some(s), from: m, to: sy.occupier.unwrap() });
            } else if sy.occupier == Some(m) && sy.owner.map_or(false, |o| enemies.contains(&o)) {
                self.systems[s].occupier = None;
            }
        }
        self.wars[wi].sides[side].retain(|&x| x != m);
        let y = self.year();
        for &o in &enemies {
            let r = self.rel_mut(m, o);
            r.stance = Stance::Hostile;
            r.truce_until = y + TRUCE_YEARS;
            r.opinion = r.opinion.max(-60.0);
        }
        let desc = if terms.is_empty() { "white peace".to_string() } else { crate::treaties::describe_all(self, &terms) };
        let t = format!("{} {} the war (separate peace): {}", self.empires[m].name, if collapsed { "collapses and leaves" } else { "leaves" }, desc);
        self.event(t);
        let lead = self.wars[wi].leader(1 - side);
        if !terms.is_empty() {
            crate::treaties::apply_terms(self, &terms, lead, m, terms.len() as f64 * crate::treaties::VALUE_SYSTEM, false, -1.0);
        }
        self.clear_empire_caches();
        self.on_system_claimed();
    }

    /// Peace for the whole war: occupations between the sides end (terms are applied by the caller).
    pub fn make_peace(&mut self, war_id: usize, terms: &[Term]) {
        let wi = match self.war_index(war_id) {
            Some(i) => i,
            None => return,
        };
        self.forces_after_peace(war_id);
        let terms_desc = crate::treaties::describe_all(self, terms);
        self.war_note(war_id, if terms_desc.is_empty() { "peace (white peace)".to_string() } else { format!("peace: {}", terms_desc) }, true);
        let w = self.wars.remove(wi);
        let (s0, s1) = (&w.sides[0], &w.sides[1]);
        for s in self.systems.iter_mut() {
            let cross = |o: Option<usize>, p: Option<usize>| match (o, p) {
                (Some(o), Some(p)) => (s0.contains(&o) && s1.contains(&p)) || (s1.contains(&o) && s0.contains(&p)),
                _ => false,
            };
            if cross(s.owner, s.occupier) {
                s.occupier = None;
            }
        }
        let y = self.year();
        for &a in s0 {
            for &b in s1 {
                let r = self.rel_mut(a, b);
                r.stance = Stance::Hostile;
                r.truce_until = y + TRUCE_YEARS;
                r.opinion = r.opinion.max(-60.0);
            }
        }
        let names = |v: &Vec<usize>| v.iter().map(|&x| self.empires[x].name.clone()).collect::<Vec<_>>().join(" + ");
        let desc = crate::treaties::describe_all(self, terms);
        let t = format!(
            "PEACE between {} and {} after {} years{}",
            names(s0),
            names(s1),
            (self.tick - w.start) / 12,
            if terms.is_empty() { " (white peace)".to_string() } else { format!(": {}", desc) }
        );
        self.event(t);
        self.clear_empire_caches();
        self.on_system_claimed();
    }

    /// A system changes hands with its colonies, people and deposits; the winner inherits what the colonies knew.
    pub fn transfer_system(&mut self, s: usize, winner: usize, loser: usize) {
        self.colony_gen += 1;
        self.loss_gen += 1;
        self.systems[s].owner = Some(winner);
        self.systems[s].occupier = None;
        for c in self.systems[s].bodies.clone() {
            if self.colonies[c].owner != Some(loser) {
                continue;
            }
            let known = self.colonies[c].rich().clone();
            let col = &mut self.colonies[c];
            let info = col.intel_for(winner);
            for (g, v) in known.0 {
                if v > info.rich.get(g) {
                    info.rich.set(g, v);
                }
            }
            col.owner = Some(winner);
            col.rich_from = Some(winner);
        }
        self.empires[winner].known[s] = true;
        self.colony_set_changed();
        self.on_system_claimed();
    }

    pub fn output_factor(&self, c: usize) -> f64 {
        if self.wars.is_empty() {
            return 1.0;
        }
        match self.colonies[c].system {
            Some(s) if self.systems[s].occupier.is_some() => OCCUPIED_OUTPUT,
            Some(s) if self.systems[s].at_front => FRONT_OUTPUT,
            _ => 1.0,
        }
    }

    pub fn mark_fronts(&mut self) {
        for s in self.systems.iter_mut() {
            s.at_front = false;
        }
        let mut pairs = vec![];
        for w in &self.wars {
            for &a in &w.sides[0] {
                for &b in &w.sides[1] {
                    pairs.push((a, b));
                }
            }
        }
        for (a, b) in pairs {
            for s in self.fronts(a, b).into_iter().chain(self.fronts(b, a)) {
                self.systems[s].at_front = true;
            }
        }
    }

    pub fn occupation_effects(&mut self) {
        for si in 0..self.systems.len() {
            if self.systems[si].occupier.is_some() {
                for c in self.systems[si].bodies.clone() {
                    if self.colonies[c].settled {
                        self.colonies[c].pop *= 1.0 - OCCUPIED_POP_LOSS;
                    }
                }
            }
        }
    }
}
