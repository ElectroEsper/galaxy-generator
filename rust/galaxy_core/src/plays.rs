//! Diplomatic plays (the Victoria 3 route to war): a demand with a deadline, backers on both sides, escalation, a
//! mediation attempt, and war at the deadline if nobody yielded. Many crises end without a shot: the target concedes
//! when outmatched, the demander backs down (losing face) when it is.

use crate::personality::shift;
use crate::treaties::{self, Term};
use crate::world::{World, TRAIT_AGGRESSION, TRAIT_CAUTION, TRAIT_INTERVENTION};

pub const DEADLINE_MONTHS: u32 = 12;
pub const ESCALATION_MONTH: u32 = 6;
pub const BACK_DOWN_RATIO: f64 = 1.0 / 1.1; // the demander's side this outmatched backs down
pub const REP_BACK_DOWN: f64 = 8.0;
pub const REP_CONCEDE_GAIN: f64 = 3.0;
pub const PLAY_TRUCE_YEARS: i64 = 5;
pub const BACK_DOWN_TRUCE_YEARS: i64 = 10;
pub const MEDIATION_EVEN: f64 = 1.3; // mediation works only while neither side dominates by this much

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct Play {
    pub id: usize,
    pub a: usize,
    pub b: usize,
    pub demands: Vec<Term>,
    /// The war goals A will fight for if it comes to war.
    pub goals: Vec<Term>,
    pub start: u32,
    /// Backers: [A's side, B's side] (not counting A and B).
    pub backers: [Vec<usize>; 2],
    pub asked: Vec<usize>,
    pub escalated: bool,
}

impl World {
    pub fn in_play(&self, e: usize) -> bool {
        self.plays.iter().any(|p| p.a == e || p.b == e)
    }

    fn side_strength(&self, p: &Play, side: usize) -> f64 {
        let lead = if side == 0 { p.a } else { p.b };
        self.empires[lead].strength + p.backers[side].iter().map(|&x| self.empires[x].strength).sum::<f64>()
    }

    /// Open a play: a demands `demands` from b, ready to fight for `goals`.
    pub fn start_play(&mut self, a: usize, b: usize, demands: Vec<Term>, goals: Vec<Term>) {
        let id = self.next_play_id;
        self.next_play_id += 1;
        let desc = treaties::describe_all(self, &demands);
        let t = format!("CRISIS: {} demands {} from {} within a year", self.empires[a].name, desc, self.empires[b].name);
        self.event(t);
        self.plays.push(Play { id, a, b, demands, goals, start: self.tick, backers: [vec![], vec![]], asked: vec![], escalated: false });
        self.seek_backers(id);
    }

    /// Third parties decide whether to back a side (each is asked once, at the start and again at escalation).
    fn seek_backers(&mut self, id: usize) {
        let pi = match self.plays.iter().position(|p| p.id == id) {
            Some(i) => i,
            None => return,
        };
        let p = self.plays[pi].clone();
        for y in 0..self.empires.len() {
            if y == p.a || y == p.b || p.backers[0].contains(&y) || p.backers[1].contains(&y) || self.in_any_war(y) || self.in_play(y) {
                continue;
            }
            if !self.rel(y, p.a).met || !self.rel(y, p.b).met {
                continue;
            }
            let ey = &self.empires[y];
            let bound_b = crate::alliances::has_pact(self, y, p.b) || ey.guarantees_(p.b);
            let fears_a = ey.main_threat == Some(p.a) || ey.threat[p.a] >= 1.5;
            let pact_a = crate::alliances::has_pact(self, y, p.a);
            let chance_b = if bound_b {
                0.6 + 0.4 * (1.0 - ey.t(TRAIT_CAUTION))
            } else if fears_a {
                0.5 * (0.5 + ey.t(TRAIT_INTERVENTION))
            } else {
                0.0
            };
            let a_ahead = self.side_strength(&p, 0) > self.side_strength(&p, 1);
            let chance_a = if pact_a {
                0.5 * (0.5 + ey.t(TRAIT_AGGRESSION))
            } else if ey.t(TRAIT_AGGRESSION) >= 0.6 && self.rel(y, p.b).border > 0 && a_ahead {
                0.3
            } else {
                0.0
            };
            let bk = ey.fx(crate::personality::FX_BACKING);
            let (chance_a, chance_b) = ((chance_a * bk).min(1.0), (chance_b * bk).min(1.0));
            let r = self.rng.randf();
            let side = if r < chance_b && chance_b >= chance_a {
                Some(1)
            } else if r < chance_a {
                Some(0)
            } else {
                None
            };
            if let Some(s) = side {
                self.plays[pi].backers[s].push(y);
                let lead = if s == 0 { p.a } else { p.b };
                let t = format!("{} backs {} in the crisis", self.empires[y].name, self.empires[lead].name);
                self.event(t);
            }
            self.plays[pi].asked.push(y);
        }
    }

    /// Monthly: concede, back down, escalate (with a mediation attempt), or go to war at the deadline.
    pub fn plays_monthly(&mut self) {
        let ids: Vec<usize> = self.plays.iter().map(|p| p.id).collect();
        for id in ids {
            let pi = match self.plays.iter().position(|p| p.id == id) {
                Some(i) => i,
                None => continue,
            };
            let p = self.plays[pi].clone();
            // A party dragged into a war elsewhere drops the crisis.
            if self.in_any_war(p.a) || self.in_any_war(p.b) {
                self.plays.remove(pi);
                continue;
            }
            let age = self.tick - p.start;
            let ratio = self.side_strength(&p, 0) / self.side_strength(&p, 1).max(1.0);
            let eb = &self.empires[p.b];
            let spine = (1.3 + 0.6 * (1.0 - eb.t(TRAIT_CAUTION)) + 0.4 * eb.t(TRAIT_AGGRESSION)) * eb.fx(crate::personality::FX_SPINE);
            if ratio >= spine {
                self.resolve_concede(pi, &p.demands.clone(), "concedes");
                continue;
            }
            // The demander holds firm until the crisis escalates; aggressive ones hold even when somewhat outmatched.
            if age >= ESCALATION_MONTH && ratio <= BACK_DOWN_RATIO - 0.3 * self.empires[p.a].t(TRAIT_AGGRESSION) {
                self.resolve_back_down(pi);
                continue;
            }
            if age >= ESCALATION_MONTH && !p.escalated {
                self.plays[pi].escalated = true;
                let y = self.year();
                self.empires[p.a].arming_until = y + crate::military::ARMING_YEARS;
                self.empires[p.b].arming_until = y + crate::military::ARMING_YEARS;
                let t = format!("The crisis between {} and {} escalates: both sides mobilise", self.empires[p.a].name, self.empires[p.b].name);
                self.event(t);
                self.seek_backers(id);
                if self.try_mediation(id) {
                    continue;
                }
            }
            if age >= DEADLINE_MONTHS {
                let pi = match self.plays.iter().position(|q| q.id == id) {
                    Some(i) => i,
                    None => continue,
                };
                let p = self.plays.remove(pi);
                let t = format!("{} rejects {}'s demands: the crisis becomes war", self.empires[p.b].name, self.empires[p.a].name);
                self.event(t);
                let war = self.declare(p.a, p.b, p.goals.clone());
                for s in 0..2 {
                    for &y in &p.backers[s] {
                        if !self.in_any_war(y) {
                            self.join_war(war, y, s, "backing it in the crisis");
                        }
                    }
                }
            }
        }
    }

    fn resolve_concede(&mut self, pi: usize, demands: &[Term], how: &str) {
        let p = self.plays.remove(pi);
        let t = format!("{} {} to {}: {}", self.empires[p.b].name, how, self.empires[p.a].name, treaties::describe_all(self, demands));
        self.event(t);
        let v = treaties::total(self, demands);
        treaties::apply_terms(self, demands, p.a, p.b, v, true, -1.0);
        let y = self.year();
        self.rel_mut(p.a, p.b).truce_until = y + PLAY_TRUCE_YEARS;
        shift(self, p.b, TRAIT_CAUTION, -0.1, "");
        shift(self, p.b, TRAIT_AGGRESSION, 0.05, "");
    }

    fn resolve_back_down(&mut self, pi: usize) {
        let p = self.plays.remove(pi);
        let t = format!("{} backs down from its demands on {}", self.empires[p.a].name, self.empires[p.b].name);
        self.event(t);
        let why = format!("backed down before {}", self.empires[p.b].name);
        crate::alliances::adjust_reputation(self, p.a, -REP_BACK_DOWN, &why);
        let why = format!("stood firm against {}", self.empires[p.a].name);
        crate::alliances::adjust_reputation(self, p.b, REP_CONCEDE_GAIN, &why);
        let y = self.year();
        self.rel_mut(p.a, p.b).truce_until = y + BACK_DOWN_TRUCE_YEARS;
        shift(self, p.a, TRAIT_CAUTION, 0.05, "");
    }

    /// A neutral interventionist proposes a compromise: only the cheapest demand. Both accept while neither side
    /// dominates (a strong demander wants everything; a strong target concedes nothing).
    fn try_mediation(&mut self, id: usize) -> bool {
        let pi = match self.plays.iter().position(|p| p.id == id) {
            Some(i) => i,
            None => return false,
        };
        let p = self.plays[pi].clone();
        let mediator = (0..self.empires.len())
            .filter(|&y| y != p.a && y != p.b && !p.backers[0].contains(&y) && !p.backers[1].contains(&y) && !self.in_any_war(y))
            .filter(|&y| self.empires[y].t(TRAIT_INTERVENTION) * self.empires[y].fx(crate::personality::FX_MEDIATION) >= 0.6 && self.rel(y, p.a).met && self.rel(y, p.b).met)
            .max_by(|&x, &y| self.empires[x].t(TRAIT_INTERVENTION).partial_cmp(&self.empires[y].t(TRAIT_INTERVENTION)).unwrap());
        let m = match mediator {
            Some(m) => m,
            None => return false,
        };
        let ratio = self.side_strength(&p, 0) / self.side_strength(&p, 1).max(1.0);
        if p.demands.len() < 2 || !(1.0 / MEDIATION_EVEN..=MEDIATION_EVEN).contains(&ratio) {
            let t = format!("{} offers to mediate between {} and {}, without success", self.empires[m].name, self.empires[p.a].name, self.empires[p.b].name);
            self.event(t);
            return false;
        }
        let cheapest = p.demands.iter().cloned().min_by(|x, y| treaties::value(self, x).partial_cmp(&treaties::value(self, y)).unwrap()).unwrap();
        let t = format!("{} mediates between {} and {}: a compromise", self.empires[m].name, self.empires[p.a].name, self.empires[p.b].name);
        self.event(t);
        self.resolve_concede(pi, &[cheapest], "accepts the compromise and yields");
        let why = format!("mediated between {} and {}", self.empires[p.a].name, self.empires[p.b].name);
        crate::alliances::adjust_reputation(self, m, 3.0, &why);
        true
    }
}
