//! A plain-data picture of the world after a month, for front ends (the Godot extension reads this from its sim
//! thread; nothing here borrows the world).

use crate::goods;
use crate::world::World;

#[derive(Clone, Debug, Default)]
pub struct SysView {
    pub name: String,
    pub pos: (f64, f64),
    pub owner: i32,
    pub occupier: i32,
    pub at_front: bool,
    pub settled: u32,
    pub bodies: u32,
    pub pop: f64,
    pub known: bool,
    /// Worst food/parts shortage among its colonies, 0..1 (prices 1x..4x base).
    pub shortage: f64,
}

/// One body of a system, for the info panel.
#[derive(Clone, Debug, Default)]
pub struct BodyView {
    pub name: String,
    pub class: String,
    pub owner: i32,
    pub settled: bool,
    pub pop: f64,
    pub max_pop: f64,
    /// Deposits the owner (or, unsettled, the system owner) knows: (good name, richness)
    pub deposits: Vec<(String, f64)>,
    pub prices: [f64; 5],
    pub facilities: i32,
}

#[derive(Clone, Debug, Default)]
pub struct SystemDetail {
    pub id: usize,
    pub name: String,
    pub star: String,
    pub owner: i32,
    pub occupier: i32,
    pub bodies: Vec<BodyView>,
}

#[derive(Clone, Debug, Default)]
pub struct EmpireView {
    pub name: String,
    pub capital: (f64, f64),
    pub colonies: u32,
    pub systems: u32,
    pub pop: f64,
    pub treasury: f64,
    pub strength: f64,
    pub exhaustion: f64,
    pub reputation: f64,
    pub personality: String,
    pub at_war_with: Vec<String>,
}

#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub tick: u32,
    pub date: String,
    pub systems: Vec<SysView>,
    pub empires: Vec<EmpireView>,
    pub wars: Vec<(u32, u32)>,
    pub pacts: Vec<(u32, u32)>,
    pub guarantees: Vec<(u32, u32)>,
    /// This month's deliveries: from, to, good, quantity.
    pub shipments: Vec<((f64, f64), (f64, f64), u32, f64)>,
    pub colonies: u32,
    pub corps: u32,
}

impl World {
    pub fn snapshot(&self) -> Snapshot {
        let mut s = Snapshot { tick: self.tick, date: format!("year {}, month {}", self.tick / 12, self.tick % 12 + 1), ..Default::default() };
        let mut sys_settled = vec![(0u32, 0.0f64); self.systems.len()];
        for &m in &self.markets {
            if let Some(si) = self.colonies[m].system {
                sys_settled[si].0 += 1;
                sys_settled[si].1 += self.colonies[m].pop;
            }
        }
        for (i, sy) in self.systems.iter().enumerate() {
            s.systems.push(SysView {
                name: sy.name.clone(),
                pos: sy.pos,
                owner: sy.owner.map_or(-1, |o| o as i32),
                occupier: sy.occupier.map_or(-1, |o| o as i32),
                at_front: sy.at_front,
                settled: sys_settled[i].0,
                bodies: sy.bodies.len() as u32,
                pop: sys_settled[i].1,
                known: sy.known,
                shortage: sy.bodies.iter().filter(|&&c| self.colonies[c].settled).map(|&c| {
                    let col = &self.colonies[c];
                    (((col.price[goods::FOOD] + col.price[goods::PARTS]) / (2.0 * crate::market::BASE_PRICE) - 1.0) / 3.0).clamp(0.0, 1.0)
                }).fold(0.0, f64::max),
            });
        }
        for e in &self.empires {
            let own = self.empire_colonies(e.id);
            s.empires.push(EmpireView {
                name: e.name.clone(),
                capital: self.colonies[e.capital].pos,
                colonies: own.len() as u32,
                systems: self.systems.iter().filter(|x| x.owner == Some(e.id)).count() as u32,
                pop: own.iter().map(|&c| self.colonies[c].pop).sum(),
                treasury: e.treasury,
                strength: e.strength,
                exhaustion: e.exhaustion,
                reputation: e.reputation,
                personality: crate::personality::label(self, e.id),
                at_war_with: self.enemies_of(e.id).into_iter().map(|x| self.empires[x].name.clone()).collect(),
            });
        }
        // Every enemy pair, for drawing (coalition members included).
        for w in &self.wars {
            for &a in &w.sides[0] {
                for &b in &w.sides[1] {
                    s.wars.push((a as u32, b as u32));
                }
            }
        }
        let n = self.empires.len();
        for a in 0..n {
            for b in (a + 1)..n {
                if self.rel(a, b).pact {
                    s.pacts.push((a as u32, b as u32));
                }
            }
            for g in &self.empires[a].guarantees {
                s.guarantees.push((a as u32, g.0 as u32));
            }
        }
        for k in self.corps.iter().filter(|k| !k.dead) {
            for mv in &k.last_moves {
                s.shipments.push((self.colonies[mv.from].pos, self.colonies[mv.to].pos, mv.good as u32, mv.qty));
            }
        }
        s.colonies = self.markets.len() as u32;
        s.corps = self.corps.iter().filter(|k| !k.dead).count() as u32;
        s
    }
}

impl World {
    pub fn system_detail(&self, id: usize) -> Option<SystemDetail> {
        let s = self.systems.get(id)?;
        let viewer = s.owner;
        let bodies = s
            .bodies
            .iter()
            .map(|&c| {
                let col = &self.colonies[c];
                let rich = match (col.settled, viewer) {
                    (true, _) => col.rich().clone(),
                    (false, Some(e)) => col.known_rich(e),
                    _ => Default::default(),
                };
                BodyView {
                    name: col.name.clone(),
                    class: col.label.clone(),
                    owner: col.owner.map_or(-1, |o| o as i32),
                    settled: col.settled,
                    pop: col.pop,
                    max_pop: col.max_pop,
                    deposits: rich.0.iter().map(|&(g, v)| (goods::NAMES[g].to_string(), v)).collect(),
                    prices: col.price,
                    facilities: col.facility_count,
                }
            })
            .collect();
        Some(SystemDetail {
            id,
            name: s.name.clone(),
            star: crate::astro::CLASS_NAMES[s.class].to_string(),
            owner: s.owner.map_or(-1, |o| o as i32),
            occupier: s.occupier.map_or(-1, |o| o as i32),
            bodies,
        })
    }
}

// The sim must be movable to its own thread.
#[allow(dead_code)]
fn assert_send() {
    fn is_send<T: Send>() {}
    is_send::<World>();
}
