# Rust simulation

The economy and politics simulation, ported from `economy_proto/` (GDScript). See `docs/rust_port.md` for the design.

| Crate | What it is |
|---|---|
| `galaxy_goods` | Every goods table: goods, raw costs, recipes, consumption, maintenance, construction and military materials. **Edit here to change goods.** |
| `galaxy_core` | The simulation: galaxy generation, markets, corporations, colonization, relations, war, diplomacy, personality, threat, alliances, treaties. |
| `galaxy_cli` | Headless runner, same arguments and CSV output as `run_headless_csv.gd`. |
| `galaxy_gd` | Godot 4.7 extension: `GalaxySim` node, runs the sim on its own thread. |

```sh
cd rust
cargo build --release                       # everything, including the Godot library
./target/release/galaxy_cli growth=1 colonize=1 systems=46 empires=4 planets=100 ticks=2160 seed=7
```

In Godot: build `galaxy_gd`, then run `economy_proto/rust_view.tscn` (the project's `galaxy.gdextension` points at
`rust/target/release/`). On Windows build on Windows (`galaxy_gd.dll`).
Headless check: `godot --headless --path . --script res://economy_proto/test_rust_sim.gd`.

Speed: 46 systems, 4 empires, 180 years in about 4 s; 1,000 systems, 8 empires, 500 years in about 110 s.
