//! Galaxy economy simulation core: a Rust port of the GDScript prototype in `economy_proto/`.
//! See `docs/rust_port.md` for the design. No Godot types here; `galaxy_cli` runs it headless.

pub mod rng;
pub use galaxy_goods as goods;
pub mod astro;
pub mod market;
pub mod corp;
pub mod world;
pub mod metrics;

pub use world::{Config, World};
