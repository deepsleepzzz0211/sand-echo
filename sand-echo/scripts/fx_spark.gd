extends Node2D
# @trace ART-002
# 命中火花（程序化表现，不参与任何逻辑判定）。

const TEX := preload("res://assets/art/fx/hit_spark.png")
const LIFETIME := 0.16

var _t: float = 0.0
var _sprite: Sprite2D = null
var _spin: float = 0.0


func _ready() -> void:
	z_index = 20
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sprite = Sprite2D.new()
	_sprite.texture = TEX
	_sprite.scale = Vector2.ONE * 1.4
	_sprite.rotation = randf() * TAU
	add_child(_sprite)
	_spin = randf_range(-8.0, 8.0)


func _process(delta: float) -> void:
	_t += delta
	var k := _t / LIFETIME
	if _sprite != null:
		_sprite.scale = Vector2.ONE * (1.4 - 0.7 * k)
		_sprite.modulate = Color(1, 1, 1, 1.0 - k)
	rotation += _spin * delta
	if _t >= LIFETIME:
		queue_free()