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
## 玩家弹丸：暖色两级配色（深琥珀描边 + 亮黄核心）已烘焙进贴图。
## 原 bullet_player.png 是「暗紫描边(71,50,75) + 纯白核心」，靠 modulate
## 整体乘暖黄会把描边染成土褐、实测显脏，故预生成一张同色系的。
const TEX_PLAYER := preload("res://assets/art/fx/bullet_warm.png")
## 敌我弹道必须一眼可辨，这是弹幕游戏的可读性底线。
## 此前敌我弹丸都是纯白（bullet_enemy / bullet_player 的主色都是 255,255,255），
## 缩到屏幕尺寸后都退化成一个白点；敌弹那张还是「四向散射」图案，
## 语义上根本不是一颗子弹。现在：
##   玩家 = 暖黄，敌人 = 品红（危险色留给敌人）
## 玩家侧的暖黄烘焙进贴图，modulate 保持白色；敌人侧用 modulate 上品红。
const TEX_ENEMY := preload("res://assets/art/fx/bullet_solo.png")
const COLOR_PLAYER := Color(1.0, 0.82, 0.35, 1.0)   # 暖黄（已烘焙进TEX_PLAYER，此常量供 tier 提亮与测试用）
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
## setup() 只记录意图，视觉真正落在 _ready() 应用。
## 原因：_sprite 是普通 var，只在 _ready() 里赋值；而 game 侧的调用顺序是
## instantiate → setup() → add_child()，setup() 时节点还没进树、_ready() 没跑，
## _sprite 仍是 null，于是「if _sprite != null」里的贴图与配色赋值全部静默跳过。
## 症状是敌我弹丸都用 bullet.tscn 里写死的默认贴图、且都是纯白——
## 也就是玩家最初报的「敌人的子弹跟角色的子弹一个样式」。
var _pending_tex: Texture2D = null
var _pending_tint: Color = Color(1, 1, 1, 1)
var _pending_scale: float = 1.0
## 武器自带的弹丸尺寸基准（weapons.json 的 bullet_scale），与 tier 尺寸相乘。
## 此前玩家侧直接写 b.scale，会被 set_tier 覆盖，故改为走接口。
var _weapon_scale: float = 1.0
var _last_tier: int = 1


func _ready() -> void:
	add_to_group("bullet")
	z_index = 5
	_sprite = get_node("Sprite") as Sprite2D
	# 现在 _sprite 已就绪，把 setup() 记下的意图真正落地
	_apply_pending_visual()
	var cs := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 5.0
	cs.shape = circle
	add_child(cs)
	area_entered.connect(_on_area_entered)


## 玩家弹丸按武器等级表现强弱（@trace WPN-001）：尺寸 + 亮度。
## 此前等级靠换贴图（bullet_t2..t5）表达，但那几张素材本身是枪械图，
## 射出去像「一把小枪在飞」。改成同一张暖色弹丸贴图后，
## 等级改由尺寸与亮度承担——放大是最直观的强度信号，实测四档递增清晰可辨。
const TIER_SIZE := [1.80, 2.02, 2.27, 2.56]
const TIER_BRIGHT := [1.00, 1.08, 1.16, 1.25]


func set_tier(tier: int) -> void:
	if owner_kind != Owner.PLAYER:
		return
	_last_tier = clampi(tier, 1, 4)
	var i := _last_tier - 1
	var br := float(TIER_BRIGHT[i])
	# 只提亮度，不换色相：贴图已是暖色，modulate 保持近白，
	# 若在此赋一个带色相的 modulate 会把阵营色与贴图暖色叠浑。
	_set_visual(_pending_tex, Color(br, br, br, 1.0),
			float(TIER_SIZE[i]) * _weapon_scale)


## 设置武器自带的弹丸尺寸基准。玩家侧调用，与武器等级尺寸相乘。
## @trace WPN-003
func set_weapon_scale(sc: float) -> void:
	_weapon_scale = maxf(0.1, sc)
	var want := _weapon_scale * float(TIER_SIZE[_last_tier - 1])
	_pending_scale = want
	scale = Vector2.ONE * want


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
		# 暖色已烘焙进贴图，modulate 保持白色，亮度留给 set_tier
		_set_visual(TEX_PLAYER, Color(1, 1, 1, 1), 1.0)
	else:
		collision_layer = LAYER_ENEMY_BULLET
		collision_mask = MASK_ENEMY_BULLET
		add_to_group("enemy_bullet")
		_set_visual(TEX_ENEMY, COLOR_ENEMY, ENEMY_SCALE)



## 记录视觉意图。若已在场景树内则立即应用，否则等 _ready() 兜底。
## 这样调用方无论在 add_child() 之前还是之后调 setup()/set_tier() 都一样生效。
func _set_visual(tex: Texture2D, tint: Color, sc: float) -> void:
	_pending_tex = tex
	_pending_tint = tint
	_pending_scale = sc
	if _sprite != null:
		_apply_pending_visual()


func _apply_pending_visual() -> void:
	if _sprite == null:
		return
	if _pending_tex != null:
		_sprite.texture = _pending_tex
	_sprite.modulate = _pending_tint
	scale = Vector2.ONE * _pending_scale


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