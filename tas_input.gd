extends RefCounted

## Per-tick input capture, encoding, and replay.
##
## A tick is 30 bytes:
##   u16 action mask
##   u8  strength[8] (0..255)
##   f32 move.x, move.y
##   f32 look.x, look.y
##   f32 look_time
##
## The recorded values are the final values seen by GameInput, not raw device
## state. That keeps replay independent of deadzones, cursor mode, and the
## current keyboard/controller layout.

const ACTIONS: Array[StringName] = [
	&"move_left",
	&"move_right",
	&"move_forward",
	&"move_back",
	&"jump",
	&"interact",
	&"do_marble",
	&"orient_camera",
]

const ACTION_COUNT: int = 8
const TICK_BYTES: int = 30

static func capture(game_input: Node, look_input: Node) -> Dictionary:
	assert(ACTION_COUNT <= 16, "tas_input: ACTION_COUNT must fit in u16 action mask")
	var mask: int = 0
	var strengths := PackedByteArray()
	strengths.resize(ACTION_COUNT)

	for i in ACTION_COUNT:
		var action: StringName = ACTIONS[i]
		var strength: float = clampf(float(game_input.call(&"get_action_strength", action)), 0.0, 1.0)
		strengths[i] = int(round(strength * 255.0))
		if bool(game_input.call(&"is_action_pressed", action)):
			mask |= 1 << i

	var move: Vector2 = game_input.call(&"get_move_vector")
	var look: Vector2 = look_input.get(&"look_vector")
	var look_time: float = float(look_input.get(&"time_since_last_look_input"))

	return {
		"mask": mask,
		"strengths": strengths,
		"move": move,
		"look": look,
		"look_time": look_time,
	}

static func append(record: PackedByteArray, tick: Dictionary) -> PackedByteArray:
	var offset: int = record.size()
	record.resize(offset + TICK_BYTES)

	record.encode_u16(offset, int(tick["mask"]))
	var strengths: PackedByteArray = tick["strengths"]
	for i in ACTION_COUNT:
		record.encode_u8(offset + 2 + i, int(strengths[i]))

	var move: Vector2 = tick["move"]
	record.encode_float(offset + 10, move.x)
	record.encode_float(offset + 14, move.y)

	var look: Vector2 = tick["look"]
	record.encode_float(offset + 18, look.x)
	record.encode_float(offset + 22, look.y)
	record.encode_float(offset + 26, float(tick["look_time"]))
	return record

static func write_look(record: PackedByteArray, offset: int, look: Vector2, look_time: float) -> PackedByteArray:
	if offset < 0 or offset + TICK_BYTES > record.size():
		return record
	record.encode_float(offset + 18, look.x)
	record.encode_float(offset + 22, look.y)
	record.encode_float(offset + 26, look_time)
	return record

static func decode(record: PackedByteArray, tick_index: int) -> Dictionary:
	var offset: int = tick_index * TICK_BYTES
	var strengths := PackedByteArray()
	strengths.resize(ACTION_COUNT)
	if offset < 0 or offset + TICK_BYTES > record.size():
		return {
			"mask": 0,
			"strengths": strengths,
			"move": Vector2.ZERO,
			"look": Vector2.ZERO,
			"look_time": 0.0,
		}

	var mask: int = record.decode_u16(offset)
	for i in ACTION_COUNT:
		strengths[i] = record.decode_u8(offset + 2 + i)

	return {
		"mask": mask,
		"strengths": strengths,
		"move": Vector2(record.decode_float(offset + 10), record.decode_float(offset + 14)),
		"look": Vector2(record.decode_float(offset + 18), record.decode_float(offset + 22)),
		"look_time": record.decode_float(offset + 26),
	}

static func tick_count(record: PackedByteArray) -> int:
	return record.size() / TICK_BYTES

static func truncate(record: PackedByteArray, ticks: int) -> PackedByteArray:
	var wanted: int = clampi(ticks, 0, tick_count(record)) * TICK_BYTES
	if wanted == record.size():
		return record
	var out := record.slice(0, wanted)
	return out

static func emit_events(game_input: Node, previous_mask: int, tick: Dictionary) -> void:
	assert(ACTION_COUNT <= 16, "tas_input: ACTION_COUNT must fit in u16 action mask")
	var mask: int = int(tick["mask"])
	var strengths: PackedByteArray = tick["strengths"]

	for i in ACTION_COUNT:
		var action: StringName = ACTIONS[i]
		var was_pressed: bool = (previous_mask & (1 << i)) != 0
		var is_pressed: bool = (mask & (1 << i)) != 0

		# do_marble is analog. InputBuffers needs to see the strength cross
		# 0.7 / 0.3 even while the button is held, so emit it every tick.
		if action == &"do_marble":
			var analog_event := InputEventAction.new()
			analog_event.action = action
			analog_event.pressed = is_pressed or strengths[i] > 0
			analog_event.strength = float(strengths[i]) / 255.0
			game_input.emit_signal(&"gameplay_input", analog_event)
			continue

		if was_pressed == is_pressed:
			continue

		var event := InputEventAction.new()
		event.action = action
		event.pressed = is_pressed
		event.strength = float(strengths[i]) / 255.0 if is_pressed else 0.0
		game_input.emit_signal(&"gameplay_input", event)

static func describe_mask(mask: int) -> String:
	var parts: Array[String] = []
	for i in ACTION_COUNT:
		if (mask & (1 << i)) != 0:
			parts.append(String(ACTIONS[i]))
	return ",".join(parts)
