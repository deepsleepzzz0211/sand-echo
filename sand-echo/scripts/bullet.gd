class_name Bullet
extends Area2D
# @trace MECH-002, ART-002, NUM-001
# 弹丸（@trace MECH-002）。纯 Area2D，只做探测、不产生物理反弹。
# 碰撞层（与 project.godot [layer_names] 一一对应）：
#   player_bullet = layer4 = 8，仅 mask enemy(4)
#   enemy_bullet  = layer5 = 16，仅 mask player(2)
# 对面阵营靠 Hurtbox 子区域暴露（Area2D），避免与本体 CharacterBody2D 的层冲突。
# 数据入口：setup()、set_bounds()；数据出口：信号 hit_target(target, damage)。

signal hit_target(target: Area2D, damage: int)

enum Owner { PLAYER, ENEMY }

const LAYER_PLAYER_BULLET := 8
const LAYER_ENEMY_BULLET := 16
const MASK_PLAYER_BULLET := 4
const MASK_ENEMY_BULLET := 2
const GROUP_ENEMY_HURTBOX := "enemy_hurtbox"
const GROUP_PLAYER_HURTBOX := "player_hurtbox"
const TEX_PLAYER := preload("res://assets/art/fx/bullet_player.png")
# 武器等级配色：同一批 CC0 弹丸帧，让玩家一眼看出手上这把枪到第几级
const TEX_TIER := [
	preload("res://assets/art/fx/bullet_t2.png"),
	preload("res://assets/art/fx/bullet_t3.png"),
	preload("res://assets/art/fx/bullet_t4.png"),
	preload("res://assets/art/fx/bullet_t5.png"),
]
const TEX_ENEMY := preload("res://assets/art/fx/bullet_enemy.png")

@export var speed: float = 520.0
@export var damage: int = 1
@export var lifetime: float = 1.2

var owner_kind: int = Owner.PLAYER
var direction: Vector2 = Vector2.RIGHT
var pierce_left: int = 0

var _age: float = 0.0
var _hit_ids: Dictionary = {}
var _sprite: Sprite2D = null
var _bounds: Rect2 = Rect2()


func _ready() -> void:
	add_to_group("bullet")
	z_index = 5
	_sprite = get_node("Sprite") as Sprite2D
	var cs := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 5.0
	cs.shape = circle
	add_child(cs)
	area_entered.connect(_on_area_entered)


## 玩家弹丸按武器等级换配色（@trace WPN-001）。tier 越高级数越大越亮。
func set_tier(tier: int) -> void:
	if owner_kind != Owner.PLAYER:
		return
	var idx := clampi(tier - 1, 0, TEX_TIER.size() - 1)
	if _sprite != null:
		_sprite.texture = TEX_TIER[idx]
		# 高级弹丸自带一点自发光，暗底上更醒目
		_sprite.modulate = Color(1.0, 1.0, 1.0).lerp(Color(1.25, 1.2, 1.1), float(idx) / float(TEX_TIER.size() - 1))


func setup(p_dir: Vector2, p_damage: int, p_owner: int, p_pierce: int = 0) -> void:
	direction = p_dir.normalized()
	damage = p_damage
	owner_kind = p_owner
	pierce_left = p_pierce
	rotation = direction.angle()
	if owner_kind == Owner.PLAYER:
		collision_layer = LAYER_PLAYER_BULLET
		collision_mask = MASK_PLAYER_BULLET
		add_to_group("player_bullet")
		if _sprite != null:
			_sprite.texture = TEX_PLAYER
	else:
		collision_layer = LAYER_ENEMY_BULLET
		collision_mask = MASK_ENEMY_BULLET
		add_to_group("enemy_bullet")
		if _sprite != null:
			_sprite.texture = TEX_ENEMY


func set_bounds(rect: Rect2) -> void:
	_bounds = rect


func _physics_process(delta: float) -> void:
	position += direction * speed * delta
	_age += delta
	if _age >= lifetime:
		queue_free()
		return
	if _bounds.size.length_squared() > 0.0 and not _bounds.grow(64.0).has_point(position):
		queue_free()


func _on_area_entered(area: Area2D) -> void:
	var want := GROUP_ENEMY_HURTBOX if owner_kind == Owner.PLAYER else GROUP_PLAYER_HURTBOX
	if not area.is_in_group(want):
		return
	var id := area.get_instance_id()
	if _hit_ids.has(id):
		return
	_hit_ids[id] = true
	hit_target.emit(area, damage)
	# 命中事件转交给 Hurtbox 的本体处理（弹丸本身不判定伤害）
	if area.has_method("apply_hit"):
		area.call("apply_hit", damage, global_position)
	if pierce_left > 0:
		pierce_left -= 1
		return
	queue_free()