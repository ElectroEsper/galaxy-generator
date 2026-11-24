class_name Goods
extends RefCounted
## Minimal goods graph for the prototype. Tier = 1 + max(input tiers).

const ORE := 0
const METAL := 1
const PARTS := 2
const FOOD := 3
const ALL : Array[int] = [ORE, METAL, PARTS, FOOD]

const RAW_COST : Dictionary = {ORE: 1.5, FOOD: 1.5}          # extraction cost / unit
const RECIPES : Dictionary = {                                 # out: {inputs, yield}
	METAL: {"in": {ORE: 2.0}, "yield": 1.0},
	PARTS: {"in": {METAL: 2.0}, "yield": 1.0},
}

static func is_raw(g : int) -> bool:
	return RAW_COST.has(g)
