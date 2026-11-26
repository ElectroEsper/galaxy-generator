//! Threat assessment (threat.gd): each year every empire scores how dangerous each empire it has met is to itself.

use crate::world::World;

pub const MIN_STRENGTH: f64 = 5.0;
pub const STRENGTH_CAP: f64 = 5.0;
pub const WAR_MEMORY: i64 = 30;
pub const TRAJECTORY_YEARS: usize = 20;
pub const NOTE_LEVEL: f64 = 1.0;

pub fn yearly(w: &mut World) {
    let year = w.year();
    for e in 0..w.empires.len() {
        let n = w.owned_systems(e).len();
        w.empires[e].sys_history.push(n);
    }
    for e in 0..w.empires.len() {
        let (mut top, mut top_score) = (None, 0.0);
        for x in 0..w.empires.len() {
            if x == e {
                continue;
            }
            let sc = score(w, e, x, year);
            w.empires[e].threat[x] = sc;
            if sc > top_score {
                top_score = sc;
                top = Some(x);
            }
        }
        let prev = w.empires[e].main_threat;
        w.empires[e].max_threat = top_score;
        w.empires[e].main_threat = if top_score >= NOTE_LEVEL { top } else { None };
        if w.empires[e].main_threat != prev {
            if let Some(t) = w.empires[e].main_threat {
                let txt = format!("{} now sees {} as its main threat ({:.1})", w.empires[e].name, w.empires[t].name, top_score);
                w.event(txt);
            }
        }
    }
}

/// How threatening x is to e.
pub fn score(w: &World, e: usize, x: usize, year: i64) -> f64 {
    let r = w.rel(e, x);
    if !r.met {
        return 0.0;
    }
    let (ee, xe) = (&w.empires[e], &w.empires[x]);
    let strength = (xe.strength / ee.strength.max(MIN_STRENGTH)).min(STRENGTH_CAP);
    let proximity = if r.border > 0 { 1.0 + r.border as f64 / 10.0 } else { 0.3 };
    let recent = xe.wars_started.iter().filter(|&&y| year - y <= WAR_MEMORY).count() as f64;
    let record = (1.0 + 0.25 * recent + 0.1 * xe.systems_taken as f64).min(3.0);
    let mut growth = 0.0;
    let h = &xe.sys_history;
    if h.len() > TRAJECTORY_YEARS {
        let then = h[h.len() - 1 - TRAJECTORY_YEARS] as f64;
        growth = ((*h.last().unwrap() as f64 - then) / then.max(1.0)).clamp(0.0, 2.0);
    }
    let war = if w.at_war(e, x) { 1.5 } else { 1.0 };
    let temper = 0.5 + (ee.t(5) + ee.t(3)) * 0.5;
    let grudge = crate::treaties::revanche_level(w, e, x) / 100.0;
    0.5 * (1.0 + grudge) * strength * proximity * record * (1.0 + growth) * war * temper
}

/// Do e and some other empire both see x as a serious threat?
pub fn common_threat(w: &World, e: usize, x: usize) -> bool {
    if w.empires[e].threat[x] < NOTE_LEVEL {
        return false;
    }
    (0..w.empires.len()).any(|y| y != e && y != x && w.empires[y].threat[x] >= NOTE_LEVEL && w.rel(e, y).met)
}
