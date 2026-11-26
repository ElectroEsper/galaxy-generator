# Godot front end (Rust-driven)

The simulation runs in Rust (`rust/`, see `docs/rust_port.md`) and is loaded through the `galaxy_gd` GDExtension
(`galaxy.gdextension`). This folder holds only the Godot side:

- `main_menu.tscn/.gd`: the main scene. Galaxy settings, the personality editor (trait blocks, personalities, rules),
  and the saved-games list.
- `game_setup.gd`: hand-off between the menu and the map view (settings or save to load; personality file path).
- `rust_view.tscn/.gd` + `territory.gdshader`: the map view. Territories, wars, pacts, fleets and armies, with a
  top bar (date, pause and speed, toggles, save/load, help, menu), a clickable empire list, empire and system
  panels, and a filterable event log. Mouse wheel zooms toward the cursor, drag or WASD pans, Home fits the
  galaxy, Space pauses, 1-5 and [ ] set speed, H shows all controls and the map legend.
- `test_menu_save.gd`, `test_rust_sim.gd`: headless checks (`godot --headless --script res://economy_proto/<file>`).
- `shot_rust_view.gd`: screenshot script.

The original GDScript prototype (economy, diplomacy, war, galaxy generator) and its result charts live on the
`archive/shadow-realm` branch.
