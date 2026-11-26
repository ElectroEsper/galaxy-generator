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

#[derive(Clone, Debug)]
pub struct War {
    pub id: usize,
    pub a: usize,
    pub b: usize,
    pub start: u32,
    pub peak_a: f64,
    pub peak_b: f64,
    /// The war an ally joined by answering a call to arms.
    pub parent: Option<usize>,
    pub goals: Vec<Term>,
    pub first_strike_until: i64,
}

impl World {
    pub fn year(&self) -> i64 {
        self.tick as i64 / 12
    }

    pub fn at_war(&self, a: usize, b: usize) -> bool {
        self.wars.iter().any(|w| (w.a == a && w.b == b) || (w.a == b && w.b == a))
    }

    pub fn in_any_war(&self, x: usize) -> bool {
        self.wars.iter().any(|w| w.a == x || w.b == x)
    }

    pub fn owned_systems(&self, e: usize) -> Vec<usize> {
        self.systems.iter().filter(|s| s.owner == Some(e)).map(|s| s.id).collect()
    }

    // ------------------------------------------------------------ Budget
    pub fn military_monthly(&mut self) {
        for e in 0..self.empires.len() {
            self.fund(e);
        }
        let ids: Vec<usize> = self.wars.iter().map(|w| w.id).collect();
        for id in ids {
            if let Some(i) = self.wars.iter().position(|w| w.id == id) {
                self.fight(i);
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
        let m = 0.3 + 1.4 * self.empires[e].t(TRAIT_MILITARISM);
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
        if self.empires[e].demilitarized_until > self.year() {
            t *= crate::treaties::DEMILITARIZE_CAP;
        }
        t
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
            let avail: f64 = self.empire_colonies(e).iter().map(|&c| self.colonies[c].stock[g]).sum();
            self.note_military(e, g, n * q);
            n = n.min(avail / q);
        }
        if n <= 0.0 {
            return;
        }
        let mut cost = n * UNIT_CASH;
        for &(g, q) in goods::MILITARY_UNIT {
            cost += self.buy(e, g, n * q).1;
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

    pub fn declare(&mut self, a: usize, b: usize, parent: Option<usize>, goals: Vec<Term>) -> usize {
        {
            let r = self.rel_mut(a, b);
            r.trade_treaty = false;
            r.passage = false;
            r.stance = Stance::Embargo;
        }
        let id = self.next_war_id;
        self.next_war_id += 1;
        let (sa, sb) = (self.empires[a].strength, self.empires[b].strength);
        let goal_value = crate::treaties::total(self, &goals);
        let desc = crate::treaties::describe_all(self, &goals);
        self.wars.push(War { id, a, b, start: self.tick, peak_a: sa, peak_b: sb, parent, goals, first_strike_until: -1 });
        if parent.is_none() {
            let y = self.year();
            self.empires[a].wars_started.push(y);
            crate::alliances::adjust_trust(self, b, a, crate::alliances::TRUST_ATTACKED);
            let why = format!("attacked {}", self.empires[b].name);
            crate::alliances::adjust_reputation(self, a, crate::alliances::REP_WAR_OF_CHOICE - crate::treaties::REP_PER_GOAL_POINT * goal_value, &why);
            let t = format!("WAR: {} declares war on {} (strength {} vs {}){}", self.empires[a].name, self.empires[b].name, sa as i64, sb as i64, if desc.is_empty() { String::new() } else { format!(" - goals: {}", desc) });
            self.event(t);
            crate::alliances::call_to_arms(self, a, b, id);
        }
        self.on_system_claimed();
        id
    }

    fn fight(&mut self, wi: usize) {
        let w = self.wars[wi].clone();
        let (a, b) = (w.a, w.b);
        let fa = self.fronts(a, b);
        let fb = self.fronts(b, a);
        self.empires[a].exhaustion += EXH_PER_MONTH;
        self.empires[b].exhaustion += EXH_PER_MONTH;
        if fa.is_empty() && fb.is_empty() {
            self.check_capitulation(w.id);
            return;
        }
        // Allies who joined this war with no front of their own fight on b's front.
        let helpers: Vec<usize> = self
            .wars
            .iter()
            .filter(|x| x.parent == Some(w.id))
            .map(|x| x.a)
            .filter(|&h| self.fronts(h, a).is_empty() && self.fronts(a, h).is_empty())
            .collect();
        let sa = self.empires[a].strength * COMMIT;
        let mut sb = self.empires[b].strength * COMMIT;
        let sh: f64 = helpers.iter().map(|&h| self.empires[h].strength * COMMIT * 0.5).sum();
        let mut la = self.empires[a].strength.min(ATTRITION * (sb + sh));
        let lb_total = ATTRITION * sa;
        let mut lb = self.empires[b].strength.min(lb_total * sb / (sb + sh).max(0.001));
        for &h in &helpers {
            let lh = self.empires[h].strength.min(lb_total * self.empires[h].strength * COMMIT * 0.5 / (sb + sh).max(0.001));
            self.empires[h].strength -= lh;
            self.empires[h].exhaustion += EXH_LOSS_WEIGHT * lh / (self.empires[h].strength + lh).max(1.0);
        }
        if (self.tick as i64) < w.first_strike_until {
            la *= 0.5;
            lb *= 1.5;
        }
        self.empires[a].strength -= la;
        self.empires[b].strength -= lb;
        sb += sh;
        let (pa, pb) = {
            let wr = &mut self.wars[wi];
            wr.peak_a = wr.peak_a.max(self.empires[a].strength);
            wr.peak_b = wr.peak_b.max(self.empires[b].strength);
            (wr.peak_a, wr.peak_b)
        };
        self.empires[a].exhaustion += EXH_LOSS_WEIGHT * la / pa.max(1.0);
        self.empires[b].exhaustion += EXH_LOSS_WEIGHT * lb / pb.max(1.0);
        let sup = sa / (sa + sb).max(0.001);
        if sup > 0.55 {
            self.occupy(a, b, &fb, (sup - 0.55) / 0.45);
        } else if sup < 0.45 {
            self.occupy(b, a, &fa, (0.45 - sup) / 0.45);
        }
        self.check_capitulation(w.id);
    }

    fn occupy(&mut self, winner: usize, loser: usize, loser_fronts: &[usize], edge: f64) {
        if self.rng.randf() >= OCCUPY_RATE * edge {
            return;
        }
        if let Some(s) = self.systems.iter().position(|s| s.owner == Some(winner) && s.occupier == Some(loser)) {
            self.systems[s].occupier = None;
            let t = format!("{} liberates {} from {}", self.empires[winner].name, self.systems[s].name, self.empires[loser].name);
            self.event(t);
            self.on_system_claimed();
            return;
        }
        let cap = self.empires[loser].capital;
        let targets: Vec<usize> = loser_fronts.iter().cloned().filter(|&s| !self.systems[s].bodies.contains(&cap)).collect();
        if targets.is_empty() {
            return;
        }
        let t = targets[self.rng.below(targets.len())];
        self.systems[t].occupier = Some(winner);
        self.empires[loser].exhaustion += EXH_PER_OCCUPIED;
        let txt = format!("{} occupies {} ({})", self.empires[winner].name, self.systems[t].name, self.empires[loser].name);
        self.event(txt);
        self.on_system_claimed();
    }

    fn check_capitulation(&mut self, war_id: usize) {
        let w = match self.wars.iter().find(|w| w.id == war_id) {
            Some(w) => w.clone(),
            None => return,
        };
        for side in [w.a, w.b] {
            if self.empires[side].exhaustion >= EXH_CAPITULATE {
                crate::treaties::capitulate(self, war_id, side);
                return;
            }
        }
    }

    /// Peace: occupations between the two end (systems return to their owners); terms are applied by the caller.
    pub fn make_peace(&mut self, war_id: usize, terms: &[Term]) {
        let w = match self.wars.iter().find(|w| w.id == war_id) {
            Some(w) => w.clone(),
            None => return,
        };
        let (a, b) = (w.a, w.b);
        for s in self.systems.iter_mut() {
            if (s.owner == Some(a) && s.occupier == Some(b)) || (s.owner == Some(b) && s.occupier == Some(a)) {
                s.occupier = None;
            }
        }
        self.wars.retain(|x| x.id != war_id);
        let children: Vec<usize> = self.wars.iter().filter(|x| x.parent == Some(war_id)).map(|x| x.id).collect();
        for c in children {
            self.make_peace(c, &[]);
        }
        let y = self.year();
        {
            let r = self.rel_mut(a, b);
            r.stance = Stance::Hostile;
            r.truce_until = y + TRUCE_YEARS;
            r.opinion = r.opinion.max(-60.0);
        }
        let desc = crate::treaties::describe_all(self, terms);
        let t = format!(
            "PEACE between {} and {} after {} years{}",
            self.empires[a].name,
            self.empires[b].name,
            (self.tick - w.start) / 12,
            if terms.is_empty() { " (white peace)".to_string() } else { format!(": {}", desc) }
        );
        self.event(t);
        self.clear_empire_caches();
        self.on_system_claimed();
    }

    /// A system changes hands with its colonies, people and deposits; the winner inherits what the colonies knew.
    pub fn transfer_system(&mut self, s: usize, winner: usize, loser: usize) {
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
        self.clear_empire_caches();
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
        let pairs: Vec<(usize, usize)> = self.wars.iter().map(|w| (w.a, w.b)).collect();
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
