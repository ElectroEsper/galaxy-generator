> **Note (2026-11-26):** parts of this document describe the original GDScript prototype, which now lives on the `archive/shadow-realm` branch. The current design is in `docs/rust_port.md`.

# Galaxy Generator – Design Notes

## Pipeline
Population (POP1/1i/2/2i) -> metallicity + age -> star class (min metallicity gate) -> L, mass,
frostline = 4.85*sqrt(L), volatile line = 2*frostline, HZ = sqrt(L/1.1)..sqrt(L/0.53),
min_orbit = 0.1*sqrt(L), max_orbit = 73*sqrt(mass). Slots placed geometrically (x1.4-2.0).

## Planet axes
- Temperature: Cryogenic <100K, Frigid 100-249, Temperate 250-340, Torrid 341-499, Infernal >=500.
- Humidity: formation budget (logistic about the frostline) x oxygen factor; has_water also x atmosphere retention.
- Geological activity: Dead / Dormant / Restrained / Active / Hyper-Active (age_proportion of thermal lifespan).
- Greenhouse: temp_eq * (1 + volcanic + clamp(retention,0,1))^(1/6), regulated by tectonics/water.
- Oxygen threshold per star: base / (1 + alpha * age/10). Volatiles: flat metallicity threshold, line at 2x frostline.
- LifeStage: Sterile / Nascent / Flourishing from water + age + geology favorability.
- Protoplanets: star age < protoplanet_age_threshold -> PROTOPLANETARY_CORE / PROTO_GIANT / DEBRIS_DISK_REMNANT;
  temperature = accretion falloff over (min_orbit..max_orbit) + 10% insolation.

## Tier 0 resources
- Richness: planet-level, fixed 0-10. Grade: per discovery. Pool (TRP) = mass * scale * richness/10.
- Discovery decays with already-found fraction, slower on richer planets (decay = base / richness).
- Renewables use logistic growth with Allee effect; below the collapse floor the resource collapses and
  life_stage is forced to STERILE. Restoration reseeds the pool and prefixes the name with "Restored ".
- Freshwater fraction scales Water richness.

## Open questions
- Should freshwater also gate Edibles/Biomass carrying capacity K?
- Exotic Biomass/Edibles driver (inverse of life maturity proposed).
- Grade vs survey-success relationship.
