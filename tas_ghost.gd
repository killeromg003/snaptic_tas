extends Node

## Standalone ghost recorder for SNAPTIC.
##
## Samples the active player body once per physics tick and replays the samples
## as a translucent proxy in the world. Playback only re-positions the proxy and
## its visual effects from recorded data, so it never re-simulates physics and is
## therefore immune to the engine's determinism problems.
##
## What is recorded per tick:
##   - body position, yaw, movement state, player mode
##   - which of the player's VFX nodes are active, plus their amount ratio
##   - one-shot VFX triggers (tick + which node) so retriggers are not lost
##   - impact bursts from Global.impact_particles (tick + position)
##
## Hotkeys
##   F8    start / stop recording (saves on stop)
##   F9    play / pause playback
##   F10   rewind playback to the start
##   Shift+F10  unload the ghost

const TICK_RATE: int = 60
const FORMAT_VERSION: int = 2

## px, py, pz, yaw, state_index, player_mode
const BASE_FLOATS: int = 6

## Per VFX node: active, amount_ratio
const VFX_FLOATS: int = 2

const MAX_FRAMES: int = 72000          # 20 minutes at 60 Hz
const GHOST_PATH: String = "user://snaptic_tas_ghost.dat"
const HUD_REFRESH_HZ: float = 12.0

const TRAIL_SAMPLES: int = 210
const TRAIL_HEAD_WIDTH: float = 0.16
const TRAIL_TAIL_WIDTH: float = 0.02
const TRAIL_COLOR := Color(0.55, 0.90, 1.0)
const TRAIL_ALPHA: float = 0.50

const IMPACT_LIFETIME_MS: int = 2500

const COLOR_RECORD := Color(1.0, 0.42, 0.42)
const COLOR_PLAY := Color(0.45, 0.85, 1.0)
const COLOR_IDLE := Color(0.74, 0.80, 0.88)
const COLOR_NOTE := Color(1.0, 0.80, 0.45)

enum Mode { IDLE, RECORDING, PLAYING }

var _mode: int = Mode.IDLE

## Flat frame data. Layout: BASE_FLOATS, then VFX_FLOATS per VFX node.
var _frames: PackedFloat32Array = PackedFloat32Array()
var _states: PackedStringArray = PackedStringArray()
var _stride: int = BASE_FLOATS
var _cursor: float = 0.0

## One entry per recorded VFX node: { path, xf }.
var _vfx_defs: Array = []
var _player_to_body: Transform3D = Transform3D.IDENTITY

## One-shot VFX triggers, appended from the VFX3D.vfx_started signal.
var _vfx_event_ticks: PackedInt32Array = PackedInt32Array()
var _vfx_event_index: PackedInt32Array = PackedInt32Array()
var _vfx_event_next: int = 0
var _vfx_connected: Array = []
var _vfx_was_active: PackedByteArray = PackedByteArray()

## Impact bursts sampled from Global.impact_particles.
var _impact_ticks: PackedInt32Array = PackedInt32Array()
var _impact_positions: PackedVector3Array = PackedVector3Array()
var _impact_next: int = 0
var _impact_was_emitting: bool = false
var _live_impacts: Array = []

var _ghost: Node3D = null
var _capsule: MeshInstance3D = null
var _sphere: MeshInstance3D = null
var _nose: MeshInstance3D = null
var _trail: MeshInstance3D = null
var _trail_mesh: ImmediateMesh = null
var _vfx_root: Node3D = null
var _vfx_clones: Array = []

var _hud_layer: CanvasLayer = null
var _hud_label: Label = null
var _note_label: Label = null
var _hud_text: String = ""
var _hud_accum: float = 0.0

var _note_text: String = ""
var _note_until: int = 0
var _last_usec: int = 0

var _pending_record: bool = false
var _pending_play: bool = false
var _pending_rewind: bool = false
var _pending_unload: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Sample after gameplay physics has updated the body this tick.
	process_physics_priority = 1000
	_last_usec = Time.get_ticks_usec()

	_build_hud()
	_load_ghost(GHOST_PATH)
	_refresh_hud(true)


# --------------------------------------------------------------------------
# Input
# --------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return

	match key.keycode:
		KEY_F8:
			_pending_record = true
		KEY_F9:
			_pending_play = true
		KEY_F10:
			if key.shift_pressed:
				_pending_unload = true
			else:
				_pending_rewind = true
		_:
			return

	get_viewport().set_input_as_handled()


# --------------------------------------------------------------------------
# Frame loop
# --------------------------------------------------------------------------

func _process(_delta: float) -> void:
	# Real elapsed time, so playback works while the game is paused or slowed.
	var now := Time.get_ticks_usec()
	var real_dt := clampf(float(now - _last_usec) / 1000000.0, 0.0, 0.25)
	_last_usec = now

	_consume_pending()
	_prune_impacts(now)

	if _mode == Mode.PLAYING:
		_advance(real_dt)

	_hud_accum += real_dt
	if _hud_accum >= 1.0 / HUD_REFRESH_HZ:
		_hud_accum = 0.0
		_refresh_hud()


func _physics_process(_delta: float) -> void:
	if _mode != Mode.RECORDING:
		return

	var player := _player()
	if player == null:
		return

	var body := _current_body(player)
	if body == null:
		return

	if _frame_count() >= MAX_FRAMES:
		_stop_recording()
		_note("recording cap reached (%d ticks)" % MAX_FRAMES)
		return

	var xform := body.global_transform
	var pos := xform.origin
	var yaw := xform.basis.get_euler().y
	var player_mode := int(player.get("player_mode"))

	_sample_impact()

	_frames.append(pos.x)
	_frames.append(pos.y)
	_frames.append(pos.z)
	_frames.append(yaw)
	_frames.append(_state_index(_state_name(player)))
	_frames.append(float(player_mode))

	_append_vfx_frame(player)


func _append_vfx_frame(player: Node) -> void:
	for entry in _vfx_defs:
		var node := player.get_node_or_null(NodePath(entry["path"]))
		var active := 0.0
		var amount := 0.0
		if node != null:
			active = 1.0 if _vfx_is_active(node) else 0.0
			if "amount_ratio" in node:
				amount = float(node.amount_ratio)
		_frames.append(active)
		_frames.append(amount)


## VFX3D.emitting is not reliable: the flag is cleared by vfx_finished while the
## particles are still alive, and some effects are driven straight on their
## child particle nodes. Treat any live child emitter as active as well.
func _vfx_is_active(node: Node) -> bool:
	if "emitting" in node and node.emitting:
		return true
	for child in node.get_children():
		if child is GPUParticles3D and child.emitting:
			return true
		if "playing" in child and child.playing:
			return true
	return false


func _on_vfx_started(index: int) -> void:
	if _mode != Mode.RECORDING:
		return
	_vfx_event_ticks.append(_frame_count())
	_vfx_event_index.append(index)


func _connect_vfx_signals(player: Node) -> void:
	_disconnect_vfx_signals()
	for index in _vfx_defs.size():
		var node := player.get_node_or_null(NodePath(_vfx_defs[index]["path"]))
		if node == null or not node.has_signal(&"vfx_started"):
			continue
		var callable := _on_vfx_started.bind(index)
		node.vfx_started.connect(callable)
		_vfx_connected.append({"node": node, "callable": callable})


func _disconnect_vfx_signals() -> void:
	for entry in _vfx_connected:
		var node = entry["node"]
		var callable: Callable = entry["callable"]
		if is_instance_valid(node) and node.vfx_started.is_connected(callable):
			node.vfx_started.disconnect(callable)
	_vfx_connected.clear()


func _sample_impact() -> void:
	var particles := _impact_source()
	if particles == null:
		return
	var emitting: bool = particles.emitting
	if emitting and not _impact_was_emitting:
		_impact_ticks.append(_frame_count())
		_impact_positions.append(particles.global_position)
	_impact_was_emitting = emitting


# --------------------------------------------------------------------------
# State transitions
# --------------------------------------------------------------------------

func _consume_pending() -> void:
	if _pending_unload:
		_pending_unload = false
		_unload()

	if _pending_record:
		_pending_record = false
		if _mode == Mode.RECORDING:
			_stop_recording()
		else:
			_start_recording()

	if _pending_play:
		_pending_play = false
		if _mode == Mode.PLAYING:
			# Freeze on the current frame but keep the ghost on screen.
			_mode = Mode.IDLE
			_apply(_cursor)
		else:
			_start_playback()

	if _pending_rewind:
		_pending_rewind = false
		_cursor = 0.0
		_impact_next = 0
		_vfx_event_next = 0
		if _ghost != null and is_instance_valid(_ghost):
			_apply(0.0)


func _start_recording() -> void:
	var player := _player()
	if player == null:
		_note("no player bound yet")
		return

	var body := _current_body(player)
	if body == null:
		_note("no player body yet")
		return

	_hide_ghost()
	_mode = Mode.RECORDING
	_frames = PackedFloat32Array()
	_states = PackedStringArray()
	_vfx_event_ticks = PackedInt32Array()
	_vfx_event_index = PackedInt32Array()
	_vfx_event_next = 0
	_impact_ticks = PackedInt32Array()
	_impact_positions = PackedVector3Array()
	_impact_next = 0
	_impact_was_emitting = false
	_cursor = 0.0

	_player_to_body = body.global_transform.affine_inverse() * (player as Node3D).global_transform
	_vfx_defs = _collect_vfx_defs(player)
	_stride = BASE_FLOATS + VFX_FLOATS * _vfx_defs.size()
	_vfx_was_active = PackedByteArray()
	_vfx_was_active.resize(_vfx_defs.size())
	_connect_vfx_signals(player)

	_note("recording (%d vfx channels)" % _vfx_defs.size())


func _stop_recording() -> void:
	_mode = Mode.IDLE
	_disconnect_vfx_signals()

	var count := _frame_count()
	if count == 0:
		_note("nothing recorded")
		return

	_save_ghost(GHOST_PATH)
	_cursor = 0.0
	_note("recorded %d ticks (%.1fs), %d vfx events" % [
		count, float(count) / float(TICK_RATE), _vfx_event_ticks.size()
	])
	print("SNAPTIC-TAS ghost: recorded %d ticks, %d vfx events" % [
		count, _vfx_event_ticks.size()
	])


func _start_playback() -> void:
	if _frames.is_empty():
		_note("no ghost loaded")
		return

	var last := float(_frame_count() - 1)
	var resuming := _cursor > 0.0 and _cursor < last
	if not resuming:
		_cursor = 0.0
		_impact_next = 0
		_vfx_event_next = 0

	_mode = Mode.PLAYING
	_ensure_ghost()
	_ensure_vfx()
	_apply(_cursor)
	_note("%s %d ticks at %s" % [
		"resuming" if resuming else "playing",
		_frame_count(), _format_time(_cursor),
	])


func _advance(real_dt: float) -> void:
	var last := float(_frame_count() - 1)
	_cursor += real_dt * float(TICK_RATE)
	if _cursor >= last:
		_cursor = last
		_apply(_cursor)
		_mode = Mode.IDLE
		_note("playback finished")
		return
	_apply(_cursor)


# --------------------------------------------------------------------------
# Playback
# --------------------------------------------------------------------------

func _apply(cursor: float) -> void:
	if _frames.is_empty():
		return

	_ensure_ghost()
	if _ghost == null:
		return

	var last := _frame_count() - 1
	var i := clampi(int(cursor), 0, last)
	var j := mini(i + 1, last)
	var t := clampf(cursor - float(i), 0.0, 1.0)

	var a := i * _stride
	var b := j * _stride
	var from := Vector3(_frames[a], _frames[a + 1], _frames[a + 2])
	var to := Vector3(_frames[b], _frames[b + 1], _frames[b + 2])
	var pos := from.lerp(to, t)
	var yaw := lerp_angle(_frames[a + 3], _frames[b + 3], t)
	var xform := Transform3D(Basis(Vector3.UP, yaw), pos)

	_ghost.global_transform = xform

	var is_marble := int(round(_frames[a + 5])) == 1
	if _capsule != null:
		_capsule.visible = not is_marble
	if _nose != null:
		_nose.visible = not is_marble
	if _sphere != null:
		_sphere.visible = is_marble

	_apply_vfx(a, xform)
	_spawn_due_vfx_events(i)
	_spawn_due_impacts(i)
	_update_trail(cursor)


func _apply_vfx(frame_offset: int, ghost_xform: Transform3D) -> void:
	if _vfx_clones.is_empty() and not _vfx_defs.is_empty():
		_ensure_vfx()
	if _vfx_clones.is_empty():
		return

	var player_xform := ghost_xform * _player_to_body
	for index in _vfx_clones.size():
		var clone = _vfx_clones[index]
		if clone == null or not is_instance_valid(clone):
			continue

		var offset := frame_offset + BASE_FLOATS + index * VFX_FLOATS
		var active: bool = _frames[offset] > 0.5
		var amount := _frames[offset + 1]

		if "amount_ratio" in clone:
			clone.amount_ratio = amount

		# Starts are driven by the recorded vfx_started events. Only the stop
		# edge needs handling here.
		if index < _vfx_was_active.size():
			if not active and _vfx_was_active[index] != 0:
				clone.stop_vfx()
			_vfx_was_active[index] = 1 if active else 0

		clone.global_transform = player_xform * (_vfx_defs[index]["xf"] as Transform3D)


func _spawn_due_vfx_events(frame_index: int) -> void:
	while _vfx_event_next < _vfx_event_ticks.size() \
			and _vfx_event_ticks[_vfx_event_next] <= frame_index:
		_emit_clone_vfx(_vfx_event_index[_vfx_event_next], _vfx_event_ticks[_vfx_event_next])
		_vfx_event_next += 1


## Each effect family expects different emit arguments, and the game passes them
## from gameplay state that is not recorded. Feed the variants the arguments
## they need so the effect lands on the ghost instead of at the world origin.
func _emit_clone_vfx(index: int, tick: int) -> void:
	var clone = _vfx_clones[index] if index < _vfx_clones.size() else null
	if clone == null or not is_instance_valid(clone):
		return

	var offset := tick * _stride + BASE_FLOATS + index * VFX_FLOATS
	var amount := 1.0
	if offset + 1 < _frames.size():
		amount = _frames[offset + 1]

	var at: Vector3 = clone.global_position
	var frame_basis: Basis = clone.global_basis

	if "packed_scene" in clone:
		clone.emit_vfx({&"global_position": at, &"global_basis": frame_basis, &"amount_ratio": amount})
	elif "initial_color" in clone:
		clone.emit_vfx({&"global_position": at, &"direction": -frame_basis.z})
	elif "amount_ratio" in clone:
		clone.emit_vfx()
	else:
		clone.emit_vfx({&"position": at, &"normal": Vector3.UP})


func _spawn_due_impacts(frame_index: int) -> void:
	while _impact_next < _impact_ticks.size() and _impact_ticks[_impact_next] <= frame_index:
		_spawn_impact(_impact_positions[_impact_next])
		_impact_next += 1


func _spawn_impact(at: Vector3) -> void:
	var source := _impact_source()
	if source == null:
		return

	var clone = source.duplicate()
	if clone == null:
		return

	if "delete_on_finished" in clone:
		clone.delete_on_finished = false

	_ensure_vfx_root()
	if _vfx_root == null:
		clone.queue_free()
		return

	_vfx_root.add_child(clone)
	clone.owner = _vfx_root
	clone.global_position = at
	clone.visible = true
	clone.emit_vfx()
	_live_impacts.append({"node": clone, "until": Time.get_ticks_msec() + IMPACT_LIFETIME_MS})


func _prune_impacts(now_usec: int) -> void:
	if _live_impacts.is_empty():
		return

	var now_ms := now_usec / 1000
	var keep: Array = []
	for entry in _live_impacts:
		var node = entry["node"]
		if not is_instance_valid(node):
			continue
		if now_ms >= int(entry["until"]):
			node.queue_free()
			continue
		keep.append(entry)
	_live_impacts = keep


# --------------------------------------------------------------------------
# Trail
# --------------------------------------------------------------------------

func _update_trail(cursor: float) -> void:
	if _trail_mesh == null:
		return

	var head := mini(int(cursor), _frame_count() - 1)
	var tail := maxi(0, head - TRAIL_SAMPLES)
	if head - tail < 2:
		_trail_mesh.clear_surfaces()
		return

	var camera := _camera()
	if camera == null:
		_trail_mesh.clear_surfaces()
		return

	var cam_pos := camera.global_position
	var span := float(head - tail)

	_trail_mesh.clear_surfaces()
	_trail_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for index in range(tail, head + 1):
		var offset := index * _stride
		var point := Vector3(_frames[offset], _frames[offset + 1], _frames[offset + 2])
		var next_offset := mini(index + 1, head) * _stride
		var next_point := Vector3(
			_frames[next_offset], _frames[next_offset + 1], _frames[next_offset + 2]
		)
		var prev_offset := maxi(index - 1, tail) * _stride
		var prev_point := Vector3(
			_frames[prev_offset], _frames[prev_offset + 1], _frames[prev_offset + 2]
		)

		var direction := next_point - prev_point
		if direction.length_squared() < 0.000001:
			direction = Vector3.FORWARD
		var to_camera := cam_pos - point
		if to_camera.length_squared() < 0.000001:
			continue
		var side := direction.cross(to_camera).normalized()

		var age := float(head - index) / span
		var width := lerpf(TRAIL_HEAD_WIDTH, TRAIL_TAIL_WIDTH, age)
		var color := TRAIL_COLOR
		color.a = TRAIL_ALPHA * (1.0 - age)

		_trail_mesh.surface_set_color(color)
		_trail_mesh.surface_add_vertex(point + side * width)
		_trail_mesh.surface_set_color(color)
		_trail_mesh.surface_add_vertex(point - side * width)
	_trail_mesh.surface_end()


# --------------------------------------------------------------------------
# Ghost visual
# --------------------------------------------------------------------------

func _ensure_ghost() -> void:
	_ensure_vfx_root()

	var player := _player()
	if player == null:
		return

	var parent := player.get_parent()
	if parent == null:
		return

	if _ghost != null and is_instance_valid(_ghost) and _ghost.get_parent() == parent:
		_ghost.visible = true
		return

	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()

	_ghost = _build_ghost()
	parent.add_child(_ghost)


func _ensure_vfx_root() -> void:
	var player := _player()
	if player == null:
		return
	var parent := player.get_parent()
	if parent == null:
		return

	if _vfx_root != null and is_instance_valid(_vfx_root) and _vfx_root.get_parent() == parent:
		return

	_hide_vfx()
	_vfx_root = Node3D.new()
	_vfx_root.name = "TASGhostVFX"
	_vfx_root.top_level = true
	parent.add_child(_vfx_root)


func _ensure_vfx() -> void:
	if _vfx_defs.is_empty():
		return

	var player := _player()
	if player == null:
		return

	_ensure_vfx_root()
	if _vfx_root == null:
		return

	if not _vfx_clones.is_empty():
		return

	_vfx_clones.clear()
	for entry in _vfx_defs:
		var source = player.get_node_or_null(NodePath(entry["path"]))
		if source == null:
			_vfx_clones.append(null)
			continue

		var clone = source.duplicate()
		if clone == null:
			_vfx_clones.append(null)
			continue

		if "delete_on_finished" in clone:
			clone.delete_on_finished = false

		_vfx_root.add_child(clone)
		# Give clones a valid owner: several VFX scripts do `"x" in owner` and
		# would otherwise hit a null base object during playback.
		clone.owner = _vfx_root
		clone.stop_vfx()
		_vfx_clones.append(clone)

	_vfx_was_active = PackedByteArray()
	_vfx_was_active.resize(_vfx_clones.size())


func _collect_vfx_defs(player: Node) -> Array:
	var defs: Array = []
	var anchor := (player as Node3D).global_transform.affine_inverse()

	for node in player.find_children("*", "", true, false):
		if not _is_replayable_vfx(node):
			continue
		var node_3d := node as Node3D
		defs.append({
			"path": str(player.get_path_to(node_3d)),
			"xf": anchor * node_3d.global_transform,
		})
	return defs


func _is_replayable_vfx(node: Node) -> bool:
	if not (node is Node3D):
		return false
	if not node.has_method(&"emit_vfx"):
		return false
	if not node.has_signal(&"vfx_started"):
		return false
	# Skeleton afterimages snapshot bone poses; they cannot be rebuilt from a
	# capsule ghost and would just spawn empty rigs.
	if "ghost_count" in node:
		return false
	return true


func _build_ghost() -> Node3D:
	var root := Node3D.new()
	root.name = "TASGhost"

	var material := _ghost_material()

	_capsule = MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	_capsule.mesh = capsule
	_capsule.material_override = material
	_capsule.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_capsule.position = Vector3(0.0, 0.9, 0.0)
	root.add_child(_capsule)

	_nose = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.22, 0.16, 0.36)
	_nose.mesh = box
	_nose.material_override = material
	_nose.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_nose.position = Vector3(0.0, 1.25, -0.32)
	root.add_child(_nose)

	_sphere = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	_sphere.mesh = sphere
	_sphere.material_override = material
	_sphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sphere.visible = false
	root.add_child(_sphere)

	_trail_mesh = ImmediateMesh.new()
	_trail = MeshInstance3D.new()
	_trail.name = "TASGhostTrail"
	_trail.mesh = _trail_mesh
	_trail.material_override = _trail_material()
	_trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_trail.top_level = true
	root.add_child(_trail)

	return root


func _ghost_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.45, 0.85, 1.0, 0.42)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	return material


func _trail_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	return material


func _hide_ghost() -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.visible = false
		if _trail_mesh != null:
			_trail_mesh.clear_surfaces()
	_hide_vfx()


func _hide_vfx() -> void:
	if _vfx_root != null and is_instance_valid(_vfx_root):
		_vfx_root.queue_free()
	_vfx_root = null
	_vfx_clones.clear()
	_vfx_was_active = PackedByteArray()
	for entry in _live_impacts:
		var node = entry["node"]
		if is_instance_valid(node):
			node.queue_free()
	_live_impacts.clear()


# --------------------------------------------------------------------------
# Persistence
# --------------------------------------------------------------------------

func _save_ghost(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_note("could not write " + path)
		return
	file.store_var({
		"format": FORMAT_VERSION,
		"tick_rate": TICK_RATE,
		"level": _level_label(),
		"created": Time.get_datetime_string_from_system(),
		"stride": _stride,
		"player_to_body": _player_to_body,
		"vfx": _vfx_defs,
		"vfx_event_ticks": _vfx_event_ticks,
		"vfx_event_index": _vfx_event_index,
		"frames": _frames,
		"states": _states,
		"impact_ticks": _impact_ticks,
		"impact_positions": _impact_positions,
	})
	file.close()


func _load_ghost(path: String) -> void:
	if not FileAccess.file_exists(path):
		return

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var data = file.get_var()
	file.close()

	if typeof(data) != TYPE_DICTIONARY:
		return

	var entry: Dictionary = data
	if int(entry.get("format", 0)) != FORMAT_VERSION:
		return

	var frames = entry.get("frames", null)
	var states = entry.get("states", null)
	if not (frames is PackedFloat32Array) or not (states is PackedStringArray):
		return

	var stride := int(entry.get("stride", 0))
	if stride < BASE_FLOATS:
		return

	var packed: PackedFloat32Array = frames
	if packed.is_empty() or packed.size() % stride != 0:
		return

	var vfx = entry.get("vfx", null)
	if not (vfx is Array):
		return
	var defs: Array = vfx
	if stride != BASE_FLOATS + VFX_FLOATS * defs.size():
		return

	var player_to_body = entry.get("player_to_body", null)
	if not (player_to_body is Transform3D):
		return

	var event_ticks = entry.get("vfx_event_ticks", null)
	var event_index = entry.get("vfx_event_index", null)
	if not (event_ticks is PackedInt32Array) or not (event_index is PackedInt32Array):
		return
	if event_ticks.size() != event_index.size():
		return

	var ticks = entry.get("impact_ticks", null)
	var positions = entry.get("impact_positions", null)
	if not (ticks is PackedInt32Array) or not (positions is PackedVector3Array):
		return
	if ticks.size() != positions.size():
		return

	_frames = packed
	_states = states
	_stride = stride
	_vfx_defs = defs
	_player_to_body = player_to_body
	_vfx_event_ticks = event_ticks
	_vfx_event_index = event_index
	_impact_ticks = ticks
	_impact_positions = positions
	_vfx_event_next = 0
	_impact_next = 0
	_cursor = 0.0
	_mode = Mode.IDLE


func _unload() -> void:
	_hide_ghost()
	_mode = Mode.IDLE
	_frames = PackedFloat32Array()
	_states = PackedStringArray()
	_vfx_defs = []
	_stride = BASE_FLOATS
	_vfx_event_ticks = PackedInt32Array()
	_vfx_event_index = PackedInt32Array()
	_vfx_event_next = 0
	_impact_ticks = PackedInt32Array()
	_impact_positions = PackedVector3Array()
	_impact_next = 0
	_cursor = 0.0
	_note("ghost unloaded")


# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

func _player() -> Node:
	return get_tree().get_first_node_in_group(&"player")


func _current_body(player: Node) -> Node3D:
	if player.has_method(&"get_current_body"):
		var body = player.call(&"get_current_body")
		if body is Node3D:
			return body
	return null


func _impact_source() -> Node3D:
	var global := get_node_or_null(^"/root/Global")
	if global == null:
		return null
	var particles = global.get("impact_particles")
	if particles is Node3D and is_instance_valid(particles):
		return particles
	return null


func _camera() -> Camera3D:
	if _ghost != null and is_instance_valid(_ghost):
		var viewport := _ghost.get_viewport()
		if viewport != null:
			return viewport.get_camera_3d()
	return null


func _state_name(player: Node) -> String:
	var machine = player.get("movement_state_machine")
	if machine == null:
		return ""
	var state = machine.get("current_state")
	if state == null:
		return ""
	return str(state.name)


func _state_index(state: String) -> float:
	var index := _states.find(state)
	if index < 0:
		_states.append(state)
		index = _states.size() - 1
	return float(index)


func _frame_count() -> int:
	if _stride < BASE_FLOATS:
		return 0
	return _frames.size() / _stride


func _level_label() -> String:
	var player := _player()
	if player == null:
		return "?"
	var parent := player.get_parent()
	if parent == null:
		return "?"
	return str(parent.name)


func _format_time(ticks: float) -> String:
	var seconds := ticks / float(TICK_RATE)
	return "%d:%05.2f" % [int(seconds / 60.0), fmod(seconds, 60.0)]


func _note(message: String) -> void:
	_note_text = message
	_note_until = Time.get_ticks_msec() + 3000
	print("SNAPTIC-TAS ghost: " + message)


# --------------------------------------------------------------------------
# HUD
# --------------------------------------------------------------------------

func _build_hud() -> void:
	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 127
	add_child(_hud_layer)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud_layer.add_child(root)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override(&"margin_left", 26)
	margin.add_theme_constant_override(&"margin_right", 26)
	margin.add_theme_constant_override(&"margin_top", 22)
	margin.add_theme_constant_override(&"margin_bottom", 24)
	root.add_child(margin)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_END
	box.add_theme_constant_override(&"separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(box)

	_hud_label = _make_label(13)
	box.add_child(_hud_label)

	_note_label = _make_label(12)
	_note_label.add_theme_color_override(&"font_color", COLOR_NOTE)
	box.add_child(_note_label)


func _make_label(font_size: int) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	label.add_theme_constant_override(&"outline_size", 5)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return label


func _refresh_hud(force: bool = false) -> void:
	if _hud_label == null:
		return

	var text := ""
	var color := COLOR_IDLE

	match _mode:
		Mode.RECORDING:
			color = COLOR_RECORD
			var blink := "●" if (Time.get_ticks_msec() / 500) % 2 == 0 else "○"
			text = "GHOST  %s REC  %s   %s   F8 stop" % [
				blink, _format_time(float(_frame_count())), _level_label()
			]
		Mode.PLAYING:
			color = COLOR_PLAY
			text = "GHOST  ▶ PLAY  %s / %s   F9 pause" % [
				_format_time(_cursor), _format_time(float(_frame_count()))
			]
		_:
			if _frames.is_empty():
				text = "GHOST  idle   F8 record"
			else:
				text = "GHOST  ■ %s   F9 play   F8 record" % _format_time(float(_frame_count()))

	if force or text != _hud_text:
		_hud_text = text
		_hud_label.text = text
		_hud_label.add_theme_color_override(&"font_color", color)

	if Time.get_ticks_msec() < _note_until and _note_text != "":
		_note_label.text = _note_text
	else:
		_note_label.text = ""
