//! Telemetry: a running history of a playthrough, kept in the World (so it survives save/load) and exported as CSV
//! files for analysis.
//!
//! Recorded:
//! - galaxy.csv: galaxy-wide economy, every 4 months (metrics_row).
//! - empires.csv: every empire, every year (empire_rows), plus fleet, army and operations.
//! - relations.csv: every pair of empires, every 5 years (relation_rows).
//! - events.csv: every event, with year, month and a category (war, diplomacy, crisis, politics, economy, other).
//! - wars.csv: one row per war: start, end, sides, goals, how it ended and the terms.
//! - summary.json: settings, length, final standings and counts.

use crate::world::World;
use serde::{Deserialize, Serialize};

pub const EMPIRE_EXTRA_HEADER: &str = ",fleet,army,operations";

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct WarRecord {
    pub id: usize,
    pub start: u32,
    pub end: Option<u32>,
    pub attacker: usize,
    pub defender: usize,
    /// Everyone who fought on each side, in joining order.
    pub sides: [Vec<usize>; 2],
    pub goals: String,
    /// "peace", "capitulation", or "separate peace" notes, and the terms.
    pub outcome: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Telemetry {
    pub galaxy: Vec<String>,
    pub empires: Vec<String>,
    pub relations: Vec<String>,
    pub wars: Vec<WarRecord>,
}

/// Rough category of an event line, for filtering.
pub fn category(text: &str) -> &'static str {
    let has = |k: &[&str]| k.iter().any(|s| text.contains(s));
    if has(&["WAR:", "occupies", "liberates", "OPERATION", "BATTLE", "operation against", "capitulat", "PEACE", "joins the war", "separate peace", "strikes"]) {
        "war"
    } else if has(&["CRISIS", "crisis", "backs down", "concedes", "mediat", "compromise"]) {
        "crisis"
    } else if has(&["pact", "guarantee", "treaty", "passage", "embargo", "stays out", "shelves", "refuses", "First contact", "opinion", "friendly", "hostile", "neutral", "threat", " arms ", "deter"]) {
        "diplomacy"
    } else if has(&["REGIME", "reputation", "adopts", "personality"]) {
        "politics"
    } else if has(&["corporation", "colony", "Colony", "settle", "founded", "bankrupt", "survey", "shortage", "price"]) {
        "economy"
    } else {
        "other"
    }
}

fn csv_field(s: &str) -> String {
    if s.contains(',') || s.contains('"') || s.contains('\n') {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

impl World {
    /// Called once per month, after the month's tick.
    pub fn record_telemetry(&mut self) {
        let t = self.tick;
        if t % 4 == 0 {
            let r = self.metrics_row();
            self.telemetry.galaxy.push(r);
        }
        if self.empires.len() > 1 {
            if t % 12 == 0 {
                let rows = self.empire_rows();
                for (e, r) in rows.into_iter().enumerate() {
                    let fleet: f64 = self.forces.iter().filter(|f| f.owner == e && f.kind == crate::forces::ForceKind::Fleet).map(|f| f.strength).sum();
                    let army: f64 = self.forces.iter().filter(|f| f.owner == e && f.kind == crate::forces::ForceKind::Army).map(|f| f.strength).sum();
                    let ops = self.ops.iter().filter(|o| o.empire == e).count();
                    self.telemetry.empires.push(format!("{},{:.0},{:.0},{}", r, fleet, army, ops));
                }
            }
            if t % 60 == 0 {
                let rows = self.relation_rows();
                self.telemetry.relations.extend(rows);
            }
        }
    }

    pub fn war_started(&mut self, id: usize, a: usize, b: usize, goals: String) {
        self.telemetry.wars.push(WarRecord { id, start: self.tick, end: None, attacker: a, defender: b, sides: [vec![a], vec![b]], goals, outcome: String::new() });
    }

    pub fn war_joined(&mut self, id: usize, e: usize, side: usize) {
        if let Some(r) = self.telemetry.wars.iter_mut().rev().find(|r| r.id == id) {
            if !r.sides[side].contains(&e) {
                r.sides[side].push(e);
            }
        }
    }

    pub fn war_note(&mut self, id: usize, note: String, ended: bool) {
        let tick = self.tick;
        if let Some(r) = self.telemetry.wars.iter_mut().rev().find(|r| r.id == id) {
            if !r.outcome.is_empty() {
                r.outcome.push_str("; ");
            }
            r.outcome.push_str(&note);
            if ended {
                r.end = Some(tick);
            }
        }
    }

    fn ename(&self, e: usize) -> String {
        self.empires.get(e).map_or(format!("Empire {}", e + 1), |x| x.name.clone())
    }

    /// Write the history as CSV files (plus summary.json) into `dir` (created if needed).
    pub fn export_telemetry(&self, dir: &str) -> Result<(), String> {
        use std::fmt::Write as _;
        let d = std::path::Path::new(dir);
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
        let write = |name: &str, body: String| std::fs::write(d.join(name), body).map_err(|e| format!("{}: {}", name, e));
        let mut s = format!("{}\n", crate::metrics::METRIC_HEADER);
        for r in &self.telemetry.galaxy {
            let _ = writeln!(s, "{}", r);
        }
        write("galaxy.csv", s)?;
        let mut s = format!("{}{}\n", crate::metrics::EMPIRE_HEADER, EMPIRE_EXTRA_HEADER);
        for r in &self.telemetry.empires {
            let _ = writeln!(s, "{}", r);
        }
        write("empires.csv", s)?;
        let mut s = format!("{}\n", crate::metrics::RELATION_HEADER);
        for r in &self.telemetry.relations {
            let _ = writeln!(s, "{}", r);
        }
        write("relations.csv", s)?;
        let mut s = String::from("tick,year,month,category,text\n");
        for (t, text) in &self.events {
            let _ = writeln!(s, "{},{},{},{},{}", t, t / 12, t % 12 + 1, category(text), csv_field(text));
        }
        write("events.csv", s)?;
        let mut s = String::from("war,start_tick,end_tick,months,attacker,defender,side_a,side_b,goals,outcome\n");
        for r in &self.telemetry.wars {
            let names = |v: &Vec<usize>| v.iter().map(|&e| self.ename(e)).collect::<Vec<_>>().join(" + ");
            let end = r.end.map_or(String::new(), |e| e.to_string());
            let months = r.end.unwrap_or(self.tick) - r.start;
            let _ = writeln!(
                s,
                "{},{},{},{},{},{},{},{},{},{}",
                r.id,
                r.start,
                end,
                months,
                csv_field(&self.ename(r.attacker)),
                csv_field(&self.ename(r.defender)),
                csv_field(&names(&r.sides[0])),
                csv_field(&names(&r.sides[1])),
                csv_field(&r.goals),
                csv_field(if r.outcome.is_empty() { "ongoing" } else { &r.outcome })
            );
        }
        write("wars.csv", s)?;
        // Summary
        let standings: Vec<serde_json::Value> = (0..self.empires.len())
            .map(|e| {
                let own: Vec<usize> = self.markets.iter().cloned().filter(|&m| self.colonies[m].owner == Some(e)).collect();
                let systems = self.systems.iter().filter(|s| s.owner == Some(e)).count();
                serde_json::json!({
                    "empire": self.ename(e),
                    "personality": crate::personality::label(self, e),
                    "systems": systems,
                    "colonies": own.len(),
                    "population": own.iter().map(|&c| self.colonies[c].pop).sum::<f64>().round(),
                    "treasury": self.empires[e].treasury.round(),
                    "strength": self.empires[e].strength.round(),
                    "reputation": self.empires[e].reputation.round(),
                    "at_war": self.in_any_war(e),
                })
            })
            .collect();
        let mut cats = std::collections::BTreeMap::new();
        for (_, text) in &self.events {
            *cats.entry(category(text)).or_insert(0u32) += 1;
        }
        let summary = serde_json::json!({
            "seed": self.cfg.seed,
            "systems": self.systems.len(),
            "empires": self.empires.len(),
            "months": self.tick,
            "date": format!("year {}, month {}", self.tick / 12, self.tick % 12 + 1),
            "wars": self.telemetry.wars.len(),
            "wars_ongoing": self.wars.len(),
            "claim_incidents": self.claim_incidents,
            "events_by_category": cats,
            "standings": standings,
            "files": ["galaxy.csv", "empires.csv", "relations.csv", "events.csv", "wars.csv"],
        });
        write("summary.json", serde_json::to_string_pretty(&summary).unwrap())?;
        Ok(())
    }
}
