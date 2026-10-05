class_name FxPopup
extends Node2D
# @trace ART-002, NUM-004
# 伤害/拾取数值上浮（@trace MECH-002 反馈清单：拾取遗物数值上浮 ≤0.3s）。

const LIFETIME := 0.6
const RISE := 26.0

var _t: float = 0.0
var _label: Label = null
var _drift: float = 0.0


func _ready() -> void:
	z_index = 40
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_drift = randf_range(-14.0, 14.0)
	_label = Label.new()
	_label.text = text
	_label.add_theme_font_size_override("font_size", 24)
	_label.add_theme_color_override("font_outline_color", Color(0.11, 0.09, 0.14))
	_label.add_theme_constant_override("outline_size", 6)
	_label.add_theme_color_override("font_color", color)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.size = Vector2(120, 32)
	_label.position = Vector2(-60, -16)
	add_child(_label)


var text: String = ""
var color: Color = Color(1, 1, 1)


static func spawn(parent: Node, at: Vector2, value_text: String, tint: Color) -> void:
	if parent == null:
		return
	var fx := preload("res://scripts/fx_popup.gd").new() as Node2D
	fx.text = value_text
	fx.color = tint
	fx.position = at
	parent.add_child(fx)


func _process(delta: float) -> void:
	_t += delta
	var k := _t / LIFETIME
	position.y -= RISE * delta
	position.x += _drift * delta
	if _label != null:
		_label.modulate = Color(1, 1, 1, 1.0 - k)
	if _t >= LIFETIME:
		queue_free()