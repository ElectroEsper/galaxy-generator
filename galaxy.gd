class_name Galaxy
extends Node

@export var star_amount : int = 500

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	seed(123)
	
	var star_cnt : int = 0
	
	while star_cnt < star_amount:
		var ss = Star.new()
		ss.init_solar_system()
		add_child(ss)
		star_cnt += 1
	
	#Universe.print_universe_stats(Universe.data)


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
