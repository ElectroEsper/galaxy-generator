extends Node

enum StarPop {POP1, POP1i, POP2, POP2i}
enum StarClass { O, B, A, F, G, K, M}
enum PlanetType {NORMAL, GAS_GIANT, ICE_GIANT, ASTEROID_BELT}

const DATABASE : Dictionary = {
	StarPopulation = {
		StarPop.POP1 : {
			metalicity = 3.0,
			age_min = 0.01,       # was 0.1: the youngest regions are the only place short-lived O/B stars still shine
			age_max = 6
		},
		StarPop.POP1i : {
			metalicity = 1.6,
			age_min = 4,
			age_max = 8
		},
		StarPop.POP2 : {
			metalicity = 0.8,
			age_min = 8,
			age_max = 11
		},
		StarPop.POP2i : {
			metalicity = 0.3,
			age_min = 10,
			age_max = 13.6
		}
	},
	StarClass = {
		luminosity = {
			StarClass.O : [30000,1000000],
			StarClass.B : [25,30000],
			StarClass.A : [5,25],
			StarClass.F : [1.5,5],
			StarClass.G : [0.6,1.5],
			StarClass.K : [0.08,0.6],
			StarClass.M : [0.0001,0.08]
		},
		mass = {
			StarClass.O : [16,100],
			StarClass.B : [2.1,16],
			StarClass.A : [1.4,2.1],
			StarClass.F : [1.04,1.4],
			StarClass.G : [0.8,1.04],
			StarClass.K : [0.45,0.8],
			StarClass.M : [0.08,0.45]
		},
		minMetalicity = {
			StarClass.O : 1.5,
			StarClass.B : 1.0,
			StarClass.A : 0.5,
			StarClass.F : 0.3,
			StarClass.G : 0.1,
			StarClass.K : 0.001,
			StarClass.M : 0.0
		},
		planetAmount = {
			StarClass.O : [0,1],
			StarClass.B : [0,4],
			StarClass.A : [0,6],
			StarClass.F : [0,6],
			StarClass.G : [0,6],
			StarClass.K : [0,5],
			StarClass.M : [0,4]
		},
		# Main-sequence lifetime, in billions of years (upper end for the class). A star exists only if the system's age is
		# below its class lifetime: old populations have lost their O, B, A and most F stars.
		lifetime = {
			StarClass.O : 0.02,
			StarClass.B : 0.4,
			StarClass.A : 2.0,
			StarClass.F : 5.0,
			StarClass.G : 12.0,
			StarClass.K : 50.0,
			StarClass.M : 1000.0
		},
		# Share of main-sequence stars by class in the real galaxy (by count; Ledrew 2001 / Habets & Heintze 1981).
		# Used as selection weights among the classes a star's metallicity allows, raised to
		# Constants.class_realism (1 = real proportions, 0 = every allowed class equally likely).
		abundance = {
			StarClass.O : 0.0000003,
			StarClass.B : 0.0013,
			StarClass.A : 0.006,
			StarClass.F : 0.03,
			StarClass.G : 0.076,
			StarClass.K : 0.121,
			StarClass.M : 0.765
		},
		chances_of_ring = {
			StarClass.O : 0,
			StarClass.B : 0,
			StarClass.A : 0.00001468385657,
			StarClass.F : 0.000013311850913,
			StarClass.G : 0.00002393793474,
			StarClass.K : 0.000030035689871,
			StarClass.M : 0.00008205075889
		},
		chances_of_belt = {
			StarClass.O : 0.0006719907195,
			StarClass.B : 0.0322976571,
			StarClass.A : 0.1506053137,
			StarClass.F : 0.1949963549,
			StarClass.G : 0.3728827676,
			StarClass.K : 0.3337703011,
			StarClass.M : 0.2536990917
		}
	},
	Constants = {
		# Star class mix: 1.0 = real galaxy (~77% M, almost no O/B), 0.5 = game mix (~49% M, ~2% B, a rare O), 0 = uniform
		class_realism = 0.5,
		base_oxygen_threshold = 0.5,
		alpha_enhancement_coeff = 0.4,
		life_possible_threshold = 0.7,
		biosphere_mature_threshold = 3.5,
		base_volatile_threshold = 0.6,
		volatile_line_multiplier = 2.0,
		# Protoplanets (young systems)
		protoplanet_age_threshold = 0.3,
		protoplanet_temp_max = 1500.0,
		protoplanet_temp_min = 400.0,
		protoplanet_falloff_rate = 3.5,
		protoplanet_insolation_weight = 0.1,
		# Exotic / radiogenic resource gating
		r_process_reference = 2.5,
		exotic_ore_deviation_threshold = 0.16,
		exotic_ore_deviation_range = 0.04,
		exotic_tidal_threshold = 0.6,
		exotic_thermal_gh_threshold = 100.0,
		radiogenic_threshold = 1.2,
		ore_threshold = 2.0,
		# Resource pools / discovery
		base_decay_rate = 8.0,
		discovery_yield_factor = 0.15,
		allee_fraction = 0.15,
		collapse_floor_fraction = 0.01
	}
}
