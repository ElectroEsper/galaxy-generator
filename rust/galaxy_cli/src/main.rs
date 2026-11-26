//! Headless runner: same arguments and output lines as economy_proto/run_headless_csv.gd.
//!   cargo run --release -p galaxy_cli -- growth=1 ticks=600 colonize=1 systems=46 empires=4 planets=100 seed=7

use galaxy_core::metrics::{EMPIRE_HEADER, METRIC_HEADER, RELATION_HEADER};
use galaxy_core::{Config, World};
use std::time::Instant;

fn main() {
    let mut cfg = Config::default();
    let mut ticks: u32 = 600;
    for a in std::env::args().skip(1) {
        let (k, v) = a.split_once('=').unwrap_or((a.as_str(), ""));
        match k {
            "growth" => cfg.growth = v != "0",
            "food" => cfg.food_mult = v.parse().unwrap_or(1.0),
            "seed" => cfg.seed = v.parse().unwrap_or(7),
            "empires" => cfg.empires = v.parse().unwrap_or(1),
            "systems" => cfg.systems = v.parse().unwrap_or(0),
            "planets" => cfg.planets = v.parse().unwrap_or(100),
            "state" => cfg.state = v != "0",
            "taxes" => cfg.taxes = v != "0",
            "colonize" => cfg.colonize = v == "1",
            "ticks" => ticks = v.parse().unwrap_or(600),
            _ => eprintln!("unknown argument {}", a),
        }
    }
    let t0 = Instant::now();
    let mut w = World::new(cfg);
    println!("INFO,setup_ms={:.1},systems={},bodies={}", t0.elapsed().as_secs_f64() * 1000.0, w.systems.len(), w.colonies.len());
    println!("CSV,{}", METRIC_HEADER);
    let multi = w.empires.len() > 1;
    if multi {
        println!("EMP,{}", EMPIRE_HEADER);
        println!("REL,{}", RELATION_HEADER);
    }
    let wall0 = Instant::now();
    let mut decade0 = Instant::now();
    let mut printed = 0;
    for t in 0..ticks {
        w.step();
        if t % 4 == 3 {
            println!("CSV,{}", w.metrics_row());
            if t % 12 == 11 && multi {
                for r in w.empire_rows() {
                    println!("EMP,{}", r);
                }
                for r in w.relation_rows() {
                    println!("REL,{}", r);
                }
            }
        }
        while printed < w.events.len() {
            println!("EVENT,{},{}", w.events[printed].0, w.events[printed].1);
            printed += 1;
        }
        if t % 120 == 119 {
            println!("TIME,decade={},ms_per_tick={:.2},colonies={}", (t + 1) / 120, decade0.elapsed().as_secs_f64() * 1000.0 / 120.0, w.markets.len());
            decade0 = Instant::now();
        }
    }
    println!("TIME,total_s={:.2}", wall0.elapsed().as_secs_f64());
}
