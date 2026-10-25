-- SNAPTIC-TAS GDPatch patcher
--
-- Four game scripts are edited, plus two project settings:
--   autoloads/input/game_input.gd                        (adds patch marker only)
--   autoloads/input/input_buffers.gd                     (tick-based timers, slow-mo input)
--   actors/player/player_states/player_aerial_state.gd   (render timer -> physics)
--   actors/player/player_states/player_bhopping_state.gd (render timer -> physics)
--   physics/common/physics_ticks_per_second = 60
--   physics/common/physics_jitter_fix = 0.0
--
-- Every patch is anchored and fails closed: if an anchor is missing the script
-- is left untouched, its marker is not added, and mod.gd refuses to start.

local MOD_ID = "snaptic_tas"

local function log(message)
  print("SNAPTIC-TAS patcher: " .. message)
end

local function replace_once(source, old, new, label)
  local first, last = source:find(old, 1, true)
  if not first then
    log("missing anchor: " .. label)
    return nil
  end
  if source:find(old, last + 1, true) then
    log("anchor is not unique: " .. label)
    return nil
  end
  return source:sub(1, first - 1) .. new .. source:sub(last + 1)
end

-- Insert a line after the (unique) line that starts with `prefix`. Used where
-- the rest of the line varies between the recovered source and the shipped
-- script (parameter names, formatting), so a whole-line anchor is brittle.
local function insert_line_after(source, prefix, line, label)
  local first = source:find(prefix, 1, true)
  if not first then
    log("missing anchor: " .. label)
    return nil
  end
  if source:find(prefix, first + 1, true) then
    log("anchor is not unique: " .. label)
    return nil
  end
  local eol = source:find("\n", first, true)
  if not eol then
    log("missing line end: " .. label)
    return nil
  end
  return source:sub(1, eol) .. line .. source:sub(eol + 1)
end

local function has_marker(source)
  return source:find("tas_patch_marker", 1, true) ~= nil
end

local function patch_game_input(source)
  if has_marker(source) then
    return source
  end

  -- Only add the patch marker; no input overrides needed without replay
  local marker = "\nfunc tas_patch_marker() -> int:\n\treturn 1\n"
  log("patched game_input.gd (marker only)")
  return source .. marker
end

local function patch_input_buffers(source)
  if has_marker(source) then
    return source
  end

  local patched = replace_once(
    source,
    "\t_do_marble_press_msec = Time.get_ticks_msec()",
    "\t_do_marble_press_msec = _tas_now_msec()",
    "input_buffers deterministic double-marble clock")
  if not patched then
    return source
  end

  local old_process =
    "func _process(delta: float):\n" ..
    "\t_do_marble_buffer_timer = max(_do_marble_buffer_timer - delta, 0.0)\n" ..
    "\t_jump_buffer_timer = max(_jump_buffer_timer - delta, 0.0)\n" ..
    "\tif _was_do_marble_pressed and GameInput.get_action_strength(&\"do_marble\") < 0.3:\n" ..
    "\t\t_was_do_marble_pressed = false"

  local new_process =
    "func _process(_delta: float):\n" ..
    "\tpass"

  patched = replace_once(patched, old_process, new_process, "input_buffers render-delta timer removal")
  if not patched then
    return source
  end

  local old_physics =
    "func _physics_process(delta: float):\n" ..
    "\tif Engine.is_editor_hint():\n" ..
    "\t\treturn\n" ..
    "\t_smash_input_timer = max(_smash_input_timer - delta, 0.0)"

  local new_physics =
    "func _physics_process(delta: float):\n" ..
    "\tif Engine.is_editor_hint():\n" ..
    "\t\treturn\n" ..
    "\tif delta <= 0.0:\n" ..
    "\t\treturn\n" ..
    "\t_tas_game_msec += delta * 1000.0\n" ..
    "\t_do_marble_buffer_timer = max(_do_marble_buffer_timer - delta, 0.0)\n" ..
    "\t_jump_buffer_timer = max(_jump_buffer_timer - delta, 0.0)\n" ..
    "\tif _was_do_marble_pressed and GameInput.get_action_strength(&\"do_marble\") < 0.3:\n" ..
    "\t\t_was_do_marble_pressed = false\n" ..
    "\t_smash_input_timer = max(_smash_input_timer - delta, 0.0)"

  patched = replace_once(patched, old_physics, new_physics, "input_buffers physics timer move")
  if not patched then
    return source
  end

  -- The stick is sampled once per physics tick, so angular speed must be
  -- divided by the unscaled tick length. The original delta is multiplied by
  -- Engine.time_scale, which made the helicopter threshold fire at 2x/4x the
  -- real rotation speed in 0.5x/0.25x slow-mo and divide by zero while paused.
  patched = replace_once(
    patched,
    "\tvar stick_angular_speed = angle_diff / delta",
    "\tvar tick_delta: float = 1.0 / float(Engine.physics_ticks_per_second)\n" ..
    "\tvar stick_angular_speed = angle_diff / tick_delta",
    "input_buffers slow-mo helicopter speed")
  if not patched then
    return source
  end

  patched = patched ..
    "\nvar _tas_game_msec: float = 0.0\n" ..
    "\nfunc _tas_now_msec() -> int:\n" ..
    "\treturn int(_tas_game_msec)\n" ..
    "\nfunc tas_patch_marker() -> int:\n" ..
    "\treturn 1\n"

  log("patched input_buffers.gd")
  return patched
end

-- Both Aerial and Bhopping advance a squash timer in _process(delta), i.e. in
-- render time. The value is only used for the stretch animation, but it is
-- script state, so it differed between two runs of the same inputs (and was
-- captured by TAS snapshots). Move the increment into the physics tick; the
-- visual sampling stays in _process.
local SQUASH_OLD_PROCESS =
  "func _process(delta: float):\n" ..
  "\t_stretch_timer += delta\n" ..
  "\tif not stretch_curve or not squashable_node:\n" ..
  "\t\treturn"

local SQUASH_NEW_PROCESS =
  "func _process(_delta: float):\n" ..
  "\tif not stretch_curve or not squashable_node:\n" ..
  "\t\treturn"

local function patch_squash_timer(source, label)
  if has_marker(source) then
    return source
  end

  local patched = replace_once(source, SQUASH_OLD_PROCESS, SQUASH_NEW_PROCESS, label .. " render timer removal")
  if not patched then
    return source
  end

  patched = insert_line_after(patched, "func _physics_process(", "\t_stretch_timer += delta\n", label .. " physics timer move")
  if not patched then
    return source
  end

  patched = patched ..
    "\nfunc tas_patch_marker() -> int:\n" ..
    "\treturn 1\n"
  log("patched " .. label)
  return patched
end

GDPatch.patch_project_settings(function(settings)
  local function set_option(key, value)
    for _, entry in ipairs(settings) do
      if entry[1] == key then
        entry[2] = value
        return
      end
    end
    table.insert(settings, { key, value })
  end

  set_option("physics/common/physics_ticks_per_second", 60)
  set_option("physics/common/physics_jitter_fix", 0.0)

  local tick_rate = "<missing>"
  local jitter = "<missing>"
  for _, entry in ipairs(settings) do
    if entry[1] == "physics/common/physics_ticks_per_second" then
      tick_rate = tostring(entry[2])
    elseif entry[1] == "physics/common/physics_jitter_fix" then
      jitter = tostring(entry[2])
    end
  end
  log("project settings tick_rate=" .. tick_rate .. " jitter=" .. jitter)
  return settings
end)

local targets = {
  "autoloads/input/game_input.gd",
  "autoloads/input/game_input.gdc",
  "autoloads/input/input_buffers.gd",
  "autoloads/input/input_buffers.gdc",
  "actors/player/player_states/player_aerial_state.gd",
  "actors/player/player_states/player_aerial_state.gdc",
  "actors/player/player_states/player_bhopping_state.gd",
  "actors/player/player_states/player_bhopping_state.gdc",
}

GDPatch.patch_script_as_text(targets, function(ctx, source)
  local path = ctx.path:gsub("\\", "/")
  if path:find("game_input.gd", 1, true) then
    return patch_game_input(source)
  end
  if path:find("input_buffers.gd", 1, true) then
    return patch_input_buffers(source)
  end
  if path:find("player_aerial_state.gd", 1, true) then
    return patch_squash_timer(source, "player_aerial_state.gd")
  end
  if path:find("player_bhopping_state.gd", 1, true) then
    return patch_squash_timer(source, "player_bhopping_state.gd")
  end
  return source
end)

log("patcher installed (mod_id=" .. MOD_ID .. ")")