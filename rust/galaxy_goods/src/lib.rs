//! Goods and recipes: everything about which goods exist, how they are made, and who consumes them for what.
//! The simulation reads these tables; to change the economy's goods, edit this crate.
//!
//! Sections: the goods list; raw extraction costs; recipes; population consumption; maintenance and subsistence;
//! construction materials; military costs. Every rate is per month (one tick).

pub const ORE: usize = 0;
pub const METAL: usize = 1;
pub const PARTS: usize = 2;
pub const FOOD: usize = 3;
pub const WATER: usize = 4;
pub const N: usize = 5;
pub const ALL: [usize; N] = [ORE, METAL, PARTS, FOOD, WATER];
pub const NAMES: [&str; N] = ["Ore", "Metal", "Parts", "Food", "Water"];

pub type PerGood = [f64; N];

/// Extraction cost per unit, for raw goods.
pub fn raw_cost(g: usize) -> f64 {
    match g {
        ORE => 1.5,
        FOOD => 1.5,
        WATER => 1.0,
        _ => f64::INFINITY,
    }
}

pub fn is_raw(g: usize) -> bool {
    matches!(g, ORE | FOOD | WATER)
}

pub struct Recipe {
    pub inputs: &'static [(usize, f64)],
    pub yield_: f64,
}

pub fn recipe(g: usize) -> Option<Recipe> {
    match g {
        METAL => Some(Recipe { inputs: &[(ORE, 2.0)], yield_: 1.0 }),
        PARTS => Some(Recipe { inputs: &[(METAL, 2.0)], yield_: 1.0 }),
        // Hydroponics: Food made anywhere from Water (+ a little equipment wear).
        FOOD => Some(Recipe { inputs: &[(WATER, 2.0), (PARTS, 0.1)], yield_: 1.0 }),
        _ => None,
    }
}

/// A small ordered good -> value map (keeps insertion order, like the GDScript dictionaries it replaces).
#[derive(Clone, Default, Debug)]
pub struct Rich(pub Vec<(usize, f64)>);

impl Rich {
    pub fn get(&self, g: usize) -> f64 {
        self.0.iter().find(|x| x.0 == g).map(|x| x.1).unwrap_or(0.0)
    }
    pub fn has(&self, g: usize) -> bool {
        self.0.iter().any(|x| x.0 == g)
    }
    pub fn set(&mut self, g: usize, v: f64) {
        if let Some(x) = self.0.iter_mut().find(|x| x.0 == g) {
            x.1 = v;
        } else {
            self.0.push((g, v));
        }
    }
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
    pub fn goods(&self) -> Vec<usize> {
        self.0.iter().map(|x| x.0).collect()
    }
}

// ---------------------------------------------------------------- Population consumption
/// Goods every colonist consumes each month: (good, units per person).
pub const POP_CONSUMPTION: &[(usize, f64)] = &[(FOOD, 0.05), (PARTS, 0.012), (WATER, 0.02)];

pub fn pop_consumption(g: usize) -> f64 {
    POP_CONSUMPTION.iter().find(|x| x.0 == g).map_or(0.0, |x| x.1)
}

// ---------------------------------------------------------------- Maintenance, salvage, subsistence
/// Buildings wear out: (good, units per person per month).
pub const MAINT_PER_POP: &[(usize, f64)] = &[(METAL, 0.004)];
/// Facilities wear out: (good, units per facility per month).
pub const MAINT_PER_FACILITY: &[(usize, f64)] = &[(PARTS, 0.08)];
/// Share of maintenance consumption recovered as scrap.
pub const SALVAGE_RATE: f64 = 0.5;
/// Goods a colony's baseline population makes for itself without any corporation: (good, units per month).
pub const SUBSISTENCE: &[(usize, f64)] = &[(FOOD, 30.0 * 0.05), (PARTS, 30.0 * 0.012)];

pub fn maint_per_pop(g: usize) -> f64 {
    MAINT_PER_POP.iter().find(|x| x.0 == g).map_or(0.0, |x| x.1)
}
pub fn maint_per_facility(g: usize) -> f64 {
    MAINT_PER_FACILITY.iter().find(|x| x.0 == g).map_or(0.0, |x| x.1)
}
pub fn subsistence(g: usize) -> f64 {
    SUBSISTENCE.iter().find(|x| x.0 == g).map_or(0.0, |x| x.1)
}

// ---------------------------------------------------------------- Construction
/// Materials to build a new facility; upgrades scale this by (0.4 + 0.2 x level).
pub const BUILD_FACILITY: &[(usize, f64)] = &[(METAL, 10.0), (PARTS, 4.0)];
/// Extra habitat materials for a company outpost's first settlers.
pub const BUILD_OUTPOST: &[(usize, f64)] = &[(METAL, 15.0), (PARTS, 6.0)];
/// Habitat the state ships with a state-founded colony.
pub const BUILD_STATE_COLONY: &[(usize, f64)] = &[(METAL, 30.0), (PARTS, 12.0)];

// ---------------------------------------------------------------- Military
/// Goods consumed to raise one point of military strength (plus UNIT_CASH).
pub const MILITARY_UNIT: &[(usize, f64)] = &[(METAL, 2.0), (PARTS, 1.0)];
/// Goods consumed per point of strength per month (spares), plus UPKEEP_CASH.
pub const MILITARY_UPKEEP: &[(usize, f64)] = &[(PARTS, 0.01)];
