extends Node

## SNAPTIC-TAS runtime — pause/step/slow-mo, record, replay, determinism check.

const HudScript         = preload("res://gdpatch/mods/snaptic_tas/tas_hud.gd")
const SnapshotCodec     = preload("res://gdpatch/mods/snaptic_tas/tas_snapshot.gd")
const DeterminismScript = preload("res://gdpatch/mods/snaptic_tas/tas_determinism.gd")
const InputScript       = preload("res://gdpatch/mods/snaptic_tas/tas_input.gd")
const RunfileScript     = preload("res://gdpatch/mods/snaptic_tas/tas_runfile.gd")

const VERSION: String = "0.4.0"
const TICK_RATE: int = 60
const SNAPSHOT_SLOTS: int = 10
const SLOWMO_STEPS: Array[float] = [1.0, 0.5, 0.25]
const LEVELS: Dictionary = {
	"test_room": 1,
	"movement_playtest": 2,
	"gym": 4,
	"mirraxis": 5,
	"magnet_puzzles": 7,
}

enum TasMode { IDLE, RECORDING, REPLAYING }

var _mode: TasMode = TasMode.IDLE

# ── Record ────────────────────────────────────────────────────────────────────
var _record_buffer: PackedByteArray = PackedByteArray()
var _record_initial_snapshot: Dictionary = {}
var _record_start_tick: int = 0
var _record_tick_count: int = 0
## Byte offset of the last appended tick. camera_tick() patches the look vector
## here after LookInput has updated it (priority 0 → 1 ordering).
var _record_current_offset: int = -1

# ── Replay ────────────────────────────────────────────────────────────────────
var _replay_buffer: PackedByteArray = PackedByteArray()
var _replay_initial_snapshot: Dictionary = {}
var _replay_tick: int = 0
var _replay_previous_mask: int = 0
var _replay_total_ticks: int = 0

# ── Determinism ───────────────────────────────────────────────────────────────
var _determinism = null
var _pending_determinism: bool = false

# ── Scene references ──────────────────────────────────────────────────────────
var _player: Node = null
var _game_input: Node = null
var _look_input: Node = null
var _camera_holder: Node = null
var _camera_manager: Node = null
var _hitstop: Node = null
var _hitstop_original_node: Node = null
var _hitstop_original_t: float = 0.0
var _hitstop_neutralized: bool = false

var _hud: CanvasLayer = null
var _snapshot = null

# ── Snapshot slots ────────────────────────────────────────────────────────────
var _snapshot_slots: Array = []
var _slot: int = 0
var _pending_snapshot_slot: int = -1
var _pending_load_slot: int = -1
var _pending_pause: bool = false

# ── Perf ──────────────────────────────────────────────────────────────────────
var _perf_enabled: bool = false
var _old_max_fps: int = 0
var _old_vsync: int = 0

# ── Hitch detection ───────────────────────────────────────────────────────────
var _last_physics_frame: int = -1
var _hitches: int = 0
var _last_hitch_tick: int = -1

# ── Time-scale / pause ────────────────────────────────────────────────────────
var _slowmo_index: int = 0
var _was_paused_by_tas: bool = false
var _stepping: bool = false

# ── Status / HUD ──────────────────────────────────────────────────────────────
var _status_message: String = ""
var _status_error: bool = false
var _status_until: int = 0
var _hud_last_refresh: int = 0
var _booted: bool = false
var _debug_level: String = ""
var _det_autostart: bool = false
var _det_autostart_air: bool = false

# ── Camera ────────────────────────────────────────────────────────────────────
var _camera_order_enabled: bool = false
var _old_camera_priority: int = 0

# ── Look-input tracking ───────────────────────────────────────────────────────
## Captured in _on_player_bound BEFORE any neutralization, so restore is correct.
var _look_physics_was_enabled: bool = true
var _input_neutralized: bool = false
var _look_physics_prior: bool = true
var _buffers_physics_prior: bool = true

# ── Pending input flags ───────────────────────────────────────────────────────
var _last_key_time: int = 0
var _pending_f6_toggle: bool = false
var _pending_f7_step: bool = false
var _pending_shift_f6_slowmo: bool = false
var _pending_f10_record: bool = false
var _pending_f11_replay: bool = false
var _pending_ctrl_f10_det: bool = false
var _pending_f12_hud: bool = false


# ══════════════════════════════════════════════════════════════════════════════
# Lifecycle
# ══════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1000
	process_physics_priority = -1000   # run before all gameplay physics each tick
	add_to_group(&"tas_runtime")

	_snapshot = SnapshotCodec.new()
	_snapshot_slots.resize(SNAPSHOT_SLOTS)

	_hud = HudScript.new()
	add_child(_hud)

	_game_input = get_node_or_null(^"/root/GameInput")
	_look_input  = get_node_or_null(^"/root/LookInput")
	_debug_level = _read_debug_level()
	_det_autostart = _has_cmdline_arg("--tas-det")
	_det_autostart_air = _has_cmdline_arg("--tas-det-air")

	_log("runtime ready (version %s, debug level '%s')" % [VERSION, _debug_level])
	call_deferred("_boot")


func _boot() -> void:
	await get_tree().process_frame
	if _debug_level != "":
		await _try_autoload_level(_debug_level)
	_booted = true
	_refresh_hud()
	if _det_autostart:
		_autostart_determinism()


## Developer hook (`--tas-det`): run the determinism check as soon as the player
## is bound and standing, so it can be reproduced headlessly without injecting
## Ctrl+F10. `--tas-det-air` starts from a falling player instead, which exercises
## the restore path for the engine-side floor state.
func _autostart_determinism() -> void:
	for i in 1800:
		if _player != null and is_instance_valid(_player) and int(_player.get("player_mode")) == 0:
			if bool(_player.call(&"is_on_floor")):
				break
		await get_tree().process_frame
	if _player == null or not is_instance_valid(_player):
		_log("determinism autostart: no player bound")
		return
	if _det_autostart_air:
		# Give the engine one move-and-slide to clear its cached floor state.
		var body = _player.get("characterbody")
		if body != null:
			body.set("global_position", body.get("global_position") + Vector3.UP * 2.0)
		for i in 6:
			await get_tree().physics_frame
	await get_tree().physics_frame
	_start_determinism()


func _exit_tree() -> void:
	if _mode == TasMode.RECORDING:
		_stop_record()
	elif _mode == TasMode.REPLAYING:
		_stop_replay()
	_restore_live_input_processing()
	_restore_look_physics()
	_restore_hitstop()
	_restore_camera_order()
	_restore_perf()
	if _snapshot != null:
		_snapshot.unbind()
	Engine.time_scale = 1.0
	remove_from_group(&"tas_runtime")


# ══════════════════════════════════════════════════════════════════════════════
# Per-frame
# ══════════════════════════════════════════════════════════════════════════════

func _process(_delta: float) -> void:
	if not _booted:
		return
	_bind_player_if_needed()
	_sync_time_scale()
	_detect_hitches()

	if _pending_f6_toggle:
		_pending_f6_toggle = false
		_toggle_pause()
	if _pending_ctrl_f10_det:
		_pending_ctrl_f10_det = false
		_start_determinism()
	if _pending_f7_step:
		_pending_f7_step = false
		_step()
	if _pending_shift_f6_slowmo:
		_pending_shift_f6_slowmo = false
		_cycle_slowmo()
	if _pending_f10_record:
		_pending_f10_record = false
		if _mode == TasMode.RECORDING:
			_stop_record()
		else:
			_start_record()
	if _pending_f11_replay:
		_pending_f11_replay = false
		if _mode == TasMode.REPLAYING:
			_stop_replay()
		else:
			_start_replay()
	if _pending_f12_hud:
		_pending_f12_hud = false
		_hud.call(&"toggle_visible")

	if _pending_pause and not _stepping:
		_pending_pause = false
		_was_paused_by_tas = true
		_sync_time_scale()

	if _was_paused_by_tas and not _stepping:
		_apply_paused_freelook()

	var now := Time.get_ticks_msec()
	if now - _hud_last_refresh >= 100:
		_hud_last_refresh = now
		_refresh_hud()


func _physics_process(_delta: float) -> void:
	# ── Determinism ──────────────────────────────────────────────────────────
	if _determinism != null:
		_determinism.on_physics_tick(_determinism_inputs)
		if _determinism.is_finished():
			_determinism = null
			_restore_live_input_processing()

	# ── Record ───────────────────────────────────────────────────────────────
	# Capture action/move/strength state now. Look is captured by LookInput at
	# priority 0 (later this same tick), so camera_tick() at priority 1 will
	# patch the correct look into _record_current_offset after this returns.
	if _mode == TasMode.RECORDING:
		if _game_input != null and _look_input != null:
			var tick_data := InputScript.capture(_game_input, _look_input)
			_record_current_offset = _record_buffer.size()
			_record_buffer = InputScript.append(_record_buffer, tick_data)
			_record_tick_count += 1

	# ── Replay ───────────────────────────────────────────────────────────────
	# Emit the recorded events into GameInput. InputBuffers processes those
	# events during its own _physics_process (runs after ours at priority 0+),
	# which is why InputBuffers is NOT neutralized during replay.
	elif _mode == TasMode.REPLAYING:
		if _replay_tick >= _replay_total_ticks:
			_stop_replay()
		elif _game_input != null:
			var tick_data := InputScript.decode(_replay_buffer, _replay_tick)
			InputScript.emit_events(_game_input, _replay_previous_mask, tick_data)
			_replay_previous_mask = int(tick_data["mask"])
			_replay_tick += 1

	# ── Deferred snapshot I/O ─────────────────────────────────────────────────
	if _pending_snapshot_slot >= 0:
		var slot := _pending_snapshot_slot
		_pending_snapshot_slot = -1
		_capture_slot(slot)
	if _pending_load_slot >= 0:
		var slot := _pending_load_slot
		_pending_load_slot = -1
		_apply_snapshot_slot(slot)


# ══════════════════════════════════════════════════════════════════════════════
# camera_tick — called by tas_camera.gd at process_physics_priority = 1
#
# Runs AFTER LookInput (priority 0) and BEFORE the camera manager (priority 10),
# making it the correct place to both read and write the look vector.
#
# RECORD  → patch the look LookInput just produced into the tick we appended.
# REPLAY  → inject the recorded look so the camera manager consumes it.
# PAUSED/DET → snap the camera so freelook feels immediate at time_scale 0.
# ══════════════════════════════════════════════════════════════════════════════

func camera_tick() -> void:
	if _player == null or not is_instance_valid(_player):
		return

	match _mode:
		TasMode.RECORDING:
			if _record_current_offset >= 0 and _look_input != null:
				var look: Vector2 = _look_input.get("look_vector")
				var look_time: float = float(_look_input.get("time_since_last_look_input"))
				_record_buffer = InputScript.write_look(
					_record_buffer, _record_current_offset, look, look_time
				)
				_record_current_offset = -1

		TasMode.REPLAYING:
			# _replay_tick was already incremented in _physics_process, so the
			# tick that just ran is at index _replay_tick - 1.
			if _look_input != null and _replay_tick > 0:
				var idx := mini(_replay_tick - 1, _replay_total_ticks - 1)
				var t := InputScript.decode(_replay_buffer, idx)
				_look_input.set("look_vector", t["look"])
				_look_input.set("time_since_last_look_input", t["look_time"])

		_:
			if _was_paused_by_tas or _determinism != null:
				_snap_camera()


# ══════════════════════════════════════════════════════════════════════════════
# Record
# ══════════════════════════════════════════════════════════════════════════════

func _start_record() -> void:
	if _player == null:
		_status("record: no player", true)
		return
	if _mode != TasMode.IDLE:
		_status("record: already in %s mode" % TasMode.keys()[_mode], true)
		return
	if _determinism != null:
		_status("record: determinism run in progress", true)
		return
	var can: Dictionary = _snapshot.can_capture(_player)
	if not bool(can.get("ok", false)):
		_status("record: " + str(can.get("reason", "cannot capture state")), true)
		return

	_record_buffer           = PackedByteArray()
	_record_initial_snapshot = _snapshot.capture(_player, Engine.get_physics_frames())
	_record_start_tick       = Engine.get_physics_frames()
	_record_tick_count       = 0
	_record_current_offset   = -1
	_mode = TasMode.RECORDING
	_status("recording…", false, 2.0)
	_log("record started at tick %d" % _record_start_tick)


func _stop_record() -> void:
	if _mode != TasMode.RECORDING:
		return
	_mode = TasMode.IDLE
	_record_current_offset = -1

	if _record_tick_count == 0:
		_status("recording discarded (no ticks)", false, 3.0)
		return

	var meta := {
		"tool_version": VERSION,
		"level":        int(_record_initial_snapshot.get("level", -1)),
		"start_tick":   _record_start_tick,
	}

	# Always overwrite the "last" slot so F11 replay picks it up immediately.
	var res_last := RunfileScript.save(
		RunfileScript.LAST_PATH,
		meta, _record_initial_snapshot, _record_buffer, [],
		InputScript.TICK_BYTES
	)
	# Timestamped archive copy.
	var ts_path: String = RunfileScript.RUN_DIR + "/" + RunfileScript.timestamp_name() + ".snaptas"
	RunfileScript.save(ts_path, meta, _record_initial_snapshot, _record_buffer, [], InputScript.TICK_BYTES)

	var saved_ok := bool(res_last.get("ok", false))
	var msg := "recording stopped: %d ticks" % _record_tick_count
	msg += " — saved" if saved_ok else (" — SAVE FAILED: " + str(res_last.get("error", "")))
	_status(msg, not saved_ok, 5.0)
	_log("record stopped: %d ticks, saved=%s, path=%s" % [_record_tick_count, str(saved_ok), ts_path])


# ══════════════════════════════════════════════════════════════════════════════
# Replay
# ══════════════════════════════════════════════════════════════════════════════

func _start_replay(path: String = RunfileScript.LAST_PATH) -> void:
	if _player == null:
		_status("replay: no player", true)
		return
	if _mode != TasMode.IDLE:
		_status("replay: already in %s mode" % TasMode.keys()[_mode], true)
		return
	if _determinism != null:
		_status("replay: determinism run in progress", true)
		return

	var run: Dictionary = RunfileScript.load(path)
	if not bool(run.get("ok", false)):
		_status("replay: " + str(run.get("error", "load failed")), true)
		return

	_replay_buffer           = run["inputs"]
	_replay_initial_snapshot = run["snapshot"]
	_replay_total_ticks      = InputScript.tick_count(_replay_buffer)
	_replay_tick             = 0
	_replay_previous_mask    = 0

	if _replay_total_ticks == 0:
		_status("replay: run file has no ticks", true)
		return

	var restored: Dictionary = _snapshot.restore(_player, _replay_initial_snapshot)
	if not bool(restored.get("ok", false)):
		_status("replay: restore failed: " + str(restored.get("reason", "unknown")), true)
		return

	_snap_view()

	# Neutralize LookInput so device input cannot override our injected look.
	# InputBuffers is intentionally left running: it must process the action
	# events we emit through GameInput's gameplay_input signal each tick, and
	# the patcher moved its timer ticks into _physics_process which must fire.
	if _look_input != null:
		_look_physics_prior = _look_input.is_physics_processing()
		_look_input.set_physics_process(false)
		_look_input.set("look_vector", Vector2.ZERO)
		_look_input.set("time_since_last_look_input", 0.0)
		_look_input.set("_mouse_relative", Vector2.ZERO)
		_look_input.set("_joy_value", Vector2.ZERO)
		_look_input.set("_button_value", Vector2.ZERO)

	# Clear any live-input residue in InputBuffers before the first tick fires.
	neutralize_live_input()

	_was_paused_by_tas = false
	_sync_time_scale()
	_mode = TasMode.REPLAYING
	_status("replay: %d ticks" % _replay_total_ticks, false, 3.0)
	_log("replay started: %d ticks from '%s'" % [_replay_total_ticks, path])


func _stop_replay() -> void:
	if _mode != TasMode.REPLAYING:
		return
	_mode = TasMode.IDLE
	_replay_previous_mask = 0

	if _look_input != null:
		_look_input.set_physics_process(_look_physics_prior)

	_status("replay done (%d / %d ticks)" % [_replay_tick, _replay_total_ticks], false, 4.0)
	_log("replay stopped at tick %d / %d" % [_replay_tick, _replay_total_ticks])


# ══════════════════════════════════════════════════════════════════════════════
# Determinism
# ══════════════════════════════════════════════════════════════════════════════

func _start_determinism() -> void:
	if _player == null or _determinism != null:
		_status("determinism: need a player and no run in progress", true)
		return
	if _mode != TasMode.IDLE:
		_status("determinism: cannot run while in %s mode" % TasMode.keys()[_mode], true)
		return
	if _pending_snapshot_slot >= 0 or _pending_load_slot >= 0:
		_status("determinism: finish pending snapshot I/O first", true)
		return
	var mode := int(_player.get("player_mode"))
	if mode != 0:
		_status("determinism: only supported in character mode (mode=%d)" % mode, true)
		return
	_was_paused_by_tas = false
	_slowmo_index = 0
	_sync_time_scale()
	_neutralize_live_input_processing()
	_determinism = DeterminismScript.new()
	_determinism.start(self, _snapshot, _player)
	_status("determinism run started", false, 5.0)


func _determinism_inputs(tick: int) -> void:
	# Inject via set() rather than calling a non-existent queue_jump() method.
	# 0.3 s matches PlayerMarbleState.MARBLE_BUFFER_LIFETIME.
	var buffers := get_node_or_null(^"/root/InputBuffers")
	if buffers == null:
		return
	if tick == 0 or tick == 30:
		buffers.set("_jump_buffer_timer", 0.3)


# ══════════════════════════════════════════════════════════════════════════════
# Pause / step / slow-mo
# ══════════════════════════════════════════════════════════════════════════════

func _sync_time_scale() -> void:
	if get_tree().paused and not _was_paused_by_tas:
		return
	if _stepping:
		return
	var target_scale := 0.0 if _was_paused_by_tas else SLOWMO_STEPS[_slowmo_index]
	if not is_equal_approx(Engine.time_scale, target_scale):
		Engine.time_scale = target_scale


func _toggle_pause() -> void:
	_was_paused_by_tas = not _was_paused_by_tas
	_sync_time_scale()
	_status("paused" if _was_paused_by_tas else "resumed")


func _step() -> void:
	if _stepping:
		return
	if _determinism != null:
		_status("step blocked: determinism run in progress", true)
		return
	_stepping = true
	var was_paused := _was_paused_by_tas
	_was_paused_by_tas = false
	Engine.time_scale = 1.0
	await get_tree().physics_frame
	_was_paused_by_tas = was_paused
	_stepping = false
	_sync_time_scale()
	_status("stepped one tick")


func _cycle_slowmo() -> void:
	_slowmo_index = (_slowmo_index + 1) % SLOWMO_STEPS.size()
	_sync_time_scale()
	if _slowmo_index == 0:
		_status("slow-mo 1x")
	else:
		_status("slow-mo %.2fx" % SLOWMO_STEPS[_slowmo_index])


# ══════════════════════════════════════════════════════════════════════════════
# Input neutralization
# ══════════════════════════════════════════════════════════════════════════════

func _neutralize_live_input_processing() -> void:
	if _input_neutralized:
		return
	if _look_input != null:
		_look_physics_prior = _look_input.is_physics_processing()
		_look_input.set_physics_process(false)
		_look_input.set("look_vector", Vector2.ZERO)
		_look_input.set("time_since_last_look_input", 0.0)
		_look_input.set("_mouse_relative", Vector2.ZERO)
		_look_input.set("_joy_value", Vector2.ZERO)
		_look_input.set("_button_value", Vector2.ZERO)
	var buffers := get_node_or_null(^"/root/InputBuffers")
	if buffers != null:
		_buffers_physics_prior = buffers.is_physics_processing()
		buffers.set_physics_process(false)
	_input_neutralized = true


func _restore_live_input_processing() -> void:
	if not _input_neutralized:
		return
	if _look_input != null:
		_look_input.set_physics_process(_look_physics_prior)
	var buffers := get_node_or_null(^"/root/InputBuffers")
	if buffers != null:
		buffers.set_physics_process(_buffers_physics_prior)
	_input_neutralized = false


## Zero all live-input accumulators without toggling process enable.
## Called at the start of replay and by the determinism codec each tick.
func neutralize_live_input() -> void:
	if _look_input != null:
		_look_input.set("look_vector", Vector2.ZERO)
		_look_input.set("time_since_last_look_input", 0.0)
		_look_input.set("_mouse_relative", Vector2.ZERO)
		_look_input.set("_joy_value", Vector2.ZERO)
		_look_input.set("_button_value", Vector2.ZERO)
	var buffers := get_node_or_null(^"/root/InputBuffers")
	if buffers == null:
		return
	buffers.set("_smash_input",              false)
	buffers.set("helicopter_input",          false)
	buffers.set("_do_marble_buffer_timer",   0.0)
	buffers.set("_jump_buffer_timer",        0.0)
	buffers.set("_smash_input_timer",        0.0)
	buffers.set("_do_marble_press_msec",     0)
	buffers.set("_do_marble_is_double",      false)
	buffers.set("_double_marble_open_msec",  0)
	buffers.set("_old_smash_input",          false)
	buffers.set("_was_do_marble_pressed",    false)
	buffers.set("_prev_stick_angle",         0.0)
	buffers.set("_prev_stick_magnitude",     0.0)
	buffers.set("_stick_cumulitave_angle",   0.0)
	buffers.set("_avg_stick_angular_speed",  [])
	buffers.set("_helicopter_buffer_i",      0)


# ══════════════════════════════════════════════════════════════════════════════
# Snapshot slots
# ══════════════════════════════════════════════════════════════════════════════

func _save_snapshot(cycle: bool) -> void:
	if _mode != TasMode.IDLE:
		_status("snapshot: not available in %s mode" % TasMode.keys()[_mode], true)
		return
	if _determinism != null:
		_status("snapshot blocked: determinism run in progress", true)
		return
	if cycle:
		_slot = (_slot + 1) % SNAPSHOT_SLOTS
		_status("snapshot slot %d (%s)" % [_slot, _slot_summary(_slot)])
		return
	if get_tree().paused or _was_paused_by_tas:
		_capture_slot(_slot)
	else:
		_pending_snapshot_slot = _slot
		_status("snapshot armed for slot %d" % _slot)


func _capture_slot(slot: int) -> void:
	if _player == null or not is_instance_valid(_player):
		_status("cannot snapshot: no player", true)
		return
	if _snapshot == null:
		_status("cannot snapshot: codec unavailable", true)
		return
	var can: Dictionary = _snapshot.can_capture(_player)
	if not bool(can.get("ok", false)):
		_status("cannot snapshot: " + str(can.get("reason", "unknown state")), true)
		return
	var tick := Engine.get_physics_frames()
	_snapshot_slots[slot] = {
		"snapshot": _snapshot.capture(_player, tick),
		"tick":     tick,
	}
	_status("saved snapshot %d at tick %d" % [slot, tick])
	_log("snapshot slot %d saved at tick %d" % [slot, tick])


func _load_snapshot(cycle: bool) -> void:
	if _mode != TasMode.IDLE:
		_status("snapshot load: not available in %s mode" % TasMode.keys()[_mode], true)
		return
	if _determinism != null:
		_status("snapshot load blocked: determinism run in progress", true)
		return
	if cycle:
		_slot = (_slot - 1 + SNAPSHOT_SLOTS) % SNAPSHOT_SLOTS
		_status("snapshot slot %d (%s)" % [_slot, _slot_summary(_slot)])
		return
	if _snapshot_slots[_slot] == null:
		_status("snapshot slot %d is empty" % _slot, true)
		return
	if get_tree().paused or _was_paused_by_tas:
		_apply_snapshot_slot(_slot)
	else:
		_pending_load_slot = _slot
		_status("snapshot load armed for slot %d" % _slot)


func _apply_snapshot_slot(slot: int) -> void:
	var entry = _snapshot_slots[slot]
	if entry == null:
		_status("snapshot slot %d is empty" % slot, true)
		return
	if _player == null or not is_instance_valid(_player):
		_status("cannot load snapshot: no player", true)
		return
	var snapshot: Dictionary = entry["snapshot"]
	var restored: Dictionary = _snapshot.restore(_player, snapshot)
	if not bool(restored.get("ok", false)):
		_status("snapshot load failed: " + str(restored.get("reason", "unknown")), true)
		return
	_snap_view()
	_was_paused_by_tas = true
	_sync_time_scale()
	_pending_pause = true
	var tick := int(entry.get("tick", 0))
	_status("loaded snapshot %d at tick %d" % [slot, tick])
	_log("snapshot slot %d loaded at tick %d" % [slot, tick])


func _slot_summary(slot: int) -> String:
	var entry = _snapshot_slots[slot]
	if entry == null:
		return "empty"
	return "tick %d" % int(entry.get("tick", 0))


# ══════════════════════════════════════════════════════════════════════════════
# Camera helpers
# ══════════════════════════════════════════════════════════════════════════════

func _snap_view() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	if _player.has_method(&"snap_followers"):
		_player.call(&"snap_followers")
	_snap_camera()


func _apply_paused_freelook() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	_snap_camera()


func _snap_camera() -> void:
	if _camera_manager == null:
		return
	var rotation_controller = _camera_manager.get("rotation_controller")
	if rotation_controller != null and rotation_controller.has_method(&"snap_to_target_rotation"):
		rotation_controller.call(&"snap_to_target_rotation")
	var position_controller = _camera_manager.get("position_controller")
	if position_controller != null and position_controller.has_method(&"snap_to_target_position"):
		position_controller.call(&"snap_to_target_position")
	if _camera_holder != null:
		_camera_holder.force_update_transform()


# ══════════════════════════════════════════════════════════════════════════════
# Player binding
# ══════════════════════════════════════════════════════════════════════════════

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
	_hitstop_original_t    = 0.0
	_hitstop_neutralized   = false

	# Capture before any neutralization changes it.
	if _look_input != null:
		_look_physics_was_enabled = _look_input.is_physics_processing()

	if _snapshot != null:
		_snapshot.bind(_player)
	_enable_perf()
	_enable_camera_order()
	_neutralize_hitstop()
	_sync_time_scale()
	_status("player ready", false, 2.0)
	_log("player bound: %s" % str(_player.get_path()))


func _on_player_lost() -> void:
	if _mode == TasMode.RECORDING:
		_stop_record()
	elif _mode == TasMode.REPLAYING:
		_stop_replay()

	if _snapshot != null:
		_snapshot.unbind()
	_restore_live_input_processing()
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
	_hitstop_original_t    = 0.0
	_hitstop_neutralized   = false
	_status("player lost; waiting", false, 3.0)


# ══════════════════════════════════════════════════════════════════════════════
# Perf / camera order / hitstop
# ══════════════════════════════════════════════════════════════════════════════

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
	var t = _hitstop.get("_t")
	_hitstop_original_t = float(t) if t != null else 0.0
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
	_hitstop.set("_t", _hitstop_original_t)
	_hitstop_neutralized = false


func _ensure_player_process_modes() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var mode := int(_player.get("player_mode"))
	if mode == 2:
		return
	var characterbody: Node = _player.get("characterbody")
	var marble: Node        = _player.get("marble")
	_player.set("process_mode", Node.PROCESS_MODE_INHERIT)
	if characterbody != null:
		characterbody.set("process_mode", Node.PROCESS_MODE_INHERIT if mode == 0 else Node.PROCESS_MODE_DISABLED)
	if marble != null:
		marble.set("process_mode", Node.PROCESS_MODE_INHERIT if mode == 1 else Node.PROCESS_MODE_DISABLED)
		marble.set("freeze", mode != 1)


## Owned only by _restore_live_input_processing; zeros vectors without touching
## set_physics_process so the two callers never fight over the toggle.
func _restore_look_physics() -> void:
	if _look_input == null:
		return
	_look_input.set(&"_mouse_relative", Vector2.ZERO)
	_look_input.set(&"_joy_value",      Vector2.ZERO)
	_look_input.set(&"_button_value",   Vector2.ZERO)


# ══════════════════════════════════════════════════════════════════════════════
# Input
# ══════════════════════════════════════════════════════════════════════════════

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
		# F8 / F9 / F10 belong to the ghost recorder (tas_ghost.gd). They are
		# deliberately not matched here so the event keeps propagating.
		#
		# Legacy snapshot / input-replay bindings, parked until the determinism
		# work is picked back up:
		#   KEY_F8  -> _save_snapshot(key_event.shift_pressed)
		#   KEY_F9  -> _load_snapshot(key_event.shift_pressed)
		#   KEY_F10 -> _pending_f10_record / _pending_ctrl_f10_det
		#   KEY_F11 -> _pending_f11_replay
		KEY_F12:
			_pending_f12_hud = true
		_:
			handled = false

	if handled:
		get_viewport().set_input_as_handled()


# ══════════════════════════════════════════════════════════════════════════════
# Utilities
# ══════════════════════════════════════════════════════════════════════════════

func _detect_hitches() -> void:
	if _was_paused_by_tas:
		_last_physics_frame = Engine.get_physics_frames()
		return
	var frame := Engine.get_physics_frames()
	if _last_physics_frame >= 0:
		var difference := frame - _last_physics_frame
		if difference > 1:
			_hitches += 1
			_last_hitch_tick = frame
			_log("frame hitch: %d physics ticks in one process frame at tick %d" % [
				difference, frame
			])
	_last_physics_frame = frame


func _status(message: String, error: bool = false, duration: float = 3.0) -> void:
	_status_message = message
	_status_error   = error
	_status_until   = Time.get_ticks_msec() + int(duration * 1000.0)
	if error:
		_log("ERROR: " + message)


func _has_cmdline_arg(flag: String) -> bool:
	for argument in OS.get_cmdline_args():
		if argument == flag:
			return true
	for argument in OS.get_cmdline_user_args():
		if argument == flag:
			return true
	return false


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


# ══════════════════════════════════════════════════════════════════════════════
# HUD
# ══════════════════════════════════════════════════════════════════════════════

func _telemetry_lines() -> Array[String]:
	var out: Array[String] = []
	if _player == null or not is_instance_valid(_player):
		return out

	var mode := int(_player.get("player_mode"))
	var body: Node3D = _player.get_current_body() as Node3D
	var vc: Node     = _player.get("velocity_component")

	var pos := Vector3.ZERO
	if body != null:
		pos = body.global_position

	var velocity := Vector3.ZERO
	if vc != null:
		var v = vc.get("velocity")
		if v is Vector3:
			velocity = v

	var grounded := false
	if body is CharacterBody3D:
		grounded = (body as CharacterBody3D).is_on_floor()
	elif body != null:
		grounded = bool(body.get("_is_on_floor"))

	var top_state := "?"
	var top_sm: Node = _player.get("state_machine")
	if top_sm != null and top_sm.get("current_state") != null:
		top_state = String(top_sm.get("current_state").name)

	var move_state := "?"
	var move_sm: Node = _player.get("movement_state_machine")
	if move_sm != null and move_sm.get("current_state") != null:
		move_state = String(move_sm.get("current_state").name)

	var horizontal := Vector2(velocity.x, velocity.z).length()

	out.append("pos  %.2f  %.2f  %.2f" % [pos.x, pos.y, pos.z])
	out.append("vel  h %.2f   v %.2f"  % [horizontal, velocity.y])
	out.append("state %s / %s" % [top_state, move_state])
	out.append("%s   %s" % [
		"grounded" if grounded else "airborne",
		"marble" if mode == 1 else "character",
	])
	return out


func _refresh_hud() -> void:
	if _hud == null:
		return

	var lines: Array[String] = []
	lines.append("[b]SNAPTIC-TAS[/b] %s" % VERSION)

	if _player == null:
		lines.append("waiting for player...")
	else:
		var run_state: String
		match _mode:
			TasMode.RECORDING:
				run_state = "[color=#ff4444]● REC %d ticks[/color]" % _record_tick_count
			TasMode.REPLAYING:
				run_state = "[color=#44ff88]▶ REPLAY %d / %d[/color]" % [_replay_tick, _replay_total_ticks]
			_:
				run_state = "PAUSED" if _was_paused_by_tas else "running"

		lines.append("tick %d   %s" % [Engine.get_physics_frames(), run_state])

		if _slowmo_index > 0 and not _was_paused_by_tas:
			lines.append("slow-mo %.2fx" % SLOWMO_STEPS[_slowmo_index])
		if _determinism != null:
			lines.append("[color=#ffcc44]determinism running…[/color]")

		lines.append("hitches %d   fps %d   physics %d" % [
			_hitches,
			Engine.get_frames_per_second(),
			Engine.physics_ticks_per_second,
		])
		lines.append_array(_telemetry_lines())
		lines.append("snapshot slot %d   %s" % [_slot, _slot_summary(_slot)])

	lines.append("[color=#9fb4c8]F6 pause   F7 step   Shift+F6 slow-mo   F12 HUD[/color]")
	lines.append("[color=#9fb4c8]F8/F9 snapshot   F10 record   F11 replay   Ctrl+F10 det[/color]")

	if Time.get_ticks_msec() <= _status_until and _status_message != "":
		var color := "#ff7070" if _status_error else "#9fe8a0"
		lines.append("[color=%s]%s[/color]" % [color, _status_message])

	_hud.call(&"set_status", lines, false)