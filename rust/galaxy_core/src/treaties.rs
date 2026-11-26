//! War goals, ultimatums and surprise attacks, war score, negotiated peace terms, and revanchism (treaties.gd).

use crate::personality::shift;
use crate::world::{World, TRAIT_AGGRESSION, TRAIT_CAUTION, TRAIT_EXPANSION, TRAIT_MERCANTILE, TRAIT_MILITARISM, TRAIT_XENOPHOBIA};

pub const VALUE_SYSTEM: f64 = 10.0;
pub const VALUE_SYSTEM_MAX: f64 = 30.0;
pub const VALUE_REPARATIONS: f64 = 20.0;
pub const VALUE_OPEN_MARKET: f64 = 6.0;
pub const VALUE_TRANSIT: f64 = 4.0;
pub const VALUE_DEMILITARIZE: f64 = 15.0;
pub const VALUE_HUMILIATE: f64 = 5.0;
pub const UNOCCUPIED_MARKUP: f64 = 1.5;
pub const REPARATIONS_SHARE: f64 = 0.25;
pub const REPARATIONS_YEARS: i64 = 10;
pub const DEMILITARIZE_CAP: f64 = 0.5;
pub const DEMILITARIZE_YEARS: i64 = 15;
pub const FORCED_YEARS: i64 = 20;
pub const HUMILIATE_REP: f64 = 10.0;
pub const REP_PER_GOAL_POINT: f64 = 0.15;
pub const REP_SURPRISE: f64 = 5.0;
pub const FIRST_STRIKE_MONTHS: i64 = 3;
pub const WHITE_PEACE_SCORE: f64 = 8.0;
pub const LOSER_TOLERANCE: f64 = 1.2;
pub const REV_BASE: f64 = 10.0;
pub const REV_PER_GREED: f64 = 25.0;
pub const REV_PER_SYSTEM: f64 = 5.0;
pub const REV_PER_PAYMENT_YEAR: f64 = 3.0;
pub const REV_FADE: f64 = 1.5;
pub const REV_ACT: f64 = 30.0;
pub const REV_REPUDIATE: f64 = 40.0;
pub const REP_REPUDIATE: f64 = 10.0;
pub const REP_PER_GREED: f64 = 15.0;

#[derive(serde::Serialize, serde::Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum TermKind {
    Cede,
    Reparations,
    OpenMarket,
    Transit,
    Demilitarize,
    Humiliate,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Copy, Debug)]
pub struct Term {
    pub kind: TermKind,
    pub system: Option<usize>,
    pub from: usize,
    pub to: usize,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Copy, Debug)]
pub struct Reparations {
    pub payer: usize,
    pub payee: usize,
    pub monthly: f64,
    pub until: i64,
}

/// A grudge against a victor: level 0..100, the systems claimed back, and when it was last fed.
#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct Revanche {
    pub victor: usize,
    pub level: f64,
    pub claims: Vec<usize>,
    pub since: i64,
}

pub fn revanche_level(w: &World, e: usize, x: usize) -> f64 {
    w.empires[e].revanche.iter().find(|r| r.victor == x).map_or(0.0, |r| r.level)
}

fn system_pop(w: &World, s: usize, owner: usize) -> f64 {
    w.systems[s].bodies.iter().filter(|&&c| w.colonies[c].owner == Some(owner)).map(|&c| w.colonies[c].pop).sum()
}

pub fn value(w: &World, t: &Term) -> f64 {
    match t.kind {
        TermKind::Cede => {
            let s = t.system.unwrap();
            let v = (VALUE_SYSTEM + system_pop(w, s, t.from) / 40.0).min(VALUE_SYSTEM_MAX);
            if w.systems[s].occupier == Some(t.to) { v } else { v * UNOCCUPIED_MARKUP }
        }
        TermKind::Reparations => VALUE_REPARATIONS,
        TermKind::OpenMarket => VALUE_OPEN_MARKET,
        TermKind::Transit => VALUE_TRANSIT,
        TermKind::Demilitarize => VALUE_DEMILITARIZE,
        TermKind::Humiliate => VALUE_HUMILIATE,
    }
}

pub fn total(w: &World, terms: &[Term]) -> f64 {
    terms.iter().map(|t| value(w, t)).sum()
}

pub fn describe(w: &World, t: &Term) -> String {
    let (f, to) = (&w.empires[t.from].name, &w.empires[t.to].name);
    match t.kind {
        TermKind::Cede => format!("{} -> {}", w.systems[t.system.unwrap()].name, to),
        TermKind::Reparations => format!("reparations to {}", to),
        TermKind::OpenMarket => format!("open market for {}", to),
        TermKind::Transit => format!("transit rights for {}", to),
        TermKind::Demilitarize => format!("{} demilitarises", f),
        TermKind::Humiliate => format!("{} humiliated", f),
    }
}

pub fn describe_all(w: &World, terms: &[Term]) -> String {
    terms.iter().map(|t| describe(w, t)).collect::<Vec<_>>().join(" / ")
}

/// War score for one side of a war (0 attackers, 1 defenders), -100..100: occupations, strength and exhaustion of
/// the whole coalitions.
pub fn score(w: &World, war_id: usize, side: usize) -> f64 {
    let war = w.wars.iter().find(|x| x.id == war_id).unwrap();
    let (us, them) = (&war.sides[side], &war.sides[1 - side]);
    let (mut held, mut lost) = (0.0, 0.0);
    for s in &w.systems {
        let (o, p) = (s.owner, s.occupier);
        if o.map_or(false, |o| them.contains(&o)) && p.map_or(false, |p| us.contains(&p)) {
            held += 1.0;
        } else if o.map_or(false, |o| us.contains(&o)) && p.map_or(false, |p| them.contains(&p)) {
            lost += 1.0;
        }
    }
    let sum = |v: &Vec<usize>| v.iter().map(|&e| w.empires[e].strength).sum::<f64>();
    let avg_exh = |v: &Vec<usize>| v.iter().map(|&e| w.empires[e].exhaustion).sum::<f64>() / v.len().max(1) as f64;
    let (ss, so) = (sum(us), sum(them));
    let st = 25.0 * (ss - so) / (ss + so).max(1.0);
    (12.0 * (held - lost) + st + 0.4 * (avg_exh(them) - avg_exh(us))).clamp(-100.0, 100.0)
}

fn by_pop_desc(w: &World, list: &mut [usize], owner: usize) {
    list.sort_by(|&x, &y| system_pop(w, y, owner).partial_cmp(&system_pop(w, x, owner)).unwrap().then(w.systems[x].name.cmp(&w.systems[y].name)));
}

/// What an attacker wants from its target, by personality and situation.
pub fn choose_goals(w: &World, a: usize, b: usize) -> Vec<Term> {
    let mut goals = vec![];
    let claims: Vec<usize> = w.empires[a].revanche.iter().find(|r| r.victor == b).map_or(vec![], |r| r.claims.iter().cloned().filter(|&s| w.systems[s].owner == Some(b)).collect());
    for &s in &claims {
        goals.push(Term { kind: TermKind::Cede, system: Some(s), from: b, to: a });
    }
    let ea = &w.empires[a];
    let n = 1 + (2.0 * ea.t(TRAIT_EXPANSION) * ea.t(TRAIT_AGGRESSION)).round() as usize;
    let cap = w.empires[b].capital;
    let mut cands: Vec<usize> = w.fronts(b, a).into_iter().filter(|&s| !w.systems[s].bodies.contains(&cap) && !claims.contains(&s)).collect();
    by_pop_desc(w, &mut cands, b);
    for &s in cands.iter().take(n.saturating_sub(claims.len())) {
        goals.push(Term { kind: TermKind::Cede, system: Some(s), from: b, to: a });
    }
    if ea.t(TRAIT_MERCANTILE) >= 0.6 {
        goals.push(Term { kind: TermKind::OpenMarket, system: None, from: b, to: a });
    }
    if ea.threat[b] >= 1.5 {
        goals.push(Term { kind: TermKind::Demilitarize, system: None, from: b, to: a });
    }
    if w.empires[b].treasury > ea.treasury && ea.t(TRAIT_AGGRESSION) >= 0.5 {
        goals.push(Term { kind: TermKind::Reparations, system: None, from: b, to: a });
    }
    if ea.t(TRAIT_AGGRESSION) >= 0.7 {
        goals.push(Term { kind: TermKind::Humiliate, system: None, from: b, to: a });
    }
    goals
}

/// The planner chose war on b. Reckless empires strike first; the rest try an ultimatum.
pub fn go_to_war(w: &mut World, a: usize, b: usize) {
    let goals = choose_goals(w, a, b);
    if w.empires[a].t(TRAIT_AGGRESSION) >= 0.65 && w.empires[a].t(TRAIT_CAUTION) <= 0.4 {
        let why = format!("surprise attack on {}", w.empires[b].name);
        crate::alliances::adjust_reputation(w, a, -REP_SURPRISE, &why);
        let id = w.declare(a, b, goals);
        let until = w.tick as i64 + FIRST_STRIKE_MONTHS;
        if let Some(war) = w.wars.iter_mut().find(|x| x.id == id) {
            war.first_strike_until = until;
        }
        let t = format!("{} strikes {} without warning", w.empires[a].name, w.empires[b].name);
        w.event(t);
        return;
    }
    let mut demand: Vec<Term> = goals.iter().cloned().filter(|t| t.kind == TermKind::Cede).take(1).collect();
    if demand.is_empty() {
        demand = goals.iter().cloned().take(1).collect();
    }
    if demand.is_empty() {
        w.declare(a, b, goals);
        return;
    }
    // The target yields if it expects to lose badly; proud or aggressive empires yield less.
    let ratio = w.empires[a].strength / crate::alliances::effective_strength(w, b, a).max(1.0);
    let eb = &w.empires[b];
    let spine = 1.3 + 0.6 * (1.0 - eb.t(TRAIT_CAUTION)) + 0.4 * eb.t(TRAIT_AGGRESSION);
    let desc = describe_all(w, &demand);
    if ratio >= spine {
        let t = format!("{} yields to {}'s ultimatum: {}", w.empires[b].name, w.empires[a].name, desc);
        w.event(t);
        let v = total(w, &demand);
        apply_terms(w, &demand, a, b, v, true, -1.0);
        let why = format!("ultimatum to {}", w.empires[b].name);
        crate::alliances::adjust_reputation(w, a, -3.0, &why);
        // A concession buys a truce and stiffens the victim (appeasement fatigue).
        let y = w.year();
        w.rel_mut(a, b).truce_until = y + crate::military::TRUCE_YEARS;
        shift(w, b, TRAIT_CAUTION, -0.1, "");
        shift(w, b, TRAIT_AGGRESSION, 0.05, "");
    } else {
        let t = format!("{} rejects {}'s ultimatum ({})", w.empires[b].name, w.empires[a].name, desc);
        w.event(t);
        w.declare(a, b, goals);
    }
}

/// What the side ahead demands with war score s: the attacker's goals (if it is ahead), then every system its members
/// occupy (each goes to its occupier), then extras for its leader, up to a budget that grows with the leader's greed.
fn demand(w: &World, war_id: usize, win: usize, s: f64) -> Vec<Term> {
    let war = w.wars.iter().find(|x| x.id == war_id).unwrap();
    let (winners, losers) = (&war.sides[win], &war.sides[1 - win]);
    let (wl, ll) = (war.leader(win), war.leader(1 - win));
    let budget = s * (0.8 + 0.7 * w.empires[wl].t(TRAIT_AGGRESSION));
    let mut cands: Vec<Term> = vec![];
    if win == 0 {
        cands.extend(war.goals.iter().cloned().filter(|t| t.kind != TermKind::Cede || w.systems[t.system.unwrap()].owner.map_or(false, |o| losers.contains(&o))).map(|mut t| {
            if t.kind == TermKind::Cede {
                t.from = w.systems[t.system.unwrap()].owner.unwrap();
            }
            t
        }));
    }
    let mut occupied: Vec<(usize, usize, usize)> = w
        .systems
        .iter()
        .filter(|x| x.owner.map_or(false, |o| losers.contains(&o)) && x.occupier.map_or(false, |o| winners.contains(&o)))
        .map(|x| (x.id, x.owner.unwrap(), x.occupier.unwrap()))
        .collect();
    occupied.sort_by(|a, b| system_pop(w, b.0, b.1).partial_cmp(&system_pop(w, a.0, a.1)).unwrap().then(w.systems[a.0].name.cmp(&w.systems[b.0].name)));
    for (sid, owner, occ) in occupied {
        if let Some(t) = cands.iter_mut().find(|t| t.kind == TermKind::Cede && t.system == Some(sid)) {
            t.to = occ; // whoever holds it gets it
        } else {
            cands.push(Term { kind: TermKind::Cede, system: Some(sid), from: owner, to: occ });
        }
    }
    for k in [TermKind::Reparations, TermKind::Humiliate] {
        if w.empires[wl].t(TRAIT_AGGRESSION) >= 0.5 && !cands.iter().any(|t| t.kind == k) {
            cands.push(Term { kind: k, system: None, from: ll, to: wl });
        }
    }
    let mut out = vec![];
    let mut v = 0.0;
    for t in cands {
        let tv = value(w, &t);
        if v + tv <= budget {
            out.push(t);
            v += tv;
        }
    }
    out
}

/// proposer (a side's leader) wants peace for the whole war. Returns true if peace was made.
pub fn negotiate(w: &mut World, war_id: usize, proposer: usize) -> bool {
    let (psid, l0, l1) = {
        let war = w.wars.iter().find(|x| x.id == war_id).unwrap();
        (war.side_of(proposer).unwrap(), war.leader(0), war.leader(1))
    };
    let s0 = score(w, war_id, 0);
    let other = if psid == 0 { l1 } else { l0 };
    if s0.abs() < WHITE_PEACE_SCORE {
        if w.empires[other].exhaustion >= 25.0 || w.empires[proposer].exhaustion >= 25.0 {
            let t = format!("{} and {} agree to a white peace", w.empires[proposer].name, w.empires[other].name);
            w.event(t);
            w.make_peace(war_id, &[]);
            return true;
        }
        return false;
    }
    let win = if s0 > 0.0 { 0 } else { 1 };
    let (winner, loser) = if win == 0 { (l0, l1) } else { (l1, l0) };
    let s = s0.abs();
    let terms = demand(w, war_id, win, s);
    let v = total(w, &terms);
    let desc = if terms.is_empty() { "nothing".to_string() } else { describe_all(w, &terms) };
    let (wn, ln) = (w.empires[winner].name.clone(), w.empires[loser].name.clone());
    if proposer == loser {
        if v <= s * LOSER_TOLERANCE || w.empires[loser].exhaustion >= 60.0 {
            w.event(format!("{} sues for peace with {} and accepts: {}", ln, wn, desc));
            settle(w, war_id, &terms, winner, loser, s);
            return true;
        }
        w.event(format!("{} sues for peace with {}: terms too harsh ({})", ln, wn, desc));
        return false;
    }
    if v <= s * LOSER_TOLERANCE || w.empires[loser].exhaustion >= 50.0 {
        w.event(format!("{} accepts {}'s terms: {}", ln, wn, desc));
        settle(w, war_id, &terms, winner, loser, s);
        return true;
    }
    let mut counter = terms.clone();
    counter.sort_by(|x, y| value(w, x).partial_cmp(&value(w, y)).unwrap());
    while !counter.is_empty() && total(w, &counter) > s {
        counter.pop();
    }
    if w.empires[winner].exhaustion >= 30.0 || total(w, &counter) >= 0.6 * v {
        let d = if counter.is_empty() { "white peace".to_string() } else { describe_all(w, &counter) };
        w.event(format!("{} counters {}'s terms; agreed: {}", ln, wn, d));
        settle(w, war_id, &counter, winner, loser, s);
        return true;
    }
    w.event(format!("{} rejects {}'s counter-offer; the war goes on", wn, ln));
    false
}

/// A side's leader collapsed: the other side takes what it demands, with a larger budget.
pub fn capitulate(w: &mut World, war_id: usize, losing_side: usize) {
    let (winner, loser) = {
        let war = w.wars.iter().find(|x| x.id == war_id).unwrap();
        (war.leader(1 - losing_side), war.leader(losing_side))
    };
    let s = score(w, war_id, 1 - losing_side).abs().max(30.0) * 1.5;
    let terms = demand(w, war_id, 1 - losing_side, s);
    let desc = if terms.is_empty() { "nothing".to_string() } else { describe_all(w, &terms) };
    let t = format!("{} capitulates to {}: {}", w.empires[loser].name, w.empires[winner].name, desc);
    w.event(t);
    settle(w, war_id, &terms, winner, loser, s / 1.5);
}

fn settle(w: &mut World, war_id: usize, terms: &[Term], winner: usize, loser: usize, s: f64) {
    let tv = total(w, terms); // valued while the occupations still stand
    w.make_peace(war_id, terms);
    apply_terms(w, terms, winner, loser, s, false, tv);
}

/// Carry out the terms (winner/loser = the sides' leaders), then the consequences of greed: reputation for the winning
/// leader, and a grudge for each empire that lost systems against the empire that took them.
pub fn apply_terms(w: &mut World, terms: &[Term], winner: usize, loser: usize, fair: f64, concession: bool, tv: f64) {
    let year = w.year();
    let tv = if tv < 0.0 { total(w, terms) } else { tv };
    let mut ceded: Vec<(usize, usize, usize)> = vec![]; // (system, from, to)
    for t in terms {
        match t.kind {
            TermKind::Cede => {
                let s = t.system.unwrap();
                w.transfer_system(s, t.to, t.from);
                ceded.push((s, t.from, t.to));
            }
            TermKind::Reparations => {
                let monthly = REPARATIONS_SHARE * w.empires[t.from].avg_tax;
                w.rel_mut(t.to, t.from).reparations = Some(Reparations { payer: t.from, payee: t.to, monthly, until: year + REPARATIONS_YEARS });
            }
            TermKind::OpenMarket => {
                let r = w.rel_mut(t.to, t.from);
                r.trade_treaty = true;
                r.forced_market = Some((t.from, year + FORCED_YEARS));
            }
            TermKind::Transit => {
                let r = w.rel_mut(t.to, t.from);
                r.passage = true;
                r.forced_transit = Some((t.from, year + FORCED_YEARS));
            }
            TermKind::Demilitarize => {
                w.empires[t.from].demilitarized_until = year + DEMILITARIZE_YEARS;
                w.empires[t.from].demilitarized_by = Some(t.to);
            }
            TermKind::Humiliate => {
                let why = format!("humiliated by {}", w.empires[t.to].name);
                crate::alliances::adjust_reputation(w, t.from, -HUMILIATE_REP, &why);
            }
        }
    }
    for &(_, _, to) in &ceded {
        w.empires[to].systems_taken += 1;
    }
    if terms.is_empty() {
        return;
    }
    let greed = tv / fair.max(1.0);
    if greed > 1.2 && !concession {
        let why = format!("harsh peace imposed on {}", w.empires[loser].name);
        crate::alliances::adjust_reputation(w, winner, -REP_PER_GREED * (greed - 1.2), &why);
    }
    // Grudges: each (loser, gainer) pair that changed hands, or the leaders if no system did.
    let mut pairs: Vec<(usize, usize)> = vec![];
    for &(_, f, t) in &ceded {
        if !pairs.contains(&(f, t)) {
            pairs.push((f, t));
        }
    }
    if pairs.is_empty() {
        pairs.push((loser, winner));
    }
    for (l, g) in pairs {
        let lost: Vec<usize> = ceded.iter().filter(|c| c.1 == l && c.2 == g).map(|c| c.0).collect();
        grudge(w, l, g, greed, &lost, concession, year);
    }
}

fn grudge(w: &mut World, loser: usize, winner: usize, greed: f64, lost: &[usize], concession: bool, year: i64) {
    let idx = match w.empires[loser].revanche.iter().position(|r| r.victor == winner) {
        Some(i) => i,
        None => {
            w.empires[loser].revanche.push(Revanche { victor: winner, level: 0.0, claims: vec![], since: year });
            w.empires[loser].revanche.len() - 1
        }
    };
    {
        let rev = &mut w.empires[loser].revanche[idx];
        rev.level = (rev.level + REV_BASE * if concession { 0.5 } else { 1.0 } + REV_PER_GREED * (greed - 0.8).max(0.0) + REV_PER_SYSTEM * lost.len() as f64).min(100.0);
        for s in lost {
            if !rev.claims.contains(s) {
                rev.claims.push(*s);
            }
        }
        rev.since = year;
    }
    let level = w.empires[loser].revanche[idx].level;
    if w.empires[loser].exhaustion >= 80.0 && w.empires[loser].t(TRAIT_CAUTION) > 0.4 {
        shift(w, loser, TRAIT_AGGRESSION, -0.15, "a crushing defeat");
        shift(w, loser, TRAIT_CAUTION, 0.1, "");
        w.empires[loser].revanche[idx].level *= 0.5;
    } else if level >= REV_ACT {
        let why = format!("revanchism against {}", w.empires[winner].name);
        shift(w, loser, TRAIT_AGGRESSION, 0.05 + level / 1000.0, &why);
        shift(w, loser, TRAIT_MILITARISM, 0.05, "");
    }
    let rev = &w.empires[loser].revanche[idx];
    let claims: Vec<String> = rev.claims.iter().map(|&s| w.systems[s].name.clone()).collect();
    let t = format!("{}'s grudge against {}: {}{}", w.empires[loser].name, w.empires[winner].name, rev.level as i64, if claims.is_empty() { String::new() } else { format!(" (claims {})", claims.join(" ")) });
    w.event(t);
}

/// Monthly reparations payments.
impl World {
    pub fn reparations_monthly(&mut self) {
        let n = self.empires.len();
        for a in 0..n {
            for b in (a + 1)..n {
                if let Some(rp) = self.rel(a, b).reparations {
                    let amt = rp.monthly.min(self.empires[rp.payer].treasury.max(0.0));
                    self.empires[rp.payer].treasury -= amt;
                    self.empires[rp.payee].treasury += amt;
                }
            }
        }
    }
}

/// Yearly: terms expire; revanchists radicalise while paying, repudiate when they can, and slowly forgive.
pub fn yearly(w: &mut World) {
    let year = w.year();
    let n = w.empires.len();
    for a in 0..n {
        for b in (a + 1)..n {
            let (na, nb) = (w.empires[a].name.clone(), w.empires[b].name.clone());
            let r = w.rel_mut(a, b);
            let mut ended = vec![];
            if r.reparations.map_or(false, |x| year >= x.until) {
                r.reparations = None;
                ended.push("Reparations");
            }
            if r.forced_market.map_or(false, |x| year >= x.1) {
                r.forced_market = None;
                ended.push("Forced market");
            }
            if r.forced_transit.map_or(false, |x| year >= x.1) {
                r.forced_transit = None;
                ended.push("Forced transit");
            }
            for k in ended {
                w.event(format!("{} between {} and {} ends", k, na, nb));
            }
        }
    }
    for e in 0..n {
        if w.empires[e].demilitarized_until > 0 && year >= w.empires[e].demilitarized_until {
            w.empires[e].demilitarized_until = 0;
        }
        let mut i = 0;
        while i < w.empires[e].revanche.len() {
            let x = w.empires[e].revanche[i].victor;
            let r = w.rel(e, x);
            let paying = r.reparations.map_or(false, |p| p.payer == e);
            let bound = paying
                || (w.empires[e].demilitarized_until > 0 && w.empires[e].demilitarized_by == Some(x))
                || r.forced_market.map_or(false, |m| m.0 == e)
                || r.forced_transit.map_or(false, |m| m.0 == e);
            if paying {
                let rev = &mut w.empires[e].revanche[i];
                rev.level = (rev.level + REV_PER_PAYMENT_YEAR).min(100.0);
                shift(w, e, TRAIT_AGGRESSION, 0.02, "");
                shift(w, e, TRAIT_XENOPHOBIA, 0.01, "");
            }
            let level = w.empires[e].revanche[i].level;
            let chance = w.in_any_war(x) || w.empires[x].strength < w.empires[e].strength;
            if bound && level >= REV_REPUDIATE && w.empires[e].t(TRAIT_AGGRESSION) >= 0.4 && chance {
                let r = w.rel_mut(e, x);
                if r.reparations.map_or(false, |p| p.payer == e) {
                    r.reparations = None;
                }
                if r.forced_market.map_or(false, |m| m.0 == e) {
                    r.forced_market = None;
                    r.trade_treaty = false;
                }
                if r.forced_transit.map_or(false, |m| m.0 == e) {
                    r.forced_transit = None;
                    r.passage = false;
                }
                if w.empires[e].demilitarized_by == Some(x) {
                    w.empires[e].demilitarized_until = 0;
                }
                let why = format!("repudiated its treaty with {}", w.empires[x].name);
                crate::alliances::adjust_reputation(w, e, -REP_REPUDIATE, &why);
                crate::alliances::adjust_trust(w, x, e, -20.0);
                let t = format!("{} repudiates the terms imposed by {}", w.empires[e].name, w.empires[x].name);
                w.event(t);
            }
            if !bound {
                let fade = REV_FADE * (1.0 + w.empires[e].t(TRAIT_MERCANTILE));
                w.empires[e].revanche[i].level -= fade;
            }
            let claims: Vec<usize> = w.empires[e].revanche[i].claims.iter().cloned().filter(|&s| w.systems[s].owner == Some(x)).collect();
            w.empires[e].revanche[i].claims = claims;
            if w.empires[e].revanche[i].level <= 0.0 {
                w.empires[e].revanche.remove(i);
                let t = format!("{} has forgiven {}", w.empires[e].name, w.empires[x].name);
                w.event(t);
            } else {
                i += 1;
            }
        }
    }
}

/// The revanchist's chance: the victor is at war elsewhere, or no longer clearly stronger.
pub fn opportunity(w: &World, e: usize, x: usize) -> bool {
    if revanche_level(w, e, x) < REV_ACT {
        return false;
    }
    let busy = w.wars.iter().any(|war| war.side_of(x).is_some() && war.side_of(e).is_none());
    let need = if busy { 0.8 } else { 1.0 };
    w.empires[e].strength >= crate::alliances::effective_strength(w, x, e) * need
}
