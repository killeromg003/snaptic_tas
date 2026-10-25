extends RefCounted

## Curated player/camera/input snapshot.
##
## The snapshot is intentionally not a full world save. It captures everything
## that can influence the player's next simulation tick: both bodies, the
## velocity component, state machines and their script variables, the marble
## static timers, InputBuffers, the control basis, the checkpoint, and the
## camera rotation state. Level props are not restored; see README known issues.

const FORMAT_VERSION: int = 1

const ALLOWED_TOP_STATES: Array[String] = ["Actionable"]
const ALLOWED_MOVEMENT_STATES: Array[String] = [
	"Grounded",
	"Jumpsquat",
	"Aerial",
	"Bhopping",
	"Landing",
	"MarbleGrounded",
	"MarbleAerial",
	"MarbleMagnetized",
	"MarbleTubing",
	"WallCling",
	"WallJumpsquat",
	"LongJumping",
]

const BLOCKED_VARS: Array[String] = [
	"p",
	"state_machine",
	"subject",
	"squashable_node",
	"head_shaker",
	"orbit_axis_mesh",
	"stretch_curve",
	"blend_curve",
	"lj_blend_curve",
	"_wall_slide_sfx",
	"_cant_unmarble_sfx",
	"_marble_loop",
	"_marble_loop_volume",
	"_time_since_contact",
	"_already_played_marble_magnetized",
	"_time_as_marble",
	"revive_flash_tween",
	"camera_holder",
	"shape_cast",
	"look_at_nodes",
	"arm_distance",
	"_effective_arm_distance",
]

const INPUT_BUFFER_FIELDS: Array[String] = [
	"_smash_input",
	"helicopter_input",
	"_do_marble_buffer_timer",
	"_jump_buffer_timer",
	"_smash_input_timer",
	"_do_marble_press_msec",
	"_do_marble_is_double",
	"_double_marble_open_msec",
	"_old_smash_input",
	"_was_do_marble_pressed",
	"_prev_stick_angle",
	"_prev_stick_magnitude",
	"_stick_cumulitave_angle",
	"_avg_stick_angular_speed",
	"_helicopter_buffer_i",
]

const MARBLE_STATICS: Array[String] = [
	"perfect_jump_count",
	"_coyote_timer",
	"_time_on_floor",
	"_jump_consumed",
	"time_since_jump",
	"consume_do_marble",
	"ground_pound",
]

var _player: Node = null
var _level_loader: Node = null
var _global: Node = null
var _input_buffers: Node = null
var _look_input: Node = null
var _camera_holder: Node = null
var _manager: Node = null
var _marble_probe: Node = null


func bind(player: Node) -> void:
	if _player == player:
		return
	_player = player
	var tree := player.get_tree()
	if tree == null:
		return
	var root := tree.root
	_level_loader = root.get_node_or_null(^"LevelLoader")
	_global = root.get_node_or_null(^"Global")
	_input_buffers = root.get_node_or_null(^"InputBuffers")
	_look_input = root.get_node_or_null(^"LookInput")
	_camera_holder = tree.get_first_node_in_group(&"camera_holder")
	_manager = _camera_holder.get_node_or_null(^"CameraControllerManager") if _camera_holder else null


func unbind() -> void:
	if _marble_probe != null:
		_marble_probe.free()
		_marble_probe = null
	_player = null
	_level_loader = null
	_global = null
	_input_buffers = null
	_look_input = null
	_camera_holder = null
	_manager = null


func can_capture(player: Node) -> Dictionary:
	if player == null or not is_instance_valid(player):
		return {"ok": false, "reason": "no player"}
	var state_machine: Node = player.get("state_machine")
	var movement_state_machine: Node = player.get("movement_state_machine")
	if state_machine == null or movement_state_machine == null:
		return {"ok": false, "reason": "player state machines are not ready"}

	var top := _state_name(state_machine.get("current_state"))
	if not ALLOWED_TOP_STATES.has(top):
		return {"ok": false, "reason": "top state '%s' is not stable (need Actionable)" % top}

	var movement := _state_name(movement_state_machine.get("current_state"))
	if not ALLOWED_MOVEMENT_STATES.has(movement):
		return {"ok": false, "reason": "movement state '%s' is not snapshottable" % movement}

	var mode := int(_prop(player, "player_mode", -1))
	if mode == 2:
		return {"ok": false, "reason": "ragdoll snapshots are not supported"}
	if mode < 0 or mode > 1:
		return {"ok": false, "reason": "unknown player mode %d" % mode}

	var characterbody: Node = player.get("characterbody")
	if characterbody != null and int(_prop(characterbody, "_ghost_frames_left", 0)) > 0:
		return {"ok": false, "reason": "characterbody teleport is still in progress"}

	var health: Node = player.get("health")
	if health != null and int(_prop(health, "current", 1)) <= 0:
		return {"ok": false, "reason": "player is dead"}

	return {"ok": true, "reason": ""}


func capture(player: Node, tick: int) -> Dictionary:
	bind(player)
	var characterbody: Node = player.get("characterbody")
	var marble: Node = player.get("marble")
	var velocity_component: Node = player.get("velocity_component")

	var snapshot := {
		"format": FORMAT_VERSION,
		"tick": tick,
		"level": int(_prop(_level_loader, "current_level", -1)),
		"player_path": _path_of(player),
		"sim": {
			"player": _capture_player(player),
			"characterbody": _capture_characterbody(characterbody),
			"marble": _capture_marble(marble),
			"velocity_component": _capture_velocity_component(velocity_component),
			"state_machines": _capture_state_machines(player),
			"states": _capture_states(player),
			"statics": _capture_statics(),
			"input_buffers": _capture_input_buffers(),
			"global": _capture_global(),
			"checkpoint": _capture_checkpoint(player),
		},
		"camera": _capture_camera(),
		"hash": 0,
	}
	snapshot["hash"] = hash(snapshot)
	return snapshot


func restore(player: Node, snapshot: Dictionary) -> Dictionary:
	if player == null or not is_instance_valid(player):
		return {"ok": false, "reason": "no player"}
	if int(snapshot.get("format", 0)) != FORMAT_VERSION:
		return {"ok": false, "reason": "unsupported snapshot format"}

	var saved_level := int(snapshot.get("level", -1))
	var current_level := int(_prop(_level_loader, "current_level", -2))
	if saved_level != current_level:
		return {"ok": false, "reason": "snapshot level %d != current level %d" % [saved_level, current_level]}

	var saved_path := str(snapshot.get("player_path", ""))
	if saved_path != "" and _path_of(player) != saved_path:
		return {"ok": false, "reason": "snapshot belongs to a different player node"}

	var sim: Dictionary = snapshot.get("sim", {})
	var player_state: Dictionary = sim.get("player", {})
	var mode := int(player_state.get("mode", 0))
	if mode == 2:
		return {"ok": false, "reason": "ragdoll snapshots are not supported"}

	# The player_mode setter has side effects (body enable/disable, deferred
	# basis changes). Run it first, then overwrite all transforms/velocities.
	player.set("player_mode", mode)

	var characterbody: Node = player.get("characterbody")
	var marble: Node = player.get("marble")
	var velocity_component: Node = player.get("velocity_component")
	var body := marble if mode == 1 else characterbody

	if velocity_component != null:
		velocity_component.set("entity", body)
	_set_current_body(player, mode)

	_restore_characterbody(characterbody, sim.get("characterbody", {}))
	_restore_marble(marble, sim.get("marble", {}))
	_restore_velocity_component(velocity_component, sim.get("velocity_component", {}))

	_restore_state_machines(player, sim.get("state_machines", {}))
	_restore_states(player, sim.get("states", {}))
	_restore_statics(sim.get("statics", {}))
	_restore_input_buffers(sim.get("input_buffers", {}))
	_restore_global(sim.get("global", {}))
	_restore_checkpoint(player, sim.get("checkpoint", {}))
	_restore_camera(snapshot.get("camera", {}))
	_restore_player(player, player_state)

	if characterbody != null:
		characterbody.set("_last_move_frame", -1)
	if _global != null:
		_global.set("_control_tick", -1)

	var state_machines: Dictionary = sim.get("state_machines", {})
	var deferred := {
		"mode": mode,
		"cb_transform": sim.get("characterbody", {}).get("transform", Transform3D.IDENTITY),
		"cb_velocity": sim.get("characterbody", {}).get("velocity", Vector3.ZERO),
		"mb_transform": sim.get("marble", {}).get("transform", Transform3D.IDENTITY),
		"mb_linear": sim.get("marble", {}).get("linear_velocity", Vector3.ZERO),
		"mb_angular": sim.get("marble", {}).get("angular_velocity", Vector3.ZERO),
		"mb_freeze": sim.get("marble", {}).get("freeze", true),
		"top_current": state_machines.get("top", {}).get("current", ""),
		"movement_current": state_machines.get("movement", {}).get("current", ""),
	}
	_deferred_reapply(player, deferred)
	return {"ok": true, "reason": ""}

func active_only(sim: Dictionary) -> Dictionary:
	var out := sim.duplicate(true)
	var mode := int(sim.get("player", {}).get("mode", 0))
	if mode == 0:
		out.erase("marble")
	else:
		out.erase("characterbody")
	return out

func hash(snapshot: Dictionary) -> int:
	var sim: Dictionary
	var camera: Dictionary
	if snapshot.has("sim") and snapshot.get("sim") is Dictionary:
		sim = snapshot.get("sim", {})
		camera = snapshot.get("camera", {})
	else:
		sim = snapshot
		camera = {}

	var rotation_controllers: Array = []
	for entry in camera.get("controllers", []):
		if entry.get("kind", "") == "rotation":
			rotation_controllers.append(entry)
	# Sort by path so that even if a caller builds the controllers array in
	# a non-deterministic order, the hash is stable. The camera manager's
	# internal array order can change on activation, which would otherwise
	# make two identical camera states hash differently.
	rotation_controllers.sort_custom(
		func(a, b): return str(a.get("path", "")) < str(b.get("path", ""))
	)

	var holder_transform: Transform3D = camera.get("holder_transform", Transform3D.IDENTITY)
	var payload := {
		"format": int(snapshot.get("format", FORMAT_VERSION)),
		"level": int(snapshot.get("level", -1)),
		"sim": active_only(sim),      # ← was: sim
		"camera_rotation": rotation_controllers,
	}
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(payload))
	var digest := context.finish()
	return digest.decode_s64(0)


func _capture_player(player: Node) -> Dictionary:
	var health: Node = player.get("health")
	return {
		"mode": int(_prop(player, "player_mode", 0)),
		"has_do_marble": bool(_prop(player, "has_do_marble", false)),
		"has_ground_pound": bool(_prop(player, "has_ground_pound", false)),
		"visible": bool(_prop(player, "visible", true)),
		"health_current": int(_prop(health, "current", 0)),
		"health_maximum": int(_prop(health, "maximum", 0)),
	}


func _capture_characterbody(body: Node) -> Dictionary:
	if body == null:
		return {}
	var pending_body = _prop(body, "_pending_pushback_body")
	return {
		"transform": _prop(body, "global_transform", Transform3D.IDENTITY),
		"velocity": _prop(body, "velocity", Vector3.ZERO),
		"was_on_floor": bool(_prop(body, "_was_on_floor", false)),
		"was_on_wall": bool(_prop(body, "_was_on_wall", false)),
		"pending_pushback": _prop(body, "_pending_pushback", Vector3.ZERO),
		"pending_pushback_best": float(_prop(body, "_pending_pushback_best", 0.0)),
		"pending_pushback_body": _path_of(pending_body),
		"floor_local_point": _prop(body, "_floor_local_point", Vector3.ZERO),
		"floor_normal": _prop(body, "_floor_normal", Vector3.UP),
		"floor_collider": _path_of(_prop(body, "floor_collider")),
		"wall_collider": _path_of(_prop(body, "_wall_collider")),
		"solid_layer": int(_prop(body, "_solid_layer", 0)),
		"solid_mask": int(_prop(body, "_solid_mask", 0)),
		"ghost_frames_left": int(_prop(body, "_ghost_frames_left", 0)),
		"collision_layer": int(_prop(body, "collision_layer", 0)),
		"collision_mask": int(_prop(body, "collision_mask", 0)),
		"contact_ids": _copy_contact_ids(_prop(body, "_contact_ids", {})),
	}


func _capture_marble(body: Node) -> Dictionary:
	if body == null:
		return {}
	var magnet: Node = _prop(body, "magnet")
	return {
		"transform": _prop(body, "global_transform", Transform3D.IDENTITY),
		"linear_velocity": _prop(body, "linear_velocity", Vector3.ZERO),
		"angular_velocity": _prop(body, "angular_velocity", Vector3.ZERO),
		"sleeping": bool(_prop(body, "sleeping", false)),
		"freeze": bool(_prop(body, "freeze", true)),
		"gravity_scale": float(_prop(body, "gravity_scale", 1.0)),
		"collision_layer": int(_prop(body, "collision_layer", 0)),
		"collision_mask": int(_prop(body, "collision_mask", 0)),
		"prev_position": _prop(body, "_prev_position", Vector3.ZERO),
		"has_prev_position": bool(_prop(body, "_has_prev_position", false)),
		"is_on_floor": bool(_prop(body, "_is_on_floor", false)),
		"is_touching": bool(_prop(body, "_is_touching", false)),
		"was_on_floor": bool(_prop(body, "_was_on_floor", false)),
		"floor_contact_point": _prop(body, "_floor_contact_point", Vector3.ZERO),
		"floor_contact_normal": _prop(body, "_floor_contact_normal", Vector3.UP),
		"contact_point": _prop(body, "_contact_point", Vector3.ZERO),
		"contact_normal": _prop(body, "_contact_normal", Vector3.UP),
		"magnet_nearest": _path_of(_prop(magnet, "nearest_overlapping")),
	}


func _capture_velocity_component(component: Node) -> Dictionary:
	if component == null:
		return {}
	return {
		"smoothed_delta_velocity": _prop(component, "_smoothed_delta_velocity", Vector3.ZERO),
		"previous_velocity": _prop(component, "_previous_velocity", Vector3.ZERO),
		"movement_config_index": int(_prop(component, "movement_config_index", 0)),
		"last_known_gravity": _prop(component, "_last_known_gravity", Vector3.ZERO),
	}


func _capture_state_machines(player: Node) -> Dictionary:
	var state_machine: Node = player.get("state_machine")
	var movement_state_machine: Node = player.get("movement_state_machine")
	return {
		"top": {
			"current": _state_name(_prop(state_machine, "current_state")),
			"prev": _state_name(_prop(state_machine, "prev_state")),
		},
		"movement": {
			"current": _state_name(_prop(movement_state_machine, "current_state")),
			"prev": _state_name(_prop(movement_state_machine, "prev_state")),
		},
	}


func _capture_states(player: Node) -> Dictionary:
	var out := {}
	for state in _all_states(player):
		out[_path_of_relative(player, state)] = _capture_vars(state)
	return out


func _capture_statics() -> Dictionary:
	var probe := _ensure_marble_probe()
	var out := {}
	for name in MARBLE_STATICS:
		out[name] = _prop(probe, name, null)
	return out


func _capture_input_buffers() -> Dictionary:
	if _input_buffers == null:
		return {}
	var out := {}
	for name in INPUT_BUFFER_FIELDS:
		var value = _input_buffers.get(name)
		if _is_plain(value):
			out[name] = value
	return out


func _capture_global() -> Dictionary:
	return {
		"control_basis": _prop(_global, "_control_basis", Basis.IDENTITY),
		"previous_surface_up": _prop(_global, "_previous_surface_up", Vector3.UP),
		"is_impacting": bool(_prop(_global, "is_impacting", false)),
	}


func _capture_checkpoint(player: Node) -> Dictionary:
	var checkpoint: Node = player.get("checkpoint_saver")
	return {
		"last": _path_of(_prop(checkpoint, "last_touched_checkpoint")),
		"fallback": _prop(checkpoint, "_fallback_position", Vector3.ZERO),
	}

func _capture_camera() -> Dictionary:
	var controllers: Array = []
	var rotation_probe: Node = null
	var position_probe: Node = null

	if _manager != null:
		var list = _manager.get("camera_controllers")
		if list is Array:
			for controller in list:
				if controller == null or not is_instance_valid(controller):
					continue
				var kind := "other"
				if controller.get("camera_target_basis") != null:
					kind = "rotation"
					if rotation_probe == null:
						rotation_probe = controller
				elif controller.get("camera_target_position") != null:
					kind = "position"
					if position_probe == null:
						position_probe = controller
				controllers.append({
					"path": _path_of(controller),
					"kind": kind,
					"vars": _capture_vars(controller),
				})

	# Sort by path so the snapshot is independent of the manager's internal
	# array order. The manager re-sorts on activation changes, which would
	# otherwise make two identical camera states hash differently.
	controllers.sort_custom(
		func(a, b): return str(a.get("path", "")) < str(b.get("path", ""))
	)

	return {
		"target_basis": _prop(rotation_probe, "camera_target_basis", Basis.IDENTITY),
		"target_position": _prop(position_probe, "camera_target_position", Vector3.ZERO),
		"holder_transform": _prop(_camera_holder, "global_transform", Transform3D.IDENTITY),
		"controllers": controllers,
		"prev_position_leader": _path_of(_prop(_manager, "_prev_position_leader")),
		"prev_rotation_leader": _path_of(_prop(_manager, "_prev_rotation_leader")),
		"needs_sorting": bool(_prop(_manager, "needs_sorting", false)),
		"look_vector": _prop(_look_input, "look_vector", Vector2.ZERO),
		"look_time": float(_prop(_look_input, "time_since_last_look_input", 0.0)),
	}


func _capture_vars(node: Node) -> Dictionary:
	var out := {}
	for property in node.get_property_list():
		if (int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var name := String(property["name"])
		if BLOCKED_VARS.has(name):
			continue
		var value = node.get(name)
		if _is_plain(value):
			out[name] = value
	return out


func _restore_characterbody(body: Node, saved: Dictionary) -> void:
	if body == null or saved.is_empty():
		return
	body.set("global_transform", saved.get("transform", Transform3D.IDENTITY))
	body.set("velocity", saved.get("velocity", Vector3.ZERO))
	body.set("_was_on_floor", bool(saved.get("was_on_floor", false)))
	body.set("_was_on_wall", bool(saved.get("was_on_wall", false)))
	body.set("_pending_pushback", saved.get("pending_pushback", Vector3.ZERO))
	body.set("_pending_pushback_best", float(saved.get("pending_pushback_best", 0.0)))
	body.set("_pending_pushback_body", _resolve(str(saved.get("pending_pushback_body", ""))))
	body.set("_floor_local_point", saved.get("floor_local_point", Vector3.ZERO))
	body.set("_floor_normal", saved.get("floor_normal", Vector3.UP))
	body.set("floor_collider", _resolve(str(saved.get("floor_collider", ""))))
	body.set("_wall_collider", _resolve(str(saved.get("wall_collider", ""))))
	body.set("_solid_layer", int(saved.get("solid_layer", 0)))
	body.set("_solid_mask", int(saved.get("solid_mask", 0)))
	body.set("_ghost_frames_left", int(saved.get("ghost_frames_left", 0)))
	body.set("collision_layer", int(saved.get("collision_layer", 0)))
	body.set("collision_mask", int(saved.get("collision_mask", 0)))
	body.set("_last_move_frame", -1)

	var contact_ids: Dictionary[int, bool] = {}
	var saved_ids: Dictionary = saved.get("contact_ids", {})
	for key in saved_ids:
		contact_ids[int(key)] = bool(saved_ids[key])
	body.set("_contact_ids", contact_ids)

func _restore_marble(body: Node, saved: Dictionary) -> void:
	if body == null or saved.is_empty():
		return
	body.set("freeze", bool(saved.get("freeze", true)))
	body.set("global_transform", saved.get("transform", Transform3D.IDENTITY))
	body.set("linear_velocity", saved.get("linear_velocity", Vector3.ZERO))
	body.set("angular_velocity", saved.get("angular_velocity", Vector3.ZERO))
	body.set("gravity_scale", float(saved.get("gravity_scale", 1.0)))
	body.set("collision_layer", int(saved.get("collision_layer", 0)))
	body.set("collision_mask", int(saved.get("collision_mask", 0)))
	body.set("_prev_position", saved.get("prev_position", Vector3.ZERO))
	body.set("_has_prev_position", bool(saved.get("has_prev_position", false)))
	body.set("_is_on_floor", bool(saved.get("is_on_floor", false)))
	body.set("_is_touching", bool(saved.get("is_touching", false)))
	body.set("_was_on_floor", bool(saved.get("was_on_floor", false)))
	body.set("_floor_contact_point", saved.get("floor_contact_point", Vector3.ZERO))
	body.set("_floor_contact_normal", saved.get("floor_contact_normal", Vector3.UP))
	body.set("_contact_point", saved.get("contact_point", Vector3.ZERO))
	body.set("_contact_normal", saved.get("contact_normal", Vector3.UP))
	body.set("sleeping", bool(saved.get("sleeping", false)))

	# Force the physics server to synchronize its per-body state immediately
	# rather than deferring to the next physics step. Without this, the next
	# _integrate_forces call reads the pre-restore transform, and the CCD
	# correction in CustomRigidBody3D applies a different shortfall in Pass B
	# than in Pass A, causing marble drift at tick 1.
	if body is RigidBody3D:
		var rid: RID = (body as RigidBody3D).get_rid()
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM,
			saved.get("transform", Transform3D.IDENTITY))
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY,
			saved.get("linear_velocity", Vector3.ZERO))
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY,
			saved.get("angular_velocity", Vector3.ZERO))
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING, false)

	var magnet: Node = body.get("magnet")
	if magnet != null:
		magnet.set("nearest_overlapping", _resolve(str(saved.get("magnet_nearest", ""))))

func _restore_velocity_component(component: Node, saved: Dictionary) -> void:
	if component == null or saved.is_empty():
		return
	component.set("_smoothed_delta_velocity", saved.get("smoothed_delta_velocity", Vector3.ZERO))
	component.set("_previous_velocity", saved.get("previous_velocity", Vector3.ZERO))
	component.set("_last_known_gravity", saved.get("last_known_gravity", Vector3.ZERO))
	component.set("movement_config_index", int(saved.get("movement_config_index", 0)))


func _restore_state_machines(player: Node, saved: Dictionary) -> void:
	var state_machine: Node = player.get("state_machine")
	var movement_state_machine: Node = player.get("movement_state_machine")
	if state_machine == null or movement_state_machine == null:
		return

	var top: Dictionary = saved.get("top", {})
	var movement: Dictionary = saved.get("movement", {})
	var top_current := _resolve_state(state_machine, str(top.get("current", "")))
	var top_previous := _resolve_state(state_machine, str(top.get("prev", "")))
	var movement_current := _resolve_state(movement_state_machine, str(movement.get("current", "")))
	var movement_previous := _resolve_state(movement_state_machine, str(movement.get("prev", "")))

	for state in _all_states(player):
		state.set("process_mode", Node.PROCESS_MODE_DISABLED)

	state_machine.set("current_state", top_current)
	state_machine.set("prev_state", top_previous)
	movement_state_machine.set("current_state", movement_current)
	movement_state_machine.set("prev_state", movement_previous)

	if top_current != null:
		top_current.set("process_mode", Node.PROCESS_MODE_INHERIT)
	if movement_current != null:
		movement_current.set("process_mode", Node.PROCESS_MODE_INHERIT)


func _restore_states(player: Node, saved: Dictionary) -> void:
	for relative_path in saved:
		var state := player.get_node_or_null(NodePath(str(relative_path)))
		if state == null:
			continue
		_restore_vars(state, saved[relative_path])


func _restore_statics(saved: Dictionary) -> void:
	var probe := _ensure_marble_probe()
	if probe == null:
		return
	for name in MARBLE_STATICS:
		if saved.has(name) and saved[name] != null:
			probe.set(name, saved[name])


func _restore_input_buffers(saved: Dictionary) -> void:
	if _input_buffers == null:
		return
	for name in INPUT_BUFFER_FIELDS:
		if not saved.has(name):
			continue
		if name == "_avg_stick_angular_speed":
			var values: Array[float] = []
			for value in saved[name]:
				values.append(float(value))
			_input_buffers.set(name, values)
		else:
			_input_buffers.set(name, saved[name])


func _restore_global(saved: Dictionary) -> void:
	if _global == null:
		return
	_global.set("_control_basis", saved.get("control_basis", Basis.IDENTITY))
	_global.set("_previous_surface_up", saved.get("previous_surface_up", Vector3.UP))
	_global.set("_control_tick", -1)
	_global.set("is_impacting", bool(saved.get("is_impacting", false)))


func _restore_checkpoint(player: Node, saved: Dictionary) -> void:
	var checkpoint: Node = player.get("checkpoint_saver")
	if checkpoint == null:
		return
	checkpoint.set("last_touched_checkpoint", _resolve(str(saved.get("last", ""))))
	checkpoint.set("_fallback_position", saved.get("fallback", Vector3.ZERO))


func _restore_camera(saved: Dictionary) -> void:
	if _camera_holder != null:
		_camera_holder.set("global_transform", saved.get("holder_transform", Transform3D.IDENTITY))

	for entry in saved.get("controllers", []):
		var controller := _resolve(str(entry.get("path", "")))
		if controller == null:
			continue
		var variables: Dictionary = entry.get("vars", {})
		_restore_vars(controller, variables)
		if variables.has("enabled"):
			controller.set("enabled", bool(variables["enabled"]))
		if variables.has("priority"):
			controller.set("priority", int(variables["priority"]))

	var rotation_controller := _find_controller_with("camera_target_basis")
	if rotation_controller != null:
		rotation_controller.set("camera_target_basis", saved.get("target_basis", Basis.IDENTITY))
	var position_controller := _find_controller_with("camera_target_position")
	if position_controller != null:
		position_controller.set("camera_target_position", saved.get("target_position", Vector3.ZERO))

	if _manager != null:
		_manager.set("_prev_position_leader", _resolve(str(saved.get("prev_position_leader", ""))))
		_manager.set("_prev_rotation_leader", _resolve(str(saved.get("prev_rotation_leader", ""))))
		_manager.set("needs_sorting", bool(saved.get("needs_sorting", false)))

	if _look_input != null:
		_look_input.set("look_vector", saved.get("look_vector", Vector2.ZERO))
		_look_input.set("time_since_last_look_input", float(saved.get("look_time", 0.0)))


func _restore_player(player: Node, saved: Dictionary) -> void:
	player.set("has_do_marble", bool(saved.get("has_do_marble", false)))
	player.set("has_ground_pound", bool(saved.get("has_ground_pound", false)))
	player.set("visible", bool(saved.get("visible", true)))
	var health: Node = player.get("health")
	if health != null:
		health.set("maximum", int(saved.get("health_maximum", 100)))
		health.set("current", int(saved.get("health_current", 100)))


func _set_current_body(player: Node, mode: int) -> void:
	var characterbody: Node = player.get("characterbody")
	var marble: Node = player.get("marble")
	var body := marble if mode == 1 else characterbody
	player.set("_current_body", body)
	if characterbody != null:
		characterbody.set("process_mode", Node.PROCESS_MODE_INHERIT if mode == 0 else Node.PROCESS_MODE_DISABLED)
	if marble != null:
		marble.set("process_mode", Node.PROCESS_MODE_INHERIT if mode == 1 else Node.PROCESS_MODE_DISABLED)
		marble.set("freeze", mode != 1)


func _deferred_reapply(player: Node, saved: Dictionary) -> void:
	if player == null or not is_instance_valid(player):
		return
	var characterbody: Node = player.get("characterbody")
	var marble: Node = player.get("marble")
	var velocity_component: Node = player.get("velocity_component")
	var mode := int(saved.get("mode", 0))
	var body := marble if mode == 1 else characterbody

	if velocity_component != null:
		velocity_component.set("entity", body)
	if characterbody != null:
		characterbody.set("global_transform", saved.get("cb_transform", Transform3D.IDENTITY))
		characterbody.set("velocity", saved.get("cb_velocity", Vector3.ZERO))
		characterbody.set("process_mode", Node.PROCESS_MODE_INHERIT if mode == 0 else Node.PROCESS_MODE_DISABLED)
		characterbody.set("_last_move_frame", -1)
	if marble != null:
		marble.set("global_transform", saved.get("mb_transform", Transform3D.IDENTITY))
		marble.set("linear_velocity", saved.get("mb_linear", Vector3.ZERO))
		marble.set("angular_velocity", saved.get("mb_angular", Vector3.ZERO))
		marble.set("freeze", bool(saved.get("mb_freeze", true)))
		marble.set("process_mode", Node.PROCESS_MODE_INHERIT if mode == 1 else Node.PROCESS_MODE_DISABLED)
	player.set("_current_body", body)

	var state_machine: Node = player.get("state_machine")
	var movement_state_machine: Node = player.get("movement_state_machine")
	for state in _all_states(player):
		state.set("process_mode", Node.PROCESS_MODE_DISABLED)
	if state_machine != null:
		var top := _resolve_state(state_machine, str(saved.get("top_current", "")))
		if top != null:
			top.set("process_mode", Node.PROCESS_MODE_INHERIT)
	if movement_state_machine != null:
		var movement := _resolve_state(movement_state_machine, str(saved.get("movement_current", "")))
		if movement != null:
			movement.set("process_mode", Node.PROCESS_MODE_INHERIT)


func _restore_vars(node: Node, saved: Dictionary) -> void:
	for name in saved:
		if BLOCKED_VARS.has(str(name)):
			continue
		var value = saved[name]
		if not _is_plain(value):
			continue
		node.set(name, value)


func _all_states(player: Node) -> Array[Node]:
	var out: Array[Node] = []
	var state_machine: Node = player.get("state_machine")
	if state_machine != null:
		for child in state_machine.get_children():
			if child is Node:
				out.append(child)
	var movement_state_machine: Node = player.get("movement_state_machine")
	if movement_state_machine != null:
		for child in movement_state_machine.get_children():
			if child is Node:
				out.append(child)
	return out


func _resolve_state(state_machine: Node, state_name: String) -> Node:
	if state_machine == null or state_name == "":
		return null
	var states = state_machine.get("states")
	if states == null:
		return null
	return states.get(state_name.to_lower())


func _find_controller_with(property: String) -> Node:
	if _manager == null:
		return null
	var list = _manager.get("camera_controllers")
	if list == null:
		return null
	for controller in list:
		if controller != null and is_instance_valid(controller) and controller.get(property) != null:
			return controller
	return null


func _ensure_marble_probe() -> Node:
	if _marble_probe != null:
		return _marble_probe
	var script = load("res://actors/player/player_states/player_marble_state.gd")
	if script == null:
		return null
	_marble_probe = script.new()
	return _marble_probe


func _state_name(state) -> String:
	if state == null or not is_instance_valid(state):
		return ""
	return String(state.name)


func _path_of(node) -> String:
	if node == null or not is_instance_valid(node):
		return ""
	if not (node is Node):
		return ""
	return str((node as Node).get_path())


func _path_of_relative(root: Node, node: Node) -> String:
	if root == null or node == null or not is_instance_valid(node):
		return ""
	return str(root.get_path_to(node))


func _resolve(path: String) -> Node:
	if path == "" or _player == null or not is_instance_valid(_player):
		return null
	return _player.get_node_or_null(NodePath(path))


func _copy_contact_ids(source) -> Dictionary:
	var out := {}
	if source == null:
		return out
	for key in source:
		out[int(key)] = bool(source[key])
	return out


func _prop(node, property: String, default_value = null):
	if node == null or not is_instance_valid(node):
		return default_value
	var value = node.get(property)
	return value if value != null else default_value


func _is_plain(value) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME, \
		TYPE_NODE_PATH, TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, \
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_RECT2, TYPE_RECT2I, TYPE_TRANSFORM2D, \
		TYPE_TRANSFORM3D, TYPE_BASIS, TYPE_QUATERNION, TYPE_COLOR, TYPE_PLANE, \
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_VECTOR4_ARRAY, \
		TYPE_PACKED_COLOR_ARRAY:
			return true
		TYPE_ARRAY:
			for item in value:
				if not _is_plain(item):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value:
				if not _is_plain(key) or not _is_plain(value[key]):
					return false
			return true
		_:
			return false