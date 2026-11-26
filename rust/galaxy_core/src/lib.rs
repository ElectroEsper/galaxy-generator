//! Galaxy economy simulation core: a Rust port of the GDScript prototype in `economy_proto/`.
//! See `docs/rust_port.md` for the design. No Godot types here; `galaxy_cli` runs it headless.

pub mod rng;
pub use galaxy_goods as goods;
pub mod astro;
pub mod market;
pub mod corp;
pub mod world;
pub mod metrics;
pub mod military;
pub mod personality;
pub mod threat;
pub mod alliances;
pub mod treaties;
pub mod diplomacy;
pub mod snapshot;
pub mod plays;
pub mod forces;
pub mod forecast;
pub mod telemetry;

pub use world::{Config, World};
