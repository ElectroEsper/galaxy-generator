//! PCG32 random numbers (same family as Godot's), plus the helpers the sim uses.

#[derive(serde::Serialize, serde::Deserialize, Clone)]
pub struct Rng {
    state: u64,
    inc: u64,
}

impl Rng {
    pub fn new(seed: u64) -> Self {
        let mut r = Rng { state: 0, inc: (0xda3e_39cb_94b9_5bdb_u64 << 1) | 1 };
        r.next_u32();
        r.state = r.state.wrapping_add(seed);
        r.next_u32();
        r
    }

    pub fn next_u32(&mut self) -> u32 {
        let old = self.state;
        self.state = old.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(self.inc);
        let xs = (((old >> 18) ^ old) >> 27) as u32;
        let rot = (old >> 59) as u32;
        xs.rotate_right(rot)
    }

    /// Uniform in [0, 1).
    pub fn randf(&mut self) -> f64 {
        self.next_u32() as f64 / 4_294_967_296.0
    }

    pub fn range(&mut self, a: f64, b: f64) -> f64 {
        a + (b - a) * self.randf()
    }

    /// Uniform integer in [a, b].
    pub fn int_range(&mut self, a: i64, b: i64) -> i64 {
        if b <= a {
            return a;
        }
        a + (self.next_u32() as i64 % (b - a + 1))
    }

    /// Uniform index in [0, n).
    pub fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            0
        } else {
            self.next_u32() as usize % n
        }
    }

    /// Normal distribution (Box-Muller).
    pub fn normal(&mut self, mean: f64, sd: f64) -> f64 {
        let u1 = self.randf().max(1e-12);
        let u2 = self.randf();
        mean + sd * (-2.0 * u1.ln()).sqrt() * (std::f64::consts::TAU * u2).cos()
    }

    pub fn shuffle<T>(&mut self, v: &mut [T]) {
        for i in (1..v.len()).rev() {
            let j = self.below(i + 1);
            v.swap(i, j);
        }
    }
}
