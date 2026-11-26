//! Goal-oriented diplomacy (diplomacy.gd): once a year each empire picks its most pressing goal, plans the cheapest
//! sequence of diplomatic actions that reaches it (uniform-cost search over boolean facts), and carries out the first
//! step. Facts are booleans, global or per partner; the state is a flat Vec<bool> indexed by (fact, partner).

use crate::goods;
use crate::market::{dist, BASE_PRICE, MAX_EMPIRES};
use crate::personality::{attack_ratio, peace_exhaustion};
use crate::world::{World, ROUTE_SAMPLE, TERRITORY_RADIUS, TRAIT_AGGRESSION, TRAIT_CAUTION, TRAIT_EXPANSION, TRAIT_INTERVENTION, TRAIT_MERCANTILE};
use std::collections::HashSet;

pub const AID_COST: f64 = 20000.0;
pub const AID_GOODWILL: f64 = 20.0;
pub const PASSAGE_FEE: f64 = 5000.0;
pub const OP_OK: f64 = -10.0;
pub const OP_GOOD: f64 = 10.0;
pub const REFUSAL_COOLDOWN: i64 = 5;
pub const MAX_DEPTH: usize = 4;
pub const RIVAL_BORDER: i32 = 15;
pub const HUNGER_RANGE: f64 = 180.0;
pub const HUNGER_BORDER: i32 = 3;
pub const WAR_BORDER: i32 = 5;
pub const PEACE_COOLDOWN: i64 = 2;

// ---------------------------------------------------------------- Facts
#[derive(serde::Serialize, serde::Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[repr(usize)]
pub enum F {
    Cash,
    Arming,
    Tired,
    Met,
    Trade,
    Pass,
    OpOk,
    OpGood,
    Reach,
    Hostile,
    Covet,
    Stronger,
    Pact,
    Opportunity,
    Guar,
    War,
    /// There is a war involving this empire that we could join against it.
    CanJoin,
}
const NF: usize = 17;
const GLOBAL: usize = MAX_EMPIRES; // partner slot for global facts

fn key(f: F, partner: usize) -> usize {
    f as usize * (MAX_EMPIRES + 1) + partner
}
fn g(f: F) -> usize {
    key(f, GLOBAL)
}

type State = Vec<bool>;
type Cond = Vec<(usize, bool)>;

#[derive(serde::Serialize, serde::Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum Act {
    ProposeTrade,
    ProposePassage,
    SendAid,
    Arm,
    DeclareWar,
    SueForPeace,
    ProposePact,
    OfferGuarantee,
    JoinWar,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct Action {
    pub act: Act,
    pub x: usize,
    pub cost: f64,
    pub pre: Cond,
    pub eff: Cond,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct Goal {
    pub name: String,
    pub priority: f64,
    pub want: Cond,
}

fn facts(w: &World, e: usize) -> State {
    let mut f = vec![false; NF * (MAX_EMPIRES + 1)];
    let year = w.year();
    let em = &w.empires[e];
    f[g(F::Cash)] = em.treasury >= AID_COST * 2.0;
    f[g(F::Arming)] = year < em.arming_until;
    f[g(F::Tired)] = em.exhaustion >= 20.0;
    let hungry = land_hungry(w, e);
    for x in 0..w.empires.len() {
        if x == e {
            continue;
        }
        let r = w.rel(e, x);
        let truce_over = year >= r.truce_until;
        f[key(F::Met, x)] = r.met;
        f[key(F::Trade, x)] = r.trade_treaty;
        f[key(F::Pass, x)] = r.passage;
        f[key(F::OpOk, x)] = r.opinion >= OP_OK;
        f[key(F::OpGood, x)] = r.opinion >= OP_GOOD;
        f[key(F::Reach, x)] = r.opinion >= OP_OK - AID_GOODWILL * 0.8;
        f[key(F::Hostile, x)] = r.met && truce_over && (matches!(r.stance, crate::world::Stance::Hostile | crate::world::Stance::Embargo) || (r.opinion < 0.0 && r.border >= RIVAL_BORDER));
        f[key(F::Covet, x)] = hungry && r.met && r.border >= HUNGER_BORDER && truce_over;
        f[key(F::Stronger, x)] = em.strength > crate::alliances::effective_strength(w, x, e) * attack_ratio(w, e);
        f[key(F::Pact, x)] = r.pact;
        f[key(F::Opportunity, x)] = crate::treaties::opportunity(w, e, x);
        f[key(F::Guar, x)] = em.guarantees_(x);
        f[key(F::War, x)] = w.at_war(e, x);
        f[key(F::CanJoin, x)] = !w.in_any_war(e) && w.wars.iter().any(|war| war.side_of(x).is_some());
    }
    f
}

fn actions(w: &World, e: usize) -> Vec<Action> {
    let mut acts = vec![];
    let aggr = w.empires[e].t(TRAIT_AGGRESSION);
    for x in 0..w.empires.len() {
        if x == e {
            continue;
        }
        let k = |f: F| key(f, x);
        let mut add = |act: Act, cost: f64, pre: Cond, eff: Cond| acts.push(Action { act, x, cost, pre, eff });
        add(Act::ProposeTrade, 1.0, vec![(k(F::Met), true), (k(F::OpOk), true), (k(F::Trade), false), (k(F::War), false)], vec![(k(F::Trade), true)]);
        add(Act::ProposePassage, 1.5, vec![(k(F::Met), true), (k(F::OpGood), true), (k(F::Pass), false), (g(F::Cash), true), (k(F::War), false)], vec![(k(F::Pass), true)]);
        add(Act::SendAid, 3.0, vec![(k(F::Met), true), (k(F::OpOk), false), (k(F::Reach), true), (g(F::Cash), true)], vec![(k(F::OpOk), true)]);
        add(Act::SendAid, 3.0, vec![(k(F::Met), true), (k(F::OpOk), true), (k(F::OpGood), false), (g(F::Cash), true)], vec![(k(F::OpGood), true)]);
        add(Act::Arm, 2.0, vec![(k(F::Met), true), (k(F::Stronger), false), (g(F::Arming), false)], vec![(k(F::Stronger), true), (g(F::Arming), true)]);
        add(Act::DeclareWar, 4.0 + 12.0 * (1.0 - aggr), vec![(k(F::Hostile), true), (k(F::Stronger), true), (k(F::War), false), (g(F::Tired), false)], vec![(k(F::War), true)]);
        add(Act::DeclareWar, 5.0 + 12.0 * (1.0 - aggr), vec![(k(F::Covet), true), (k(F::Stronger), true), (k(F::War), false), (g(F::Tired), false)], vec![(k(F::War), true)]);
        add(Act::DeclareWar, 3.0, vec![(k(F::Opportunity), true), (k(F::War), false), (g(F::Tired), false)], vec![(k(F::War), true)]);
        add(Act::ProposePact, 2.0, vec![(k(F::Met), true), (k(F::OpOk), true), (k(F::Pact), false), (k(F::War), false)], vec![(k(F::Pact), true)]);
        add(Act::OfferGuarantee, 2.5, vec![(k(F::Met), true), (k(F::Guar), false), (k(F::War), false)], vec![(k(F::Guar), true)]);
        add(Act::SueForPeace, 1.0, vec![(k(F::War), true)], vec![(k(F::War), false)]);
        add(Act::JoinWar, 2.0, vec![(k(F::CanJoin), true), (k(F::War), false), (g(F::Tired), false)], vec![(k(F::War), true)]);
    }
    acts
}

fn satisfied(st: &State, want: &Cond) -> bool {
    want.iter().all(|&(k, v)| st[k] == v)
}

/// Cheapest action sequence (uniform-cost search, depth-limited) from facts to a state satisfying want.
pub fn plan(start: &State, want: &Cond, actions: &[Action]) -> Vec<usize> {
    let mut frontier: Vec<(f64, State, Vec<usize>)> = vec![(0.0, start.clone(), vec![])];
    let mut seen: HashSet<State> = HashSet::new();
    while !frontier.is_empty() {
        let bi = (0..frontier.len()).min_by(|&i, &j| frontier[i].0.partial_cmp(&frontier[j].0).unwrap()).unwrap();
        let (cost, st, path) = frontier.remove(bi);
        if satisfied(&st, want) {
            return path;
        }
        if path.len() >= MAX_DEPTH || !seen.insert(st.clone()) {
            continue;
        }
        for (ai, a) in actions.iter().enumerate() {
            if !satisfied(&st, &a.pre) {
                continue;
            }
            let mut nxt = st.clone();
            for &(k, v) in &a.eff {
                nxt[k] = v;
            }
            if a.act == Act::SendAid {
                nxt[g(F::Cash)] = st[g(F::Cash)]; // assume one gesture is affordable
            }
            let mut p = path.clone();
            p.push(ai);
            frontier.push((cost + a.cost, nxt, p));
        }
    }
    vec![]
}

// ---------------------------------------------------------------- Helpers
fn avg_price(w: &World, e: usize, gd: usize) -> f64 {
    let own = w.empire_colonies(e);
    own.iter().map(|&c| w.colonies[c].price[gd]).sum::<f64>() / (own.len().max(1)) as f64
}

/// At least 5 systems, and no unclaimed star system within HUNGER_RANGE of any of them.
pub fn land_hungry(w: &World, e: usize) -> bool {
    let mine = w.owned_systems(e);
    if mine.len() < 5 {
        return false;
    }
    !w.systems.iter().any(|s| s.owner.is_none() && mine.iter().any(|&m| dist(w.systems[m].pos, s.pos) <= HUNGER_RANGE))
}

fn owner_at(w: &World, p: (f64, f64)) -> Option<usize> {
    let mut best = None;
    let mut bd = TERRITORY_RADIUS;
    for s in &w.systems {
        if s.owner.is_some() {
            let d = dist(s.pos, p);
            if d <= bd {
                bd = d;
                best = s.owner;
            }
        }
    }
    best
}

/// The first other empire whose territory lies between e's capital and x's without passage rights.
fn blocker(w: &World, e: usize, x: usize) -> Option<usize> {
    let a = w.colonies[w.empires[e].capital].pos;
    let b = w.colonies[w.empires[x].capital].pos;
    let n = (dist(a, b) / ROUTE_SAMPLE) as usize;
    for i in 1..n {
        let t = i as f64 / n as f64;
        if let Some(z) = owner_at(w, (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)) {
            if z != e && z != x && !(w.rel(e, z).met && w.rel(e, z).passage) {
                return Some(z);
            }
        }
    }
    None
}

// ---------------------------------------------------------------- Goals
fn goals(w: &World, e: usize) -> Vec<Goal> {
    let mut out: Vec<Goal> = vec![];
    let em = &w.empires[e];
    let n = w.empires.len();
    let year = w.year();
    let others: Vec<usize> = (0..n).filter(|&x| x != e).collect();
    // Supply: goods we're short of, from the met empire that has them cheapest.
    for gd in goods::ALL {
        let mine = avg_price(w, e, gd);
        if mine < BASE_PRICE * 1.8 {
            continue;
        }
        let (mut best, mut bp) = (None, mine * 0.7);
        for &x in &others {
            if !w.rel(e, x).met {
                continue;
            }
            let p = avg_price(w, x, gd);
            if p < bp {
                bp = p;
                best = Some(x);
            }
        }
        if let Some(x) = best {
            if !w.rel(e, x).trade_treaty {
                out.push(Goal { name: format!("secure {} from {}", goods::NAMES[gd], w.empires[x].name), priority: mine / BASE_PRICE * em.w(TRAIT_MERCANTILE), want: vec![(key(F::Trade, x), true)] });
            }
        }
    }
    // Reach a trade partner through a third empire's territory.
    for &x in &others {
        if !w.rel(e, x).trade_treaty {
            continue;
        }
        if let Some(z) = blocker(w, e, x) {
            out.push(Goal { name: format!("reach {} through {}", w.empires[x].name, w.empires[z].name), priority: 1.5, want: vec![(key(F::Pass, z), true)] });
        }
    }
    // Calm a hostile neighbour; open trade with friends.
    for &x in &others {
        let r = w.rel(e, x);
        if r.met && r.opinion < -25.0 && r.border > 0 {
            out.push(Goal { name: format!("ease tension with {}", w.empires[x].name), priority: 0.5 + r.border as f64 / 10.0, want: vec![(key(F::OpOk, x), true)] });
        }
        if r.met && !r.trade_treaty && r.opinion >= OP_GOOD {
            out.push(Goal { name: format!("open trade with {}", w.empires[x].name), priority: 0.3 * em.w(TRAIT_MERCANTILE), want: vec![(key(F::Trade, x), true)] });
        }
    }
    // War: end a war going badly; deter a stronger hostile neighbour; seize the border from a weaker hostile one.
    for &x in &others {
        let r = w.rel(e, x);
        if w.at_war(e, x) {
            // Judge the war by the coalitions, not by our own strength alone (a junior ally is always smaller).
            let wi = w.war_index(w.war_between(e, x).unwrap()).unwrap();
            let war = &w.wars[wi];
            let side = war.side_of(e).unwrap();
            // Losing by forecast: play the war out from here on what we believe (coalitions included).
            let (mine, theirs) = (war.sides[side].clone(), war.sides[1 - side].clone());
            let losing = w.forecast_war(e, &mine, &theirs, 0, false, 0x9EACE ^ x as u64).p_win < 0.3;
            if em.exhaustion >= peace_exhaustion(w, e) || losing {
                out.push(Goal { name: format!("end the war with {}", w.empires[x].name), priority: 5.0, want: vec![(key(F::War, x), false)] });
            }
            continue;
        }
        let hostile = r.met && (matches!(r.stance, crate::world::Stance::Hostile | crate::world::Stance::Embargo) || (r.opinion < 0.0 && r.border >= RIVAL_BORDER));
        if (hostile || em.threat[x] >= 1.5) && w.empires[x].strength > em.strength {
            out.push(Goal { name: format!("deter {}", w.empires[x].name), priority: (1.0 + r.border as f64 / 10.0) * em.w(TRAIT_CAUTION), want: vec![(key(F::Stronger, x), true)] });
        }
        if hostile && em.t(TRAIT_AGGRESSION) >= 0.25 && r.border >= WAR_BORDER && year >= r.truce_until && em.exhaustion < 20.0 {
            out.push(Goal { name: format!("seize the border with {}", w.empires[x].name), priority: (0.8 + r.border as f64 / 15.0) * em.w(TRAIT_AGGRESSION), want: vec![(key(F::War, x), true)] });
        }
    }
    // Land hunger: nothing left to settle nearby, so take it from the weakest neighbour along a shared border.
    if em.exhaustion < 20.0 && em.t(TRAIT_AGGRESSION) >= 0.25 && !w.in_any_war(e) && land_hungry(w, e) {
        let mut best: Option<usize> = None;
        for &x in &others {
            let r = w.rel(e, x);
            if r.met && r.border >= HUNGER_BORDER && year >= r.truce_until && best.map_or(true, |b| w.empires[x].strength < w.empires[b].strength) {
                best = Some(x);
            }
        }
        if let Some(x) = best {
            out.push(Goal { name: format!("expand into {} (no free land left)", w.empires[x].name), priority: 0.9 * em.w(TRAIT_EXPANSION) * em.w(TRAIT_AGGRESSION), want: vec![(key(F::War, x), true)] });
        }
    }
    // Revanche: take back what was lost when the victor is distracted or no longer stronger.
    for rev in &em.revanche {
        if rev.level >= crate::treaties::REV_ACT && !rev.claims.is_empty() && em.exhaustion < 20.0 && !w.in_any_war(e) {
            let names: Vec<String> = rev.claims.iter().map(|&s| w.systems[s].name.clone()).collect();
            out.push(Goal { name: format!("reclaim {} from {}", names.join(" "), w.empires[rev.victor].name), priority: 0.8 + rev.level / 50.0, want: vec![(key(F::War, rev.victor), true)] });
        }
    }
    // Coalitions: join a war against an aggressor we fear while its victims are losing; or, if aggressive, join a
    // winning attacker against a neighbour to share the spoils.
    if !w.in_any_war(e) && em.exhaustion < 20.0 {
        for war in &w.wars {
            let (att, def) = (war.leader(0), war.leader(1));
            if war.side_of(e).is_some() || w.rel(e, att).pact && w.rel(e, def).pact {
                continue;
            }
            let attackers_ahead = crate::treaties::score(w, war.id, 0);
            if (em.main_threat == Some(att) || em.threat[att] >= 1.5) && attackers_ahead > 0.0 && w.rel(e, att).met {
                out.push(Goal { name: format!("join the coalition against {}", w.empires[att].name), priority: (0.7 + 0.3 * em.threat[att].min(3.0)) * em.w(TRAIT_INTERVENTION), want: vec![(key(F::War, att), true)] });
            }
            if attackers_ahead > 20.0 && em.t(TRAIT_AGGRESSION) >= 0.6 && w.rel(e, def).border > 0 && !w.rel(e, def).pact && !em.guarantees_(def) && year >= w.rel(e, def).truce_until {
                out.push(Goal { name: format!("share the spoils of {}'s war on {}", w.empires[att].name, w.empires[def].name), priority: 0.6 * em.w(TRAIT_AGGRESSION) * em.w(TRAIT_EXPANSION), want: vec![(key(F::War, def), true)] });
            }
        }
    }
    // Alliances against the main threat.
    if let Some(t) = em.main_threat {
        if em.max_threat >= crate::threat::NOTE_LEVEL {
            let mut partner: Option<usize> = None;
            for &y in &others {
                if y == t || w.rel(e, y).pact || !w.rel(e, y).met || !crate::alliances::can_ally(w, e, y) {
                    continue;
                }
                if crate::alliances::reliance(w, e, y) < crate::alliances::PACT_TRUST {
                    continue;
                }
                if w.empires[y].threat[t] >= crate::threat::NOTE_LEVEL && partner.map_or(true, |p| w.empires[y].strength > w.empires[p].strength) {
                    partner = Some(y);
                }
            }
            if let Some(p) = partner {
                out.push(Goal { name: format!("contain {} with {}", w.empires[t].name, w.empires[p].name), priority: (0.6 + 0.3 * em.max_threat.min(3.0)) * em.w(TRAIT_CAUTION), want: vec![(key(F::Pact, p), true)] });
            }
            for &y in &others {
                if y == t || em.guarantees_(y) || !w.rel(e, y).met || !crate::alliances::can_ally(w, e, y) {
                    continue;
                }
                if !w.empires[y].guarantees_(e) && w.empires[y].strength < w.empires[t].strength * crate::alliances::SMALL && w.rel(y, t).border > 0 && w.rel(e, y).border > 0 {
                    out.push(Goal { name: format!("shield {} from {}", w.empires[y].name, w.empires[t].name), priority: 0.8 * em.w(TRAIT_INTERVENTION), want: vec![(key(F::Guar, y), true)] });
                }
            }
        }
    }
    out.sort_by(|a, b| b.priority.partial_cmp(&a.priority).unwrap());
    out
}

// ---------------------------------------------------------------- Partner decisions
fn accepts_trade(w: &World, x: usize, e: usize) -> bool {
    let mut benefit = 0.5;
    for gd in goods::ALL {
        let theirs = avg_price(w, x, gd);
        if theirs >= BASE_PRICE * 1.5 && avg_price(w, e, gd) < theirs * 0.8 {
            benefit += 1.0;
        }
    }
    w.rel(x, e).opinion / 20.0 + benefit >= 1.0
}

// ---------------------------------------------------------------- Yearly turn
impl World {
    pub fn diplomacy_yearly(&mut self) {
        crate::threat::yearly(self);
        crate::personality::yearly(self);
        crate::alliances::yearly(self);
        crate::treaties::yearly(self);
        for e in 0..self.empires.len() {
            self.diplomacy_turn(e);
        }
    }

    fn diplomacy_turn(&mut self, e: usize) {
        let st = facts(self, e);
        let acts = actions(self, e);
        let year = self.year();
        for goal in goals(self, e) {
            if satisfied(&st, &goal.want) {
                continue;
            }
            // Plan only with actions toward the partner(s) the goal is about: same answers, far smaller search.
            let partners: Vec<usize> = goal.want.iter().map(|&(k, _)| k % (MAX_EMPIRES + 1)).filter(|&p| p != GLOBAL).collect();
            let sub: Vec<Action> = acts.iter().filter(|a| partners.contains(&a.x)).cloned().collect();
            let p = plan(&st, &goal.want, &sub);
            if p.is_empty() {
                continue;
            }
            let a = sub[p[0]].clone();
            // Only a goal about ending the war may end it: otherwise every trade or pact goal with an enemy would
            // start by suing for peace (and junior members would walk out of every war within a year).
            if a.act == Act::SueForPeace && !goal.want.iter().any(|&(k, v)| k == key(F::War, a.x) && !v) {
                continue;
            }
            let cool = if a.act == Act::SueForPeace { PEACE_COOLDOWN } else { REFUSAL_COOLDOWN };
            let gated = matches!(a.act, Act::ProposeTrade | Act::ProposePassage | Act::SueForPeace | Act::ProposePact | Act::OfferGuarantee);
            if gated && self.empires[e].refusals.get(&a.x).map_or(false, |&y| y + cool > year) {
                continue;
            }
            self.execute(e, &a, &goal, year);
            return; // one diplomatic initiative per year
        }
    }

    fn execute(&mut self, e: usize, a: &Action, goal: &Goal, year: i64) {
        let x = a.x;
        let (en, xn) = (self.empires[e].name.clone(), self.empires[x].name.clone());
        match a.act {
            Act::SendAid => {
                self.empires[e].treasury -= AID_COST;
                self.empires[x].treasury += AID_COST;
                let r = self.rel_mut(e, x);
                r.goodwill += AID_GOODWILL;
                r.opinion = (r.opinion + AID_GOODWILL * 0.5).min(100.0);
                self.event(format!("{} sends aid to {} (goal: {})", en, xn, goal.name));
            }
            Act::ProposeTrade => {
                if accepts_trade(self, x, e) {
                    self.rel_mut(e, x).trade_treaty = true;
                    self.event(format!("{} and {} sign a trade treaty (goal: {})", en, xn, goal.name));
                } else {
                    self.empires[e].refusals.insert(x, year);
                    self.event(format!("{} refuses a trade treaty with {}", xn, en));
                }
            }
            Act::Arm => {
                self.empires[e].arming_until = year + crate::military::ARMING_YEARS;
                let t = format!("{} arms (goal: {}; strength {} vs {})", en, goal.name, self.empires[e].strength as i64, self.empires[x].strength as i64);
                self.event(t);
            }
            Act::DeclareWar => crate::treaties::go_to_war(self, e, x),
            Act::SueForPeace => {
                if let Some(id) = self.war_between(e, x) {
                    let wi = self.war_index(id).unwrap();
                    let side = self.wars[wi].side_of(e).unwrap();
                    if self.wars[wi].leader(side) == e {
                        if !crate::treaties::negotiate(self, id, e) {
                            self.empires[e].refusals.insert(x, year);
                        }
                    } else {
                        self.separate_peace(id, e, false); // a minor member just leaves
                    }
                }
            }
            Act::JoinWar => {
                // The war x is in; we join the other side.
                if let Some(wi) = self.wars.iter().position(|w| w.side_of(x).is_some() && w.side_of(e).is_none()) {
                    let id = self.wars[wi].id;
                    let side = 1 - self.wars[wi].side_of(x).unwrap();
                    // Forecast the war with us in it: only join a side we expect to win with.
                    let mut mine = self.wars[wi].sides[side].clone();
                    mine.push(e);
                    let theirs = self.wars[wi].sides[1 - side].clone();
                    let o = self.forecast_war(e, &mine, &theirs, 0, false, 0x101E ^ x as u64);
                    if o.p_win < self.war_threshold(e) {
                        let t = format!("{} stays out of the war against {} (forecast: {:.0}% to win)", en, xn, o.p_win * 100.0);
                        self.event(t);
                        self.empires[e].refusals.insert(x, year);
                        return;
                    }
                    let (rep, why) = if side == 1 { (2.0, "a coalition against the aggressor") } else { (crate::alliances::REP_WAR_OF_CHOICE, "to share the spoils") };
                    let reason = format!("{} (goal: {})", why, goal.name);
                    self.join_war(id, e, side, &reason);
                    let rwhy = format!("joined the war against {}", xn);
                    crate::alliances::adjust_reputation(self, e, rep, &rwhy);
                }
            }
            Act::ProposePact => {
                // Worth it only if the pact improves our odds against our main threat by forecast.
                if let Some(t) = self.empires[e].main_threat {
                    if t != x {
                        let alone = self.forecast_war(e, &[t], &[e], 1, false, 0xA1 ^ t as u64).p_win;
                        let with = self.forecast_war(e, &[t], &[e, x], 1, false, 0xA2 ^ t as u64).p_win;
                        if with - alone < 0.05 {
                            return;
                        }
                    }
                }
                if crate::alliances::accepts_pact(self, x, e) {
                    let r = self.rel_mut(e, x);
                    r.pact = true;
                    r.pact_year = year;
                    r.opinion = (r.opinion + 10.0).min(100.0);
                    self.event(format!("{} and {} sign a defensive pact (goal: {})", en, xn, goal.name));
                } else {
                    self.empires[e].refusals.insert(x, year);
                    self.event(format!("{} refuses a pact with {}", xn, en));
                }
            }
            Act::OfferGuarantee => {
                // Only guarantee what we expect to be able to defend.
                if let Some(t) = self.empires[e].main_threat {
                    if t != x && self.forecast_war(e, &[t], &[x, e], 1, false, 0x6A ^ x as u64).p_win < 0.4 {
                        return;
                    }
                }
                if crate::alliances::accepts_guarantee(self, x, e) {
                    let against = self.empires[e].main_threat;
                    self.empires[e].guarantees.push((x, against, year));
                    let r = self.rel_mut(e, x);
                    r.opinion = (r.opinion + 5.0).min(100.0);
                    self.event(format!("{} guarantees the independence of {} (goal: {})", en, xn, goal.name));
                } else {
                    self.empires[e].refusals.insert(x, year);
                    self.event(format!("{} declines {}'s protection", xn, en));
                }
            }
            Act::ProposePassage => {
                if self.rel(x, e).opinion >= OP_GOOD {
                    self.rel_mut(e, x).passage = true;
                    self.empires[e].treasury -= PASSAGE_FEE;
                    self.empires[x].treasury += PASSAGE_FEE;
                    self.event(format!("{} grants {} free passage (goal: {})", xn, en, goal.name));
                } else {
                    self.empires[e].refusals.insert(x, year);
                    self.event(format!("{} refuses {} passage", xn, en));
                }
            }
        }
    }
}
