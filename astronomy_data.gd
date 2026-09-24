extends Node

enum StarPop {POP1, POP1i, POP2, POP2i}
enum StarClass { O, B, A, F, G, K, M}
enum PlanetType {NORMAL, GAS_GIANT, ICE_GIANT, ASTEROID_BELT}

const DATABASE : Dictionary = {
	StarPopulation = {
		StarPop.POP1 : {
			metalicity = 3.0,
			age_min = 0.1,
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
		base_oxygen_threshold = 0.5,
		alpha_enhancement_coeff = 0.4,
		life_possible_threshold = 0.7,
		biosphere_mature_threshold = 3.5,
		base_volatile_threshold = 0.6,
		volatile_line_multiplier = 2.0
	}
}
