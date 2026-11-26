//! Godot extension. `GalaxySim` (a Node) owns a galaxy_core World on its own thread: the thread advances months at
//! the requested pace (or as fast as it can) and publishes a plain-data Snapshot after each one. The view calls
//! `poll()` every frame and gets a Dictionary only when a new month is ready, so drawing never waits on the sim.

use galaxy_core::snapshot::Snapshot;
use galaxy_core::{Config, World};
use godot::prelude::*;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

struct GalaxyExtension;

#[gdextension]
unsafe impl ExtensionLibrary for GalaxyExtension {}

struct Shared {
    paused: AtomicBool,
    stop: AtomicBool,
    /// Months per second, as f64 bits.
    speed: AtomicU64,
    latest: Mutex<Option<Snapshot>>,
    /// System the view asked about (-1: none), and the answer.
    detail_req: std::sync::atomic::AtomicI64,
    detail: Mutex<Option<galaxy_core::snapshot::SystemDetail>>,
    events: Mutex<Vec<String>>,
    /// Save request (absolute path) and its result ("" = ok, otherwise the error).
    save_req: Mutex<Option<(bool, String)>>, // (is telemetry export, absolute path)
    save_result: Mutex<Option<String>>,
}

#[derive(GodotClass)]
#[class(base = Node)]
pub struct GalaxySim {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
    base: Base<Node>,
}

#[godot_api]
impl INode for GalaxySim {
    fn init(base: Base<Node>) -> Self {
        GalaxySim {
            shared: Arc::new(Shared {
                paused: AtomicBool::new(false),
                stop: AtomicBool::new(false),
                speed: AtomicU64::new(6.0f64.to_bits()),
                latest: Mutex::new(None),
                detail_req: std::sync::atomic::AtomicI64::new(-1),
                detail: Mutex::new(None),
                events: Mutex::new(vec![]),
                save_req: Mutex::new(None),
                save_result: Mutex::new(None),
            }),
            thread: None,
            base,
        }
    }

    fn exit_tree(&mut self) {
        self.stop();
    }
}

/// Both maps given (res:// or file paths) -> image-driven placement; otherwise None (uniform disc).
fn load_maps(density: &GString, population: &GString) -> Option<Arc<galaxy_core::astro::PlacementMaps>> {
    if density.is_empty() || population.is_empty() {
        return None;
    }
    let read = |path: &GString| -> Option<(usize, usize, Vec<[f32; 3]>)> {
        let mut img = godot::classes::Image::load_from_file(path)?;
        img.convert(godot::classes::image::Format::RGB8);
        let (w, h) = (img.get_width() as usize, img.get_height() as usize);
        let data = img.get_data();
        let bytes = data.as_slice();
        Some((w, h, (0..w * h).map(|i| [bytes[i * 3] as f32 / 255.0, bytes[i * 3 + 1] as f32 / 255.0, bytes[i * 3 + 2] as f32 / 255.0]).collect()))
    };
    let (w, h, d) = read(density)?;
    let (w2, h2, c) = read(population)?;
    if w != w2 || h != h2 {
        godot_error!("GalaxySim: density and population maps must be the same size");
        return None;
    }
    Some(Arc::new(galaxy_core::astro::PlacementMaps { width: w, height: h, density: d.iter().map(|p| (p[0] + p[1] + p[2]) / 3.0).collect(), colour: c }))
}

fn put<T: ToGodot>(d: &mut Dictionary<Variant, Variant>, k: &str, v: T) {
    d.set(&k.to_variant(), &v.to_variant());
}

fn get_or<T: FromGodot>(d: &Dictionary<Variant, Variant>, k: &str, default: T) -> T {
    d.get(k).and_then(|v| v.try_to::<T>().ok()).unwrap_or(default)
}

#[godot_api]
impl GalaxySim {
    /// Build a galaxy and start the sim thread. Keys (all optional): systems, planets, empires, seed, colonize, taxes,
    /// state, growth, max_corps, density_map + population_map (image paths: stars placed from the maps).
    #[func]
    fn start(&mut self, config: Dictionary<Variant, Variant>) {
        self.stop();
        let cfg = Config {
            systems: get_or::<i64>(&config, "systems", 46) as usize,
            planets: get_or::<i64>(&config, "planets", 100) as usize,
            empires: get_or::<i64>(&config, "empires", 4) as usize,
            seed: get_or::<i64>(&config, "seed", 7) as u64,
            colonize: get_or(&config, "colonize", true),
            taxes: get_or(&config, "taxes", true),
            state: get_or(&config, "state", true),
            growth: get_or(&config, "growth", true),
            max_corps: get_or::<i64>(&config, "max_corps", 60) as usize,
            food_mult: 1.0,
            personalities: {
                let json: GString = get_or(&config, "personalities", GString::new());
                if json.is_empty() {
                    Default::default()
                } else {
                    match galaxy_core::personality::Book::from_json(&json.to_string()) {
                        Ok(b) => Arc::new(b),
                        Err(e) => {
                            godot_error!("GalaxySim: bad personalities ({}); using the built-in ones", e);
                            Default::default()
                        }
                    }
                }
            },
            maps: load_maps(&get_or(&config, "density_map", GString::new()), &get_or(&config, "population_map", GString::new())),
        };
        self.spawn(move || World::new(cfg), false);
    }

    /// Save the running galaxy (res://, user:// or a plain path). Works while paused. Returns "" or an error.
    #[func]
    fn save_game(&mut self, path: GString) -> GString {
        if self.thread.is_none() {
            return "no galaxy running".into();
        }
        let abs = godot::classes::ProjectSettings::singleton().globalize_path(&path).to_string();
        *self.shared.save_result.lock().unwrap() = None;
        self.request_io(false, abs)
    }

    /// Export the playthrough's history (CSV files + summary.json) into a folder (res://, user:// or a plain path).
    /// Works while paused. Returns "" or an error.
    #[func]
    fn export_telemetry(&mut self, dir: GString) -> GString {
        if self.thread.is_none() {
            return "no galaxy running".into();
        }
        let abs = godot::classes::ProjectSettings::singleton().globalize_path(&dir).to_string();
        *self.shared.save_result.lock().unwrap() = None;
        self.request_io(true, abs)
    }

    fn request_io(&mut self, telemetry: bool, abs: String) -> GString {
        *self.shared.save_req.lock().unwrap() = Some((telemetry, abs));
        let t0 = Instant::now();
        while t0.elapsed() < Duration::from_secs(10) {
            if let Some(r) = self.shared.save_result.lock().unwrap().take() {
                return r.as_str().into();
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        "timed out waiting for the sim".into()
    }

    /// Stop the current galaxy and resume a saved one. Returns "" or an error (the current galaxy keeps running then).
    #[func]
    fn load_game(&mut self, path: GString) -> GString {
        let abs = godot::classes::ProjectSettings::singleton().globalize_path(&path).to_string();
        let w = match World::load_file(&abs) {
            Ok(w) => w,
            Err(e) => return e.as_str().into(),
        };
        self.stop();
        self.spawn(move || w, true);
        GString::new()
    }

    /// The built-in personality book as JSON (the editor's starting point).
    #[func]
    fn default_personalities() -> GString {
        galaxy_core::personality::Book::builtin().to_json().as_str().into()
    }

    /// The trait names archetypes can use.
    #[func]
    fn trait_names() -> PackedStringArray {
        let mut a = PackedStringArray::new();
        for n in galaxy_core::personality::NAMES {
            a.push(n);
        }
        a
    }

    /// The effect names trait blocks can scale.
    #[func]
    fn effect_names() -> PackedStringArray {
        let mut a = PackedStringArray::new();
        for n in galaxy_core::personality::EFFECTS {
            a.push(n);
        }
        a
    }

    /// "" if the JSON is a valid personality book, otherwise what is wrong with it.
    #[func]
    fn validate_personalities(json: GString) -> GString {
        match galaxy_core::personality::Book::from_json(&json.to_string()) {
            Ok(_) => GString::new(),
            Err(e) => e.as_str().into(),
        }
    }

    #[func]
    fn stop(&mut self) {
        self.shared.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }

    /// Ask for the bodies of one system; the answer arrives as "detail" in a later poll() (also while paused).
    #[func]
    fn request_detail(&mut self, system: i64) {
        self.shared.detail_req.store(system, Ordering::SeqCst);
    }

    /// The latest system detail, or an empty Dictionary.
    #[func]
    fn take_detail(&mut self) -> Dictionary<Variant, Variant> {
        let det = match self.shared.detail.lock().unwrap().take() {
            Some(d) => d,
            None => return Dictionary::new(),
        };
        let mut d: Dictionary<Variant, Variant> = Dictionary::new();
        put(&mut d, "id", det.id as i64);
        put(&mut d, "name", GString::from(det.name.as_str()));
        put(&mut d, "star", GString::from(det.star.as_str()));
        put(&mut d, "owner", det.owner as i64);
        put(&mut d, "occupier", det.occupier as i64);
        let mut bodies: Array<Dictionary<Variant, Variant>> = Array::new();
        for b in &det.bodies {
            let mut bd: Dictionary<Variant, Variant> = Dictionary::new();
            put(&mut bd, "name", GString::from(b.name.as_str()));
            put(&mut bd, "class", GString::from(b.class.as_str()));
            put(&mut bd, "owner", b.owner as i64);
            put(&mut bd, "settled", b.settled);
            put(&mut bd, "pop", b.pop);
            put(&mut bd, "max_pop", b.max_pop);
            put(&mut bd, "facilities", b.facilities as i64);
            let mut dep = PackedStringArray::new();
            for (g, v) in &b.deposits {
                dep.push(&GString::from(format!("{} {:.1}", g, v).as_str()));
            }
            put(&mut bd, "deposits", dep);
            let mut pr = PackedFloat32Array::new();
            for p in b.prices {
                pr.push(p as f32);
            }
            put(&mut bd, "prices", pr);
            bodies.push(&bd);
        }
        put(&mut d, "bodies", bodies);
        let mut fs = PackedStringArray::new();
        for f in &det.forces {
            fs.push(f.as_str());
        }
        put(&mut d, "forces", fs);
        d
    }

    #[func]
    fn set_paused(&mut self, paused: bool) {
        self.shared.paused.store(paused, Ordering::SeqCst);
    }

    #[func]
    fn is_paused(&self) -> bool {
        self.shared.paused.load(Ordering::SeqCst)
    }

    /// Months per second (the sim runs as fast as it can if this exceeds what it can do).
    #[func]
    fn set_speed(&mut self, months_per_second: f64) {
        self.shared.speed.store(months_per_second.max(0.1).to_bits(), Ordering::SeqCst);
    }

    /// The newest month as a Dictionary, or an empty Dictionary when nothing new happened since the last call.
    #[func]
    fn poll(&mut self) -> Dictionary<Variant, Variant> {
        let snap = match self.shared.latest.lock().unwrap().take() {
            Some(s) => s,
            None => return Dictionary::new(),
        };
        let mut d: Dictionary<Variant, Variant> = Dictionary::new();
        put(&mut d, "tick", snap.tick as i64);
        put(&mut d, "date", GString::from(snap.date.as_str()));
        put(&mut d, "colonies", snap.colonies as i64);
        put(&mut d, "corps", snap.corps as i64);
        // Systems: 10 floats each: x, y, owner, occupier, at_front, settled bodies, bodies, pop, known, shortage
        let mut sys = PackedFloat32Array::new();
        let mut names = PackedStringArray::new();
        for s in &snap.systems {
            for v in [s.pos.0, s.pos.1, s.owner as f64, s.occupier as f64, s.at_front as i32 as f64, s.settled as f64, s.bodies as f64, s.pop, s.known as i32 as f64, s.shortage] {
                sys.push(v as f32);
            }
            names.push(&GString::from(s.name.as_str()));
        }
        put(&mut d, "systems", sys);
        put(&mut d, "system_names", names);
        let mut emps: Array<Dictionary<Variant, Variant>> = Array::new();
        for e in &snap.empires {
            let mut ed: Dictionary<Variant, Variant> = Dictionary::new();
            put(&mut ed, "name", GString::from(e.name.as_str()));
            put(&mut ed, "capital", Vector2::new(e.capital.0 as f32, e.capital.1 as f32));
            put(&mut ed, "colonies", e.colonies as i64);
            put(&mut ed, "systems", e.systems as i64);
            put(&mut ed, "pop", e.pop);
            put(&mut ed, "treasury", e.treasury);
            put(&mut ed, "strength", e.strength);
            put(&mut ed, "exhaustion", e.exhaustion);
            put(&mut ed, "reputation", e.reputation);
            put(&mut ed, "personality", GString::from(e.personality.as_str()));
            put(&mut ed, "fleet", e.fleet);
            put(&mut ed, "army", e.army);
            put(&mut ed, "operations", e.operations as i64);
            let mut tl = PackedInt32Array::new();
            for &l in &e.tech {
                tl.push(l as i32);
            }
            put(&mut ed, "tech", tl);
            let mut ww = PackedStringArray::new();
            for x in &e.at_war_with {
                ww.push(&GString::from(x.as_str()));
            }
            put(&mut ed, "at_war_with", ww);
            emps.push(&ed);
        }
        put(&mut d, "empires", emps);
        let pairs = |v: &Vec<(u32, u32)>| {
            let mut a = PackedInt32Array::new();
            for &(x, y) in v {
                a.push(x as i32);
                a.push(y as i32);
            }
            a
        };
        put(&mut d, "wars", pairs(&snap.wars));
        put(&mut d, "pacts", pairs(&snap.pacts));
        put(&mut d, "guarantees", pairs(&snap.guarantees));
        // Shipments: 6 floats each: from x, from y, to x, to y, good, quantity
        let mut sh = PackedFloat32Array::new();
        for (a, b, g, q) in &snap.shipments {
            for v in [a.0, a.1, b.0, b.1, *g as f64, *q] {
                sh.push(v as f32);
            }
        }
        put(&mut d, "shipments", sh);
        // Forces: 9 floats each: x, y, owner, army (0/1), strength, dest x, dest y, in operation (0/1), id
        let mut fo = PackedFloat32Array::new();
        for f in &snap.forces {
            for v in [f.pos.0, f.pos.1, f.owner as f64, f.army as i32 as f64, f.strength, f.dest.0, f.dest.1, f.in_op as i32 as f64, f.id as f64] {
                fo.push(v as f32);
            }
        }
        put(&mut d, "forces", fo);
        let mut ev = PackedStringArray::new();
        for e in self.shared.events.lock().unwrap().drain(..) {
            ev.push(&GString::from(e.as_str()));
        }
        put(&mut d, "events", ev);
        d
    }
}

impl GalaxySim {
    fn spawn<F: FnOnce() -> World + Send + 'static>(&mut self, make: F, loaded: bool) {
        let shared = self.shared.clone();
        shared.stop.store(false, Ordering::SeqCst);
        shared.events.lock().unwrap().clear();
        self.thread = Some(std::thread::spawn(move || {
            let mut w = make();
            *shared.latest.lock().unwrap() = Some(w.snapshot());
            let mut printed = if loaded { w.events.len() } else { 0 };
            let mut budget = 0.0f64;
            let mut last = Instant::now();
            while !shared.stop.load(Ordering::SeqCst) {
                if let Some((telemetry, p)) = shared.save_req.lock().unwrap().take() {
                    let r = if telemetry { w.export_telemetry(&p) } else { w.save_file(&p) }.err().unwrap_or_default();
                    *shared.save_result.lock().unwrap() = Some(r);
                }
                let req = shared.detail_req.swap(-1, Ordering::SeqCst);
                if req >= 0 {
                    *shared.detail.lock().unwrap() = w.system_detail(req as usize);
                }
                let now = Instant::now();
                let dt = (now - last).as_secs_f64();
                last = now;
                if shared.paused.load(Ordering::SeqCst) {
                    budget = 0.0;
                    std::thread::sleep(Duration::from_millis(10));
                    continue;
                }
                let speed = f64::from_bits(shared.speed.load(Ordering::SeqCst));
                budget = (budget + dt * speed).min(2.0); // never build a backlog of more than 2 months
                if budget < 1.0 {
                    std::thread::sleep(Duration::from_millis(2));
                    continue;
                }
                budget -= 1.0;
                w.step();
                let snap = w.snapshot();
                *shared.latest.lock().unwrap() = Some(snap);
                if printed < w.events.len() {
                    let mut ev = shared.events.lock().unwrap();
                    for (t, text) in &w.events[printed..] {
                        ev.push(format!("y{} {}", t / 12, text));
                    }
                    printed = w.events.len();
                }
            }
        }));
    }
}
