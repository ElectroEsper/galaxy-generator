class_name Empire
extends RefCounted
## One space-faring state: its capital, colonies, treasury, colonial office, survey programme and its own map of known space.
## Corporations belong to an empire (taxed there) but may trade and build in any colony; the first empire to settle a body
## in a star system owns that whole system.

var id : int
var name : String
var color : Color
var capital : ColonyMarket = null
# Finances and state programmes
var treasury : float = 0.0
var tax_collected : float = 0.0
var state_colonies : int = 0
var state_spent : float = 0.0
var survey_backlog : int = 0
var surveys_ordered : int = 0
var sector_events : int = 0
var settlements : int = 0
var customs_collected : float = 0.0
var refusals : Dictionary = {}       # other empire id -> year it last refused a proposal (diplomacy cooldown)
# Known space: systems this empire has charted (SystemNode -> true)
var known : Dictionary = {}

# Per-month caches (cleared by the sim at the start of each tick and whenever a colony is founded)
var near_cache : Dictionary = {}
var donor_cache : Dictionary = {}
var cand_cache : Array = []
var cand_valid : bool = false
var ob_cache : Array = []
var ob_valid : bool = false
var known_frontier_cache : Array = []
var known_valid : bool = false
var survey_board : Array = []
var survey_board_valid : bool = false

func _init(i : int, n : String, col : Color) -> void:
	id = i; name = n; color = col

func clear_caches() -> void:
	near_cache.clear(); donor_cache.clear()
	cand_valid = false; ob_valid = false; survey_board_valid = false

func knows(sys) -> bool:
	return sys == null or known.has(sys)

func is_known(c : ColonyMarket) -> bool:
	return c.system == null or known.has(c.system)

## May this empire survey/settle this body? (charted, and its system isn't another empire's territory)
func may_enter(c : ColonyMarket) -> bool:
	if not is_known(c):
		return false
	return c.system == null or c.system.owner == null or c.system.owner == self
