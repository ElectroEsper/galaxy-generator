class_name GameSetup
extends RefCounted
## Hand-off between the main menu and the map view: the galaxy settings to start with, or a save to resume.

const PERSONALITY_PATH := "user://personalities.json"
const SAVE_DIR := "user://saves"
const QUICKSAVE := "user://saves/quicksave.sav"

static var config : Dictionary = {}
static var load_path : String = ""

## The player's personality book (JSON), or "" to use the built-in one.
static func personalities_json() -> String:
	if FileAccess.file_exists(PERSONALITY_PATH):
		var src := FileAccess.get_file_as_string(PERSONALITY_PATH)
		var d = JSON.parse_string(src)
		# Books from before trait blocks have no "blocks": fall back to the built-in book.
		if d is Dictionary and d.has("blocks"):
			return src
	return ""

static func list_saves() -> PackedStringArray:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(SAVE_DIR):
		if f.ends_with(".sav"):
			out.append(f.get_basename())
	return out
