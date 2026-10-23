extends CanvasLayer

## Minimal always-on-top HUD. It never accepts mouse input.

var _panel: PanelContainer
var _label: RichTextLabel
var _last_text: String = ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 128

	_panel = PanelContainer.new()
	_panel.position = Vector2(12, 12)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_theme_stylebox_override("panel", _make_style())
	add_child(_panel)

	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.custom_minimum_size = Vector2(460, 0)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("normal_font_size", 14)
	_label.add_theme_font_size_override("bold_font_size", 14)
	_label.add_theme_color_override("default_color", Color(0.88, 0.94, 1.0))
	_panel.add_child(_label)

	visible = true


func _make_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.035, 0.055, 0.82)
	style.border_color = Color(0.35, 0.75, 1.0, 0.55)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(9)
	return style


func set_status(lines: Array, error: bool = false) -> void:
	var text: String = ""
	for i in lines.size():
		if i > 0:
			text += "\n"
		text += str(lines[i])
	if error:
		text = "[color=#ff7070]" + text + "[/color]"
	if text == _last_text:
		return
	_last_text = text
	if _label:
		_label.text = text


func toggle_visible() -> void:
	visible = not visible


func is_hud_visible() -> bool:
	return visible
