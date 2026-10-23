extends Node

## SNAPTIC-TAS runtime (pause, step, slow-mo via time_scale, HUD only).
##
## Uses Engine.time_scale for pause/step/slow-mo so player physics always run.

const HudScript = preload("res://gdpatch/mods/snaptic_tas/tas_hud.gd")

const VERSION: String = "0.2.0"
const TICK_RATE: int = 60
const SLOWMO_STEPS: Array[float] = [1.0, 0.5, 0.25]
const LEVELS: Dictionary = {
	"test_room": 1,
	"movement_playtest": 2,
	"gym": 4,
	"mirraxis": 5,
	"magnet_puzzles": 7,
}

var _player: Node = null
var _look_input: Node = null
var _camera_holder: Node = null
var _camera_manager: Node = null
var _hitstop: Node = null
var _hitstop_original_node: Node = null
var _hitstop_neutralized: bool = false

var _hud: CanvasLayer = null

var _perf_enabled: bool = false
var _old_max_fps: int = 0
var _old_vsync: int = 0
var _last_physics_frame: int = -1
var _hitches: int = 0
var _last_hitch_tick: int = -1

var _slowmo_index: int = 0
var _was_paused_by_tas: bool = false
var _stepping: bool = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1000
	add_to_group(&"tas_runtime")

	_hud = HudScript.new()
	add_child(_hud)

	_look_input = get_node_or_null(^"/root/LookInput")
	_debug_level = _read_debug_level()

	_log("runtime ready (version %s, debug level '%s')" % [VERSION, _debug_level])
	call_deferred("_boot")


func _boot() -> void:
	await get_tree().process_frame
	if _debug_level != "":
		await _try_autoload_level(_debug_level)
	_booted = true
	_refresh_hud()


func _process(delta: float) -> void:
	if not _booted:
		return
	_bind_player_if_needed()
	_sync_time_scale()

	if _pending_f6_toggle:
		_pending_f6_toggle = false
		_toggle_pause()
	if _pending_f7_step:
		_pending_f7_step = false
		_step()
	if _pending_shift_f6_slowmo:
		_pending_shift_f6_slowmo = false
		_cycle_slowmo()
	if _pending_f12_hud:
		_pending_f12_hud = false
		_hud.toggle_visible()

	_hud_timer += delta
	if _hud_timer >= 0.1:
		_hud_timer = 0.0
		_refresh_hud()


func _physics_process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		return


func _sync_time_scale() -> void:
	## Keep Engine.time_scale in sync with our slow-mo/pause state.
	## If the game was paused externally (Escape menu), don't fight it.
	if get_tree().paused and not _was_paused_by_tas:
		return
	var target_scale := 0.0 if _was_paused_by_tas else SLOWMO_STEPS[_slowmo_index]
	if not is_equal_approx(Engine.time_scale, target_scale):
		Engine.time_scale = target_scale


func _toggle_pause() -> void:
	_was_paused_by_tas = not _was_paused_by_tas
	_sync_time_scale()
	_status("paused" if _was_paused_by_tas else "resumed")


func _step() -> void:
	## Single frame step: run at 1x for exactly one physics frame, then return to pause.
	if _stepping:
		return
	_stepping = true
	var was_paused := _was_paused_by_tas
	_was_paused_by_tas = false
	Engine.time_scale = 1.0
	await get_tree().physics_frame
	_was_paused_by_tas = was_paused
	_sync_time_scale()
	_stepping = false
	_status("stepped one tick")


func _cycle_slowmo() -> void:
	_slowmo_index = (_slowmo_index + 1) % SLOWMO_STEPS.size()
	_sync_time_scale()
	if _slowmo_index == 0:
		_status("slow-mo 1x")
	else:
		_status("slow-mo %.2fx" % SLOWMO_STEPS[_slowmo_index])


func _bind_player_if_needed() -> void:
	var current: Node = get_tree().get_first_node_in_group(&"player")
	if current == _player:
		return
	if _player != null:
		_on_player_lost()
	_player = current
	if _player != null:
		_on_player_bound()


func _on_player_bound() -> void:
	if _player == null:
		return
	_camera_holder = get_tree().get_first_node_in_group(&"camera_holder")
	_camera_manager = null
	if _camera_holder != null:
		_camera_manager = _camera_holder.get_node_or_null(^"CameraControllerManager")
		if _camera_manager != null:
			_old_camera_priority = int(_camera_manager.process_priority)
	_hitstop = _player.get("hitstop_component")
	_hitstop_original_node = null
	_hitstop_neutralized = false
	_enable_perf()
	_enable_camera_order()
	_neutralize_hitstop()
	_sync_time_scale()
	_status("player ready", false, 2.0)
	_log("player bound: %s" % str(_player.get_path()))


func _on_player_lost() -> void:
	_restore_look_physics()
	_restore_hitstop()
	_restore_camera_order()
	_restore_perf()
	Engine.time_scale = 1.0
	_was_paused_by_tas = false
	_slowmo_index = 0
	_player = null
	_camera_holder = null
	_camera_manager = null
	_hitstop = null
	_hitstop_original_node = null
	_hitstop_neutralized = false
	_status("player lost; waiting", false, 3.0)


func _enable_perf() -> void:
	if _perf_enabled:
		return
	_old_max_fps = Engine.max_fps
	Engine.max_fps = 240
	if DisplayServer.get_name() != "headless":
		_old_vsync = int(DisplayServer.window_get_vsync_mode())
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_perf_enabled = true
	_log("performance mode: max_fps=240, vsync off")


func _restore_perf() -> void:
	if not _perf_enabled:
		return
	Engine.max_fps = _old_max_fps
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(_old_vsync)
	_perf_enabled = false


func _enable_camera_order() -> void:
	if _camera_order_enabled or _camera_manager == null:
		return
	_old_camera_priority = int(_camera_manager.process_priority)
	_camera_manager.process_priority = 10
	_camera_order_enabled = true


func _restore_camera_order() -> void:
	if not _camera_order_enabled or _camera_manager == null:
		return
	_camera_manager.process_priority = _old_camera_priority
	_camera_order_enabled = false


func _neutralize_hitstop() -> void:
	if _hitstop == null or _hitstop_neutralized:
		return
	_hitstop_original_node = _hitstop.get("node_to_pause")
	_hitstop.set("node_to_pause", null)
	_hitstop.set("_t", 0.0)
	_hitstop_neutralized = true
	_ensure_player_process_modes()


func _restore_hitstop() -> void:
	if _hitstop == null or not _hitstop_neutralized:
		return
	if _hitstop_original_node != null and is_instance_valid(_hitstop_original_node):
		_hitstop.set("node_to_pause", _hitstop_original_node)
	else:
		_hitstop.set("node_to_pause", null)
	_hitstop_neutralized = false


func _ensure_player_process_modes() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var mode := int(_player.get("player_mode"))
	var characterbody: Node = _player.get("characterbody")
	var marble: Node = _player.get("marble")
	_player.set("process_mode", Node.PROCESS_MODE_INHERIT)
	if characterbody != null:
		characterbody.set("process_mode", Node.PROCESS_MODE_INHERIT if mode == 0 else Node.PROCESS_MODE_DISABLED)
	if marble != null:
		marble.set("process_mode", Node.PROCESS_MODE_INHERIT if mode == 1 else Node.PROCESS_MODE_DISABLED)
		marble.set("freeze", mode != 1)


func _restore_look_physics() -> void:
	if _look_input == null:
		return
	_look_input.set_physics_process(_look_physics_was_enabled)
	_look_input.set(&"_mouse_relative", Vector2.ZERO)
	_look_input.set(&"_joy_value", Vector2.ZERO)
	_look_input.set(&"_button_value", Vector2.ZERO)


var _last_key_time: int = 0
var _pending_f6_toggle: bool = false
var _pending_f7_step: bool = false
var _pending_shift_f6_slowmo: bool = false
var _pending_f12_hud: bool = false

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return
	var key := key_event.keycode

	var handled := true
	match key:
		KEY_F6:
			if key_event.shift_pressed:
				_pending_shift_f6_slowmo = true
			else:
				_pending_f6_toggle = true
		KEY_F7:
			_pending_f7_step = true
		KEY_F12:
			_pending_f12_hud = true
		_:
			handled = false

	if handled:
		get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	_restore_look_physics()
	_restore_hitstop()
	_restore_camera_order()
	_restore_perf()
	Engine.time_scale = 1.0
	remove_from_group(&"tas_runtime")


func _read_debug_level() -> String:
	var level := ""
	var gdpatch := get_node_or_null(^"/root/GDPatch")
	if gdpatch != null and gdpatch.has_method(&"get_config_option"):
		var value = gdpatch.call(&"get_config_option", "snaptic_tas", "debug", "autoload_level")
		if value != null:
			level = str(value).strip_edges()
	for argument in OS.get_cmdline_args():
		if argument.begins_with("--tas-level="):
			level = argument.substr(12).strip_edges()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--tas-level="):
			level = argument.substr(12).strip_edges()
	return level


func _try_autoload_level(level: String) -> void:
	var index := int(LEVELS.get(level.to_lower(), -1))
	if index < 0:
		_status("unknown debug level '%s'" % level, true, 8.0)
		return
	var loader := get_node_or_null(^"/root/LevelLoader")
	if loader == null:
		_status("debug level: LevelLoader not found", true, 8.0)
		return
	await get_tree().process_frame
	loader.call(&"load_level", index)
	_status("debug auto-load: " + level, false, 5.0)
	_log("debug auto-load level %s (%d)" % [level, index])


func _log(message: String) -> void:
	print("SNAPTIC-TAS: " + message)
	var gdpatch := get_node_or_null(^"/root/GDPatch")
	if gdpatch != null and gdpatch.has_method(&"log_message"):
		gdpatch.call(&"log_message", "info", message)