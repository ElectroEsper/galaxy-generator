//! Profit-driven corporations (corporation.gd): extractors, producers, freight and surveyors. They act on the shared
//! world, so their logic is written as methods on World taking the corporation's index.

use crate::goods::{self, PerGood, METAL, N, PARTS};
use crate::market::{dist, Claim, Colony, Request, COVER_TICKS};
use crate::world::World;
use std::collections::HashMap;

pub const CAPEX: f64 = 80.0;
pub const UPKEEP: f64 = 1.0;
pub const SHIP_CAPACITY: f64 = 6.0;
pub const SHIP_UPKEEP: f64 = 1.5;
pub const CLASS_CAP_MULT: f64 = 2.0;
pub const CLASS_UPKEEP_MULT: f64 = 1.4;
pub const CLASS_REFIT_COST: f64 = 0.3;
pub const MAX_SHIP_CLASS: i32 = 6;
pub const SHIP_TIME: f64 = 4.0;
pub const LOAD_TIME: f64 = 0.5;
pub const GROW_FILL: f64 = 0.15;
pub const SHIP_COST: f64 = 0.4;
pub const EXPORT_SHARE: f64 = 1.0;
pub const PAYBACK_HORIZON: f64 = 25.0;
pub const REQUEST_COVER: f64 = 4.0;
pub const MAX_LEVEL: i32 = 8;
pub const LEVEL_BONUS: f64 = 0.6;
pub const UPKEEP_GROWTH: f64 = 0.25;
pub const EXTRACT_CAP_MULT: f64 = 40.0;
pub const HEADROOM: f64 = 1.3;
pub const IDLE_BLOCK: f64 = 0.3;
pub const CLOSE_AFTER: i32 = 20;
pub const INSOLVENT_AFTER: i32 = 15;
pub const SURVEY_MONTHS: f64 = 6.0;
pub const INTRA_SYSTEM_DIST: f64 = 0.4;
pub const SURVEY_LOSS: f64 = 0.03;
pub const SURVEY_LOSS_GIANT: f64 = 0.04;
pub const SURVEY_LOSS_BELT: f64 = 0.03;
pub const SHIP_BUY_MONTHS: i32 = 6;
pub const SURVEY_UPKEEP: f64 = 2.0;
pub const SURVEY_SHIP_COST: f64 = 150.0;
pub const SURVEY_YIELD: f64 = 0.6;
pub const SURVEY_DECAY: f64 = 8.0;
pub const SURVEY_CONTRACT: f64 = 20.0;
pub const CLAIM_PRICE: f64 = 150.0;
pub const MAX_UNSOLD_CLAIMS: i32 = 6;
pub const OUTPOST_COST: f64 = 160.0;
pub const OUTPOST_SETTLERS: f64 = 20.0;
pub const OUTPOST_PAYBACK: f64 = 60.0;
pub const BUILD_MONTHS: i32 = 6;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub enum Kind {
    Extractor,
    Producer,
    Freight,
    Surveyor,
}

#[derive(Clone, Debug)]
pub struct Facility {
    pub colony: usize,
    pub good: usize,
    pub recipe: bool,
    pub level: i32,
    pub losing: i32,
    pub build: PerGood,
    pub build_ticks: i32,
    pub pending_level: i32,
}

impl Facility {
    pub fn new(colony: usize, good: usize, recipe: bool) -> Facility {
        Facility { colony, good, recipe, level: 1, losing: 0, build: [0.0; N], build_ticks: 0, pending_level: 0 }
    }
    pub fn building(&self) -> bool {
        self.build_ticks > 0 || self.build.iter().any(|&x| x > 0.0)
    }
    pub fn extracts(&self) -> bool {
        !self.recipe
    }
    pub fn level_mult(&self) -> f64 {
        1.0 + LEVEL_BONUS * (self.level - 1) as f64
    }
    pub fn throughput(&self, c: &Colony) -> f64 {
        let base = if self.extracts() { c.rich().get(self.good) } else { goods::recipe(self.good).unwrap().yield_ };
        base * self.level_mult()
    }
    pub fn upkeep(&self) -> f64 {
        UPKEEP * (1.0 + UPKEEP_GROWTH * (self.level - 1) as f64)
    }
    pub fn upgrade_scale(&self) -> f64 {
        0.4 + 0.2 * self.level as f64
    }
    pub fn upgrade_cost(&self) -> f64 {
        CAPEX * self.upgrade_scale()
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Move {
    pub from: usize,
    pub to: usize,
    pub good: usize,
    pub qty: f64,
}

#[derive(Clone, Debug)]
pub struct Corp {
    pub id: usize,
    pub kind: Kind,
    pub empire: Option<usize>,
    pub cash: f64,
    pub facilities: Vec<Facility>,
    pub ships: i32,
    pub ship_class: i32,
    pub broke_ticks: i32,
    pub idle_ticks: i32,
    pub upgrades: i32,
    pub utilisation: f64,
    pub rr: usize,
    pub marg_rate: f64,
    pub fill: f64,
    pub moved: f64,
    pub last_moves: Vec<Move>,
    pub survey_jobs: Vec<(usize, f64)>,
    pub months_since_buy: i32,
    pub ships_lost: i32,
    pub surveys_done: i32,
    pub claims_sold: i32,
    pub dead: bool,
    pub route_memo: HashMap<(usize, usize), bool>,
}

impl Corp {
    pub fn new(id: usize, kind: Kind, cash: f64, empire: Option<usize>) -> Corp {
        Corp {
            id,
            kind,
            empire,
            cash,
            facilities: vec![],
            ships: 0,
            ship_class: 1,
            broke_ticks: 0,
            idle_ticks: 0,
            upgrades: 0,
            utilisation: 0.0,
            rr: 0,
            marg_rate: 0.0,
            fill: 0.0,
            moved: 0.0,
            last_moves: vec![],
            survey_jobs: vec![],
            months_since_buy: 0,
            ships_lost: 0,
            surveys_done: 0,
            claims_sold: 0,
            dead: false,
            route_memo: HashMap::new(),
        }
    }
    pub fn is_idle_funded(&self) -> bool {
        self.facilities.is_empty() && self.cash >= CAPEX * 1.5
    }
    pub fn is_dead(&self) -> bool {
        self.broke_ticks >= INSOLVENT_AFTER
    }
    pub fn ship_capacity(&self) -> f64 {
        SHIP_CAPACITY * CLASS_CAP_MULT.powi(self.ship_class - 1)
    }
}

/// A new-facility or outpost option on the opportunity board.
#[derive(Clone, Copy, Debug)]
pub struct Opt {
    pub pb: f64,
    pub i: usize,
    pub c: usize,
    pub g: usize,
    pub recipe: bool,
    pub frontier: bool,
    pub cost: f64,
}

fn cmp_opt(a: &Opt, b: &Opt) -> std::cmp::Ordering {
    a.pb.partial_cmp(&b.pb).unwrap_or(std::cmp::Ordering::Equal).then(a.i.cmp(&b.i))
}

impl World {
    // ------------------------------------------------------------ Shared helpers
    pub fn site_room(c: &Colony, g: usize, recipe: bool) -> f64 {
        if recipe {
            f64::INFINITY
        } else {
            c.rich().get(g) * EXTRACT_CAP_MULT - c.extraction[g]
        }
    }

    pub fn unit_margin(c: &Colony, g: usize, recipe: bool) -> f64 {
        if !recipe {
            return c.price[g] - goods::raw_cost(g);
        }
        let r = goods::recipe(g).unwrap();
        let mut m = r.yield_ * c.price[g];
        for &(i, q) in r.inputs {
            m -= q * c.price[i];
        }
        m
    }

    pub fn input_availability(c: &Colony, g: usize, recipe: bool) -> f64 {
        if !recipe {
            return 1.0;
        }
        let mut a: f64 = 1.0;
        for &(i, _) in goods::recipe(g).unwrap().inputs {
            a = a.min(c.stock[i] / (c.use_[i] * COVER_TICKS * 0.5));
        }
        a.clamp(0.05, 1.0)
    }

    pub fn materials_cost(c: &Colony, scale: f64, outpost: bool) -> f64 {
        let mut cost: f64 = goods::BUILD_FACILITY.iter().map(|&(g, q)| q * scale * c.price[g]).sum();
        if outpost {
            cost += goods::BUILD_OUTPOST.iter().map(|&(g, q)| q * c.price[g]).sum::<f64>();
        }
        cost
    }

    /// Lane cost between two bodies: a short hop inside one star system, otherwise map distance.
    pub fn lane_dist(a: &Colony, b: &Colony) -> f64 {
        if a.system.is_some() && a.system == b.system {
            INTRA_SYSTEM_DIST
        } else {
            1.0 + dist(a.pos, b.pos) / 200.0
        }
    }

    fn lane(&self, a: usize, b: usize) -> f64 {
        Self::lane_dist(&self.colonies[a], &self.colonies[b])
    }

    /// Keep colony capacity / extraction bookkeeping in sync with a facility's throughput.
    fn register(&mut self, ki: usize, fi: usize, sign: f64) {
        let f = self.corps[ki].facilities[fi].clone();
        self.invalidate_good(f.good);
        let thr = f.throughput(&self.colonies[f.colony]);
        let c = &mut self.colonies[f.colony];
        c.capacity[f.good] += sign * thr;
        if f.extracts() {
            c.extraction[f.good] += sign * thr;
        }
    }

    pub fn seed_facility(&mut self, ki: usize, c: usize, g: usize, recipe: bool) {
        self.corps[ki].facilities.push(Facility::new(c, g, recipe));
        let fi = self.corps[ki].facilities.len() - 1;
        self.register(ki, fi, 1.0);
        self.colonies[c].facility_count += 1;
        if !recipe {
            self.colonies[c].extractor_count += 1;
        }
    }

    fn remove_facility(&mut self, ki: usize, fi: usize) {
        self.register(ki, fi, -1.0);
        let f = self.corps[ki].facilities.remove(fi);
        self.colonies[f.colony].facility_count -= 1;
        if f.extracts() {
            self.colonies[f.colony].extractor_count -= 1;
        }
    }

    pub fn dissolve(&mut self, ki: usize) {
        while !self.corps[ki].facilities.is_empty() {
            let last = self.corps[ki].facilities.len() - 1;
            self.remove_facility(ki, last);
        }
    }

    pub fn corp_run(&mut self, ki: usize) {
        match self.corps[ki].kind {
            Kind::Freight => self.run_freight(ki),
            Kind::Surveyor => self.run_survey(ki),
            _ => {
                self.run_facilities(ki);
                self.review_and_expand(ki);
                let k = &mut self.corps[ki];
                k.idle_ticks = if k.facilities.is_empty() { k.idle_ticks + 1 } else { 0 };
            }
        }
        let k = &mut self.corps[ki];
        k.broke_ticks = if k.cash < 0.0 { k.broke_ticks + 1 } else { 0 };
    }

    // ------------------------------------------------------------ Extractors and producers
    fn run_facilities(&mut self, ki: usize) {
        for fi in 0..self.corps[ki].facilities.len() {
            if self.corps[ki].facilities[fi].building() {
                self.advance_build(ki, fi);
                if self.corps[ki].facilities[fi].pending_level == 0 {
                    continue;
                }
            }
            let f = self.corps[ki].facilities[fi].clone();
            let out_factor = self.output_factor(f.colony);
            let c = &mut self.colonies[f.colony];
            if f.extracts() {
                if Self::unit_margin(c, f.good, false) <= 0.0 {
                    continue;
                }
                let q = c.rich().get(f.good) * f.level_mult() * out_factor;
                c.stock[f.good] += q;
                self.corps[ki].cash += q * (c.price[f.good] - goods::raw_cost(f.good));
            } else {
                let r = goods::recipe(f.good).unwrap();
                let idle = Self::unit_margin(c, f.good, true) <= 0.0;
                let mut runs = if idle { 0.0 } else { f.level_mult() * out_factor };
                for &(i, q) in r.inputs {
                    c.note_use(i, q * f.level_mult());
                    let want = q * f.level_mult() * REQUEST_COVER;
                    if c.stock[i] < want {
                        c.requests.push(Request { good: i, qty: want - c.stock[i], payer: Some(ki) });
                    }
                    if !idle {
                        runs = f64::min(runs, c.stock[i] / q);
                    }
                }
                if runs <= 0.0 {
                    continue;
                }
                let mut cash = 0.0;
                for &(i, q) in r.inputs {
                    let n = runs * q;
                    c.stock[i] -= n;
                    cash -= n * c.price[i];
                }
                let out = runs * r.yield_;
                c.stock[f.good] += out;
                cash += out * c.price[f.good];
                self.corps[ki].cash += cash;
            }
        }
        let upkeep: f64 = self.corps[ki].facilities.iter().map(|f| f.upkeep()).sum();
        self.corps[ki].cash -= upkeep;
    }

    fn facility_margin(&self, f: &Facility) -> f64 {
        let c = &self.colonies[f.colony];
        Self::unit_margin(c, f.good, f.recipe) * f.throughput(c) - f.upkeep()
    }

    /// Every new-facility option for a kind of corporation, best payback first (ties keep scan order).
    fn opportunity_board(&mut self, kind: Kind, e: Option<usize>) -> Vec<Opt> {
        let key = (kind as u8, e.map_or(-1, |x| x as i64));
        if let Some(v) = self.boards.get(&key) {
            return v.clone();
        }
        let as_recipe = kind == Kind::Producer;
        let mut opts = vec![];
        for mi in 0..self.markets.len() {
            let c = self.markets[mi];
            if self.colonies[c].facility_slots_free() <= 0 {
                continue;
            }
            for g in goods::ALL {
                if (as_recipe && goods::recipe(g).is_none()) || (!as_recipe && !goods::is_raw(g)) {
                    continue;
                }
                let col = &self.colonies[c];
                let q = if as_recipe { 1.0 } else { col.rich().get(g) };
                if q <= 0.0 || Self::site_room(col, g, as_recipe) < q {
                    continue;
                }
                let unmet = self.regional(true, g) * HEADROOM - self.regional(false, g);
                if unmet < q * 0.5 {
                    continue;
                }
                let col = &self.colonies[c];
                let absorb = f64::min(1.0, (col.use_[g] * HEADROOM + unmet * EXPORT_SHARE) / q);
                let m = Self::unit_margin(col, g, as_recipe) * q * Self::input_availability(col, g, as_recipe) * absorb - UPKEEP;
                let cost = CAPEX + Self::materials_cost(col, 1.0, false);
                if m > 0.0 {
                    let i = opts.len();
                    opts.push(Opt { pb: cost / m, i, c, g, recipe: as_recipe, frontier: false, cost });
                }
            }
        }
        opts.sort_by(cmp_opt);
        self.boards.insert(key, opts.clone());
        opts
    }

    /// Outpost options for empire e and raw good g, best payback first.
    fn outpost_list(&mut self, e: usize, g: usize) -> Vec<Opt> {
        if let Some(v) = self.out_cache.get(&(e, g)) {
            return v.clone();
        }
        let unmet = self.regional(true, g) * HEADROOM - self.regional(false, g);
        let mut opts = vec![];
        for (ri, row) in self.outpost_base(e).into_iter().enumerate() {
            if row.g != g || unmet < row.q * 0.5 {
                continue;
            }
            let absorb = f64::min(1.0, unmet * EXPORT_SHARE / row.q);
            let m = row.unit * row.q * absorb - UPKEEP;
            let fee = self.colonies[row.c].intel[e].as_ref().and_then(|i| i.claims[g]).map_or(0.0, |cl| CLAIM_PRICE * cl.value);
            let cost = row.cost + fee;
            if m > 0.0 {
                let pb = cost / m * PAYBACK_HORIZON / OUTPOST_PAYBACK;
                opts.push(Opt { pb, i: 1_000_000 + ri, c: row.c, g, recipe: false, frontier: true, cost });
            }
        }
        opts.sort_by(cmp_opt);
        self.out_cache.insert((e, g), opts.clone());
        opts
    }

    fn review_and_expand(&mut self, ki: usize) {
        // Close chronic losers (only surplus capacity, unless losing for a very long time).
        let mut fi = 0;
        while fi < self.corps[ki].facilities.len() {
            let f = self.corps[ki].facilities[fi].clone();
            let losing = if self.facility_margin(&f) <= 0.0 { f.losing + 1 } else { 0 };
            self.corps[ki].facilities[fi].losing = losing;
            let surplus = self.regional(false, f.good) > self.regional(true, f.good) * HEADROOM;
            if (losing > CLOSE_AFTER && surplus) || losing > CLOSE_AFTER * 4 {
                self.remove_facility(ki, fi);
            } else {
                fi += 1;
            }
        }
        // In trouble: shed the worst loss-maker each month.
        if self.corps[ki].cash < 0.0 {
            let mut worst = None;
            let mut wm = 0.0;
            for (i, f) in self.corps[ki].facilities.iter().enumerate() {
                let fm = self.facility_margin(f);
                if f.losing > 3 && fm < wm {
                    wm = fm;
                    worst = Some(i);
                }
            }
            if let Some(i) = worst {
                self.remove_facility(ki, i);
            }
        }
        if self.corps[ki].cash < CAPEX * 0.6 {
            return;
        }
        // No new capacity for a good while our own plants making it stand idle.
        let mut idle_n = [0usize; N];
        let mut all_n = [0usize; N];
        for f in &self.corps[ki].facilities {
            if f.building() {
                continue;
            }
            all_n[f.good] += 1;
            if f.losing > 2 {
                idle_n[f.good] += 1;
            }
        }
        let idle_share = |g: usize| if all_n[g] == 0 { 0.0 } else { idle_n[g] as f64 / all_n[g] as f64 };
        let kind = self.corps[ki].kind;
        let empire = self.corps[ki].empire;
        let cash = self.corps[ki].cash;
        let mut best_pb = f64::INFINITY;
        let mut best_new: Option<Opt> = None;
        let mut best_up: Option<usize> = None;
        // Merged walk over the opportunity board and (for extractors) the outpost lists, best payback first.
        let mut lists = vec![self.opportunity_board(kind, empire)];
        if kind == Kind::Extractor && self.cfg.colonize {
            if let Some(e) = empire {
                for g in goods::ALL {
                    if goods::is_raw(g) {
                        lists.push(self.outpost_list(e, g));
                    }
                }
            }
        }
        let mut ptr = vec![0usize; lists.len()];
        loop {
            let mut bi: Option<usize> = None;
            for li in 0..lists.len() {
                if ptr[li] >= lists[li].len() {
                    continue;
                }
                match bi {
                    None => bi = Some(li),
                    Some(b) => {
                        if cmp_opt(&lists[li][ptr[li]], &lists[b][ptr[b]]) == std::cmp::Ordering::Less {
                            bi = Some(li);
                        }
                    }
                }
            }
            let b = match bi {
                Some(b) => b,
                None => break,
            };
            let o = lists[b][ptr[b]];
            ptr[b] += 1;
            if o.pb >= best_pb {
                break;
            }
            if idle_share(o.g) > IDLE_BLOCK {
                continue;
            }
            if cash < o.cost * if o.frontier { 1.2 } else { 1.5 } {
                continue;
            }
            best_pb = o.pb;
            best_new = Some(o);
            break;
        }
        // Upgrades of our own facilities.
        for fi in 0..self.corps[ki].facilities.len() {
            let f = self.corps[ki].facilities[fi].clone();
            if f.level >= MAX_LEVEL || f.building() || idle_share(f.good) > IDLE_BLOCK {
                continue;
            }
            let col = &self.colonies[f.colony];
            let delta = f.throughput(col) / f.level_mult() * LEVEL_BONUS;
            if Self::site_room(col, f.good, f.recipe) < delta || cash < f.upgrade_cost() {
                continue;
            }
            let unmet = self.regional(true, f.good) * HEADROOM - self.regional(false, f.good);
            if unmet < delta * 0.5 {
                continue;
            }
            let col = &self.colonies[f.colony];
            let absorb = f64::min(1.0, (col.use_[f.good] * HEADROOM + unmet * EXPORT_SHARE) / (f.throughput(col) + delta));
            let gain = Self::unit_margin(col, f.good, f.recipe) * delta * Self::input_availability(col, f.good, f.recipe) * absorb - UPKEEP * UPKEEP_GROWTH;
            let cost = f.upgrade_cost() + Self::materials_cost(col, f.upgrade_scale(), false);
            if gain > 0.0 && cost / gain < best_pb {
                best_pb = cost / gain;
                best_up = Some(fi);
                best_new = None;
            }
        }
        if best_pb >= PAYBACK_HORIZON {
            return;
        }
        if let Some(fi) = best_up {
            let k = &mut self.corps[ki];
            let f = &mut k.facilities[fi];
            k.cash -= f.upgrade_cost();
            f.pending_level = f.level + 1;
            let s = f.upgrade_scale();
            for &(g, q) in goods::BUILD_FACILITY {
                f.build[g] = q * s;
            }
            f.build_ticks = BUILD_MONTHS;
            k.upgrades += 1;
        } else if let Some(o) = best_new {
            if o.frontier {
                if !self.found_outpost(o.c, empire.unwrap()) {
                    return;
                }
                self.corps[ki].cash -= OUTPOST_COST;
            }
            self.corps[ki].cash -= CAPEX;
            if !o.recipe {
                self.buy_claim(ki, o.c, o.g);
            }
            let mut f = Facility::new(o.c, o.g, o.recipe);
            for &(g, q) in goods::BUILD_FACILITY {
                f.build[g] += q;
            }
            if o.frontier {
                for &(g, q) in goods::BUILD_OUTPOST {
                    f.build[g] += q;
                }
            }
            f.build_ticks = BUILD_MONTHS;
            self.corps[ki].facilities.push(f);
            let fi = self.corps[ki].facilities.len() - 1;
            self.register(ki, fi, 1.0);
            self.colonies[o.c].facility_count += 1;
            if !o.recipe {
                self.colonies[o.c].extractor_count += 1;
            }
        }
    }

    /// Construction: take what's on the colony's shelf (paying for it), ask Freight for the rest.
    fn advance_build(&mut self, ki: usize, fi: usize) {
        let c = self.corps[ki].facilities[fi].colony;
        {
            let f = &mut self.corps[ki].facilities[fi];
            f.build_ticks = (f.build_ticks - 1).max(0);
        }
        for g in goods::ALL {
            let want = self.corps[ki].facilities[fi].build[g];
            if want <= 0.0 {
                continue;
            }
            let col = &mut self.colonies[c];
            col.note_use(g, want / BUILD_MONTHS as f64);
            let take = col.stock[g].min(want);
            if take < want {
                col.requests.push(Request { good: g, qty: want - take, payer: Some(ki) });
            }
            col.stock[g] -= take;
            let cost = take * col.price[g];
            self.corps[ki].cash -= cost;
            let f = &mut self.corps[ki].facilities[fi];
            f.build[g] = want - take;
            if f.build[g] <= 0.01 {
                f.build[g] = 0.0;
            }
        }
        let f = &self.corps[ki].facilities[fi];
        if !f.building() && f.pending_level > 0 {
            self.register(ki, fi, -1.0);
            let f = &mut self.corps[ki].facilities[fi];
            f.level = f.pending_level;
            f.pending_level = 0;
            self.register(ki, fi, 1.0);
        }
    }

    // ------------------------------------------------------------ Freight
    fn route_ok_memo(&mut self, ki: usize, a: usize, b: usize) -> bool {
        if let Some(&v) = self.corps[ki].route_memo.get(&(a, b)) {
            return v;
        }
        let e = self.corps[ki].empire;
        let ok = self.route_ok(e, a, b);
        self.corps[ki].route_memo.insert((a, b), ok);
        ok
    }

    fn run_freight(&mut self, ki: usize) {
        self.corps[ki].last_moves.clear();
        self.corps[ki].route_memo.clear();
        let colonize = self.cfg.colonize;
        let ships = self.corps[ki].ships;
        let mut budget = (1 + ships) as f64 * SHIP_TIME;
        let total_budget = budget;
        let cap = self.corps[ki].ship_capacity();
        let mut done = 0;
        let moved_before = self.corps[ki].moved;
        let mut last_rate = -1.0;
        let n = self.markets.len();
        self.corps[ki].rr = (self.corps[ki].rr + 7) % n.max(1);
        let rr = self.corps[ki].rr;
        // Contracts first: deliver inputs that producers and builders asked for (the requester pays the fee).
        for di in 0..n {
            if budget <= 0.0 {
                break;
            }
            let dest = self.markets[(di + rr) % n];
            let mut ri = 0;
            while ri < self.colonies[dest].requests.len() {
                if budget <= 0.0 || !self.colonies[dest].port_free() {
                    break;
                }
                let req = self.colonies[dest].requests[ri];
                let g = req.good;
                let mut src: Option<usize> = None;
                for mi in 0..n {
                    let m = self.markets[mi];
                    let cm = &self.colonies[m];
                    if m != dest && cm.port_free() && cm.stock[g] >= 8.0 && src.map_or(true, |s| cm.stock[g] > self.colonies[s].stock[g]) {
                        if colonize && !self.route_ok_memo(ki, m, dest) {
                            continue;
                        }
                        src = Some(m);
                    }
                }
                let src = match src {
                    Some(s) => s,
                    None => {
                        ri += 1;
                        continue;
                    }
                };
                let q = req.qty.min(cap).min(self.colonies[src].stock[g] * 0.5);
                if q <= 0.0 {
                    ri += 1;
                    continue;
                }
                let d = self.lane(src, dest);
                let fee = SHIP_COST * d * q;
                let trip = d + LOAD_TIME;
                budget -= trip;
                let gain = q * (self.colonies[dest].price[g] - self.colonies[src].price[g]) + fee;
                last_rate = gain / trip;
                self.colonies[src].port_used += 1;
                self.colonies[dest].port_used += 1;
                self.colonies[src].stock[g] -= q;
                self.colonies[dest].stock[g] += q;
                self.colonies[dest].requests[ri].qty -= q;
                self.corps[ki].cash += gain;
                if let Some(p) = req.payer {
                    self.corps[p].cash -= fee;
                }
                if colonize && self.colonies[src].owner != self.colonies[dest].owner {
                    let value = q * self.colonies[dest].price[g];
                    let customs = self.tariff_rate(src, dest) * value;
                    self.corps[ki].cash -= customs;
                    self.record_trade(src, dest, value, customs);
                }
                self.corps[ki].moved += q;
                done += 1;
                self.corps[ki].last_moves.push(crate::corp::Move { from: src, to: dest, good: g, qty: q });
                ri += 1;
            }
        }
        // Candidate lanes: for each good, the 6 cheapest sources x the 6 dearest destinations.
        let mut sources: Vec<Vec<usize>> = vec![];
        let mut dests: Vec<Vec<usize>> = vec![];
        for g in goods::ALL {
            let mut by_price = self.markets.clone();
            by_price.sort_by(|&x, &y| self.colonies[x].price[g].partial_cmp(&self.colonies[y].price[g]).unwrap());
            sources.push(by_price.iter().take(6).cloned().collect());
            by_price.reverse();
            dests.push(by_price.iter().take(6).cloned().collect());
        }
        while budget > 0.0 {
            let mut best_m = 0.0;
            let mut best: Option<(usize, usize, usize)> = None;
            for g in goods::ALL {
                for &a in &sources[g] {
                    if self.colonies[a].stock[g] < 6.0 || !self.colonies[a].port_free() {
                        continue;
                    }
                    for &b in &dests[g] {
                        if a == b || !self.colonies[b].port_free() {
                            continue;
                        }
                        let mut m = self.colonies[b].price[g] - self.colonies[a].price[g] - SHIP_COST * self.lane(a, b);
                        if colonize && self.colonies[a].owner != self.colonies[b].owner {
                            m -= self.tariff_rate(a, b) * self.colonies[b].price[g];
                        }
                        if m > best_m {
                            if colonize && !self.route_ok_memo(ki, a, b) {
                                continue;
                            }
                            best_m = m;
                            best = Some((g, a, b));
                        }
                    }
                }
            }
            if best_m <= 0.3 {
                break;
            }
            let (g, a, b) = best.unwrap();
            let q = (self.colonies[a].stock[g] * 0.5).min(cap).min((self.corps[ki].cash / self.colonies[a].price[g]).max(0.0));
            if q <= 0.0 {
                break;
            }
            let trip = self.lane(a, b) + LOAD_TIME;
            budget -= trip;
            last_rate = q * best_m / trip;
            self.colonies[a].port_used += 1;
            self.colonies[b].port_used += 1;
            self.colonies[a].stock[g] -= q;
            self.colonies[b].stock[g] += q;
            self.corps[ki].cash += q * best_m;
            if colonize && self.colonies[a].owner != self.colonies[b].owner {
                let value = q * self.colonies[b].price[g];
                let customs = self.tariff_rate(a, b) * value;
                self.record_trade(a, b, value, customs);
            }
            self.corps[ki].moved += q;
            done += 1;
            self.corps[ki].last_moves.push(crate::corp::Move { from: a, to: b, good: g, qty: q });
        }
        let k = &mut self.corps[ki];
        k.utilisation = 0.8 * k.utilisation + 0.2 * (1.0 - budget.max(0.0) / total_budget);
        if done > 0 {
            k.fill = 0.8 * k.fill + 0.2 * ((k.moved - moved_before) / (done as f64 * cap)).min(1.0);
        }
        if last_rate >= 0.0 {
            k.marg_rate = 0.9 * k.marg_rate + 0.1 * last_rate;
        } else if budget > 0.0 {
            k.marg_rate *= 0.9;
        }
        let ship_upkeep = SHIP_UPKEEP * CLASS_UPKEEP_MULT.powi(k.ship_class - 1);
        k.cash -= ship_upkeep * (1 + k.ships) as f64;
        // Grow while busy, full and paying back on the marginal delivery; shrink when idle.
        let marg_gain = k.marg_rate * SHIP_TIME - ship_upkeep;
        if k.cash > CAPEX * 3.0 && k.utilisation > 0.85 && k.fill > GROW_FILL && marg_gain > 0.0 && CAPEX / marg_gain < PAYBACK_HORIZON {
            let refit = CAPEX * k.ships as f64 * CLASS_REFIT_COST * k.ship_class as f64;
            let refit_per_cap = if k.ships > 0 { refit / (k.ships as f64 * k.ship_capacity() * (CLASS_CAP_MULT - 1.0)) } else { f64::INFINITY };
            let ship_per_cap = CAPEX / k.ship_capacity();
            if k.ship_class < MAX_SHIP_CLASS && k.ships > 0 && refit_per_cap < ship_per_cap && k.cash > refit * 2.0 {
                k.cash -= refit;
                k.ship_class += 1;
            } else {
                k.cash -= CAPEX;
                k.ships += 1;
            }
        } else if k.utilisation < 0.25 && k.ships > 0 {
            k.ships -= 1;
        }
    }

    // ------------------------------------------------------------ Surveyors
    pub fn survey_months(c: &Colony) -> f64 {
        (2.0 + 4.0 * c.body_radius.max(0.2).powf(0.6)).min(24.0)
    }

    fn loss_chance(c: &Colony) -> f64 {
        let mut p = SURVEY_LOSS;
        if c.label.starts_with("Asteroid") || c.label.starts_with("Debris") {
            p += SURVEY_LOSS_BELT;
        } else if c.body_radius > 5.0 {
            p += SURVEY_LOSS_GIANT;
        }
        p
    }

    /// Whose knowledge holds the claims on a body: its owner's for a settled colony, else the corporation's empire.
    fn claims_empire(&self, ki: usize, c: usize) -> Option<usize> {
        let col = &self.colonies[c];
        if col.settled && col.owner.is_some() {
            col.owner
        } else {
            self.corps[ki].empire
        }
    }

    /// The first extractor to work a surveyed deposit buys the claim from the surveyor who found it.
    fn buy_claim(&mut self, ki: usize, c: usize, g: usize) {
        let e = match self.claims_empire(ki, c) {
            Some(e) => e,
            None => return,
        };
        let cl = match self.colonies[c].intel[e].as_ref().and_then(|i| i.claims[g]) {
            Some(cl) => cl,
            None => return,
        };
        let fee = CLAIM_PRICE * cl.value;
        self.corps[ki].cash -= fee;
        self.corps[cl.owner].cash += fee;
        self.corps[cl.owner].claims_sold += 1;
        self.colonies[c].intel_for(e).claims[g] = None;
    }

    fn unsold_claims(&self, ki: usize) -> i32 {
        let e = match self.corps[ki].empire {
            Some(e) if self.cfg.colonize => e,
            _ => return 0,
        };
        let mut n = 0;
        for &c in &self.frontier {
            if let Some(i) = &self.colonies[c].intel[e] {
                n += i.claims.iter().flatten().filter(|cl| cl.owner == ki).count() as i32;
            }
        }
        n
    }

    fn build_survey_board(&mut self, e: usize) {
        let mut cands = self.known_frontier(e);
        cands.extend(self.markets.iter().cloned().filter(|&m| self.colonies[m].owner == Some(e)));
        let mut rows: Vec<(f64, usize, usize)> = vec![];
        for (i, c) in cands.into_iter().enumerate() {
            let known: f64 = self.colonies[c].intel[e].as_ref().map_or(0.0, |x| x.rich.0.iter().map(|y| y.1).sum());
            let n = self.colonies[c].surveys_by(e);
            let ev = if n == 0 { 1.0 } else { 0.4 * known / n as f64 };
            let near = self.nearest_settled(c, e);
            let v = ev / (Self::survey_months(&self.colonies[c]) + self.lane(c, near) / SHIP_TIME);
            if v > 0.0 {
                rows.push((v, i, c));
            }
        }
        rows.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap().then(a.1.cmp(&b.1)));
        self.empires[e].survey_board = Some(rows.into_iter().map(|r| r.2).collect());
    }

    fn pick_survey_target(&mut self, ki: usize) -> Option<usize> {
        let e = self.corps[ki].empire?;
        if self.empires[e].survey_board.is_none() {
            self.build_survey_board(e);
        }
        let mut busy = std::collections::HashSet::new();
        for k in &self.corps {
            if !k.dead && k.kind == Kind::Surveyor && k.empire == Some(e) {
                for j in &k.survey_jobs {
                    busy.insert(j.0);
                }
            }
        }
        self.empires[e].survey_board.as_ref().unwrap().iter().cloned().find(|c| !busy.contains(c))
    }

    fn run_survey(&mut self, ki: usize) {
        self.corps[ki].last_moves.clear();
        self.corps[ki].months_since_buy += 1;
        let jobs = std::mem::take(&mut self.corps[ki].survey_jobs);
        let mut keep = vec![];
        for (t, eta) in jobs {
            let eta = eta - 1.0;
            if eta > 0.0 {
                keep.push((t, eta));
                continue;
            }
            if self.rng.randf() < Self::loss_chance(&self.colonies[t]) {
                let k = &mut self.corps[ki];
                k.ships_lost += 1;
                if k.ships > 0 {
                    k.ships -= 1;
                } else {
                    k.cash -= SURVEY_SHIP_COST * 0.5;
                }
                continue;
            }
            self.complete_survey(ki, t);
        }
        // Jobs completed this month were removed; ones still under way stay.
        let mut cur = std::mem::take(&mut self.corps[ki].survey_jobs);
        keep.append(&mut cur);
        self.corps[ki].survey_jobs = keep;
        let free = (1 + self.corps[ki].ships) - self.corps[ki].survey_jobs.len() as i32;
        for _ in 0..free.max(0) {
            let t = match self.pick_survey_target(ki) {
                Some(t) => t,
                None => break,
            };
            let e = self.corps[ki].empire.unwrap();
            let near = self.nearest_settled(t, e);
            let eta = Self::survey_months(&self.colonies[t]) + self.lane(t, near) / SHIP_TIME;
            self.corps[ki].survey_jobs.push((t, eta));
        }
        let ordered = self.corps[ki].empire.map_or(0, |e| self.empires[e].survey_backlog);
        let unsold = self.unsold_claims(ki);
        let k = &mut self.corps[ki];
        k.cash -= SURVEY_UPKEEP * (1 + k.ships) as f64;
        let per_ship_year = 12.0 / (SURVEY_MONTHS + 1.0);
        if k.months_since_buy >= SHIP_BUY_MONTHS && k.cash > SURVEY_SHIP_COST * 4.0 && (unsold < MAX_UNSOLD_CLAIMS || ordered as f64 > (1 + k.ships) as f64 * per_ship_year) {
            k.cash -= SURVEY_SHIP_COST;
            k.ships += 1;
            k.months_since_buy = 0;
        } else if k.cash < SURVEY_SHIP_COST && k.ships > 0 && ordered == 0 {
            k.ships -= 1;
            k.cash += SURVEY_SHIP_COST * 0.5;
        }
    }

    fn complete_survey(&mut self, ki: usize, t: usize) {
        let e = self.corps[ki].empire.unwrap();
        if self.colonies[t].surveys_by(e) == 0 {
            // Paid by the state: an ordered survey at the order price, otherwise the standing contract fee.
            let mut fee = SURVEY_CONTRACT;
            if self.empires[e].survey_backlog > 0 {
                self.empires[e].survey_backlog -= 1;
                fee = crate::world::SURVEY_ORDER_PRICE;
            }
            self.corps[ki].cash += fee;
            self.empires[e].treasury -= fee;
        }
        self.colonies[t].surveys += 1;
        self.colonies[t].intel_for(e).surveys += 1;
        self.empires[e].survey_board = None;
        self.corps[ki].surveys_done += 1;
        for (g, r) in self.colonies[t].hidden.0.clone() {
            let found = self.colonies[t].intel_for(e).found.get(g);
            let amount = r * self.rng.range(0.4, 1.0) * (-SURVEY_DECAY / (r * 5.0) * found).exp() * SURVEY_YIELD;
            let inc = self.reveal(t, e, g, amount);
            if inc > 0.0 && self.colonies[t].extraction[g] <= 0.0 {
                let info = self.colonies[t].intel_for(e);
                let prev = match info.claims[g] {
                    Some(cl) if cl.owner == ki => cl.value,
                    _ => 0.0,
                };
                info.claims[g] = Some(Claim { owner: ki, value: prev + inc });
            }
        }
    }
}

// Silence unused-import warnings for goods used only in some configurations.
#[allow(dead_code)]
const _USED: [usize; 2] = [METAL, PARTS];
