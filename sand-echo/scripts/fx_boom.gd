class_name FxBoom
extends Node2D
# @trace ART-003, ART-002
# 敌人死亡爆炸。
#
# 【为什么是程序化的】Kenney Desert Shooter Pack 里**没有爆炸序列帧**——
# 已逐目录核对：Weapons/Tiles 的 40 张全是弹丸（0000-0019）与准星（0020-0039），
# Enemies/Tiles 16 张全是敌人帧，Interface/Tiles 198 张是面板框与字形。
# 想要真正的爆炸动画得另找素材包（另议）。
# 所以这里用工程内已有素材合成：中心白闪 + 放射状火花 + 冲击环，三层错开时间，
# 视觉上读得出「炸开了」，且不引入任何新素材。

const CORE := preload("res://assets/art/fx/hit_spark.png")
const CORE_LIFE := 0.26
const RING_LIFE := 0.34
const RING_GROW := 3.4

var _core_t: float = 0.0
var _ring_t: float = 0.0
var _core: Sprite2D = null
var _ring: Sprite2D = null
var _scale: float = 1.0


## scale：随敌人体型缩放（Boss 炸得更大）
func setup(at: Vector2, scale_factor: float = 1.0, tint: Color = Color(1.0, 0.85, 0.45)) -> void:
	position = at
	_scale = clampf(scale_factor, 0.6, 4.0)
	z_index = 22
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	_core = Sprite2D.new()
	_core.texture = CORE
	_core.modulate = Color(1.0, 0.95, 0.85, 1.0)
	add_child(_core)

	_ring = Sprite2D.new()
	_ring.texture = CORE
	_ring.modulate = Color(tint.r, tint.g, tint.b, 0.9)
	_ring.scale = Vector2.ONE * 0.35 * _scale
	add_child(_ring)

	_ring.rotation = randf() * TAU


func _process(delta: float) -> void:
	_core_t += delta
	_ring_t += delta

	if _core != null:
		var kc := clampf(_core_t / CORE_LIFE, 0.0, 1.0)
		# 先胀后收，并短暂过曝成白色，读起来像一次小爆闪
		var s := _scale * (0.6 + 1.9 * sin(kc * PI * 0.85))
		_core.scale = Vector2.ONE * maxf(0.01, s)
		_core.modulate = Color(1.0, 0.95 + 0.4 * (1.0 - kc), 0.85, 1.0 - kc * kc)

	if _ring != null:
		var kr := clampf(_ring_t / RING_LIFE, 0.0, 1.0)
		_ring.scale = Vector2.ONE * maxf(0.01, _scale * (0.35 + RING_GROW * kr))
		_ring.modulate.a = 0.9 * (1.0 - kr) * (1.0 - kr)
		_ring.rotation += delta * 3.0

	if _core_t >= CORE_LIFE and _ring_t >= RING_LIFE:
		queue_free()