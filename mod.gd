extends Node

## GDPatch mod entry point.
##
## This node is created by GDPatch from
## res://gdpatch/mods/snaptic_tas/mod.gd. It validates the pinned game/engine
## versions and the patcher markers before creating the TAS runtime. On any
## mismatch it shows an error HUD and leaves the game running unmodified (the
## Lua patches are anchored and fail closed, but they may still be present).

const TOOL_VERSION: String = "0.2.0"
const REQUIRED_ENGINE: String = "4.7.1"
const REQUIRED_GAME: String = "0.91"
const REQUIRED_TICK_RATE: int = 60

const REQUIRED_PATHS: Array[String] = [
	"res://actors/player/player.gd",
	"res://actors/player/player.tscn",
	"res://actors/player/player_states/player_marble_state.gd",
	"res://autoloads/global/global.gd",
	"res://autoloads/input/look_input.gd",
	"res://autoloads/level_loader/level_loader.gd",
	"res://features/camera/camera_controller_manager.gd",
	"res://features/camera/rotation/crc_input_control.gd",
	"res://features/camera/position/cpc_spring_arm.gd",
	"res://levels/gym/gym.tscn",
	"res://levels/test_room/test_room.tscn",
	"res://levels/movement_playtest/movement_playtest.tscn",
]

var _runtime: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("_boot")


func _boot() -> void:
	await get_tree().process_frame

	var errors: Array[String] = []

	var version := Engine.get_version_info()
	var found_engine := "%d.%d.%d" % [
		int(version.get("major", 0)),
		int(version.get("minor", 0)),
		int(version.get("patch", 0)),
	]
	if found_engine != REQUIRED_ENGINE:
		errors.append("Engine %s required; found %s (%s)" % [
			REQUIRED_ENGINE, found_engine, str(version.get("string", ""))
		])

	var game_version := str(ProjectSettings.get_setting("application/config/version", ""))
	if game_version != REQUIRED_GAME:
		errors.append("SNAPTIC %s required; found '%s'" % [REQUIRED_GAME, game_version])

	if Engine.physics_ticks_per_second != REQUIRED_TICK_RATE:
		errors.append("physics tick rate must be %d; found %d" % [
			REQUIRED_TICK_RATE, Engine.physics_ticks_per_second
		])

	if not is_equal_approx(Engine.time_scale, 1.0):
		errors.append("Engine.time_scale must be 1.0 at boot; found %s" % str(Engine.time_scale))

	var jitter = ProjectSettings.get_setting("physics/common/physics_jitter_fix", null)
	if jitter == null:
		errors.append("physics/common/physics_jitter_fix is missing (patcher did not run)")
	elif not is_equal_approx(float(jitter), 0.0):
		errors.append("physics jitter fix must be 0.0; found %s" % str(jitter))

	var game_input := get_node_or_null(^"/root/GameInput")
	if game_input == null:
		errors.append("GameInput autoload not found")
	elif not game_input.has_method(&"tas_patch_marker"):
		errors.append("game_input.gd patch marker missing (unsupported game build)")

	var input_buffers := get_node_or_null(^"/root/InputBuffers")
	if input_buffers == null:
		errors.append("InputBuffers autoload not found")
	elif not input_buffers.has_method(&"tas_patch_marker"):
		errors.append("input_buffers.gd patch marker missing (unsupported game build)")

	for path in REQUIRED_PATHS:
		if not ResourceLoader.exists(path):
			errors.append("expected script/scene missing: " + path)

	if not errors.is_empty():
		_show_error(errors)
		return

	var runtime_script = load("res://gdpatch/mods/snaptic_tas/tas_runtime.gd")
	if runtime_script == null:
		_show_error(["Could not load tas_runtime.gd (parse error; see GDPatch/output.log)."])
		return

	_runtime = runtime_script.new()
	if _runtime == null:
		_show_error(["Could not instantiate tas_runtime.gd (missing class_name or _init error)."])
		return
	_runtime.name = "TASRuntime"
	add_child(_runtime)
	_log("enabled: SNAPTIC %s / Godot %s / %d Hz" % [
		game_version, found_engine, Engine.physics_ticks_per_second
	])


func _show_error(errors: Array[String]) -> void:
	var lines: Array[String] = []
	lines.append("SNAPTIC-TAS %s disabled" % TOOL_VERSION)
	lines.append("The game is still running, but TAS features are off.")
	lines.append("")
	for error in errors:
		lines.append("- " + error)
		_log("error: " + error)

	var layer := CanvasLayer.new()
	layer.layer = 129
	add_child(layer)

	var panel := PanelContainer.new()
	panel.position = Vector2(16, 16)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.015, 0.02, 0.92)
	style.border_color = Color(1.0, 0.35, 0.35, 0.8)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", style)
	layer.add_child(panel)

	var label := Label.new()
	var text := ""
	for i in lines.size():
		if i > 0:
			text += "\n"
		text += lines[i]
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(720, 0)
	label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.82))
	panel.add_child(label)


func _log(message: String) -> void:
	print("SNAPTIC-TAS: " + message)
	var gdpatch := get_node_or_null(^"/root/GDPatch")
	if gdpatch != null and gdpatch.has_method(&"log_message"):
		gdpatch.call(&"log_message", "info", message)