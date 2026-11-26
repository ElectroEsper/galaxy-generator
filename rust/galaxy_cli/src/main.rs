//! Headless runner: same arguments and output lines as economy_proto/run_headless_csv.gd.
//!   cargo run --release -p galaxy_cli -- growth=1 ticks=600 colonize=1 systems=46 empires=4 planets=100 seed=7

use galaxy_core::metrics::{EMPIRE_HEADER, METRIC_HEADER, RELATION_HEADER};
use galaxy_core::{Config, World};
use std::time::Instant;

fn main() {
    let mut cfg = Config::default();
    let mut ticks: u32 = 600;
    let (mut save, mut load) = (None::<String>, None::<String>);
    let mut telemetry: Option<String> = None;
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
            // save=<file>: save after the run; load=<file>: resume a save instead of generating a galaxy
            // threads=N: worker threads for the parallel phases (results do not depend on it)
            "threads" => {
                let n: usize = v.parse().unwrap_or(0);
                rayon::ThreadPoolBuilder::new().num_threads(n).build_global().expect("thread pool");
            }
            "save" => save = Some(v.to_string()),
            // telemetry=<dir>: write galaxy/empires/relations/events/wars CSVs and summary.json after the run
            "telemetry" => telemetry = Some(v.to_string()),
            "load" => load = Some(v.to_string()),
            // personalities=<file.json>: archetype book (personalities=dump prints the built-in one and exits)
            "personalities" => {
                if v == "dump" {
                    println!("{}", galaxy_core::personality::Book::builtin().to_json());
                    return;
                }
                let txt = std::fs::read_to_string(v).expect("personalities file");
                cfg.personalities = std::sync::Arc::new(galaxy_core::personality::Book::from_json(&txt).unwrap_or_else(|e| panic!("{}", e)));
            }
            // maps=<dir> with spiral_density.png and spiral_population.png (maps=default: the repo's galaxy_maps/)
            "maps" => {
                let dir = if v == "default" { if std::path::Path::new("galaxy_maps").exists() { "galaxy_maps" } else { "../galaxy_maps" } } else { v };
                cfg.maps = Some(std::sync::Arc::new(load_maps(&format!("{}/spiral_density.png", dir), &format!("{}/spiral_population.png", dir))));
            }
            _ => eprintln!("unknown argument {}", a),
        }
    }
    let t0 = Instant::now();
    let mut w = match &load {
        Some(p) => World::load_file(p).unwrap_or_else(|e| panic!("load {}: {}", p, e)),
        None => World::new(cfg),
    };
    println!("INFO,setup_ms={:.1},systems={},bodies={}", t0.elapsed().as_secs_f64() * 1000.0, w.systems.len(), w.colonies.len());
    println!("CSV,{}", METRIC_HEADER);
    let multi = w.empires.len() > 1;
    if multi {
        println!("EMP,{}", EMPIRE_HEADER);
        println!("REL,{}", RELATION_HEADER);
    }
    let wall0 = Instant::now();
    let mut decade0 = Instant::now();
    let mut printed = if load.is_some() { w.events.len() } else { 0 };
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
    for (k, v) in &w.prof {
        println!("PROFILE,{},{:.2}", k, v);
    }
    if let Some(dir) = telemetry {
        w.export_telemetry(&dir).unwrap_or_else(|e| panic!("telemetry {}: {}", dir, e));
        println!("INFO,telemetry={}", dir);
    }
    if let Some(p) = save {
        w.save_file(&p).unwrap_or_else(|e| panic!("save {}: {}", p, e));
        println!("INFO,saved={},bytes={}", p, std::fs::metadata(&p).map(|m| m.len()).unwrap_or(0));
    }
}

/// Load an image as RGB floats 0..1.
fn load_rgb(path: &str) -> (usize, usize, Vec<[f32; 3]>) {
    let file = std::fs::File::open(path).unwrap_or_else(|e| panic!("cannot open {}: {}", path, e));
    let mut dec = png::Decoder::new(std::io::BufReader::new(file));
    dec.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = dec.read_info().expect("bad png");
    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).expect("bad png frame");
    let ch = info.color_type.samples();
    let (w, h) = (info.width as usize, info.height as usize);
    let px = (0..w * h)
        .map(|i| {
            let p = &buf[i * ch..i * ch + ch];
            match ch {
                1 | 2 => [p[0] as f32 / 255.0; 3],
                _ => [p[0] as f32 / 255.0, p[1] as f32 / 255.0, p[2] as f32 / 255.0],
            }
        })
        .collect();
    (w, h, px)
}

fn load_maps(density: &str, population: &str) -> galaxy_core::astro::PlacementMaps {
    let (w, h, d) = load_rgb(density);
    let (w2, h2, c) = load_rgb(population);
    assert!(w == w2 && h == h2, "density and population maps must be the same size");
    galaxy_core::astro::PlacementMaps { width: w, height: h, density: d.iter().map(|p| (p[0] + p[1] + p[2]) / 3.0).collect(), colour: c }
}
