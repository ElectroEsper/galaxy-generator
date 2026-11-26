//! Per-colony market (colony_market.gd) and star systems (system_node.gd).

use crate::goods::{self, PerGood, Rich, FOOD, N, PARTS};

pub const BASE_PRICE: f64 = 10.0;
pub const COVER_TICKS: f64 = 10.0;
pub const USE_FLOOR: f64 = 0.02;
pub const BASE_SELF_POP: f64 = 30.0;
pub const JOBS_PER_FACILITY: f64 = 8.0;
pub const BIRTH_RATE: f64 = 0.003;
pub const DEATH_RATE: f64 = 0.02;
pub const EXTRACTOR_SLOT: f64 = 0.5;
pub const PORT_BASE: i32 = 4;
pub const PORT_POP_PER_SLOT: f64 = 100.0;
pub const MAX_EMPIRES: usize = 32;

#[derive(serde::Serialize, serde::Deserialize, Clone, Copy, Debug)]
pub struct Claim {
    pub owner: usize, // corporation id
    pub value: f64,
}

/// What one empire knows about one body.
#[derive(serde::Serialize, serde::Deserialize, Clone, Default, Debug)]
pub struct Intel {
    pub rich: Rich,
    pub found: Rich,
    pub surveys: i32,
    pub claims: [Option<Claim>; N],
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Copy, Debug)]
pub struct Request {
    pub good: usize,
    pub qty: f64,
    pub payer: Option<usize>,
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct Colony {
    pub id: usize,
    pub name: String,
    pub pop: f64,
    pub port_used: i32,
    /// Richness when no empire's knowledge drives this colony (non-colonization runs).
    pub richness_own: Rich,
    /// For a settled body: the empire whose knowledge IS its richness (its surveys feed extraction directly).
    pub rich_from: Option<usize>,
    pub stock: PerGood,
    pub price: PerGood,
    pub use_: PerGood,
    pub use_tick: PerGood,
    pub capacity: PerGood,
    pub max_pop: f64,
    pub extraction: PerGood,
    pub extractor_count: i32,
    pub facility_count: i32,
    pub requests: Vec<Request>,
    pub growth_enabled: bool,
    pub jobs: f64,
    pub local_cash: f64,
    pub label: String,
    pub pos: (f64, f64),
    pub shortfall: f64,
    pub settled: bool,
    pub system: Option<usize>,
    pub body_radius: f64,
    pub site_score: f64,
    pub hidden: Rich,
    pub surveys: i32,
    pub owner: Option<usize>,
    pub intel: Vec<Option<Intel>>,
}

impl Colony {
    pub fn new(id: usize, name: String, pop: f64, rich: Rich, ceiling: f64) -> Colony {
        let mut c = Colony {
            id,
            name,
            pop,
            port_used: 0,
            richness_own: rich,
            rich_from: None,
            stock: [40.0; N],
            price: [BASE_PRICE; N],
            use_: [0.1; N],
            use_tick: [0.0; N],
            capacity: [0.0; N],
            max_pop: ceiling,
            extraction: [0.0; N],
            extractor_count: 0,
            facility_count: 0,
            requests: vec![],
            growth_enabled: true,
            jobs: 0.0,
            local_cash: 0.0,
            label: String::new(),
            pos: (0.0, 0.0),
            shortfall: 0.0,
            settled: true,
            system: None,
            body_radius: 1.0,
            site_score: 0.0,
            hidden: Rich::default(),
            surveys: 0,
            owner: None,
            intel: vec![None; MAX_EMPIRES],
        };
        for g in c.rich().goods() {
            c.capacity[g] += c.local_output(g);
        }
        for &(g, q) in goods::SUBSISTENCE {
            c.capacity[g] += q;
        }
        c
    }

    /// Known richness that drives this colony's economy.
    pub fn rich(&self) -> &Rich {
        match self.rich_from {
            Some(e) => match &self.intel[e] {
                Some(i) => &i.rich,
                None => &self.richness_own,
            },
            None => &self.richness_own,
        }
    }

    pub fn intel_for(&mut self, e: usize) -> &mut Intel {
        if self.intel[e].is_none() {
            self.intel[e] = Some(Intel::default());
        }
        self.intel[e].as_mut().unwrap()
    }

    pub fn known_rich(&self, e: usize) -> Rich {
        self.intel[e].as_ref().map(|i| i.rich.clone()).unwrap_or_default()
    }

    pub fn has_known(&self, e: usize) -> bool {
        self.intel[e].as_ref().map_or(false, |i| !i.rich.is_empty())
    }

    pub fn surveys_by(&self, e: usize) -> i32 {
        self.intel[e].as_ref().map_or(0, |i| i.surveys)
    }

    pub fn facility_slots_free(&self) -> i32 {
        let load = (self.facility_count - self.extractor_count) as f64 + self.extractor_count as f64 * EXTRACTOR_SLOT;
        (self.max_pop / JOBS_PER_FACILITY - load).floor() as i32
    }

    pub fn local_output(&self, g: usize) -> f64 {
        self.rich().get(g) * 0.25
    }

    pub fn target_pop(&self) -> f64 {
        (BASE_SELF_POP + self.jobs * JOBS_PER_FACILITY).min(self.max_pop)
    }

    pub fn workforce_gap(&self) -> f64 {
        (self.target_pop() - self.pop) / self.pop.max(1.0)
    }

    pub fn maintenance_demand(&self, g: usize) -> f64 {
        self.pop * goods::maint_per_pop(g) + self.facility_count as f64 * goods::maint_per_facility(g)
    }

    pub fn pop_demand(&self, g: usize) -> f64 {
        let mut d = self.pop * goods::pop_consumption(g);
        if self.growth_enabled {
            d += self.maintenance_demand(g);
        }
        d
    }

    pub fn note_use(&mut self, g: usize, amount: f64) {
        self.use_tick[g] += amount;
    }

    pub fn port_slots(&self) -> i32 {
        PORT_BASE + (self.pop / PORT_POP_PER_SLOT) as i32
    }

    pub fn port_free(&self) -> bool {
        self.port_used < self.port_slots()
    }

    /// Monthly market update: subsistence, local business, population, consumption, prices.
    pub fn tick(&mut self, external_migration: bool) {
        for &(g, q) in goods::SUBSISTENCE {
            self.stock[g] += q;
        }
        for (g, _) in self.rich().0.clone() {
            let q = self.local_output(g);
            if self.price[g] > goods::raw_cost(g) {
                self.stock[g] += q;
                self.local_cash += q * (self.price[g] - goods::raw_cost(g));
            }
        }
        if self.growth_enabled {
            let need = self.pop_demand(FOOD).max(0.001);
            let fed = (self.stock[FOOD] / (need * 3.0)).clamp(0.0, 1.0);
            self.pop += self.pop * BIRTH_RATE * fed * (1.0 - self.pop / self.max_pop) - self.pop * DEATH_RATE * (1.0 - fed);
            if !external_migration {
                self.pop += (self.target_pop() - self.pop).max(0.0) * 0.02;
            }
            self.pop = self.pop.clamp(5.0, self.max_pop);
        } else {
            self.pop += (self.target_pop() - self.pop) * 0.02;
        }
        for g in goods::ALL {
            let demand = self.pop_demand(g);
            let take = self.stock[g].min(demand);
            self.stock[g] -= take;
            if self.growth_enabled && take > 0.0 && self.maintenance_demand(g) > 0.0 {
                self.stock[g] += goods::SALVAGE_RATE * self.maintenance_demand(g) * take / demand.max(0.001);
            }
            let used = demand + self.use_tick[g];
            self.use_[g] = 0.9 * self.use_[g] + 0.1 * used.max(USE_FLOOR);
            let cover = self.stock[g] / (self.use_[g] * COVER_TICKS);
            self.price[g] = BASE_PRICE * cover.max(0.001).powf(-0.7).clamp(0.1, 10.0);
        }
        self.use_tick = [0.0; N];
        self.requests.clear();
        let premium = (self.price[FOOD] + self.price[PARTS]) / (2.0 * BASE_PRICE) - 1.0;
        self.shortfall = 0.9 * self.shortfall + 0.1 * premium;
    }

    /// Turn a generated colony into unsettled frontier: nobody lives there and its deposits are unknown.
    pub fn make_frontier(&mut self) {
        self.hidden = self.richness_own.clone();
        for g in self.rich().goods() {
            self.capacity[g] -= self.local_output(g);
        }
        self.richness_own = Rich::default();
        self.settled = false;
        self.pop = 0.0;
    }
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Debug)]
pub struct StarSystem {
    pub id: usize,
    pub name: String,
    pub pos: (f64, f64),
    pub class: usize,
    pub bodies: Vec<usize>,
    pub known: bool,
    pub owner: Option<usize>,
    pub occupier: Option<usize>,
    pub at_front: bool,
}

pub fn dist(a: (f64, f64), b: (f64, f64)) -> f64 {
    ((a.0 - b.0).powi(2) + (a.1 - b.1).powi(2)).sqrt()
}
