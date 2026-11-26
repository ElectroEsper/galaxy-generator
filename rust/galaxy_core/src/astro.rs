//! Star and planet generation (astronomy_data.gd, solar_system.gd, planet.gd, planet_resources.gd) and the bridge that
//! turns generated bodies into colonies (galaxy_colonies.gd). Only what the economy uses is kept: planet type, mass,
//! radius, temperature, life stage, and Ore / Water / Edibles richness. The 50-class planet classifier is not ported yet
//! (it only names planets).

use crate::rng::Rng;

// ---------------------------------------------------------------- Database
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Pop {
    Pop1,
    Pop1i,
    Pop2,
    Pop2i,
}

/// (max metallicity, age min, age max in Gy)
fn pop_data(p: Pop) -> (f64, f64, f64) {
    match p {
        Pop::Pop1 => (3.0, 0.01, 6.0),
        Pop::Pop1i => (1.6, 4.0, 8.0),
        Pop::Pop2 => (0.8, 8.0, 11.0),
        Pop::Pop2i => (0.3, 10.0, 13.6),
    }
}

pub const CLASS_NAMES: [&str; 7] = ["O", "B", "A", "F", "G", "K", "M"];
const LUMINOSITY: [(f64, f64); 7] = [(30000.0, 1e6), (25.0, 30000.0), (5.0, 25.0), (1.5, 5.0), (0.6, 1.5), (0.08, 0.6), (0.0001, 0.08)];
const MASS: [(f64, f64); 7] = [(16.0, 100.0), (2.1, 16.0), (1.4, 2.1), (1.04, 1.4), (0.8, 1.04), (0.45, 0.8), (0.08, 0.45)];
const MIN_METALLICITY: [f64; 7] = [1.5, 1.0, 0.5, 0.3, 0.1, 0.001, 0.0];
const LIFETIME: [f64; 7] = [0.02, 0.4, 2.0, 5.0, 12.0, 50.0, 1000.0];
const ABUNDANCE: [f64; 7] = [0.000_000_3, 0.0013, 0.006, 0.03, 0.076, 0.121, 0.765];
const CLASS_REALISM: f64 = 0.5;

const BASE_OXYGEN_THRESHOLD: f64 = 0.5;
const ALPHA_ENHANCEMENT: f64 = 0.4;
const LIFE_POSSIBLE: f64 = 0.7;
const BIOSPHERE_MATURE: f64 = 3.5;
const BASE_VOLATILE_THRESHOLD: f64 = 0.6;
const VOLATILE_LINE_MULT: f64 = 2.0;
pub const PROTOPLANET_AGE: f64 = 0.3;
const PROTO_TEMP_MAX: f64 = 1500.0;
const PROTO_TEMP_MIN: f64 = 400.0;
const PROTO_FALLOFF: f64 = 3.5;
const PROTO_INSOLATION: f64 = 0.1;
const ACCU_CAP: f64 = 100.0;
const TAU_ACCUM: f64 = 3.0;

// ---------------------------------------------------------------- Star
pub struct Star {
    pub pop: Pop,
    pub class: usize,
    pub l: f64,
    pub age: f64,
    pub mass: f64,
    pub metallicity: f64,
    pub frostline: f64,
    pub volatileline: f64,
    pub min_orbit: f64,
    pub max_orbit: f64,
    pub oxygen_threshold: f64,
    pub planets: Vec<Planet>,
}

fn valid_classes(pop: Pop, age: Option<f64>) -> Vec<usize> {
    let (pm, _, _) = pop_data(pop);
    (0..7)
        .filter(|&c| age.map_or(true, |a| LIFETIME[c] >= a) && MIN_METALLICITY[c] <= pm)
        .collect()
}

fn pick_class(rng: &mut Rng, valid: &[usize]) -> usize {
    if valid.is_empty() {
        return 6;
    }
    let w: Vec<f64> = valid.iter().map(|&c| ABUNDANCE[c].powf(CLASS_REALISM)).collect();
    let mut roll = rng.randf() * w.iter().sum::<f64>();
    for (i, &c) in valid.iter().enumerate() {
        roll -= w[i];
        if roll <= 0.0 {
            return c;
        }
    }
    *valid.last().unwrap()
}

/// Weighted population pick; weights in the order POP2i, POP1, POP1i, POP2 (the GDScript default order).
fn select_population(rng: &mut Rng, weights: &[(Pop, f64)]) -> Pop {
    let total: f64 = weights.iter().map(|x| x.1).sum();
    let mut roll = rng.randf() * total;
    for &(p, w) in weights {
        roll -= w;
        if roll <= 0.0 && !valid_classes(p, None).is_empty() {
            return p;
        }
    }
    Pop::Pop1
}

pub const DEFAULT_POP_WEIGHTS: [(Pop, f64); 4] = [(Pop::Pop2i, 0.25), (Pop::Pop1, 0.25), (Pop::Pop1i, 0.25), (Pop::Pop2, 0.25)];

impl Star {
    pub fn generate(rng: &mut Rng, pop_weights: &[(Pop, f64)]) -> Star {
        let pop = select_population(rng, pop_weights);
        let (pm, amin, amax) = pop_data(pop);
        let age = rng.range(amin, amax);
        let class = pick_class(rng, &valid_classes(pop, Some(age)));
        let l = rng.range(LUMINOSITY[class].0, LUMINOSITY[class].1);
        let mn = MIN_METALLICITY[class];
        let metallicity = rng.range(mn.min(pm), mn.max(pm));
        let mult = (age - amin) / (amax - amin);
        let mass = MASS[class].0 * (1.0 + mult);
        let frostline = 4.85 * l.sqrt();
        let mut star = Star {
            pop,
            class,
            l,
            age,
            mass,
            metallicity,
            frostline,
            volatileline: VOLATILE_LINE_MULT * frostline,
            min_orbit: 0.1 * l.sqrt(),
            max_orbit: 73.0 * mass.sqrt(),
            oxygen_threshold: BASE_OXYGEN_THRESHOLD / (1.0 + ALPHA_ENHANCEMENT * (age / 10.0)),
            planets: vec![],
        };
        // Orbit slots: geometric spacing from the innermost orbit; giants mostly beyond the frost line.
        let mut d = star.min_orbit * rng.range(1.4, 2.0);
        let mut slots: Vec<(f64, BaseType)> = vec![];
        while d < star.max_orbit {
            let r = d / star.frostline;
            let t = if rng.randf() < if r >= 1.0 { 0.7 } else { 0.03 } {
                if d >= star.frostline { BaseType::IceGiant } else { BaseType::GasGiant }
            } else {
                BaseType::Normal
            };
            slots.push((d, t));
            d *= rng.range(1.4, 2.0);
        }
        for i in 0..slots.len() {
            let (dist, mut t) = slots[i];
            // A rocky body within 2 AU of a giant never formed a planet: it's an asteroid belt.
            if t == BaseType::Normal && slots.iter().any(|s| (s.0 - dist).abs() < 2.0 && matches!(s.1, BaseType::GasGiant | BaseType::IceGiant)) {
                t = BaseType::Belt;
            }
            let p = Planet::generate(rng, &star, dist, t);
            star.planets.push(p);
        }
        star
    }
}

// ---------------------------------------------------------------- Planet
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BaseType {
    Normal,
    GasGiant,
    IceGiant,
    Belt,
}

pub struct Planet {
    pub distance: f64,
    pub btype: BaseType,
    pub mass: f64,
    pub radius: f64,
    pub temperature_raw: f64,
    pub life_stage: u8, // 0 sterile, 1 nascent, 2 flourishing
    pub has_water: bool,
    pub has_ice: bool,
    /// Richness 0..10 (planet_resources.gd)
    pub ore: f64,
    pub water: f64,
    pub edibles: f64,
    pub volatiles: f64,
}

fn volcanism_level(normal: bool, has_volcanism: bool, index: f64) -> u8 {
    // 0 none, 1 dead, 2 dormant, 3 restrained, 4 active, 5 hyper-active
    if !normal {
        0
    } else if !has_volcanism {
        1
    } else if index > 0.8 {
        5
    } else if index > 0.5 {
        4
    } else if index > 0.25 {
        3
    } else {
        2
    }
}

fn geo_favorability(level: u8) -> f64 {
    match level {
        1 => 0.3,
        2 => 0.7,
        3 | 4 => 1.0,
        5 => 0.5,
        _ => 0.0,
    }
}

fn regulation_coef(water: bool, tectonic: bool, outgassing: f64) -> f64 {
    if water && tectonic {
        outgassing * 0.1
    } else if water {
        outgassing * 0.5
    } else {
        outgassing * 1.5
    }
}

impl Planet {
    fn generate(rng: &mut Rng, star: &Star, distance: f64, btype: BaseType) -> Planet {
        let mut p = Planet { distance, btype, mass: 0.0, radius: 0.0, temperature_raw: 0.0, life_stage: 0, has_water: false, has_ice: false, ore: 0.0, water: 0.0, edibles: 0.0, volatiles: 0.0 };
        let metal01 = (star.metallicity / 3.0).clamp(0.0, 1.0);
        if btype == BaseType::Belt {
            p.mass = 0.002 / distance.sqrt();
            p.radius = distance;
            p.ore = (5.0 + metal01 * 4.0 + rng.range(-1.0, 1.0)).clamp(0.0, 10.0);
            return p;
        }
        let normal = btype == BaseType::Normal;
        if normal {
            p.mass = rng.range(0.005, 2.0);
            p.radius = p.mass.powf(0.27);
        } else {
            p.mass = rng.range(10.0, 4130.0);
            p.radius = rng.range(10.0, 12.0);
        }
        if rng.randf() <= 0.5 {
            let _moons = if normal { rng.int_range(1, 3) } else { rng.int_range(1, 6) };
        }
        let temp_eq = 255.0 * star.l.powf(0.25) / distance.sqrt();
        let can_water = temp_eq > 188.0 && temp_eq < 350.0;
        let can_ice = temp_eq < 273.0;
        let formation_budget = (0.3 + 0.5 / (1.0 + (-8.0 * (distance / star.frostline - 1.0)).exp())).clamp(0.0, 1.0);
        let oxygen_factor = (star.metallicity / star.oxygen_threshold).min(1.0);
        let water_budget = formation_budget * oxygen_factor;
        // (The GDScript writes 1/3, an integer 0, so its thermal lifespan is a flat 11; this uses the intended cube root.)
        let thermal_lifespan = 11.0 * p.mass.cbrt();
        let age_proportion = star.age / thermal_lifespan;
        let tectonic = normal && p.mass >= 0.5 && age_proportion <= 0.45;
        let has_dynamo = age_proportion <= 0.65;
        let has_volcanism = age_proportion <= 0.95;
        let vindex = 1.0 - age_proportion;
        let volcanism = volcanism_level(normal, has_volcanism, vindex);
        let outgassing = if !normal || !has_volcanism || distance / star.frostline > 1.0 {
            0.0
        } else if vindex > 0.8 {
            1.5
        } else if vindex > 0.5 {
            1.0
        } else if vindex > 0.25 {
            0.3
        } else {
            0.1
        };
        let age_bonus = if tectonic { 0.0 } else { ACCU_CAP * (1.0 - (-star.age / TAU_ACCUM).exp()) };
        let condensation_gate = 1.0 / (1.0 + (-0.03 * (temp_eq - 195.0)).exp());
        let mut reg = regulation_coef(can_water, tectonic, outgassing);
        let mut gh_volc = outgassing * reg * (1.0 + age_bonus) * condensation_gate;
        let rotation = match btype {
            BaseType::IceGiant => 16.0,
            BaseType::Normal => 14.0,
            BaseType::GasGiant => 10.5,
            BaseType::Belt => 0.0,
        };
        let tidallock = 1.2e5 * ((rotation * distance.powi(6)) / (star.mass * p.radius.powi(2))) < star.age;
        let _magnetic = !tidallock && has_dynamo;
        let mut retention = 1.0 - (((1.0 - (p.mass / (p.radius * (temp_eq / 288.0)))) / 4.5) * star.age) + reg;
        let can_volatiles = temp_eq < 250.0;
        let r_vol = distance / star.volatileline;
        let vol_budget = (0.3 + 0.5 / (1.0 + (-8.0 * (r_vol - 1.0)).exp())).clamp(0.0, 1.0) * (star.metallicity / BASE_VOLATILE_THRESHOLD).min(1.0);
        let has_volatile_ice = can_volatiles && rng.randf() <= vol_budget;
        let has_volatile = can_volatiles && rng.randf() <= vol_budget * retention.clamp(0.0, 1.0);
        p.has_ice = can_ice && rng.randf() <= water_budget;
        p.has_water = can_water && rng.randf() <= water_budget * retention.clamp(0.0, 1.0);
        if !p.has_water && can_water {
            reg = regulation_coef(false, tectonic, outgassing);
            gh_volc = outgassing * reg * (1.0 + age_bonus) * condensation_gate;
            retention = 1.0 - (((1.0 - (p.mass / (p.radius * (temp_eq / 288.0)))) / 4.5) * star.age) + reg;
        }
        p.life_stage = if !p.has_water || star.age < LIFE_POSSIBLE {
            0
        } else {
            let eff = (star.age - LIFE_POSSIBLE) * geo_favorability(volcanism);
            if eff >= BIOSPHERE_MATURE { 2 } else if eff > 0.0 { 1 } else { 0 }
        };
        p.temperature_raw = (temp_eq * (1.0 + gh_volc + retention.clamp(0.0, 1.0)).powf(1.0 / 6.0)).round();
        if star.age < PROTOPLANET_AGE {
            let r_scale = ((distance - star.min_orbit) / (star.max_orbit - star.min_orbit).max(0.0001)).clamp(0.0, 1.0);
            let accretion = PROTO_TEMP_MIN + (PROTO_TEMP_MAX - PROTO_TEMP_MIN) * (-PROTO_FALLOFF * r_scale).exp();
            p.temperature_raw = (accretion + temp_eq * PROTO_INSOLATION).round();
        }
        // Resources (planet_resources.gd)
        match btype {
            BaseType::GasGiant => p.volatiles = rng.range(5.0, 9.0),
            BaseType::IceGiant => {
                p.volatiles = rng.range(5.0, 9.0);
                p.water = rng.range(4.0, 8.0);
            }
            _ => {
                p.ore = (metal01 * 9.0 * rng.range(0.6, 1.2)).clamp(0.0, 10.0);
                if has_volatile || has_volatile_ice {
                    p.volatiles = rng.range(2.0, 7.0);
                }
                if p.has_water || p.has_ice {
                    p.water = rng.range(3.0, 8.0);
                }
                match p.life_stage {
                    2 => {
                        p.edibles = rng.range(5.0, 9.0);
                        let _biomass = rng.range(4.0, 9.0);
                    }
                    1 => {
                        p.edibles = rng.range(1.0, 4.0);
                        let _biomass = rng.range(1.0, 4.0);
                    }
                    _ => {}
                }
            }
        }
        p
    }

    pub fn label(&self) -> &'static str {
        match self.btype {
            BaseType::Belt => "Asteroid belt",
            BaseType::GasGiant => "Gas giant",
            BaseType::IceGiant => "Ice giant",
            BaseType::Normal => {
                if self.life_stage == 2 {
                    "Garden"
                } else if self.temperature_raw >= 500.0 {
                    "Infernal"
                } else if self.temperature_raw >= 341.0 {
                    "Torrid"
                } else if self.temperature_raw >= 250.0 {
                    "Temperate"
                } else if self.temperature_raw >= 100.0 {
                    "Frigid"
                } else {
                    "Cryogenic"
                }
            }
        }
    }
}
