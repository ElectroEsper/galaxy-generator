//! A plain-data picture of the world after a month, for front ends (the Godot extension reads this from its sim
//! thread; nothing here borrows the world).

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
                at_war_with: self.wars.iter().filter_map(|w| if w.a == e.id { Some(w.b) } else if w.b == e.id { Some(w.a) } else { None }).map(|x| self.empires[x].name.clone()).collect(),
            });
        }
        s.wars = self.wars.iter().map(|w| (w.a as u32, w.b as u32)).collect();
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

// The sim must be movable to its own thread.
#[allow(dead_code)]
fn assert_send() {
    fn is_send<T: Send>() {}
    is_send::<World>();
}
