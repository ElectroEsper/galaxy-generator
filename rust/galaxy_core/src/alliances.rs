//! Defensive pacts, guarantees, calls to arms, trust and reputation (alliances.gd).

use crate::world::{World, TRAIT_CAUTION, TRAIT_INTERVENTION, TRAIT_XENOPHOBIA};

pub const ALLY_WEIGHT: f64 = 0.6;
pub const PACT_MIN_YEARS: i64 = 10;
pub const LAPSE_THREAT: f64 = 0.8;
pub const BETRAYAL_OPINION: f64 = 30.0;
pub const JOIN_EXHAUSTION: f64 = 40.0;
pub const SMALL: f64 = 0.5;
pub const SMALL_END: f64 = 0.7;
pub const GUARANTEE_MIN_YEARS: i64 = 5;
pub const TRUST_START: f64 = 50.0;
pub const TRUST_BETRAYED: f64 = -40.0;
pub const TRUST_ATTACKED: f64 = -30.0;
pub const TRUST_HONOURED: f64 = 15.0;
pub const TRUST_KEPT: f64 = 1.0;
pub const REP_BETRAYAL: f64 = -15.0;
pub const REP_WAR_OF_CHOICE: f64 = -5.0;
pub const REP_HONOURED: f64 = 5.0;
pub const REP_RECOVERY: f64 = 1.0;
pub const PACT_TRUST: f64 = 40.0;
pub const GUARANTEE_TRUST: f64 = 30.0;

pub fn has_pact(w: &World, a: usize, b: usize) -> bool {
    a != b && w.rel(a, b).pact
}

/// Empires bound to defend x: pact partners and guarantors.
pub fn defenders_of(w: &World, x: usize) -> Vec<usize> {
    (0..w.empires.len()).filter(|&y| y != x && (has_pact(w, x, y) || w.empires[y].guarantees_(x))).collect()
}

/// What an attacker expects to face: x's strength plus a reputation-weighted share of its defenders'.
pub fn effective_strength(w: &World, x: usize, attacker: usize) -> f64 {
    let mut s = w.empires[x].strength;
    for y in defenders_of(w, x) {
        if y != attacker && !has_pact(w, y, attacker) {
            s += ALLY_WEIGHT * w.empires[y].strength * (w.empires[y].reputation / 50.0).clamp(0.2, 1.5);
        }
    }
    s
}

/// How much a trusts b.
pub fn trust(w: &World, a: usize, b: usize) -> f64 {
    let r = w.rel(a, b);
    if a < b { r.trust[0] } else { r.trust[1] }
}

pub fn adjust_trust(w: &mut World, a: usize, b: usize, amount: f64) {
    let v = (trust(w, a, b) + amount).clamp(0.0, 100.0);
    let r = w.rel_mut(a, b);
    if a < b {
        r.trust[0] = v;
    } else {
        r.trust[1] = v;
    }
}

/// How far a would rely on b's promises: its own trust blended with b's reputation.
pub fn reliance(w: &World, a: usize, b: usize) -> f64 {
    0.6 * trust(w, a, b) + 0.4 * w.empires[b].reputation
}

pub fn adjust_reputation(w: &mut World, e: usize, amount: f64, why: &str) {
    w.empires[e].reputation = (w.empires[e].reputation + amount).clamp(0.0, 100.0);
    if amount.abs() >= 10.0 {
        let t = format!("{}'s reputation {} to {} ({})", w.empires[e].name, if amount > 0.0 { "rises" } else { "falls" }, w.empires[e].reputation as i64, why);
        w.event(t);
    }
}

/// New pacts and guarantees: not with an empire at war (signing would mean joining it).
pub fn can_ally(w: &World, a: usize, b: usize) -> bool {
    !w.in_any_war(a) && !w.in_any_war(b)
}

pub fn accepts_pact(w: &World, x: usize, e: usize) -> bool {
    let r = w.rel(e, x);
    if r.opinion < -10.0 || !can_ally(w, e, x) || reliance(w, x, e) < (PACT_TRUST + 20.0 * w.empires[x].t(TRAIT_XENOPHOBIA)) * w.empires[x].fx(crate::personality::FX_PACT_TRUST) {
        return false;
    }
    if let Some(t) = w.empires[e].main_threat {
        if w.empires[x].threat[t] >= crate::threat::NOTE_LEVEL {
            return true;
        }
    }
    w.empires[x].max_threat >= crate::threat::NOTE_LEVEL && r.opinion >= 10.0
}

pub fn accepts_guarantee(w: &World, x: usize, e: usize) -> bool {
    w.rel(e, x).opinion >= -20.0 && can_ally(w, e, x) && reliance(w, x, e) >= GUARANTEE_TRUST
}

/// defender was attacked: each pact partner and guarantor decides whether to join.
pub fn call_to_arms(w: &mut World, attacker: usize, defender: usize, war_id: usize) {
    for y in defenders_of(w, defender) {
        if y == attacker || w.at_war(y, attacker) || has_pact(w, y, attacker) {
            continue;
        }
        let pact = has_pact(w, y, defender);
        let mut chance = if pact { 0.6 + 0.4 * (1.0 - w.empires[y].t(TRAIT_CAUTION)) } else { 0.3 + 0.6 * w.empires[y].t(TRAIT_INTERVENTION) };
        chance = (chance * w.empires[y].fx(crate::personality::FX_CALL_TO_ARMS)).min(1.0);
        // A hopeless war is harder to honour: scale by the forecast of the defenders' side with us in it.
        if let Some(wi) = w.war_index(war_id) {
            let mut mine = w.wars[wi].sides[1].clone();
            mine.push(y);
            let theirs = w.wars[wi].sides[0].clone();
            let p = w.forecast_war(y, &mine, &theirs, 0, false, 0xCA11 ^ defender as u64).p_win;
            chance *= (0.4 + p).min(1.0);
        }
        if w.empires[y].exhaustion > JOIN_EXHAUSTION {
            chance *= 0.3;
        }
        let what = if pact { "pact" } else { "guarantee" };
        if w.rng.randf() < chance {
            adjust_trust(w, defender, y, TRUST_HONOURED);
            let why = format!("stood by {}", w.empires[defender].name);
            adjust_reputation(w, y, REP_HONOURED, &why);
            w.join_war(war_id, y, 1, &format!("honouring its {}", what));
        } else {
            {
                let r = w.rel_mut(y, defender);
                r.opinion = (r.opinion - BETRAYAL_OPINION).max(-100.0);
                if pact {
                    r.pact = false;
                }
            }
            if !pact {
                w.empires[y].guarantees.retain(|g| g.0 != defender);
            }
            adjust_trust(w, defender, y, TRUST_BETRAYED);
            let why = format!("abandoned {}", w.empires[defender].name);
            adjust_reputation(w, y, REP_BETRAYAL, &why);
            let t = format!("{} abandons {} to {} (its {} is void)", w.empires[y].name, w.empires[defender].name, w.empires[attacker].name, what);
            w.event(t);
        }
    }
}

/// Reputation recovers; kept promises build trust; pacts lapse when the shared fear is gone; guarantees end when the
/// protected empire is safe.
pub fn yearly(w: &mut World) {
    let year = w.year();
    let n = w.empires.len();
    for e in 0..n {
        let rep = w.empires[e].reputation;
        w.empires[e].reputation += (50.0 - rep).clamp(-REP_RECOVERY, REP_RECOVERY);
        for (x, _, _) in w.empires[e].guarantees.clone() {
            adjust_trust(w, x, e, TRUST_KEPT);
        }
    }
    for a in 0..n {
        for b in (a + 1)..n {
            if !w.rel(a, b).pact {
                continue;
            }
            adjust_trust(w, a, b, TRUST_KEPT);
            adjust_trust(w, b, a, TRUST_KEPT);
            let calm = w.empires[a].max_threat < LAPSE_THREAT && w.empires[b].max_threat < LAPSE_THREAT;
            let r = w.rel(a, b);
            if (calm && year - r.pact_year >= PACT_MIN_YEARS) || r.opinion < -30.0 {
                w.rel_mut(a, b).pact = false;
                let t = format!("The pact between {} and {} lapses", w.empires[a].name, w.empires[b].name);
                w.event(t);
            }
        }
    }
    for g in 0..n {
        for (x, against, start) in w.empires[g].guarantees.clone() {
            if year - start < GUARANTEE_MIN_YEARS {
                continue;
            }
            let safe = match against {
                None => true,
                Some(t) => w.empires[x].strength >= w.empires[t].strength * SMALL_END || w.rel(x, t).border == 0,
            };
            let fear = against.map_or(0.0, |t| w.empires[g].threat[t]);
            if safe || fear < LAPSE_THREAT {
                w.empires[g].guarantees.retain(|q| q.0 != x);
                let t = format!("{} ends its guarantee of {}", w.empires[g].name, w.empires[x].name);
                w.event(t);
            }
        }
    }
}
