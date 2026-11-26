//! Physical war: fleets and armies are entities that sit in star systems, move along jump lanes, and fight where
//! they meet. An empire's `strength` stays the total of its forces (diplomacy, threat and crises still read it).
//!
//! Roles:
//! - **Fleets** fight for control of space. An army can only land in a system its side controls (no enemy fleet
//!   there).
//! - **Armies** fight ground battles against garrisons and the system's own defences. Winning occupies the system
//!   (or liberates it).
//!
//! Planning: in peacetime, forces only relocate (garrisons) and patrol (fleets cycle through border systems). Anything
//! more complex is an **operation**. In wartime, each empire's war planner ranks goals (defend a threatened system,
//! liberate an occupied one, invade an enemy system). For each goal, a small GOAP planner chains the actions that
//! reach it from the current facts:
//!     assemble forces at a staging system -> move the fleet in -> win space control -> land the army -> take it.
//! Operations then execute action by action and replan when a fact changes (the fleet was beaten, the army
//! destroyed...).

use crate::market::dist;
use crate::world::World;
use serde::{Deserialize, Serialize};

pub const SPEED: f64 = 45.0; // map units per month
pub const BATTLE_RATE: f64 = 0.12; // share of the enemy's strength dealt as losses per month (Lanchester-style)
pub const DEFENDER_BONUS: f64 = 1.25;
pub const STRIKE_BONUS: f64 = 1.5;
pub const FLEET_SHARE: f64 = 0.5; // share of new strength that goes to fleets
pub const SYSTEM_DEFENCE: f64 = 15.0; // ground defence of a system, before garrisons
pub const DEFENCE_PER_POP: f64 = 0.002;
pub const MIN_FORCE: f64 = 0.5; // smaller detachments disband into the nearest friendly force
pub const MAX_OPS: usize = 3; // concurrent operations per empire
pub const ASSEMBLE_MONTHS: u32 = 6; // an operation whose forces stop moving without assembling is dropped after this
pub const OP_SUPERIORITY: f64 = 1.3; // wanted local superiority, scaled by the empire's attack ratio
pub const NEIGHBOURS: usize = 4;

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum ForceKind {
    Fleet,
    Army,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Force {
    pub id: usize,
    pub owner: usize,
    pub kind: ForceKind,
    pub strength: f64,
    /// Where it is (the system it last reached).
    pub system: usize,
    /// Remaining route (next system first) and progress toward the next system (map units travelled).
    pub path: Vec<usize>,
    pub progress: f64,
    /// Operation it is assigned to.
    pub op: Option<usize>,
    /// Patrol route index (fleets in peacetime).
    pub patrol: usize,
}

impl Force {
    pub fn moving(&self) -> bool {
        !self.path.is_empty()
    }
}

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum OpGoal {
    /// Take an enemy system.
    Invade,
    /// Free an own system an enemy occupies.
    Liberate,
    /// Drive enemy forces out of (or away from) an own system.
    Defend,
}

/// GOAP facts an operation reasons about.
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum Fact {
    Assembled,
    FleetAtTarget,
    SpaceControl,
    ArmyAtTarget,
    Taken,
}
const NFACT: usize = 5;

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum Step {
    Assemble,
    MoveFleet,
    WinSpace,
    LandArmy,
    TakeGround,
}

struct ActionDef {
    step: Step,
    pre: &'static [Fact],
    eff: Fact,
    cost: u32,
}

const ACTIONS: [ActionDef; 5] = [
    ActionDef { step: Step::Assemble, pre: &[], eff: Fact::Assembled, cost: 1 },
    ActionDef { step: Step::MoveFleet, pre: &[Fact::Assembled], eff: Fact::FleetAtTarget, cost: 1 },
    ActionDef { step: Step::WinSpace, pre: &[Fact::FleetAtTarget], eff: Fact::SpaceControl, cost: 2 },
    ActionDef { step: Step::LandArmy, pre: &[Fact::SpaceControl, Fact::Assembled], eff: Fact::ArmyAtTarget, cost: 1 },
    ActionDef { step: Step::TakeGround, pre: &[Fact::ArmyAtTarget, Fact::SpaceControl], eff: Fact::Taken, cost: 2 },
];

/// Cheapest action chain from `facts` to `goal` (breadth-first over fact sets; tiny state space).
pub fn plan(facts: [bool; NFACT], goal: Fact) -> Option<Vec<Step>> {
    let mut frontier: Vec<([bool; NFACT], Vec<Step>, u32)> = vec![(facts, vec![], 0)];
    let mut best: Option<(Vec<Step>, u32)> = None;
    let mut seen: Vec<[bool; NFACT]> = vec![facts];
    while let Some((f, steps, cost)) = frontier.pop() {
        if f[goal as usize] {
            if best.as_ref().map_or(true, |b| cost < b.1) {
                best = Some((steps, cost));
            }
            continue;
        }
        for a in &ACTIONS {
            if f[a.eff as usize] || !a.pre.iter().all(|p| f[*p as usize]) {
                continue;
            }
            let mut nf = f;
            nf[a.eff as usize] = true;
            if seen.contains(&nf) {
                continue;
            }
            seen.push(nf);
            let mut ns = steps.clone();
            ns.push(a.step);
            frontier.insert(0, (nf, ns, cost + a.cost));
        }
    }
    best.map(|b| b.0)
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Operation {
    pub id: usize,
    pub empire: usize,
    pub war: usize,
    pub goal: OpGoal,
    pub target: usize,
    pub staging: usize,
    pub fleet: Option<usize>,
    pub army: Option<usize>,
    pub steps: Vec<Step>,
    pub start: u32,
    pub step_start: u32,
    /// Once the forces have assembled, the operation is under way (they don't go back to the staging system).
    pub assembled: bool,
}

impl World {
    // ------------------------------------------------------------ Map graph
    /// Jump lanes: each system to its nearest neighbours, then components joined by their closest pairs.
    pub fn build_lanes(&mut self) {
        let n = self.systems.len();
        let mut adj: Vec<Vec<usize>> = vec![vec![]; n];
        for i in 0..n {
            let mut d: Vec<(f64, usize)> = (0..n).filter(|&j| j != i).map(|j| (dist(self.systems[i].pos, self.systems[j].pos), j)).collect();
            d.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap().then(a.1.cmp(&b.1)));
            for &(_, j) in d.iter().take(NEIGHBOURS) {
                if !adj[i].contains(&j) {
                    adj[i].push(j);
                }
                if !adj[j].contains(&i) {
                    adj[j].push(i);
                }
            }
        }
        // Join components.
        loop {
            let mut comp = vec![usize::MAX; n];
            let mut nc = 0;
            for s in 0..n {
                if comp[s] != usize::MAX {
                    continue;
                }
                let mut stack = vec![s];
                comp[s] = nc;
                while let Some(x) = stack.pop() {
                    for &y in &adj[x] {
                        if comp[y] == usize::MAX {
                            comp[y] = nc;
                            stack.push(y);
                        }
                    }
                }
                nc += 1;
            }
            if nc <= 1 {
                break;
            }
            let mut best = (f64::INFINITY, 0, 0);
            for i in 0..n {
                for j in 0..n {
                    if comp[i] == 0 && comp[j] != 0 {
                        let d = dist(self.systems[i].pos, self.systems[j].pos);
                        if d < best.0 {
                            best = (d, i, j);
                        }
                    }
                }
            }
            adj[best.1].push(best.2);
            adj[best.2].push(best.1);
        }
        for a in adj.iter_mut() {
            a.sort_unstable();
        }
        self.jump_lanes = adj;
    }

    /// Shortest route a -> b along jump lanes (excluding a, including b). Empty if a == b.
    pub fn route(&self, a: usize, b: usize) -> Vec<usize> {
        if a == b || self.jump_lanes.is_empty() {
            return vec![];
        }
        let n = self.systems.len();
        let mut d = vec![f64::INFINITY; n];
        let mut prev = vec![usize::MAX; n];
        let mut done = vec![false; n];
        d[a] = 0.0;
        loop {
            let mut u = usize::MAX;
            let mut best = f64::INFINITY;
            for i in 0..n {
                if !done[i] && d[i] < best {
                    best = d[i];
                    u = i;
                }
            }
            if u == usize::MAX || u == b {
                break;
            }
            done[u] = true;
            for &v in &self.jump_lanes[u] {
                let nd = d[u] + dist(self.systems[u].pos, self.systems[v].pos);
                if nd < d[v] {
                    d[v] = nd;
                    prev[v] = u;
                }
            }
        }
        if prev[b] == usize::MAX {
            return vec![];
        }
        let mut path = vec![b];
        let mut x = b;
        while prev[x] != a {
            x = prev[x];
            path.push(x);
        }
        path.reverse();
        path
    }


    // ------------------------------------------------------------ Forces bookkeeping
    fn new_force(&mut self, owner: usize, kind: ForceKind, strength: f64, system: usize) -> usize {
        let id = self.next_force_id;
        self.next_force_id += 1;
        self.forces.push(Force { id, owner, kind, strength, system, path: vec![], progress: 0.0, op: None, patrol: 0 });
        id
    }

    pub fn force_index(&self, id: usize) -> Option<usize> {
        self.forces.iter().position(|f| f.id == id)
    }

    pub fn forces_of(&self, e: usize) -> f64 {
        self.forces.iter().filter(|f| f.owner == e).map(|f| f.strength).sum()
    }

    /// Strength at a system by side (the empires in `side`), optionally of one kind.
    fn local(&self, s: usize, side: &[usize], kind: Option<ForceKind>) -> f64 {
        self.forces.iter().filter(|f| f.system == s && !f.moving() && side.contains(&f.owner) && kind.map_or(true, |k| f.kind == k)).map(|f| f.strength).sum()
    }

    /// Enemy strength at or adjacent to s (what an operation should expect to meet there).
    fn threat_near(&self, s: usize, enemies: &[usize], kind: Option<ForceKind>) -> f64 {
        let mut t = self.local(s, enemies, kind);
        for &n in &self.jump_lanes[s] {
            t += 0.5 * self.local(n, enemies, kind);
        }
        t
    }

    /// Bring forces in line with `strength` (the budget layer): new strength appears at the capital, split between
    /// fleet and army; a shortfall (demobilisation, unpaid upkeep) shrinks every force alike.
    pub fn sync_forces(&mut self, e: usize) {
        if self.systems.is_empty() {
            return;
        }
        let total = self.forces_of(e);
        let want = self.empires[e].strength;
        let cap_sys = match self.colonies[self.empires[e].capital].system {
            Some(s) => s,
            None => return,
        };
        if want > total + 0.01 {
            let add = want - total;
            let fs = FLEET_SHARE * self.empires[e].t(crate::world::TRAIT_MILITARISM).max(0.3) / 0.5;
            let fs = fs.clamp(0.3, 0.7);
            for (kind, amt) in [(ForceKind::Fleet, add * fs), (ForceKind::Army, add * (1.0 - fs))] {
                match self.forces.iter().position(|f| f.owner == e && f.kind == kind && f.system == cap_sys && !f.moving() && f.op.is_none()) {
                    Some(i) => self.forces[i].strength += amt,
                    None => {
                        self.new_force(e, kind, amt, cap_sys);
                    }
                }
            }
        } else if total > want + 0.01 && total > 0.0 {
            let k = want / total;
            for f in self.forces.iter_mut().filter(|f| f.owner == e) {
                f.strength *= k;
            }
        }
    }

    /// Forces of an empire that no longer exists as a power (no capital system) or detachments too small to matter.
    fn tidy_forces(&mut self) {
        // Merge idle forces of one owner and kind in one system.
        let mut i = 0;
        while i < self.forces.len() {
            let f = self.forces[i].clone();
            if f.op.is_none() && !f.moving() {
                if let Some(j) = (i + 1..self.forces.len()).find(|&j| {
                    let g = &self.forces[j];
                    g.owner == f.owner && g.kind == f.kind && g.system == f.system && g.op.is_none() && !g.moving()
                }) {
                    let s = self.forces[j].strength;
                    self.forces[i].strength += s;
                    self.forces.remove(j);
                    continue;
                }
            }
            i += 1;
        }
        // Tiny detachments fold into the owner's biggest force (losses already counted).
        let mut k = 0;
        while k < self.forces.len() {
            if self.forces[k].strength < MIN_FORCE {
                let f = self.forces.remove(k);
                if let Some(big) = (0..self.forces.len()).filter(|&j| self.forces[j].owner == f.owner).max_by(|&a, &b| self.forces[a].strength.partial_cmp(&self.forces[b].strength).unwrap().then(b.cmp(&a))) {
                    self.forces[big].strength += f.strength;
                }
                continue;
            }
            k += 1;
        }
    }

    /// Split `amount` off force i into a new detachment (same place). Returns the new force id.
    fn detach(&mut self, i: usize, amount: f64) -> usize {
        let amount = amount.min(self.forces[i].strength);
        self.forces[i].strength -= amount;
        let (owner, kind, sys) = (self.forces[i].owner, self.forces[i].kind, self.forces[i].system);
        self.new_force(owner, kind, amount, sys)
    }

    fn send(&mut self, fid: usize, to: usize) {
        if let Some(i) = self.force_index(fid) {
            if self.forces[i].system == to && !self.forces[i].moving() {
                return;
            }
            if self.forces[i].path.last() == Some(&to) {
                return;
            }
            // Re-route from where it stands (a force mid-lane finishes the lane first).
            let from = if self.forces[i].moving() { self.forces[i].path[0] } else { self.forces[i].system };
            let mut p = self.route(from, to);
            if self.forces[i].moving() {
                p.insert(0, from);
            } else {
                self.forces[i].progress = 0.0;
            }
            self.forces[i].path = p;
        }
    }

    // ------------------------------------------------------------ Monthly
    pub fn forces_monthly(&mut self) {
        if self.systems.is_empty() || self.empires.len() < 2 {
            return;
        }
        if self.jump_lanes.len() != self.systems.len() {
            self.build_lanes();
        }
        for e in 0..self.empires.len() {
            self.sync_forces(e);
        }
        self.peacetime_moves();
        self.merge_supports();
        self.plan_operations();
        self.run_operations();
        self.move_forces();
        self.battles();
        self.tidy_forces();
        for e in 0..self.empires.len() {
            self.empires[e].strength = self.forces_of(e);
        }
    }

    /// Peacetime: armies garrison the capital and the most exposed systems; fleets patrol border systems. Forces of
    /// an empire at war that aren't in an operation hold where they are.
    fn peacetime_moves(&mut self) {
        for e in 0..self.empires.len() {
            if self.in_any_war(e) {
                continue;
            }
            let own = self.owned_systems(e);
            if own.is_empty() {
                continue;
            }
            let border: Vec<usize> = own.iter().cloned().filter(|&s| self.systems[s].at_front || self.jump_lanes[s].iter().any(|&n| self.systems[n].owner.map_or(false, |o| o != e))).collect();
            let cap_sys = self.colonies[self.empires[e].capital].system.unwrap_or(own[0]);
            let ids: Vec<usize> = self.forces.iter().filter(|f| f.owner == e && f.op.is_none()).map(|f| f.id).collect();
            for fid in ids {
                let i = match self.force_index(fid) {
                    Some(i) => i,
                    None => continue,
                };
                if self.forces[i].moving() {
                    continue;
                }
                let at = self.forces[i].system;
                let foreign = self.systems[at].owner != Some(e);
                match self.forces[i].kind {
                    ForceKind::Fleet => {
                        // Patrol: move to the next border system every few months.
                        if (foreign || self.tick % 6 == (e as u32 % 6)) && !border.is_empty() {
                            let k = (self.forces[i].patrol + 1) % border.len();
                            self.forces[i].patrol = k;
                            let to = border[k];
                            self.send(fid, to);
                        } else if foreign {
                            self.send(fid, cap_sys);
                        }
                    }
                    ForceKind::Army => {
                        if foreign {
                            self.send(fid, cap_sys);
                        } else if at == cap_sys && !border.is_empty() && self.forces[i].strength > 4.0 * MIN_FORCE && self.tick % 12 == (e as u32 % 12) {
                            // Relocation: post a share of the capital garrison to the most exposed border system.
                            let target = border.iter().cloned().max_by(|&a, &b| self.border_pressure(e, a).partial_cmp(&self.border_pressure(e, b)).unwrap().then(b.cmp(&a))).unwrap();
                            let have = self.local(target, &[e], Some(ForceKind::Army));
                            if have < self.forces[i].strength * 0.25 {
                                let d = self.detach(i, self.forces[i].strength * 0.2);
                                self.send(d, target);
                            }
                        }
                    }
                }
            }
        }
    }

    /// How exposed an own system is: foreign neighbours' owners' strength, weighted by threat.
    fn border_pressure(&self, e: usize, s: usize) -> f64 {
        self.jump_lanes[s].iter().filter_map(|&n| self.systems[n].owner).filter(|&o| o != e).map(|o| self.empires[e].threat[o] + 0.1).sum()
    }

    /// War planner: rank goals for each empire at war and open operations for the best ones.
    fn plan_operations(&mut self) {
        // Drop operations whose war ended or whose target is no longer valid.
        let ops = self.ops.clone();
        for op in ops {
            let alive = self.war_index(op.war).is_some();
            let valid = alive
                && match op.goal {
                    OpGoal::Invade => self.systems[op.target].owner.map_or(false, |o| self.at_war(op.empire, o)) && self.systems[op.target].occupier.map_or(true, |o| o == op.empire || self.at_war(op.empire, o)),
                    OpGoal::Liberate => self.systems[op.target].owner == Some(op.empire) && self.systems[op.target].occupier.map_or(false, |o| self.at_war(op.empire, o)),
                    OpGoal::Defend => self.systems[op.target].owner == Some(op.empire),
                };
            // Stale: still assembling long after setting out, with nothing of it on the move any more.
            let tag = |id: Option<usize>| id.map(|x| usize::MAX - x);
            let any_moving = self.forces.iter().any(|f| f.moving() && (f.op == Some(op.id) || f.op == tag(op.fleet) || f.op == tag(op.army)));
            let assembled = alive && self.op_facts(&op, &self.enemies_of(op.empire))[Fact::Assembled as usize];
            let stale = !assembled && self.tick - op.step_start > ASSEMBLE_MONTHS && !any_moving;
            if stale && std::env::var("OPDEBUG").is_ok() {
                let desc: Vec<String> = self.forces.iter().filter(|f| f.op == Some(op.id) || f.op == tag(op.fleet) || f.op == tag(op.army)).map(|f| format!("{:?}#{} at {} path {:?} str {:.0} op {:?}", f.kind, f.id, f.system, f.path, f.strength, f.op.map(|x| if x > usize::MAX / 2 { -((usize::MAX - x) as i64) - 1 } else { x as i64 }))).collect();
                eprintln!("STALE op {} staging {} target {} fleet {:?} army {:?}: {}", op.id, op.staging, op.target, op.fleet, op.army, desc.join(" | "));
            }
            if !valid || stale {
                self.end_op(op.id, if stale { "could not assemble" } else { "" });
            }
        }
        for e in 0..self.empires.len() {
            if !self.in_any_war(e) {
                continue;
            }
            let enemies = self.enemies_of(e);
            let war = match self.wars.iter().find(|w| w.side_of(e).is_some()) {
                Some(w) => w.id,
                None => continue,
            };
            let mut goals: Vec<(f64, OpGoal, usize)> = vec![];
            let own = self.owned_systems(e);
            let cap_sys = self.colonies[self.empires[e].capital].system;
            for &s in &own {
                if let Some(o) = self.systems[s].occupier {
                    if enemies.contains(&o) {
                        goals.push((3.0 + if Some(s) == cap_sys { 3.0 } else { 0.0 }, OpGoal::Liberate, s));
                        continue;
                    }
                }
                let t = self.threat_near(s, &enemies, None);
                if t > 0.0 && self.local(s, &enemies, None) > 0.0 {
                    goals.push((2.5 + if Some(s) == cap_sys { 3.0 } else { 0.0 }, OpGoal::Defend, s));
                }
            }
            for s in 0..self.systems.len() {
                let owner = match self.systems[s].owner {
                    Some(o) if enemies.contains(&o) => o,
                    _ => continue,
                };
                if self.systems[s].occupier.is_some() {
                    continue;
                }
                if self.systems[s].bodies.contains(&self.empires[owner].capital) {
                    continue; // capitals fall through treaties, not invasion
                }
                // Reachable: adjacent to a system we own or occupy.
                let near_ours = self.jump_lanes[s].iter().any(|&n| self.systems[n].owner == Some(e) && self.systems[n].occupier.is_none() || self.systems[n].occupier == Some(e));
                if !near_ours {
                    continue;
                }
                let goal_bonus = if self.wars.iter().any(|w| w.side_of(e) == Some(0) && w.goals.iter().any(|g| g.system == Some(s))) { 1.0 } else { 0.0 };
                let value = 1.0 + goal_bonus + self.systems[s].bodies.iter().filter(|&&c| self.colonies[c].settled).count() as f64 * 0.2;
                goals.push((value, OpGoal::Invade, s));
            }
            goals.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap().then(a.2.cmp(&b.2)));
            for (_, goal, target) in goals {
                if self.ops.iter().filter(|o| o.empire == e).count() >= MAX_OPS {
                    break;
                }
                if self.ops.iter().any(|o| o.empire == e && o.target == target) {
                    continue;
                }
                self.open_op(e, war, goal, target, &enemies);
            }
        }
    }

    /// Open an operation if enough idle force can be found: pick a staging system (own, nearest the target), detach
    /// what the target needs from idle forces, and plan the steps.
    fn open_op(&mut self, e: usize, war: usize, goal: OpGoal, target: usize, enemies: &[usize]) {
        let own = self.owned_systems(e);
        let staging = if goal == OpGoal::Invade {
            match own.iter().cloned().filter(|&s| self.systems[s].occupier.is_none() && self.jump_lanes[s].contains(&target)).min_by(|&a, &b| {
                dist(self.systems[a].pos, self.systems[target].pos).partial_cmp(&dist(self.systems[b].pos, self.systems[target].pos)).unwrap().then(a.cmp(&b))
            }) {
                Some(s) => s,
                None => match self.systems.iter().position(|s| s.occupier == Some(e) && self.jump_lanes[s.id].contains(&target)) {
                    Some(s) => s,
                    None => return,
                },
            }
        } else {
            target
        };
        let ratio = OP_SUPERIORITY * crate::personality::attack_ratio(self, e) / 1.3;
        // At least a fifth of the empire's fleet: token detachments achieve nothing.
        let own_fleet: f64 = self.forces.iter().filter(|f| f.owner == e && f.kind == ForceKind::Fleet).map(|f| f.strength).sum();
        let fleet_need = (self.threat_near(target, enemies, Some(ForceKind::Fleet)) * ratio).max(own_fleet * 0.2).max(1.0);
        let ground = match goal {
            OpGoal::Invade => SYSTEM_DEFENCE + self.system_pop(target) * DEFENCE_PER_POP + self.local(target, enemies, Some(ForceKind::Army)),
            OpGoal::Liberate => self.local(target, enemies, Some(ForceKind::Army)) + 1.0,
            OpGoal::Defend => 0.0,
        };
        let army_need = ground * ratio;
        let fleet = self.gather(e, ForceKind::Fleet, fleet_need, staging);
        let fleet = match fleet {
            Some(f) => f,
            None => return,
        };
        let army = if army_need > 0.0 {
            match self.gather(e, ForceKind::Army, army_need, staging) {
                Some(a) => Some(a),
                None => {
                    // Not enough troops: release everything gathered for it.
                    self.clear_provisional(e);
                    return;
                }
            }
        } else {
            None
        };
        let goal_fact = match goal {
            OpGoal::Defend => Fact::SpaceControl,
            _ => Fact::Taken,
        };
        let steps = match plan([false; NFACT], goal_fact) {
            Some(s) => s,
            None => {
                self.clear_provisional(e);
                return;
            }
        };
        let id = self.next_op_id;
        self.next_op_id += 1;
        for fid in [Some(fleet), army].into_iter().flatten() {
            if let Some(i) = self.force_index(fid) {
                self.forces[i].op = Some(id);
            }
            self.send(fid, staging);
        }
        // Support detachments stay tagged with their carrier (usize::MAX - carrier id) and merge on arrival.
        let what = match goal {
            OpGoal::Invade => "invade",
            OpGoal::Liberate => "liberate",
            OpGoal::Defend => "defend",
        };
        let t = format!("OPERATION: {} moves to {} {} ({:.0} ships, {:.0} troops)", self.empires[e].name, what, self.systems[target].name, self.force_index(fleet).map_or(0.0, |i| self.forces[i].strength), army.and_then(|a| self.force_index(a)).map_or(0.0, |i| self.forces[i].strength));
        self.event(t);
        self.ops.push(Operation { id, empire: e, war, goal, target, staging, fleet: Some(fleet), army, steps, start: self.tick, step_start: self.tick, assembled: false });
    }

    /// Undo provisional tags from a failed gather (the detachments simply become idle forces again).
    fn clear_provisional(&mut self, e: usize) {
        for f in self.forces.iter_mut() {
            if f.owner == e && f.op.map_or(false, |t| t > usize::MAX / 2) {
                f.op = None;
            }
        }
    }

    fn system_pop(&self, s: usize) -> f64 {
        self.systems[s].bodies.iter().map(|&c| self.colonies[c].pop).sum()
    }

    /// Detach `need` of idle strength of a kind (nearest forces first, keeping a home guard at the capital).
    /// Returns the id of a force (at one of the source systems) that will carry it, or None if there isn't enough.
    fn gather(&mut self, e: usize, kind: ForceKind, need: f64, staging: usize) -> Option<usize> {
        let cap_sys = self.colonies[self.empires[e].capital].system;
        let mut idle: Vec<(f64, usize)> = self
            .forces
            .iter()
            .filter(|f| f.owner == e && f.kind == kind && f.op.is_none() && !f.moving())
            .map(|f| (dist(self.systems[f.system].pos, self.systems[staging].pos), f.id))
            .collect();
        idle.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap().then(a.1.cmp(&b.1)));
        let avail: f64 = idle.iter().map(|&(_, id)| {
            let f = &self.forces[self.force_index(id).unwrap()];
            if Some(f.system) == cap_sys { f.strength * 0.7 } else { f.strength }
        }).sum();
        if avail < need {
            return None;
        }
        let mut left = need;
        let mut carrier: Option<usize> = None;
        for (_, id) in idle {
            if left <= 0.0 {
                break;
            }
            let i = self.force_index(id).unwrap();
            let usable = if Some(self.forces[i].system) == cap_sys { self.forces[i].strength * 0.7 } else { self.forces[i].strength };
            let take = usable.min(left);
            left -= take;
            let d = if take >= self.forces[i].strength - 1e-9 { id } else { self.detach(i, take) };
            match carrier {
                None => carrier = Some(d),
                Some(c) => {
                    // Extra detachments join the carrier at the staging system: mark them with the same pending op
                    // (via a provisional tag of usize::MAX) and send them along; they merge on arrival.
                    if let Some(j) = self.force_index(d) {
                        self.forces[j].op = Some(usize::MAX - c);
                    }
                    self.send(d, staging);
                }
            }
        }
        if let Some(c) = carrier {
            if let Some(i) = self.force_index(c) {
                self.forces[i].op = Some(usize::MAX); // provisional until the operation is created
            }
        }
        carrier
    }

    fn end_op(&mut self, id: usize, why: &str) {
        let op = match self.ops.iter().position(|o| o.id == id) {
            Some(i) => self.ops.remove(i),
            None => return,
        };
        for f in self.forces.iter_mut() {
            if f.op == Some(id) {
                f.op = None;
            }
        }
        if !why.is_empty() {
            let t = format!("{}'s operation against {} ends: {}", self.empires[op.empire].name, self.systems[op.target].name, why);
            self.event(t);
        }
    }

    fn op_force(&self, fid: Option<usize>) -> Option<&Force> {
        fid.and_then(|f| self.force_index(f)).map(|i| &self.forces[i])
    }

    /// Facts as they stand for an operation.
    fn op_facts(&self, op: &Operation, enemies: &[usize]) -> [bool; NFACT] {
        let fleet = self.op_force(op.fleet);
        let army = self.op_force(op.army);
        let at = |f: Option<&Force>, s: usize| f.map_or(false, |f| f.system == s && !f.moving());
        let support_here = self.forces.iter().filter(|f| f.op == Some(usize::MAX - op.fleet.unwrap_or(usize::MAX)) || f.op == Some(usize::MAX - op.army.unwrap_or(usize::MAX))).count() == 0;
        let assembled = at(fleet, op.staging) && (op.army.is_none() || at(army, op.staging)) && support_here;
        let fleet_at = at(fleet, op.target);
        let space = self.local(op.target, enemies, Some(ForceKind::Fleet)) <= 0.0 && fleet_at;
        let army_at = at(army, op.target);
        let taken = match op.goal {
            OpGoal::Invade => self.systems[op.target].occupier == Some(op.empire),
            OpGoal::Liberate => self.systems[op.target].occupier.is_none(),
            OpGoal::Defend => space,
        };
        let mut f = [false; NFACT];
        f[Fact::Assembled as usize] = op.assembled || assembled || fleet_at || army_at;
        f[Fact::FleetAtTarget as usize] = fleet_at;
        f[Fact::SpaceControl as usize] = space;
        f[Fact::ArmyAtTarget as usize] = army_at;
        f[Fact::Taken as usize] = taken;
        f
    }

    /// Support detachments that reached their carrier's system merge into it.
    fn merge_supports(&mut self) {
        // Support detachments reaching their carrier's system merge into it.
        let mut k = 0;
        while k < self.forces.len() {
            let f = self.forces[k].clone();
            if let Some(tag) = f.op {
                if tag > usize::MAX / 2 && tag != usize::MAX && !f.moving() {
                    let carrier = usize::MAX - tag;
                    match self.force_index(carrier) {
                        Some(c) if self.forces[c].system == f.system && !self.forces[c].moving() => {
                            self.forces[c].strength += f.strength;
                            self.forces.remove(k);
                            continue;
                        }
                        Some(c) if self.forces[c].op.is_none() => self.forces[k].op = None,
                        None => self.forces[k].op = None,
                        _ => {}
                    }
                }
            }
            k += 1;
        }
    }

    fn run_operations(&mut self) {
        let ids: Vec<usize> = self.ops.iter().map(|o| o.id).collect();
        for id in ids {
            let oi = match self.ops.iter().position(|o| o.id == id) {
                Some(i) => i,
                None => continue,
            };
            let op = self.ops[oi].clone();
            let enemies = self.enemies_of(op.empire);
            if self.op_force(op.fleet).is_none() && self.op_force(op.army).is_none() {
                self.end_op(id, "its forces were destroyed");
                continue;
            }
            let goal_fact = if op.goal == OpGoal::Defend { Fact::SpaceControl } else { Fact::Taken };
            let facts = self.op_facts(&op, &enemies);
            if facts[Fact::Assembled as usize] {
                self.ops[oi].assembled = true;
            }
            if facts[goal_fact as usize] {
                let done = match op.goal {
                    OpGoal::Invade => "system taken",
                    OpGoal::Liberate => "system liberated",
                    OpGoal::Defend => "enemy driven off",
                };
                // Leave the army as garrison; the fleet returns to the pool.
                self.end_op(id, done);
                continue;
            }
            // Replan from the current facts (handles setbacks: fleet beaten, army lost...).
            let steps = match plan(facts, goal_fact) {
                Some(s) if !s.is_empty() => s,
                _ => {
                    self.end_op(id, "no way to reach its goal");
                    continue;
                }
            };
            if std::env::var("OPDEBUG").is_ok() && self.tick % 12 == 0 {
                let fl = self.op_force(op.fleet).map(|f| (f.system, f.path.clone(), f.strength as i64));
                let ar = self.op_force(op.army).map(|f| (f.system, f.path.clone(), f.strength as i64));
                eprintln!("t{} op {} e{} {:?} target {} staging {} steps {:?} facts {:?} fleet {:?} army {:?}", self.tick, op.id, op.empire, op.goal, op.target, op.staging, steps, facts, fl, ar);
            }
            if self.ops[oi].steps.first() != steps.first() {
                self.ops[oi].step_start = self.tick;
            }
            self.ops[oi].steps = steps.clone();
            // A force missing for a step the plan needs ends the operation.
            match steps[0] {
                Step::Assemble => {
                    for fid in [op.fleet, op.army].into_iter().flatten() {
                        self.send(fid, op.staging);
                    }
                }
                Step::MoveFleet | Step::WinSpace => {
                    match op.fleet {
                        Some(f) if self.force_index(f).is_some() => self.send(f, op.target),
                        _ => {
                            self.end_op(id, "its fleet was destroyed");
                            continue;
                        }
                    }
                    // Abort if the fleet is now clearly outmatched at the target.
                    let mine = self.op_force(op.fleet).map_or(0.0, |f| f.strength);
                    let theirs = self.threat_near(op.target, &enemies, Some(ForceKind::Fleet));
                    if theirs > mine * 1.6 && self.tick - self.ops[oi].step_start > 1 {
                        self.end_op(id, "the enemy fleet is too strong");
                        continue;
                    }
                }
                Step::LandArmy | Step::TakeGround => match op.army {
                    Some(a) if self.force_index(a).is_some() => self.send(a, op.target),
                    _ => {
                        self.end_op(id, "its army was destroyed");
                        continue;
                    }
                },
            }
        }
    }

    /// Advance moving forces along their routes. Armies don't enter a system held by an enemy fleet unless a friendly
    /// fleet is there too (they wait at the previous system).
    fn move_forces(&mut self) {
        for i in 0..self.forces.len() {
            if !self.forces[i].moving() {
                continue;
            }
            let mut budget = SPEED;
            while budget > 0.0 && !self.forces[i].path.is_empty() {
                let next = self.forces[i].path[0];
                let here = self.forces[i].system;
                if self.forces[i].kind == ForceKind::Army {
                    let e = self.forces[i].owner;
                    let enemies = self.enemies_of(e);
                    let mut friends = vec![e];
                    if let Some(w) = self.wars.iter().find(|w| w.side_of(e).is_some()) {
                        friends = w.sides[w.side_of(e).unwrap()].clone();
                    }
                    if self.local(next, &enemies, Some(ForceKind::Fleet)) > 0.0 && self.local(next, &friends, Some(ForceKind::Fleet)) <= 0.0 {
                        break; // wait for the escort
                    }
                }
                let leg = dist(self.systems[here].pos, self.systems[next].pos);
                let need = leg - self.forces[i].progress;
                if budget >= need {
                    budget -= need;
                    self.forces[i].system = next;
                    self.forces[i].path.remove(0);
                    self.forces[i].progress = 0.0;
                } else {
                    self.forces[i].progress += budget;
                    budget = 0.0;
                }
            }
        }
    }

    /// Battles: in every system with hostile forces, fleets fight; then armies fight for the ground, and the
    /// system changes hands when the attackers hold space and the defenders' ground forces are gone.
    fn battles(&mut self) {
        let mut sys: Vec<usize> = self.forces.iter().filter(|f| !f.moving()).map(|f| f.system).collect();
        sys.sort_unstable();
        sys.dedup();
        for s in sys {
            let here: Vec<usize> = (0..self.forces.len()).filter(|&i| self.forces[i].system == s && !self.forces[i].moving()).collect();
            // Wars present here: pairs of hostile owners.
            let owners: Vec<usize> = {
                let mut o: Vec<usize> = here.iter().map(|&i| self.forces[i].owner).collect();
                o.sort_unstable();
                o.dedup();
                o
            };
            let war = self.wars.iter().find(|w| owners.iter().any(|&a| w.side_of(a) == Some(0)) && owners.iter().any(|&b| w.side_of(b) == Some(1))).cloned();
            let w = match war {
                Some(w) => w,
                None => continue,
            };
            let holder = self.systems[s].occupier.or(self.systems[s].owner);
            let def_side = holder.and_then(|h| w.side_of(h));
            let strike = (self.tick as i64) < w.first_strike_until;
            // Space battle.
            let fleet = |side: usize, me: &World| -> f64 { here.iter().filter(|&&i| me.forces[i].kind == ForceKind::Fleet && w.sides[side].contains(&me.forces[i].owner)).map(|&i| me.forces[i].strength).sum() };
            let (f0, f1) = (fleet(0, self), fleet(1, self));
            if f0 > 0.0 && f1 > 0.0 {
                let mult = |side: usize| (if def_side == Some(side) { DEFENDER_BONUS } else { 1.0 }) * (if strike && side == 0 { STRIKE_BONUS } else { 1.0 });
                let loss = [BATTLE_RATE * f1 * mult(1), BATTLE_RATE * f0 * mult(0)];
                let t = format!("BATTLE at {}: {} fleets {:.0} vs {} fleets {:.0}", self.systems[s].name, self.empires[w.leader(0)].name, f0, self.empires[w.leader(1)].name, f1);
                if self.tick % 3 == 0 {
                    self.event(t);
                }
                self.apply_losses(&here, &w, ForceKind::Fleet, [f0, f1], loss);
            }
            // Ground battle: attackers are the side that doesn't hold the system; it needs space control.
            let att = match def_side {
                Some(d) => 1 - d,
                None => continue,
            };
            let (fa, fd) = (fleet(att, self), fleet(1 - att, self));
            let army = |side: usize, me: &World| -> f64 { here.iter().filter(|&&i| me.forces.get(i).map_or(false, |f| f.kind == ForceKind::Army && w.sides[side].contains(&f.owner))).map(|&i| me.forces[i].strength).sum() };
            let a_att = army(att, self);
            if a_att <= 0.0 || fd > 0.0 || fa <= 0.0 && fd > 0.0 {
                continue;
            }
            let own_holder = self.systems[s].owner;
            let liberating = self.systems[s].occupier.is_some() && own_holder.map_or(false, |o| w.sides[att].contains(&o));
            let defence = if liberating { 0.0 } else { SYSTEM_DEFENCE + self.system_pop(s) * DEFENCE_PER_POP };
            let a_def = army(1 - att, self) + defence;
            let mut loss = [0.0; 2];
            loss[att] = BATTLE_RATE * a_def * DEFENDER_BONUS;
            loss[1 - att] = BATTLE_RATE * a_att * if strike && att == 0 { STRIKE_BONUS } else { 1.0 };
            // Fixed defences absorb losses before garrisons do.
            let garrison = army(1 - att, self);
            let mut sides_loss_real = loss;
            if garrison <= 0.0 {
                sides_loss_real[1 - att] = 0.0;
            }
            self.apply_losses(&here, &w, ForceKind::Army, [army(0, self), army(1, self)], sides_loss_real);
            // The ground falls when the remaining defence (garrison + fixed defences worn down) is overwhelmed.
            let worn = (a_def - loss[1 - att]).max(0.0);
            let left_att = army(att, self);
            if left_att > worn * 1.5 || (army(1 - att, self) <= 0.0 && left_att > defence * 0.8) {
                let leader = here.iter().filter(|&&i| self.forces.get(i).map_or(false, |f| f.kind == ForceKind::Army && w.sides[att].contains(&f.owner))).map(|&i| self.forces[i].owner).next();
                if let Some(taker) = leader {
                    self.change_hands(s, taker, liberating);
                }
            }
        }
    }

    /// Spread side losses over that side's forces of a kind at a system, and charge war exhaustion.
    fn apply_losses(&mut self, here: &[usize], w: &crate::military::War, kind: ForceKind, totals: [f64; 2], loss: [f64; 2]) {
        for side in 0..2 {
            if totals[side] <= 0.0 {
                continue;
            }
            for &i in here {
                if i >= self.forces.len() {
                    continue;
                }
                let f = &self.forces[i];
                if f.kind != kind || !w.sides[side].contains(&f.owner) {
                    continue;
                }
                let l = (loss[side] * f.strength / totals[side]).min(f.strength);
                let owner = f.owner;
                self.forces[i].strength -= l;
                if let Some(wi) = self.war_index(w.id) {
                    let pk = self.wars[wi].peak[owner].max(self.empires[owner].strength);
                    self.wars[wi].peak[owner] = pk;
                    self.empires[owner].exhaustion += crate::military::EXH_LOSS_WEIGHT * l / pk.max(1.0);
                }
            }
        }
    }

    fn change_hands(&mut self, s: usize, taker: usize, liberating: bool) {
        if liberating {
            let (owner, occ) = (self.systems[s].owner.unwrap(), self.systems[s].occupier.unwrap());
            self.systems[s].occupier = None;
            let t = format!("{} liberates {} from {}", self.empires[owner].name, self.systems[s].name, self.empires[occ].name);
            self.event(t);
        } else {
            let l = self.systems[s].owner.unwrap();
            self.systems[s].occupier = Some(taker);
            self.empires[l].exhaustion += crate::military::EXH_PER_OCCUPIED;
            let t = format!("{} occupies {} ({})", self.empires[taker].name, self.systems[s].name, self.empires[l].name);
            self.event(t);
        }
        self.on_system_claimed();
    }

    /// After a peace: operations of the two sides end; their forces in foreign territory head home.
    pub fn forces_after_peace(&mut self, war_id: usize) {
        let ids: Vec<usize> = self.ops.iter().filter(|o| o.war == war_id).map(|o| o.id).collect();
        for id in ids {
            self.end_op(id, "");
        }
    }
}
