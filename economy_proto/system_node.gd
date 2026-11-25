class_name SystemNode
extends RefCounted
## A star system as the map sees it: one node with a position; its planets, giants and belts are colonies/frontier inside it.

var name : String
var position : Vector2
var star_class : String = ""
var bodies : Array = []        # ColonyMarket, settled or not
var known : bool = true        # charted by anyone (for the view); each Empire keeps its own map
var owner = null               # Empire that settled here first (owns the whole system)

func _init(n : String, pos : Vector2) -> void:
	name = n; position = pos

func settled_bodies() -> Array:
	return bodies.filter(func(c): return c.settled)

func population() -> float:
	var p : float = 0.0
	for c in bodies:
		if c.settled: p += c.pop
	return p

func surveyed_count() -> int:
	return bodies.filter(func(c): return c.surveys > 0).size()
