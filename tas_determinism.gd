extends RefCounted

## Determinism check.
## Each sample is the state BEFORE that tick's physics step.
## Pass A and Pass B share identical code paths through on_physics_tick().

const TICKS: int = 120
const SNAPSHOT_KEEP: int = TICKS   # snapshots kept per pass so any drifting tick can be diffed

var _codec: RefCounted = null
var _player: Node = null
var _runtime: Node = null
var _base_snapshot: Dictionary = {}

var _phase: int = 0  # 0 idle, 1 pass A, 2 pass B, 3 done
var _tick: int = 0
var _pending_restore: bool = false

var _hashes_a: PackedInt64Array = PackedInt64Array()
var _hashes_b: PackedInt64Array = PackedInt64Array()

var _snaps_a: Array = []
var _snaps_b: Array = []


func start(runtime: Node, codec: RefCounted, player: Node) -> void:
	_runtime = runtime
	_codec = codec
	_player = player

	_base_snapshot = _codec.capture(
		_player,
		Engine.get_physics_frames()
	)

	_hashes_a.clear()
	_hashes_b.clear()
	_snaps_a.clear()
	_snaps_b.clear()

	_tick = 0
	_phase = 1
	_pending_restore = false

	print(
		"SNAPTIC-TAS determinism: base captured at physics tick %d"
		% Engine.get_physics_frames()
	)


func on_physics_tick(inputs_for_tick: Callable) -> void:
	if _phase != 1 and _phase != 2:
		return

	if _pending_restore:
		_pending_restore = false
		_perform_restore()

	# Neutralize live input BEFORE sampling, so both passes see the same
	# (zero) input state on every tick. Without this, LookInput and
	# InputBuffers accumulate per-tick device/timing noise between the two
	# passes and the comparison measures wall-clock rather than the sim.
	if _runtime != null and _runtime.has_method(&"neutralize_live_input"):
		_runtime.call(&"neutralize_live_input")

	var snap: Dictionary = _codec.capture(
		_player,
		Engine.get_physics_frames()
	)
	var h: int = _codec.hash(snap)

	if _phase == 1:
		_hashes_a.append(h)
		if _snaps_a.size() < SNAPSHOT_KEEP:
			_snaps_a.append(snap.duplicate(true))
	else:
		_hashes_b.append(h)
		if _snaps_b.size() < SNAPSHOT_KEEP:
			_snaps_b.append(snap.duplicate(true))

	inputs_for_tick.call(_tick)
	_tick += 1

	if _tick >= TICKS:
		_finish_pass()


func is_finished() -> bool:
	return _phase == 3


func _finish_pass() -> void:
	if _phase == 1:
		# Do NOT restore here. Schedule the restore for the next physics
		# callback (Pass B's tick 0) so that no physics step can elapse
		# between the restore and the sample that follows it.
		_phase = 2
		_tick = 0
		_pending_restore = true
		print("SNAPTIC-TAS determinism: starting Pass B")
	else:
		_phase = 3
		_report()


func _perform_restore() -> void:
	var result: Dictionary = _codec.restore(_player, _base_snapshot)
	if not bool(result.get("ok", false)):
		print(
			"SNAPTIC-TAS determinism: ABORT — restore failed: "
			+ str(result.get("reason", "unknown"))
		)
		_phase = 3
		return

	var restored_snap: Dictionary = _codec.capture(
		_player,
		Engine.get_physics_frames()
	)

	# Diff the full snapshot (sim + camera), excluding metadata keys
	# /tick and /hash, so a lossy camera restore is caught here.
	var restore_diff: int = _diff(_base_snapshot, restored_snap, "")
	print(
		"SNAPTIC-TAS determinism: restore check, "
		+ "%d differing fields" % restore_diff
	)

	if restore_diff > 0:
		print(
			"SNAPTIC-TAS determinism: ABORT — "
			+ "restore is lossy, Pass B is invalid"
		)
		_phase = 3


func _report() -> void:
	if _hashes_a.size() != _hashes_b.size():
		print(
			"SNAPTIC-TAS determinism: SAMPLE COUNT MISMATCH A=%d B=%d"
			% [_hashes_a.size(), _hashes_b.size()]
		)
		return

	var drift_ticks: int = 0
	var first_drift: int = -1
	var details_left: int = 8
	for i in _hashes_a.size():
		if _hashes_a[i] == _hashes_b[i]:
			continue
		drift_ticks += 1
		if first_drift < 0:
			first_drift = i
		if drift_ticks <= 8:
			print("SNAPTIC-TAS determinism: DRIFT at tick offset %d" % i)
		elif drift_ticks == 9:
			print("SNAPTIC-TAS determinism: ... more drifting ticks suppressed")

		if details_left > 0 and i < _snaps_a.size() and i < _snaps_b.size():
			details_left -= 1
			var sim_a: Dictionary = _snaps_a[i].get("sim", {})
			var sim_b: Dictionary = _snaps_b[i].get("sim", {})
			var active_a: Dictionary = _codec.active_only(sim_a)
			var active_b: Dictionary = _codec.active_only(sim_b)
			print("SNAPTIC-TAS determinism: tick-%d active-sim field diff (A vs B):" % i)
			var diff_count: int = _diff(active_a, active_b, "")
			print("SNAPTIC-TAS determinism: tick-%d differing fields: %d" % [i, diff_count])

	if drift_ticks == 0:
		print(
			"SNAPTIC-TAS determinism: DETERMINISTIC over %d ticks"
			% _hashes_a.size()
		)
	else:
		print(
			"SNAPTIC-TAS determinism: NON-DETERMINISTIC: %d / %d ticks differ, first at tick offset %d"
			% [drift_ticks, _hashes_a.size(), first_drift]
		)


func _diff(a: Dictionary, b: Dictionary, path: String) -> int:
	var count: int = 0
	var all_keys: Dictionary = {}
	for k in a:
		all_keys[k] = true
	for k in b:
		all_keys[k] = true
	for key in all_keys:
		var key_str := str(key)
		# Metadata, not state: the physics tick number and the self-hash
		# always differ between Pass A and Pass B by construction.
		if path == "" and (key_str == "tick" or key_str == "hash"):
			continue
		var full: String = path + "/" + key_str
		var in_a: bool = a.has(key)
		var in_b: bool = b.has(key)
		if in_a and not in_b:
			print("  MISSING IN B: " + full)
			count += 1
			continue
		if in_b and not in_a:
			print("  MISSING IN A: " + full)
			count += 1
			continue
		var va = a[key]
		var vb = b[key]
		if va is Dictionary and vb is Dictionary:
			count += _diff(va, vb, full)
		else:
			# Compare bytes, not strings: str() rounds floats and can hide
			# sub-printable differences that var_to_bytes (and therefore
			# the hash) would still catch.
			if var_to_bytes(va) != var_to_bytes(vb):
				print("  DIFF: " + full + " A=" + str(va) + " B=" + str(vb))
				count += 1
	return count