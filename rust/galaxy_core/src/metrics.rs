//! CSV output, same columns as economy_sim.gd's metrics_row / empire_rows / relation_rows, so the existing plot
//! scripts read Rust runs unchanged.

use crate::corp::Kind;
use crate::goods::{self, FOOD, METAL, ORE, PARTS, WATER};
use crate::market::BASE_PRICE;
use crate::world::World;

pub const METRIC_HEADER: &str = "tick,pop,colonies_with_jobs,in_shortage,avg_ore,avg_metal,avg_parts,avg_food,extractors,producers,freight,facilities,ships,promotions,attractions,avg_level,upgrades,hydro_facilities,food_extractors,avg_water,water_sites,ship_class,port_use,settled,surveyed,survey_ships,settlements,claims_sold,treasury,corp_cash,tax_collected,under_construction,state_colonies,state_spent,surveys_ordered,survey_backlog,survey_losses,systems_settled,known_systems,sector_events";
pub const EMPIRE_HEADER: &str = "tick,empire,colonies,systems,pop,facilities_here,known_systems,surveyed,survey_ships,treasury,tax_collected,state_colonies,sector_events,corps,customs,strength,exhaustion,mil_spent,occupied_by_enemy,at_war,personality,target_strength,main_threat,max_threat,reputation";
pub const RELATION_HEADER: &str = "tick,a,b,met,opinion,stance,border,trade,incidents,trade_treaty,passage,goodwill,pact,guarantees";

impl World {
    pub fn metrics_row(&self) -> String {
        let n = self.markets.len().max(1) as f64;
        let (mut pop, mut jobs_n, mut short_n) = (0.0, 0, 0);
        let mut avg = [0.0; goods::N];
        let (mut water_sites, mut pu, mut ps) = (0, 0.0, 0.0);
        let mut systems = std::collections::HashSet::new();
        for &m in &self.markets {
            let c = &self.colonies[m];
            pop += c.pop;
            if c.jobs > 0.0 {
                jobs_n += 1;
            }
            if (c.price[FOOD] + c.price[PARTS]) / (2.0 * BASE_PRICE) > 2.0 {
                short_n += 1;
            }
            for g in goods::ALL {
                avg[g] += c.price[g] / n;
            }
            if c.rich().has(WATER) {
                water_sites += 1;
            }
            pu += c.port_used as f64;
            ps += c.port_slots() as f64;
            if let Some(s) = c.system {
                systems.insert(s);
            }
        }
        let (mut ex, mut pr, mut fr, mut fac, mut ships, mut sclass) = (0, 0, 0, 0, 0, 0);
        let (mut sships, mut csold, mut slost, mut nbuild) = (0, 0, 0, 0);
        let (mut lvl, mut upg, mut hydro, mut farm) = (0.0, 0, 0, 0);
        let mut ccash = 0.0;
        for k in self.corps.iter().filter(|k| !k.dead) {
            ccash += k.cash;
            nbuild += k.facilities.iter().filter(|f| f.building()).count();
            match k.kind {
                Kind::Extractor => ex += 1,
                Kind::Producer => pr += 1,
                Kind::Freight => fr += 1,
                Kind::Surveyor => {
                    sships += 1 + k.ships;
                    csold += k.claims_sold;
                    slost += k.ships_lost;
                    continue;
                }
            }
            fac += k.facilities.len();
            ships += k.ships;
            if k.kind == Kind::Freight {
                sclass = sclass.max(k.ship_class);
            }
            upg += k.upgrades;
            for f in &k.facilities {
                lvl += f.level as f64;
                if f.good == FOOD {
                    if f.recipe {
                        hydro += 1;
                    } else {
                        farm += 1;
                    }
                }
            }
        }
        let surveyed = self.frontier.iter().filter(|&&c| self.colonies[c].surveys > 0).count();
        let known = self.systems.iter().filter(|s| s.known).count();
        let esum = |f: &dyn Fn(&crate::world::Empire) -> f64, fallback: f64| if self.empires.is_empty() { fallback } else { self.empires.iter().map(f).sum() };
        format!(
            "{},{:.0},{},{},{:.2},{:.2},{:.2},{:.2},{},{},{},{},{},{},{},{:.2},{},{},{},{:.2},{},{},{:.3},{},{},{},{},{},{:.0},{:.0},{:.0},{},{},{:.0},{},{},{},{},{},{}",
            self.tick, pop, jobs_n, short_n, avg[ORE], avg[METAL], avg[PARTS], avg[FOOD], ex, pr, fr, fac, ships, self.promotions, self.attractions,
            lvl / (fac.max(1)) as f64, upg, hydro, farm, avg[WATER], water_sites, sclass, pu / ps.max(1.0), self.markets.len(), surveyed, sships,
            self.settlements, csold, esum(&|e| e.treasury, self.treasury), ccash, self.tax_collected, nbuild,
            esum(&|e| e.state_colonies as f64, 0.0), esum(&|e| e.state_spent, 0.0), esum(&|e| e.surveys_ordered as f64, 0.0),
            esum(&|e| e.survey_backlog as f64, 0.0), slost, systems.len(), known, self.sector_events
        )
    }

    pub fn empire_rows(&self) -> Vec<String> {
        let mut rows = vec![];
        for e in &self.empires {
            let own: Vec<usize> = self.markets.iter().cloned().filter(|&m| self.colonies[m].owner == Some(e.id)).collect();
            let pop: f64 = own.iter().map(|&c| self.colonies[c].pop).sum();
            let fac: i32 = own.iter().map(|&c| self.colonies[c].facility_count).sum();
            let sys: std::collections::HashSet<usize> = own.iter().filter_map(|&c| self.colonies[c].system).collect();
            let surveyed = self.frontier.iter().filter(|&&c| self.colonies[c].surveys_by(e.id) > 0).count();
            let corps: Vec<_> = self.corps.iter().filter(|k| !k.dead && k.empire == Some(e.id)).collect();
            let sships: i32 = corps.iter().filter(|k| k.kind == Kind::Surveyor).map(|k| 1 + k.ships).sum();
            rows.push(format!(
                "{},{},{},{},{:.0},{},{},{},{},{:.0},{:.0},{},{},{},{:.0},{:.0},{:.1},{:.0},{},{},{},{:.0},{},{:.2},{:.0}",
                self.tick, e.id, own.len(), sys.len(), pop, fac, e.known.iter().filter(|&&k| k).count(), surveyed, sships, e.treasury, e.tax_collected,
                e.state_colonies, e.sector_events, corps.len(), e.customs_collected, 0.0, 0.0, 0.0, 0, 0, "balanced", 0.0, 0, 0.0, 50.0
            ));
        }
        rows
    }

    pub fn relation_rows(&self) -> Vec<String> {
        let n = self.empires.len();
        let mut rows = vec![];
        for a in 0..n {
            for b in (a + 1)..n {
                let r = self.rel(a, b);
                rows.push(format!(
                    "{},{},{},{},{:.1},{},{},{:.1},{:.2},{},{},{:.1},{},",
                    self.tick, a, b, r.met as i32, r.opinion, r.stance.name(), r.border, r.trade, r.incidents, r.trade_treaty as i32, r.passage as i32, r.goodwill, 0
                ));
            }
        }
        rows
    }
}
