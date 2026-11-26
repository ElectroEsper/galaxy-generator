//! The simulation world (economy_sim.gd + empire.gd + galaxy_colonies.gd): setup, colonization, relations, and the
//! monthly tick. Corporations live in corp.rs as methods on World (they act on the shared world state).

use crate::astro::{BaseType, Star, DEFAULT_POP_WEIGHTS, PROTOPLANET_AGE};
use crate::corp::{Corp, Kind, Opt};
use crate::goods::{self, PerGood, Rich, FOOD, METAL, ORE, PARTS, WATER};
use crate::market::{dist, Colony, StarSystem, BASE_PRICE, MAX_EMPIRES};
use crate::rng::Rng;
use std::collections::HashMap;

pub const PROMOTE_CASH: f64 = 80.0;
pub const CAPITAL_POP: f64 = 600.0;
pub const CAPITAL_CEILING: f64 = 3000.0;
pub const SETTLER_MIN_POP: f64 = 100.0;
pub const MIGRATION_RATE: f64 = 0.02;
pub const PROFIT_TAX: f64 = 0.25;
pub const WEALTH_TAX: f64 = 0.005;
pub const WEALTH_FREE: f64 = 800.0;
pub const STATE_REVIEW_MONTHS: u32 = 12;
pub const STATE_SETTLERS: f64 = 40.0;
pub const STATE_GRANT: f64 = 60.0;
pub const STATE_RESERVE: f64 = 2.0;
pub const SURVEY_ORDER_PRICE: f64 = 80.0;
pub const SURVEY_BUDGET_SHARE: f64 = 0.05;
pub const HOME_HORIZON: f64 = 160.0;
pub const COLONY_HORIZON: f64 = 110.0;
pub const SECTOR_RADIUS: f64 = 140.0;
pub const SECTOR_BASE_CHANCE: f64 = 0.002;
pub const SECTOR_EXHAUSTED_CHANCE: f64 = 0.04;
pub const BORDER_RANGE: f64 = 90.0;
pub const TRADE_WEIGHT: f64 = 8.0;
pub const BORDER_WEIGHT: f64 = 3.0;
pub const INCIDENT_PENALTY: f64 = 15.0;
pub const INCIDENT_DECAY: f64 = 0.98;
pub const OPINION_RATE: f64 = 0.05;
pub const TERRITORY_RADIUS: f64 = 70.0;
pub const ROUTE_SAMPLE: f64 = 20.0;
pub const GOODWILL_WEIGHT: f64 = 1.0;
const VIEW_CENTER: (f64, f64) = (576.0, 340.0);
const VIEW_RADIUS: (f64, f64) = (470.0, 250.0);
/// Half-size of an image-driven galaxy on the map (it is square), before scaling by sqrt(systems / 46).
const MAP_RADIUS: f64 = 330.0;

#[derive(Clone, Debug)]
pub struct Config {
    pub planets: usize,
    pub systems: usize,
    pub empires: usize,
    pub seed: u64,
    pub growth: bool,
    pub colonize: bool,
    pub taxes: bool,
    pub state: bool,
    pub max_corps: usize,
    pub food_mult: f64,
    /// Image-driven star placement; None = stars on a uniform disc.
    pub maps: Option<std::sync::Arc<crate::astro::PlacementMaps>>,
}

impl Default for Config {
    fn default() -> Self {
        Config { planets: 100, systems: 0, empires: 1, seed: 7, growth: true, colonize: false, taxes: true, state: true, max_corps: 60, food_mult: 1.0, maps: None }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Stance {
    None,
    Friendly,
    Neutral,
    Hostile,
    Embargo,
}

impl Stance {
    pub fn name(self) -> &'static str {
        match self {
            Stance::None => "none",
            Stance::Friendly => "friendly",
            Stance::Neutral => "neutral",
            Stance::Hostile => "hostile",
            Stance::Embargo => "embargo",
        }
    }
    pub fn tariff(self) -> f64 {
        match self {
            Stance::Friendly => 0.0,
            Stance::Neutral | Stance::None => 0.10,
            Stance::Hostile | Stance::Embargo => 0.35,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Relation {
    pub met: bool,
    pub opinion: f64,
    pub trade: f64,
    pub month_trade: f64,
    pub border: i32,
    pub incidents: f64,
    pub stance: Stance,
    pub trade_treaty: bool,
    pub passage: bool,
    pub goodwill: f64,
    pub truce_until: i64,
    pub pact: bool,
    pub pact_year: i64,
    /// Trust of the lower-id empire in the higher, and of the higher in the lower (0..100).
    pub trust: [f64; 2],
    pub reparations: Option<crate::treaties::Reparations>,
    pub forced_market: Option<(usize, i64)>,
    pub forced_transit: Option<(usize, i64)>,
}

impl Default for Relation {
    fn default() -> Self {
        Relation {
            met: false, opinion: 0.0, trade: 0.0, month_trade: 0.0, border: 0, incidents: 0.0, stance: Stance::None, trade_treaty: false,
            passage: false, goodwill: 0.0, truce_until: 0, pact: false, pact_year: 0, trust: [50.0; 2], reparations: None,
            forced_market: None, forced_transit: None,
        }
    }
}

/// One space-faring state (empire.gd). Military, diplomacy and personality fields come with the next port stage.
#[derive(Clone, Debug)]
pub struct Empire {
    pub id: usize,
    pub name: String,
    pub capital: usize,
    pub treasury: f64,
    pub tax_collected: f64,
    pub month_tax: f64,
    pub state_colonies: i32,
    pub state_spent: f64,
    pub survey_backlog: i32,
    pub surveys_ordered: i32,
    pub sector_events: i32,
    pub settlements: i32,
    pub customs_collected: f64,
    pub known: Vec<bool>,
    /// Personality traits, 0..1: aggression, expansion, mercantile, xenophobia, militarism, caution, intervention.
    pub traits: [f64; 7],
    pub base_traits: [f64; 7],
    pub stability: f64,
    pub regime_year: i64,
    // Military (military.rs)
    pub strength: f64,
    pub exhaustion: f64,
    pub avg_tax: f64,
    pub target_strength: f64,
    pub mil_spent: f64,
    pub arming_until: i64,
    // Diplomacy, threat, alliances, treaties
    pub refusals: HashMap<usize, i64>,
    pub threat: [f64; MAX_EMPIRES],
    pub max_threat: f64,
    pub main_threat: Option<usize>,
    pub wars_started: Vec<i64>,
    pub systems_taken: i32,
    pub sys_history: Vec<usize>,
    /// (protected empire, the threat it is protected against, start year)
    pub guarantees: Vec<(usize, Option<usize>, i64)>,
    pub reputation: f64,
    pub revanche: Vec<crate::treaties::Revanche>,
    pub demilitarized_until: i64,
    pub demilitarized_by: Option<usize>,
    // Per-month caches (cleared at the start of each tick and whenever a colony is founded)
    /// Nearest own colony per system/body key: (colony, distance, key position). Kept across months and updated in
    /// place when a colony is founded; cleared only when the empire loses a colony.
    pub near_cache: HashMap<u64, (usize, f64, (f64, f64))>,
    pub donor_cache: HashMap<u64, Option<usize>>,
    pub donor_any: Option<bool>,
    pub cand_cache: Option<Vec<usize>>,
    pub ob_cache: Option<std::sync::Arc<Vec<ObRow>>>,
    pub known_frontier: Option<Vec<usize>>,
    /// Survey board: (value, scan index, body), best first. Rebuilt when known space or the colony set changes;
    /// a completed survey only re-scores its own row.
    pub survey_board: Option<Vec<(f64, usize, usize)>>,
    pub survey_gen: u64,
    /// Month the survey board was last rebuilt (it is refreshed at most once a month).
    pub survey_board_tick: i64,
    /// Generation of the colony set this empire's nearest-colony cache was built for.
    pub near_gen: u64,
    /// Bodies this empire knows deposits on, in id order (the outpost candidates are drawn from these).
    pub known_bodies: Vec<usize>,
}

/// Fixed parts of an outpost option for the month: body, good, richness, net unit margin, cost without claim fee.
#[derive(Clone, Copy, Debug)]
pub struct ObRow {
    pub c: usize,
    pub g: usize,
    pub q: f64,
    pub unit: f64,
    pub cost: f64,
}

pub const TRAIT_AGGRESSION: usize = 0;
pub const TRAIT_EXPANSION: usize = 1;
pub const TRAIT_MERCANTILE: usize = 2;
pub const TRAIT_XENOPHOBIA: usize = 3;
pub const TRAIT_MILITARISM: usize = 4;
pub const TRAIT_CAUTION: usize = 5;
pub const TRAIT_INTERVENTION: usize = 6;

impl Empire {
    pub fn w(&self, t: usize) -> f64 {
        0.5 + self.traits[t]
    }
    pub fn t(&self, t: usize) -> f64 {
        self.traits[t]
    }
    pub fn guarantees_(&self, x: usize) -> bool {
        self.guarantees.iter().any(|g| g.0 == x)
    }
    pub fn clear_caches(&mut self) {
        self.donor_cache.clear();
        self.donor_any = None;
        self.cand_cache = None;
        self.ob_cache = None;
    }
}

pub struct World {
    pub cfg: Config,
    pub rng: Rng,
    pub tick: u32,
    pub colonies: Vec<Colony>,
    /// Settled colonies (markets), in founding order.
    pub markets: Vec<usize>,
    /// Every non-capital body (settled ones stay listed).
    pub frontier: Vec<usize>,
    pub systems: Vec<StarSystem>,
    pub corps: Vec<Corp>,
    pub empires: Vec<Empire>,
    pub relations: Vec<Relation>,
    pub wars: Vec<crate::military::War>,
    pub next_war_id: usize,
    /// Diplomatic crises under way (plays.rs).
    pub plays: Vec<crate::plays::Play>,
    pub next_play_id: usize,
    /// Separate random stream for personality, so it never shifts the economy's random numbers.
    pub prng: Rng,
    pub events: Vec<(u32, String)>,
    pub promotions: i32,
    pub attractions: i32,
    pub settlements: i32,
    pub sector_events: i32,
    pub treasury: f64,
    pub tax_collected: f64,
    pub external_migration: bool,
    /// Homeworlds generated up front, one per empire (colonization runs).
    pub forced_capitals: Vec<usize>,
    /// Bumped whenever a colony is founded or changes hands (positions never change, so nearest-colony answers only
    /// go stale then).
    pub colony_gen: u64,
    /// Bumped when an empire loses a colony (the only change that can make a nearest-colony answer worse).
    pub loss_gen: u64,
    pub(crate) rescore_after: Option<(usize, usize)>,
    /// Freight lane candidates for the month: per good, the 6 cheapest and 6 dearest markets.
    pub(crate) lanes: (Vec<Vec<usize>>, Vec<Vec<usize>>),
    pub(crate) lanes_tick: Option<u32>,
    /// Profiling: seconds spent per phase (cumulative).
    pub prof: std::collections::BTreeMap<&'static str, f64>,
    // Caches
    pub(crate) reg_use: Option<PerGood>,
    pub(crate) reg_cap: Option<PerGood>,
    pub(crate) boards: HashMap<(u8, i64), std::sync::Arc<Vec<Opt>>>,
    pub(crate) out_cache: HashMap<(usize, usize), std::sync::Arc<Vec<Opt>>>,
    route_cache: HashMap<(usize, u64, u64), bool>,
    route_geo: HashMap<(u64, u64), Vec<Vec<usize>>>,
}

fn key_of(c: &Colony) -> u64 {
    match c.system {
        Some(s) => s as u64,
        None => (1u64 << 32) + c.id as u64,
    }
}

impl World {
    // ------------------------------------------------------------ Setup
    pub fn new(cfg: Config) -> World {
        let mut w = World {
            rng: Rng::new(cfg.seed),
            prng: Rng::new(cfg.seed.wrapping_mul(7919).wrapping_add(12345)),
            wars: vec![],
            next_war_id: 0,
            plays: vec![],
            next_play_id: 0,
            cfg,
            tick: 0,
            colonies: vec![],
            markets: vec![],
            frontier: vec![],
            systems: vec![],
            corps: vec![],
            empires: vec![],
            relations: vec![],
            events: vec![],
            promotions: 0,
            attractions: 0,
            settlements: 0,
            sector_events: 0,
            treasury: 0.0,
            tax_collected: 0.0,
            external_migration: false,
            forced_capitals: vec![],
            colony_gen: 1,
            loss_gen: 1,
            rescore_after: None,
            lanes: (vec![], vec![]),
            lanes_tick: None,
            prof: Default::default(),
            reg_use: None,
            reg_cap: None,
            boards: HashMap::new(),
            out_cache: HashMap::new(),
            route_cache: HashMap::new(),
            route_geo: HashMap::new(),
        };
        w.generate_galaxy();
        w.markets = (0..w.colonies.len()).collect();
        let growth = w.cfg.growth;
        for c in w.colonies.iter_mut() {
            c.growth_enabled = growth;
        }
        for (k, cash) in [(Kind::Extractor, 300.0), (Kind::Producer, 300.0), (Kind::Freight, 300.0)] {
            w.add_corp(k, cash, None);
        }
        if w.cfg.colonize {
            w.setup_colonization();
        }
        w
    }

    pub fn add_corp(&mut self, kind: Kind, cash: f64, empire: Option<usize>) -> usize {
        let id = self.corps.len();
        self.corps.push(Corp::new(id, kind, cash, empire));
        id
    }

    /// Stars on a uniform disc; every body (rocky, giant, belt) becomes a colony (galaxy_colonies.gd generate_all).
    fn generate_galaxy(&mut self) {
        let star_count = self.cfg.systems;
        let scale = if star_count > 0 { (star_count as f64 / 46.0).sqrt() } else { 1.0 };
        let maps = self.cfg.maps.clone();
        let mut star_idx = 0;
        // Guaranteed homeworlds first (colonization runs): one capital star per empire, spread apart.
        if self.cfg.colonize {
            let n = self.cfg.empires.clamp(1, MAX_EMPIRES);
            let spots = self.capital_spots(n, scale);
            for pos in spots {
                let (star, best) = self.capital_star();
                let ids = self.add_star(&star, pos, star_idx, true);
                self.forced_capitals.push(ids[best]);
                star_idx += 1;
            }
        }
        // The rest of the galaxy. With maps: star pixels sampled up front (systems mode) or generously (planets mode).
        let pixels = match &maps {
            Some(m) => m.sample(&mut self.rng, if star_count > 0 { star_count } else { self.cfg.planets.max(8) * 2 }),
            None => vec![],
        };
        let mut pi = 0;
        while (star_count > 0 && star_idx < star_count) || (star_count == 0 && self.colonies.len() < self.cfg.planets) {
            let (star, pos) = match &maps {
                Some(m) => {
                    if pi >= pixels.len() {
                        break;
                    }
                    let (px, py) = pixels[pi];
                    pi += 1;
                    let pop = m.population(&mut self.rng, px, py);
                    let star = Star::generate(&mut self.rng, &[(pop, 1.0)]);
                    (star, Self::map_pos(m, px, py, scale))
                }
                None => {
                    let star = Star::generate(&mut self.rng, &DEFAULT_POP_WEIGHTS);
                    let a = self.rng.randf() * std::f64::consts::TAU;
                    let r = self.rng.randf().sqrt();
                    (star, (VIEW_CENTER.0 + a.cos() * r * VIEW_RADIUS.0 * scale, VIEW_CENTER.1 + a.sin() * r * VIEW_RADIUS.1 * scale))
                }
            };
            self.add_star(&star, pos, star_idx, false);
            star_idx += 1;
        }
    }

    /// Square maps: one radius for both axes, so the galaxy keeps its shape.
    fn map_pos(m: &crate::astro::PlacementMaps, px: usize, py: usize, scale: f64) -> (f64, f64) {
        let u = px as f64 / m.width as f64 * 2.0 - 1.0;
        let v = py as f64 / m.height as f64 * 2.0 - 1.0;
        (VIEW_CENTER.0 + u * MAP_RADIUS * scale, VIEW_CENTER.1 + v * MAP_RADIUS * scale)
    }

    /// Where the homeworlds go: evenly around a ring on a uniform galaxy; on an image galaxy, spots drawn from the
    /// density map and picked greedily to be as far from each other as possible.
    fn capital_spots(&mut self, n: usize, scale: f64) -> Vec<(f64, f64)> {
        match self.cfg.maps.clone() {
            Some(m) => {
                let cands: Vec<(f64, f64)> = m.sample(&mut self.rng, 300).into_iter().map(|(x, y)| Self::map_pos(&m, x, y, scale)).collect();
                let mut out: Vec<(f64, f64)> = vec![];
                for _ in 0..n {
                    let pick = if out.is_empty() {
                        cands[self.rng.below(cands.len().max(1))]
                    } else {
                        *cands
                            .iter()
                            .max_by(|a, b| {
                                let da = out.iter().map(|o| dist(**a, *o)).fold(f64::INFINITY, f64::min);
                                let db = out.iter().map(|o| dist(**b, *o)).fold(f64::INFINITY, f64::min);
                                da.partial_cmp(&db).unwrap()
                            })
                            .unwrap()
                    };
                    out.push(pick);
                }
                out
            }
            None => {
                let r = if n == 1 { 0.0 } else { 0.62 };
                let a0 = self.rng.randf() * std::f64::consts::TAU;
                (0..n)
                    .map(|i| {
                        let a = a0 + std::f64::consts::TAU * i as f64 / n as f64;
                        (VIEW_CENTER.0 + a.cos() * r * VIEW_RADIUS.0 * scale, VIEW_CENTER.1 + a.sin() * r * VIEW_RADIUS.1 * scale)
                    })
                    .collect()
            }
        }
    }

    /// Roll stars until one has a proper homeworld: a temperate rocky world with good Ore and Water or Food, past
    /// the protoplanet age. Returns the star and the index of that planet among its bodies.
    fn capital_star(&mut self) -> (Star, usize) {
        for attempt in 0..2000 {
            let star = Star::generate(&mut self.rng, &DEFAULT_POP_WEIGHTS);
            if star.age < PROTOPLANET_AGE {
                continue;
            }
            let relaxed = attempt >= 1000; // very unlikely: settle for any world with Ore and Water or Food
            let mut best: Option<(usize, f64)> = None;
            for (i, p) in star.planets.iter().enumerate() {
                if p.btype != BaseType::Normal {
                    continue;
                }
                let temperate = (250.0..=340.0).contains(&p.temperature_raw);
                let ok = if relaxed { p.ore >= 1.0 && (p.water >= 1.0 || p.edibles >= 1.0) } else { temperate && p.ore >= 3.0 && (p.water >= 3.0 || p.edibles >= 3.0) };
                let score = p.ore + p.edibles * 1.5 + p.water + p.mass;
                if ok && best.map_or(true, |b| score > b.1) {
                    best = Some((i, score));
                }
            }
            if let Some((i, _)) = best {
                return (star, i);
            }
        }
        panic!("no homeworld found in 2000 stars");
    }

    /// Add a star system and its bodies as colonies; returns the new colony ids in body order.
    fn add_star(&mut self, star: &Star, pos: (f64, f64), star_idx: usize, capital: bool) -> Vec<usize> {
        let star_count = self.cfg.systems;
        let sid = self.systems.len();
        let mut ids = vec![];
        if star.planets.is_empty() {
            return ids;
        }
        self.systems.push(StarSystem { id: sid, name: format!("S{}", star_idx), pos, class: star.class, bodies: vec![], known: true, owner: None, occupier: None, at_front: false });
        for p in &star.planets {
            if star_count == 0 && self.colonies.len() >= self.cfg.planets && !capital {
                break;
            }
            let mut rich = Rich::default();
            if p.ore >= 1.0 {
                rich.set(ORE, p.ore / 5.0);
            }
            if p.water >= 1.0 {
                rich.set(WATER, p.water / 5.0);
            }
            if p.edibles >= 1.0 {
                rich.set(FOOD, p.edibles / 5.0 * self.cfg.food_mult);
            }
            let ceiling = (120.0 + p.mass * 120.0 + 250.0 * p.life_stage as f64).clamp(120.0, 800.0);
            let pop = self.rng.range(40.0, 90.0);
            let id = self.colonies.len();
            let mut c = Colony::new(id, format!("S{}.{}", star_idx, id), pop, rich, ceiling);
            let habitable = if (250.0..=340.0).contains(&p.temperature_raw) { 3.0 } else { 0.0 };
            let score = if p.btype != BaseType::Normal || star.age < PROTOPLANET_AGE { 0.0 } else { p.ore + p.edibles * 1.5 + habitable };
            c.site_score = score + c.max_pop / 200.0;
            c.pos = pos;
            c.system = Some(sid);
            c.body_radius = p.radius.min(30.0);
            c.label = p.label().to_string();
            if p.btype != BaseType::Normal {
                c.max_pop = if p.btype == BaseType::Belt { 100.0 } else { 80.0 };
                c.pop = c.pop.min(c.max_pop * 0.5);
            }
            self.systems[sid].bodies.push(id);
            self.colonies.push(c);
            ids.push(id);
        }
        ids
    }

    fn setup_colonization(&mut self) {
        self.external_migration = true;
        let n = self.cfg.empires.clamp(1, MAX_EMPIRES);
        // Capitals: the best self-sufficient planet; further empires take good homeworlds far from the others.
        let value: Vec<f64> = self
            .colonies
            .iter()
            .map(|c| {
                let r = c.rich();
                let selfsuf = r.has(ORE) && (r.has(FOOD) || r.has(WATER));
                c.site_score * if selfsuf { 1.0 } else { 0.25 }
            })
            .collect();
        let best_v = value.iter().cloned().fold(-1.0, f64::max);
        let mut capitals: Vec<usize> = vec![];
        if self.forced_capitals.len() >= n {
            capitals = self.forced_capitals[..n].to_vec(); // the guaranteed homeworlds
        }
        for i in capitals.len()..n {
            // Strict first (a good homeworld in a system of its own), then relaxed, so small or harsh galaxies still
            // get every capital instead of failing.
            let mut pick = None;
            for strict in [true, false] {
                let mut pv = -1.0;
                for c in 0..self.colonies.len() {
                    if capitals.contains(&c) {
                        continue;
                    }
                    if strict && capitals.iter().any(|&x| self.colonies[x].system == self.colonies[c].system && self.colonies[c].system.is_some()) {
                        continue;
                    }
                    let mut v = value[c];
                    if i > 0 {
                        if strict && v < best_v * 0.5 {
                            continue;
                        }
                        let dmin = capitals.iter().map(|&x| dist(self.colonies[x].pos, self.colonies[c].pos)).fold(f64::INFINITY, f64::min);
                        v = dmin + v * 0.001;
                    }
                    if v > pv {
                        pv = v;
                        pick = Some(c);
                    }
                }
                if pick.is_some() {
                    break;
                }
            }
            match pick {
                Some(p) => capitals.push(p),
                None => break, // fewer bodies than empires: run with as many empires as fit
            }
        }
        let n = capitals.len();
        let nsys = self.systems.len();
        for (i, &cap) in capitals.iter().enumerate() {
            self.empires.push(Empire {
                id: i,
                name: format!("Empire {}", i + 1),
                capital: cap,
                treasury: 0.0,
                tax_collected: 0.0,
                month_tax: 0.0,
                state_colonies: 0,
                state_spent: 0.0,
                survey_backlog: 0,
                surveys_ordered: 0,
                sector_events: 0,
                settlements: 0,
                customs_collected: 0.0,
                known: vec![false; nsys],
                traits: [0.5; 7],
                base_traits: [0.5; 7],
                stability: 0.5,
                regime_year: -100,
                strength: 0.0,
                exhaustion: 0.0,
                avg_tax: 0.0,
                target_strength: 0.0,
                mil_spent: 0.0,
                arming_until: 0,
                refusals: HashMap::new(),
                threat: [0.0; MAX_EMPIRES],
                max_threat: 0.0,
                main_threat: None,
                wars_started: vec![],
                systems_taken: 0,
                sys_history: vec![],
                guarantees: vec![],
                reputation: 50.0,
                revanche: vec![],
                demilitarized_until: 0,
                demilitarized_by: None,
                near_cache: HashMap::new(),
                donor_cache: HashMap::new(),
                donor_any: None,
                cand_cache: None,
                ob_cache: None,
                known_frontier: None,
                survey_board: None,
                survey_gen: 0,
                survey_board_tick: -1,
                near_gen: 0,
                known_bodies: vec![],
            });
            let c = &mut self.colonies[cap];
            c.name = if n == 1 { "Capital".into() } else { format!("Capital {}", i + 1) };
            c.max_pop = CAPITAL_CEILING;
            c.pop = CAPITAL_POP;
        }
        self.relations = vec![Relation::default(); n * n];
        if n > 1 {
            for e in 0..n {
                crate::personality::generate(self, e);
            }
        }
        for c in 0..self.colonies.len() {
            if !capitals.contains(&c) {
                self.colonies[c].make_frontier();
                self.frontier.push(c);
            }
        }
        for (e, &cap) in capitals.iter().enumerate() {
            // Home deposits are fully known; the home system is charted (public knowledge at home, so no claims).
            let rich = self.colonies[cap].richness_own.clone();
            {
                let c = &mut self.colonies[cap];
                c.hidden = rich.clone();
                let info = c.intel_for(e);
                for &(g, v) in &rich.0 {
                    info.rich.set(g, v);
                    info.found.set(g, 1.0);
                }
                info.surveys = 1;
                c.surveys = 1;
                c.owner = Some(e);
                c.rich_from = Some(e);
            }
            if let Some(s) = self.colonies[cap].system {
                self.systems[s].owner = Some(e);
                for b in self.systems[s].bodies.clone() {
                    if b == cap {
                        continue;
                    }
                    self.colonies[b].surveys = 1;
                    self.colonies[b].intel_for(e).surveys = 1;
                    for (g, v) in self.colonies[b].hidden.0.clone() {
                        self.reveal(b, e, g, v);
                    }
                }
            }
        }
        self.markets = capitals.clone();
        for s in self.systems.iter_mut() {
            s.known = false;
        }
        for e in 0..n {
            let p = self.colonies[capitals[e]].pos;
            self.reveal_around(e, p, HOME_HORIZON);
        }
        for e in 0..n {
            let (ex, pr) = if e == 0 {
                for k in self.corps.iter_mut() {
                    k.empire = Some(0);
                }
                (0, 1)
            } else {
                let ex = self.add_corp(Kind::Extractor, 300.0, Some(e));
                let pr = self.add_corp(Kind::Producer, 300.0, Some(e));
                self.add_corp(Kind::Freight, 300.0, Some(e));
                (ex, pr)
            };
            self.seed_capital(capitals[e], ex, pr);
        }
        for e in 0..n {
            self.add_corp(Kind::Surveyor, 600.0, Some(e));
        }
    }

    /// The homeworld starts with an established economy sized to its population (no capex: it predates the game).
    fn seed_capital(&mut self, cap: usize, ex: usize, pr: usize) {
        let p = self.colonies[cap].pop;
        for pass in 0..4 {
            let hydro: f64 = self.corps[pr].facilities.iter().filter(|f| f.good == FOOD).map(|f| f.throughput(&self.colonies[f.colony])).sum();
            let fc = self.colonies[cap].facility_count as f64;
            let parts_need = (p * goods::pop_consumption(PARTS) + fc * goods::maint_per_facility(PARTS) * (1.0 - goods::SALVAGE_RATE) + hydro * 0.1) * 1.3;
            let mut needs: PerGood = [0.0; goods::N];
            needs[FOOD] = p * goods::pop_consumption(FOOD) * 1.2;
            needs[WATER] = (p * goods::pop_consumption(WATER) + hydro * 2.0) * 1.3;
            needs[PARTS] = parts_need;
            needs[METAL] = (p * goods::maint_per_pop(METAL) + parts_need * 2.0) * 1.1;
            needs[ORE] = needs[METAL] * 2.0 * 1.1;
            for g in [WATER, FOOD, ORE, METAL, PARTS] {
                let mut guard = 0;
                while self.colonies[cap].capacity[g] < needs[g] && self.colonies[cap].facility_slots_free() > 0 && guard < 200 {
                    guard += 1;
                    let q = self.colonies[cap].rich().get(g);
                    if q > 0.0 && Self::site_room(&self.colonies[cap], g, false) >= q {
                        self.seed_facility(ex, cap, g, false);
                    } else if goods::recipe(g).is_some() {
                        self.seed_facility(pr, cap, g, true);
                    } else {
                        break;
                    }
                }
            }
            if pass == 3 {
                for g in goods::ALL {
                    self.colonies[cap].stock[g] = needs[g] * crate::market::COVER_TICKS;
                }
                self.corps[ex].cash = 40.0 * self.corps[ex].facilities.len() as f64 + 300.0;
                self.corps[pr].cash = 40.0 * self.corps[pr].facilities.len() as f64 + 300.0;
            }
        }
    }

    // ------------------------------------------------------------ Knowledge and caches
    pub fn invalidate_all(&mut self) {
        self.reg_use = None;
        self.reg_cap = None;
        self.boards.clear();
        self.out_cache.clear();
    }

    /// Capacity of good g changed. Regional totals refresh at once; the ranked boards are kept for the month (the
    /// option a corporation picks is re-checked against current numbers before it builds).
    pub fn invalidate_good(&mut self, g: usize) {
        self.reg_cap = None;
        let _ = g;
    }

    /// Start of the month: every per-month cache goes.
    pub fn clear_empire_caches(&mut self) {
        for e in self.empires.iter_mut() {
            e.clear_caches();
        }
        self.invalidate_all();
    }

    /// Mid-month (a colony founded or a system changing hands): the outpost tables are kept for the month (settled or
    /// foreign bodies are skipped when they're read); settler donors and regional totals refresh.
    pub fn colony_set_changed(&mut self) {
        for e in self.empires.iter_mut() {
            e.donor_cache.clear();
            e.donor_any = None;
            e.cand_cache = None;
        }
        self.reg_use = None;
        self.reg_cap = None;
        self.out_cache.clear();
    }

    /// Regional total of `use` (true) or `capacity` (false) for good g across settled colonies.
    pub fn regional(&mut self, use_: bool, g: usize) -> f64 {
        if use_ {
            if self.reg_use.is_none() {
                let mut t = [0.0; goods::N];
                for &m in &self.markets {
                    for gg in goods::ALL {
                        t[gg] += self.colonies[m].use_[gg];
                    }
                }
                self.reg_use = Some(t);
            }
            self.reg_use.unwrap()[g]
        } else {
            if self.reg_cap.is_none() {
                let mut t = [0.0; goods::N];
                for &m in &self.markets {
                    for gg in goods::ALL {
                        t[gg] += self.colonies[m].capacity[gg];
                    }
                }
                self.reg_cap = Some(t);
            }
            self.reg_cap.unwrap()[g]
        }
    }

    pub fn is_known(&self, e: usize, c: usize) -> bool {
        match self.colonies[c].system {
            Some(s) => self.empires[e].known[s],
            None => true,
        }
    }

    /// May e survey/settle this body? (charted, and not another empire's territory)
    pub fn may_enter(&self, e: usize, c: usize) -> bool {
        if !self.is_known(e, c) {
            return false;
        }
        match self.colonies[c].system {
            Some(s) => self.systems[s].owner.map_or(true, |o| o == e),
            None => true,
        }
    }

    /// A survey by e revealed `amount` more of good g (capped by the true richness). Returns how much was new.
    pub fn reveal(&mut self, c: usize, e: usize, g: usize, amount: f64) -> f64 {
        let col = &mut self.colonies[c];
        let r = col.hidden.get(g);
        let old = col.intel_for(e).rich.get(g);
        let nv = r.min(old + amount);
        if nv <= old + 0.001 {
            return 0.0;
        }
        let first = col.intel_for(e).rich.is_empty();
        let info = col.intel_for(e);
        info.rich.set(g, nv);
        info.found.set(g, nv / r.max(0.001));
        let own_colony = col.settled && col.owner == Some(e);
        if own_colony {
            col.capacity[g] += (nv - old) * 0.25;
        }
        if first {
            let kb = &mut self.empires[e].known_bodies;
            if let Err(at) = kb.binary_search(&c) {
                kb.insert(at, c);
            }
        }
        if own_colony {
            self.invalidate_all();
        }
        nv - old
    }

    /// First settlers arrive, sent by e: the body (and its whole system, if unclaimed) becomes e's.
    pub fn settle(&mut self, c: usize, settlers: f64, e: usize) {
        self.colony_gen += 1;
        // A new colony can only bring things closer: update the nearest-colony cache in place.
        let p = self.colonies[c].pos;
        for v in self.empires[e].near_cache.values_mut() {
            let d = dist(p, v.2);
            if d < v.1 {
                *v = (c, d, v.2);
            }
        }
        {
            let col = &mut self.colonies[c];
            col.settled = true;
            col.pop = settlers;
            col.owner = Some(e);
            col.intel_for(e);
            col.rich_from = Some(e);
        }
        if let Some(s) = self.colonies[c].system {
            if self.systems[s].owner.is_none() {
                self.systems[s].owner = Some(e);
                self.on_system_claimed();
            }
        }
        self.invalidate_all();
        let col = &mut self.colonies[c];
        for g in col.rich().goods() {
            col.capacity[g] += col.local_output(g);
        }
    }

    pub fn empire_colonies(&self, e: usize) -> Vec<usize> {
        self.markets.iter().cloned().filter(|&m| self.colonies[m].owner == Some(e)).collect()
    }

    pub fn nearest_settled(&mut self, c: usize, e: usize) -> usize {
        if self.empires[e].near_gen != self.loss_gen {
            self.empires[e].near_cache.clear();
            self.empires[e].near_gen = self.loss_gen;
        }
        let k = key_of(&self.colonies[c]);
        if let Some(&v) = self.empires[e].near_cache.get(&k) {
            return v.0;
        }
        let mut best = self.empires[e].capital;
        let mut bd = f64::INFINITY;
        let p = self.colonies[c].pos;
        for &m in &self.markets {
            if self.colonies[m].owner != Some(e) {
                continue;
            }
            let d = dist(self.colonies[m].pos, p);
            if d < bd {
                bd = d;
                best = m;
            }
        }
        self.empires[e].near_cache.insert(k, (best, bd, p));
        best
    }

    fn settler_donor(&mut self, c: usize, e: usize) -> Option<usize> {
        let k = key_of(&self.colonies[c]);
        if let Some(&v) = self.empires[e].donor_cache.get(&k) {
            return v;
        }
        let p = self.colonies[c].pos;
        let mut best = None;
        let mut bv = 0.0;
        for &m in &self.markets {
            let col = &self.colonies[m];
            if col.owner != Some(e) || col.pop < SETTLER_MIN_POP {
                continue;
            }
            let v = (col.pop / col.target_pop().max(1.0)) * col.pop / (1.0 + dist(col.pos, p) / 200.0);
            if v > bv {
                bv = v;
                best = Some(m);
            }
        }
        self.empires[e].donor_cache.insert(k, best);
        best
    }

    pub fn can_send_settlers(&mut self, e: usize) -> bool {
        if self.empires[e].donor_any.is_none() {
            let any = self.markets.iter().any(|&m| self.colonies[m].owner == Some(e) && self.colonies[m].pop >= SETTLER_MIN_POP);
            self.empires[e].donor_any = Some(any);
        }
        self.empires[e].donor_any.unwrap()
    }

    /// Unsettled bodies with deposits known to e, outside other empires' territory.
    pub fn frontier_candidates(&mut self, e: usize) -> Vec<usize> {
        if self.empires[e].cand_cache.is_none() {
            let v: Vec<usize> = self.empires[e].known_bodies.iter().cloned().filter(|&c| !self.colonies[c].settled && self.may_enter(e, c)).collect();
            self.empires[e].cand_cache = Some(v);
        }
        self.empires[e].cand_cache.clone().unwrap()
    }

    /// How many outpost candidates e has (without copying the list).
    pub fn candidate_count(&mut self, e: usize) -> usize {
        self.frontier_candidates(e);
        self.empires[e].cand_cache.as_ref().unwrap().len()
    }

    pub fn outpost_base(&mut self, e: usize) -> std::sync::Arc<Vec<ObRow>> {
        if self.empires[e].ob_cache.is_none() {
            let mut rows = vec![];
            if self.can_send_settlers(e) {
                let mut mats_by_near: HashMap<usize, f64> = HashMap::new();
                for c in self.frontier_candidates(e) {
                    if self.colonies[c].settled {
                        continue;
                    }
                    let near = self.nearest_settled(c, e);
                    let mats = *mats_by_near.entry(near).or_insert_with(|| Self::materials_cost(&self.colonies[near], 1.0, true));
                    let d = Self::lane_dist(&self.colonies[c], &self.colonies[near]);
                    if let Some(info) = &self.colonies[c].intel[e] {
                        for &(g, q) in &info.rich.0 {
                            let unit = self.colonies[near].price[g] - goods::raw_cost(g) - crate::corp::SHIP_COST * d;
                            rows.push(ObRow { c, g, q, unit, cost: crate::corp::CAPEX + crate::corp::OUTPOST_COST + mats });
                        }
                    }
                }
            }
            *self.prof.entry("n_outpost_base_builds").or_insert(0.0) += 1.0;
            *self.prof.entry("n_outpost_rows").or_insert(0.0) += rows.len() as f64;
            *self.prof.entry("n_frontier_scanned").or_insert(0.0) += self.frontier.len() as f64;
            self.empires[e].ob_cache = Some(std::sync::Arc::new(rows));
        }
        self.empires[e].ob_cache.clone().unwrap()
    }

    pub fn known_frontier(&mut self, e: usize) -> Vec<usize> {
        if self.empires[e].known_frontier.is_none() {
            let v: Vec<usize> = self.frontier.iter().cloned().filter(|&c| self.may_enter(e, c)).collect();
            self.empires[e].known_frontier = Some(v);
        }
        self.empires[e].known_frontier.clone().unwrap()
    }

    pub fn reveal_around(&mut self, e: usize, pos: (f64, f64), radius: f64) -> i32 {
        self.empires[e].known_frontier = None;
        self.empires[e].survey_board = None;
        let mut n = 0;
        for s in 0..self.systems.len() {
            if !self.empires[e].known[s] && dist(self.systems[s].pos, pos) <= radius {
                self.empires[e].known[s] = true;
                self.systems[s].known = true;
                n += 1;
            }
        }
        n
    }

    // ------------------------------------------------------------ Colonization
    fn on_settled(&mut self, c: usize, e: usize) {
        self.colony_set_changed();
        let p = self.colonies[c].pos;
        self.reveal_around(e, p, COLONY_HORIZON);
        self.colonies[c].growth_enabled = self.cfg.growth;
        self.markets.push(c);
        self.settlements += 1;
        self.empires[e].settlements += 1;
    }

    /// A corporation founds an outpost for its empire: settlers move from the empire's best donor colony.
    pub fn found_outpost(&mut self, c: usize, e: usize) -> bool {
        let donor = match self.settler_donor(c, e) {
            Some(d) => d,
            None => return false,
        };
        if self.colonies[c].settled || !self.may_enter(e, c) {
            return false;
        }
        self.colonies[donor].pop -= crate::corp::OUTPOST_SETTLERS;
        self.check_claim_jump(c, e);
        self.settle(c, crate::corp::OUTPOST_SETTLERS, e);
        self.on_settled(c, e);
        true
    }

    fn state_colonize(&mut self, e: usize) {
        let own = self.empire_colonies(e);
        let mut scarcity = [0.0; goods::N];
        for g in goods::ALL {
            let p: f64 = own.iter().map(|&m| self.colonies[m].price[g]).sum();
            scarcity[g] = p / own.len() as f64 / BASE_PRICE;
        }
        let mut best = None;
        let mut bv = 0.0;
        for c in self.frontier.clone() {
            if self.colonies[c].settled || self.colonies[c].surveys_by(e) == 0 || !self.may_enter(e, c) {
                continue;
            }
            let rich = self.colonies[c].known_rich(e);
            if rich.is_empty() {
                continue;
            }
            let mut v = self.colonies[c].max_pop / 400.0;
            for &(g, q) in &rich.0 {
                v += q * scarcity[g];
            }
            let near = self.nearest_settled(c, e);
            v /= 1.0 + dist(self.colonies[c].pos, self.colonies[near].pos) / 200.0;
            if v > bv {
                bv = v;
                best = Some(c);
            }
        }
        let best = match best {
            Some(b) => b,
            None => return,
        };
        let near = self.nearest_settled(best, e);
        let habitat: f64 = goods::BUILD_STATE_COLONY.iter().map(|&(g, q)| q * self.colonies[near].price[g]).sum();
        let cost = crate::corp::OUTPOST_COST + STATE_GRANT + habitat;
        let donor = match self.settler_donor(best, e) {
            Some(d) => d,
            None => return,
        };
        if self.empires[e].treasury < cost * STATE_RESERVE || self.colonies[donor].pop < STATE_SETTLERS * 2.5 {
            return;
        }
        for &(g, q) in goods::BUILD_STATE_COLONY {
            self.colonies[near].stock[g] = (self.colonies[near].stock[g] - q).max(0.0);
        }
        self.colonies[donor].pop -= STATE_SETTLERS;
        self.check_claim_jump(best, e);
        self.settle(best, STATE_SETTLERS, e);
        self.colony_set_changed();
        let p = self.colonies[best].pos;
        self.reveal_around(e, p, COLONY_HORIZON);
        self.colonies[best].growth_enabled = self.cfg.growth;
        self.colonies[best].local_cash = STATE_GRANT;
        // The state buys out its surveyors' claims at the going price.
        let claims = self.colonies[best].intel_for(e).claims;
        for cl in claims.iter().flatten() {
            let fee = crate::corp::CLAIM_PRICE * cl.value;
            self.corps[cl.owner].cash += fee;
            self.corps[cl.owner].claims_sold += 1;
            self.empires[e].treasury -= fee;
            self.empires[e].state_spent += fee;
        }
        for cl in self.colonies[best].intel_for(e).claims.iter().flatten().cloned().collect::<Vec<_>>() {
            self.corps[cl.owner].unsold -= 1;
        }
        self.colonies[best].intel_for(e).claims = [None; goods::N];
        self.markets.push(best);
        self.settlements += 1;
        self.empires[e].settlements += 1;
        self.empires[e].state_colonies += 1;
        self.empires[e].treasury -= cost;
        self.empires[e].state_spent += cost;
    }

    fn maybe_discover_sector(&mut self, e: usize) {
        let mut known_n = 0;
        let mut surveyed_n = 0;
        let mut dark = vec![];
        for s in 0..self.systems.len() {
            if self.empires[e].known[s] {
                for &c in &self.systems[s].bodies {
                    known_n += 1;
                    if self.colonies[c].surveys_by(e) > 0 {
                        surveyed_n += 1;
                    }
                }
            } else {
                dark.push(s);
            }
        }
        if dark.is_empty() {
            return;
        }
        let exhaustion = surveyed_n as f64 / (known_n.max(1)) as f64;
        if self.rng.randf() >= SECTOR_BASE_CHANCE + SECTOR_EXHAUSTED_CHANCE * exhaustion.powi(3) {
            return;
        }
        let centre = dark[self.rng.below(dark.len())];
        let p = self.systems[centre].pos;
        self.reveal_around(e, p, SECTOR_RADIUS);
        self.empires[e].sector_events += 1;
        self.sector_events += 1;
    }

    fn order_surveys(&mut self, e: usize) {
        let unexplored = self.frontier.iter().filter(|&&c| self.colonies[c].surveys_by(e) == 0 && self.may_enter(e, c)).count() as i32;
        let afford = (self.empires[e].treasury * SURVEY_BUDGET_SHARE / SURVEY_ORDER_PRICE) as i32;
        let n = (unexplored - self.empires[e].survey_backlog).min(afford);
        if n > 0 {
            self.empires[e].survey_backlog += n;
            self.empires[e].surveys_ordered += n;
        }
    }

    /// Zero-sum migration inside one empire, from better- to worse-staffed colonies.
    fn migrate(&mut self, e: usize) {
        let own = self.empire_colonies(e);
        if own.len() < 2 {
            return;
        }
        let tp: f64 = own.iter().map(|&c| self.colonies[c].pop).sum();
        let tt: f64 = own.iter().map(|&c| self.colonies[c].target_pop()).sum();
        let avg = tp / tt.max(1.0);
        let mut pull = vec![];
        let mut push = vec![];
        let (mut sp, mut ss) = (0.0, 0.0);
        for &c in &own {
            let col = &self.colonies[c];
            let dev = col.pop - avg * col.target_pop();
            if dev < 0.0 && col.pop < col.max_pop {
                pull.push((c, -dev * MIGRATION_RATE));
                sp += -dev * MIGRATION_RATE;
            } else if dev > 0.0 {
                push.push((c, dev * MIGRATION_RATE));
                ss += dev * MIGRATION_RATE;
            }
        }
        let moved = f64::min(sp, ss);
        if moved <= 0.0 {
            return;
        }
        for (c, v) in pull {
            self.colonies[c].pop += v / sp * moved;
        }
        for (c, v) in push {
            self.colonies[c].pop -= v / ss * moved;
        }
    }

    // ------------------------------------------------------------ Relations
    pub fn rel(&self, a: usize, b: usize) -> &Relation {
        let (x, y) = (a.min(b), a.max(b));
        &self.relations[x * self.empires.len() + y]
    }
    pub fn rel_mut(&mut self, a: usize, b: usize) -> &mut Relation {
        let n = self.empires.len();
        let (x, y) = (a.min(b), a.max(b));
        &mut self.relations[x * n + y]
    }

    pub fn event(&mut self, text: String) {
        self.events.push((self.tick, text));
    }

    pub fn tariff_rate(&self, src: usize, dest: usize) -> f64 {
        let (a, b) = (self.colonies[src].owner, self.colonies[dest].owner);
        match (a, b) {
            (Some(a), Some(b)) if a != b => {
                let r = self.rel(a, b);
                if !r.met {
                    return 0.0;
                }
                r.stance.tariff() * if r.trade_treaty { 0.5 } else { 1.0 }
            }
            _ => 0.0,
        }
    }

    fn treaty(&self, a: usize, b: usize, passage: bool) -> bool {
        if a == b {
            return true;
        }
        let r = self.rel(a, b);
        r.met && if passage { r.passage } else { r.trade_treaty }
    }

    pub fn on_system_claimed(&mut self) {
        self.route_cache.clear();
        for k in self.corps.iter_mut() {
            k.route_memo.clear();
        }
    }

    /// Route geometry: for each sample point along a->b, every system within TERRITORY_RADIUS, nearest first.
    fn route_geometry(&mut self, a: (f64, f64), b: (f64, f64)) -> Vec<Vec<usize>> {
        let key = (a.0.to_bits() ^ a.1.to_bits().rotate_left(17), b.0.to_bits() ^ b.1.to_bits().rotate_left(17));
        if let Some(v) = self.route_geo.get(&key) {
            return v.clone();
        }
        let n = (dist(a, b) / ROUTE_SAMPLE) as usize;
        let mut pts = vec![];
        for i in 1..n {
            let t = i as f64 / n as f64;
            let p = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t);
            let mut near: Vec<(f64, i64, usize)> = vec![];
            for (si, s) in self.systems.iter().enumerate() {
                let d = dist(s.pos, p);
                if d <= TERRITORY_RADIUS {
                    near.push((d, -(si as i64), si));
                }
            }
            if near.is_empty() {
                continue;
            }
            near.sort_by(|x, y| x.0.partial_cmp(&y.0).unwrap().then(x.1.cmp(&y.1)));
            pts.push(near.into_iter().map(|x| x.2).collect());
        }
        self.route_geo.insert(key, pts.clone());
        pts
    }

    /// May a freighter of empire f carry goods from a to b? Trade treaties with foreign empires at either end, and
    /// passage treaties with any other empire whose territory the route crosses.
    pub fn route_ok(&mut self, f: Option<usize>, a: usize, b: usize) -> bool {
        let f = match f {
            Some(f) if self.empires.len() > 1 => f,
            _ => return true,
        };
        let ka = key_of(&self.colonies[a]);
        let kb = key_of(&self.colonies[b]);
        if let Some(&v) = self.route_cache.get(&(f, ka, kb)) {
            return v;
        }
        let mut ok = true;
        let mut ends = vec![];
        for o in [self.colonies[a].owner, self.colonies[b].owner].into_iter().flatten() {
            if o != f {
                if !self.treaty(f, o, false) {
                    ok = false;
                }
                ends.push(o);
            }
        }
        if ok {
            let (pa, pb) = (self.colonies[a].pos, self.colonies[b].pos);
            for near in self.route_geometry(pa, pb) {
                let mut z = None;
                for s in near {
                    if self.systems[s].owner.is_some() {
                        z = self.systems[s].occupier.or(self.systems[s].owner);
                        break;
                    }
                }
                match z {
                    Some(z) if z != f && !ends.contains(&z) => {
                        if !self.treaty(f, z, true) {
                            ok = false;
                            break;
                        }
                    }
                    _ => {}
                }
            }
        }
        self.route_cache.insert((f, ka, kb), ok);
        ok
    }

    pub fn record_trade(&mut self, src: usize, dest: usize, value: f64, customs: f64) {
        let (a, b) = (self.colonies[src].owner, self.colonies[dest].owner);
        if let (Some(a), Some(b)) = (a, b) {
            if a != b {
                self.rel_mut(a, b).month_trade += value;
                self.empires[b].treasury += customs;
                self.empires[b].customs_collected += customs;
            }
        }
    }

    fn check_claim_jump(&mut self, c: usize, e: usize) {
        let s = match self.colonies[c].system {
            Some(s) if self.systems[s].owner.is_none() => s,
            _ => return,
        };
        for other in 0..self.empires.len() {
            if other == e {
                continue;
            }
            if self.systems[s].bodies.iter().any(|&b| self.colonies[b].surveys_by(other) > 0) {
                self.rel_mut(e, other).incidents += 1.0;
                crate::personality::shift(self, other, TRAIT_XENOPHOBIA, crate::personality::INCIDENT_DRIFT, "");
                let t = format!("{} settled {}, which {} had surveyed (incident)", self.empires[e].name, self.systems[s].name, self.empires[other].name);
                self.event(t);
            }
        }
    }

    fn update_relations(&mut self) {
        let n = self.empires.len();
        let mut owned: Vec<Vec<usize>> = vec![vec![]; n];
        for s in &self.systems {
            if let Some(o) = s.owner {
                owned[o].push(s.id);
            }
        }
        let mut at_war = vec![false; n * n];
        for wr in &self.wars {
            for &p in &wr.sides[0] {
                for &q in &wr.sides[1] {
                    at_war[p.min(q) * n + p.max(q)] = true;
                }
            }
        }
        for a in 0..n {
            for b in (a + 1)..n {
                if !self.rel(a, b).met {
                    let meet = owned[b].iter().any(|&s| self.empires[a].known[s]) || owned[a].iter().any(|&s| self.empires[b].known[s]);
                    if !meet {
                        continue;
                    }
                    let r = self.rel_mut(a, b);
                    r.met = true;
                    r.stance = Stance::Neutral;
                    let t = format!("First contact: {} and {}", self.empires[a].name, self.empires[b].name);
                    self.event(t);
                }
                let mut border = 0;
                for &sa in &owned[a] {
                    for &sb in &owned[b] {
                        if dist(self.systems[sa].pos, self.systems[sb].pos) <= BORDER_RANGE {
                            border += 1;
                        }
                    }
                }
                let merc = (self.empires[a].w(TRAIT_MERCANTILE) + self.empires[b].w(TRAIT_MERCANTILE)) * 0.5;
                let xeno = (self.empires[a].w(TRAIT_XENOPHOBIA) + self.empires[b].w(TRAIT_XENOPHOBIA)) * 0.5;
                let r = self.rel_mut(a, b);
                r.border = border;
                r.trade = 0.9 * r.trade + 0.1 * r.month_trade;
                r.month_trade = 0.0;
                r.incidents *= INCIDENT_DECAY;
                r.goodwill *= INCIDENT_DECAY;
                let target = TRADE_WEIGHT * merc * (1.0 + r.trade).ln() - BORDER_WEIGHT * xeno * border as f64 - INCIDENT_PENALTY * r.incidents + GOODWILL_WEIGHT * r.goodwill;
                r.opinion = (r.opinion + OPINION_RATE * (target - r.opinion)).clamp(-100.0, 100.0);
                if at_war[a * n + b] {
                    continue; // at war: stance stays "embargo" until peace
                }
                let st = if r.opinion >= 25.0 {
                    Stance::Friendly
                } else if r.opinion <= -60.0 {
                    Stance::Embargo
                } else if r.opinion <= -25.0 {
                    Stance::Hostile
                } else {
                    Stance::Neutral
                };
                if st != r.stance {
                    let (old, op) = (r.stance, r.opinion);
                    r.stance = st;
                    let cancel = matches!(st, Stance::Hostile | Stance::Embargo) && (r.trade_treaty || r.passage);
                    if cancel {
                        r.trade_treaty = false;
                        r.passage = false;
                    }
                    let t = format!("{} and {}: {} -> {} (opinion {})", self.empires[a].name, self.empires[b].name, old.name(), st.name(), op as i64);
                    self.event(t);
                    if cancel {
                        let t = format!("{} and {}: treaties cancelled", self.empires[a].name, self.empires[b].name);
                        self.event(t);
                    }
                }
            }
        }
    }

    /// Each month a different empire's corporations act first; within an empire, corporations keep their order.
    fn turn_order(&self, t: u32) -> Vec<usize> {
        let alive: Vec<usize> = (0..self.corps.len()).filter(|&k| !self.corps[k].dead).collect();
        if self.empires.len() <= 1 {
            return alive;
        }
        let n = self.empires.len();
        let mut out = vec![];
        for i in 0..n {
            let e = (t as usize + i) % n;
            out.extend(alive.iter().filter(|&&k| self.corps[k].empire == Some(e)));
        }
        out.extend(alive.iter().filter(|&&k| self.corps[k].empire.is_none()));
        out
    }

    // ------------------------------------------------------------ Emergence
    fn try_emergence(&mut self, c: usize) {
        let first = self.colonies[c].rich().0.first().map(|x| x.0);
        if self.colonies[c].local_cash > PROMOTE_CASH && first.is_some() {
            let owner = self.colonies[c].owner;
            let cash = self.colonies[c].local_cash * 0.5;
            let k = self.add_corp(Kind::Extractor, cash, owner);
            self.colonies[c].local_cash = 0.0;
            self.seed_facility(k, c, first.unwrap(), false);
            self.promotions += 1;
            return;
        }
        let gap = self.colonies[c].workforce_gap();
        let sf = self.colonies[c].shortfall;
        if self.rng.randf() < (gap - 0.15).max(0.0) * 0.03 || self.rng.randf() < (sf - 0.25).max(0.0) * 0.05 {
            let kind = self.founding_kind();
            if self.corps.iter().any(|k| !k.dead && k.kind == kind && k.is_idle_funded()) {
                return;
            }
            let owner = self.colonies[c].owner;
            self.add_corp(kind, 200.0, owner);
            self.attractions += 1;
        }
    }

    fn founding_kind(&mut self) -> Kind {
        let fr: Vec<f64> = self.corps.iter().filter(|k| !k.dead && k.kind == Kind::Freight).map(|k| k.utilisation).collect();
        if fr.is_empty() || (fr.iter().sum::<f64>() / fr.len() as f64 > 0.85 && self.rng.randf() < 0.3) {
            return Kind::Freight;
        }
        let (mut raw_unmet, mut proc_unmet) = (0.0, 0.0);
        for g in goods::ALL {
            let u = self.regional(true, g) * crate::corp::HEADROOM - self.regional(false, g);
            if goods::is_raw(g) && self.has_extraction_site(g) {
                raw_unmet += u.max(0.0);
            }
            if goods::recipe(g).is_some() {
                proc_unmet += u.max(0.0);
            }
        }
        if raw_unmet > proc_unmet {
            Kind::Extractor
        } else {
            Kind::Producer
        }
    }

    fn has_extraction_site(&mut self, g: usize) -> bool {
        if self.markets.iter().any(|&c| self.colonies[c].rich().get(g) > 0.0 && self.colonies[c].facility_slots_free() > 0) {
            return true;
        }
        for e in 0..self.empires.len() {
            for c in self.frontier_candidates(e) {
                if self.colonies[c].known_rich(e).get(g) > 0.0 {
                    return true;
                }
            }
        }
        false
    }

    // ------------------------------------------------------------ The month
    pub fn lap_pub(&mut self, phase: &'static str, t0: &mut std::time::Instant) {
        self.lap(phase, t0)
    }

    fn lap(&mut self, phase: &'static str, t0: &mut std::time::Instant) {
        let now = std::time::Instant::now();
        *self.prof.entry(phase).or_insert(0.0) += (now - *t0).as_secs_f64();
        *t0 = now;
    }

    pub fn step(&mut self) {
        let t = self.tick;
        let mut t0 = std::time::Instant::now();
        self.clear_empire_caches();
        for &m in &self.markets {
            self.colonies[m].jobs = 0.0;
            self.colonies[m].port_used = 0;
        }
        for k in &self.corps {
            if k.dead {
                continue;
            }
            for f in &k.facilities {
                self.colonies[f.colony].jobs += 1.0;
            }
        }
        self.lap("reset", &mut t0);
        for ki in self.turn_order(t) {
            let before = self.corps[ki].cash;
            let mut tk = std::time::Instant::now();
            self.corp_run(ki);
            let phase = match self.corps[ki].kind {
                Kind::Extractor => "corp_extractor",
                Kind::Producer => "corp_producer",
                Kind::Freight => "corp_freight",
                Kind::Surveyor => "corp_surveyor",
            };
            self.lap(phase, &mut tk);
            if self.cfg.taxes {
                let k = &mut self.corps[ki];
                let tax = (k.cash - before).max(0.0) * PROFIT_TAX + (k.cash - WEALTH_FREE).max(0.0) * WEALTH_TAX;
                k.cash -= tax;
                self.tax_collected += tax;
                match k.empire {
                    Some(e) => {
                        let em = &mut self.empires[e];
                        let _ = &em;
                        em.treasury += tax;
                        em.tax_collected += tax;
                        em.month_tax += tax;
                    }
                    None => self.treasury += tax,
                }
            }
        }
        t0 = std::time::Instant::now();
        if self.cfg.colonize {
            for e in 0..self.empires.len() {
                self.migrate(e);
            }
            for e in 0..self.empires.len() {
                self.maybe_discover_sector(e);
            }
            self.lap("migration_sectors", &mut t0);
            if self.empires.len() > 1 {
                self.update_relations();
                self.lap("relations", &mut t0);
                self.mark_fronts();
                self.military_monthly();
                self.plays_monthly();
                self.occupation_effects();
                self.lap("military", &mut t0);
                if t % 12 == 6 {
                    self.diplomacy_yearly();
                }
                self.lap("diplomacy", &mut t0);
            }
            if self.cfg.state && t % STATE_REVIEW_MONTHS == STATE_REVIEW_MONTHS - 1 {
                for e in 0..self.empires.len() {
                    self.state_colonize(e);
                    self.order_surveys(e);
                }
            }
            if t % 120 == 119 {
                for e in 0..self.empires.len() {
                    if !self.corps.iter().any(|k| !k.dead && k.kind == Kind::Surveyor && k.empire == Some(e)) {
                        self.add_corp(Kind::Surveyor, 600.0, Some(e));
                        self.empires[e].treasury -= 600.0;
                    }
                }
            }
        }
        self.lap("state", &mut t0);
        self.invalidate_all();
        let ext = self.external_migration;
        for m in self.markets.clone() {
            self.colonies[m].tick(ext);
            let alive = self.corps.iter().filter(|k| !k.dead).count();
            if t > 20 && alive < self.cfg.max_corps {
                self.try_emergence(m);
            }
        }
        self.lap("markets_emergence", &mut t0);
        for ki in 0..self.corps.len() {
            if !self.corps[ki].dead && self.corps[ki].is_dead() {
                self.dissolve(ki);
                self.corps[ki].dead = true;
            }
        }
        self.tick += 1;
    }
}
