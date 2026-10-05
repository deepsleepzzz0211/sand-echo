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
## 敌我弹道必须一眼可辨，这是弹幕游戏的可读性底线。
## 此前敌我弹丸都是纯白（bullet_enemy / bullet_player 的主色都是 255,255,255），
## 缩到屏幕尺寸后都退化成一个白点；敌弹那张还是「四向散射」图案，
## 语义上根本不是一颗子弹。现在：
##   玩家 = 暖黄，敌人 = 品红（危险色留给敌人）
## 颜色用 modulate 叠，不额外占用 bullet_t2..t5 —— 那几张要留给武器等级视觉。
const TEX_ENEMY := preload("res://assets/art/fx/bullet_solo.png")
const COLOR_PLAYER := Color(1.0, 0.82, 0.35, 1.0)   # 暖黄：自己的输出
const COLOR_ENEMY := Color(1.0, 0.28, 0.68, 1.0)    # 品红：打向我的
## 敌人弹丸缩放。bullet_solo 的实体只有 24px 画布里约 5px，1.0 缩放在 1920x1080
## 上几乎看不见；放大到与玩家弹丸（约 14px）相当。
## 由本模块自己负责：调用方（enemy.gd）不该伸手进来看 Sprite 再改缩放。
const ENEMY_SCALE := 2.6

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


## 玩家弹丸按武器等级提亮（@trace WPN-001）。tier 越高级数越大越亮。
## 注意是在基色上「乘」亮度而不是直接赋 modulate：直接赋值会把 setup() 里
## 按阵营刷的暖黄冲掉，玩家和敌人弹丸就又变成同一个颜色了。
func set_tier(tier: int) -> void:
	if owner_kind != Owner.PLAYER:
		return
	var idx := clampi(tier - 1, 0, TEX_TIER.size() - 1)
	if _sprite != null:
		_sprite.texture = TEX_TIER[idx]
		# 高级弹丸自带一点自发光，暗底上更醒目
		var t := float(idx) / float(TEX_TIER.size() - 1)
		var boost := Color(1.0, 1.0, 1.0).lerp(Color(1.25, 1.2, 1.1), t)
		_sprite.modulate = Color(
			COLOR_PLAYER.r * boost.r,
			COLOR_PLAYER.g * boost.g,
			COLOR_PLAYER.b * boost.b,
			COLOR_PLAYER.a)


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
			_sprite.modulate = COLOR_PLAYER
	else:
		collision_layer = LAYER_ENEMY_BULLET
		collision_mask = MASK_ENEMY_BULLET
		add_to_group("enemy_bullet")
		if _sprite != null:
			_sprite.texture = TEX_ENEMY
			_sprite.modulate = COLOR_ENEMY
		# 与玩家侧一致：缩放节点本身，视觉与碰撞体一起变大
		scale = Vector2.ONE * ENEMY_SCALE


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