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
# Military (see military.gd)
var strength : float = 0.0
var exhaustion : float = 0.0
var month_tax : float = 0.0
var avg_tax : float = 0.0             # smoothed monthly tax income (sets the army target)
var target_strength : float = 0.0
# Threat (see threat.gd): other empire id -> score; track record others judge us by
var threat : Dictionary = {}
var max_threat : float = 0.0
var main_threat : int = -1
var wars_started : Array = []         # years
var systems_taken : int = 0
var guarantees : Array = []          # ids of empires this one has promised to protect (alliances.gd)
var sys_history : Array = []          # systems owned, one entry per year          # taxes collected this month (the military budget is a share of it)
var mil_spent : float = 0.0
var arming_until : int = 0            # year until which the planner wants extra armament
var traits : Dictionary = {}          # personality (see personality.gd); empty = all 0.5
var stability : float = 0.5
var base_traits : Dictionary = {}     # the current regime's values; traits drift back toward them
var regime_year : int = -100
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
