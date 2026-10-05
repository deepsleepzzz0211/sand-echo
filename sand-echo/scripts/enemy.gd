class_name Enemy
extends CharacterBody2D
# @trace MECH-007, MECH-002, ART-002, NUM-004, SIG-003
# 敌人（@trace MECH-007 追击 + 远程弹幕）。四种类型由 data/enemies.json 驱动。
# 数据入口：setup(stats)；数据出口：信号 died(enemy_id, gold_reward)。
# 受击判定走子节点 Hurtbox（Area2D，enemy 层），避免与本体移动碰撞互相干扰。

signal died(enemy_id: String, gold_reward: int)
signal damaged(amount: int, is_crit: bool)

enum Brain { CHASER, KEEPER, SHOOTER }

const HURTBOX_RADIUS := 12.0
const BODY_RADIUS := 10.0
const FRAMES := {
	"e_chaser": preload("res://assets/art/actors/enemy_chaser_frames.tres"),
	"e_shooter": preload("res://assets/art/actors/enemy_shooter_frames.tres"),
	"e_burst": preload("res://assets/art/actors/enemy_burst_frames.tres"),
	"boss": preload("res://assets/art/actors/enemy_boss_frames.tres"),
}
const SEPARATION_FORCE := 220.0
const CONTACT_DAMAGE_CD := 0.55

@onready var _sprite: AnimatedSprite2D = $Sprite
@onready var _hurtbox: Area2D = $Hurtbox

var enemy_id: String = "e_chaser"
var display_name: String = "沙怪"
var hp: int = 12
var max_hp: int = 12
var speed: float = 95.0
var contact_dmg: int = 8
var brain: int = Brain.CHASER
var bullet_dmg: int = 0
var fire_interval: float = 0.0
var bullet_speed: float = 0.0
var spread_count: int = 0
var spread_deg: float = 24.0
var gold_reward: int = 5
var preferred_range: float = 0.0
var is_boss: bool = false
var knockback_resist: float = 0.0
var dead: bool = false

var _fire_timer: float = 0.0
var _contact_cd: float = 0.0
var _flash: float = 0.0
var _attack_anim: float = 0.0
var _arena: Rect2 = Rect2()
var _bullet_scene: PackedScene = preload("res://scenes/bullet.tscn")
var _rng := RandomNumberGenerator.new()
var _frames_res: SpriteFrames = null

# --- 血条（补上此前完全缺失的反馈；用 bar_fill.png，素材审计里的闲置项）---
const BAR_TEX: Texture2D = preload("res://assets/art/ui/bar_fill.png")
const BOOM_SCRIPT := preload("res://scripts/fx_boom.gd")
const BAR_W := 28.0
const BAR_H := 3.0
const BAR_Y := -18.0
var _hp_max: int = 1
var _bar_fill: Sprite2D = null
var _bar_root: Node2D = null


func _ready() -> void:
	add_to_group("enemy")
	collision_layer = 4    # enemy
	collision_mask = 1 | 2 | 4  # world | player | enemy（同族互相挤开）
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var cs := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = BODY_RADIUS
	cs.shape = circle
	cs.name = "Body"
	add_child(cs)
	_hurtbox.collision_layer = 4
	_hurtbox.collision_mask = 2
	_hurtbox.add_to_group("enemy_hurtbox")
	_hurtbox.hit_taken.connect(_on_hurtbox_hit_taken)
	_hurtbox.contact_made.connect(_on_contact_made)
	_rng.randomize()
	_fire_timer = _rng.randf_range(0.2, 0.8)
	_apply_frames()
	_build_hp_bar()


## 血条：只有一条红色填充条。
## 此前还有一条同尺寸的近黑底衬（Color(0.08,0.07,0.10)）作为「已损失血量」的轨道。
## 但它不随血量缩短——不管敌人剩多少血，那条黑线都是满宽的，
## 在深色沙地上看起来就是每只怪头顶常驻一根黑线（玩家两次反馈都是它）。
## 现在整条去掉：受损时只显示一条按血量缩短的红条。
func _build_hp_bar() -> void:
	_bar_root = Node2D.new()
	_bar_root.name = "HpBar"
	_bar_root.position = Vector2(0, BAR_Y)
	_bar_root.z_index = 3
	add_child(_bar_root)
	_bar_fill = Sprite2D.new()
	_bar_fill.texture = BAR_TEX
	_bar_fill.scale = Vector2(BAR_W / 16.0, BAR_H / 16.0)
	_bar_fill.modulate = Color(0.85, 0.25, 0.22, 1.0)
	_bar_root.add_child(_bar_fill)
	# 填充条以左端为锚点：向左延伸表示已损失的血
	_bar_fill.centered = false
	_bar_fill.position = Vector2(-BAR_W * 0.5, 0)
	_bar_fill.offset = Vector2(8, 8)
	_refresh_hp_bar()


func _refresh_hp_bar() -> void:
	if _bar_fill == null:
		return
	var ratio := clampf(float(hp) / float(maxi(1, _hp_max)), 0.0, 1.0)
	# 整条隐藏而不是只藏填充条：底衬是近黑色（0.08,0.07,0.10），
	# 之前只有填充条按血量显隐，于是每只怪头顶常驻一根黑线。
	_bar_root.visible = ratio < 0.999
	_bar_fill.visible = _bar_root.visible
	_bar_fill.scale.x = (BAR_W / 16.0) * ratio


func _apply_frames() -> void:
	if _sprite == null:
		return
	var frames: SpriteFrames = _frames_res
	if frames == null:
		frames = FRAMES.get(enemy_id, FRAMES["e_chaser"])
	# e_brute「甲壳兽」在本素材包里没有专属帧（Enemies/Tiles 只有 16 张 = 4 种 × 4 帧）。
	# 折中做法：借用 burst 的轮廓 + 放大体型 + 染成铁锈色，靠体型与配色区分，不再是沙蜥的样子。
	if enemy_id == "e_brute" and _frames_res == null:
		frames = FRAMES["e_burst"]
		if _sprite != null:
			_sprite.modulate = Color(1.25, 0.85, 0.7)
		scale = Vector2.ONE * 1.45
	if frames != null:
		_sprite.sprite_frames = frames
		_sprite.play("move")


func setup(stats: Dictionary, p_arena: Rect2 = Rect2(), seed_value: int = 0) -> void:
	_arena = p_arena
	if seed_value != 0:
		_rng.seed = seed_value
	enemy_id = String(stats.get("id", "e_chaser"))
	_frames_res = FRAMES.get(enemy_id, null)
	display_name = String(stats.get("name", "沙怪"))
	max_hp = int(stats.get("hp", 12))
	hp = max_hp
	speed = float(stats.get("speed", 95.0))
	contact_dmg = int(stats.get("contact_dmg", 8))
	bullet_dmg = int(stats.get("bullet_dmg", 0))
	fire_interval = float(stats.get("fire_interval", 0.0))
	bullet_speed = float(stats.get("bullet_speed", 0.0))
	_hp_max = maxi(1, hp)
	spread_count = int(stats.get("spread", 0))
	spread_deg = float(stats.get("spread_deg", 24.0))
	gold_reward = int(stats.get("gold", 5))
	preferred_range = float(stats.get("preferred_range", 0.0))
	knockback_resist = float(stats.get("knockback_resist", 0.0))
	is_boss = bool(stats.get("boss", false))
	match String(stats.get("brain", "chaser")):
		"keeper":
			brain = Brain.KEEPER
		"shooter":
			brain = Brain.SHOOTER
		_:
			brain = Brain.CHASER


func set_arena(rect: Rect2) -> void:
	_arena = rect


func _physics_process(delta: float) -> void:
	if dead:
		return
	_tick_timers(delta)
	var target := _player_node()
	if target == null:
		velocity = Vector2.ZERO
		return
	var to_target := target.global_position - global_position
	var dist := to_target.length()
	var dir := to_target / maxf(dist, 0.001)
	match brain:
		Brain.CHASER:
			velocity = dir * speed
		Brain.KEEPER:
			velocity = _orbit(dir, dist, delta)
		Brain.SHOOTER:
			velocity = _keep_range(dir, dist, delta)
	move_and_slide()
	_apply_separation(delta)
	_clamp_to_arena()
	_update_sprite(dir)
	_update_shooting(target, dir, dist)


func _tick_timers(delta: float) -> void:
	_fire_timer = maxf(0.0, _fire_timer - delta)
	_contact_cd = maxf(0.0, _contact_cd - delta)
	_flash = maxf(0.0, _flash - delta)
	_attack_anim = maxf(0.0, _attack_anim - delta)


func _player_node() -> Node2D:
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return null
	return players[0] as Node2D


func _orbit(dir: Vector2, dist: float, _delta: float) -> Vector2:
	# 环绕玩家：保持中距离并侧向绕行，避免所有敌人叠在一条直线上
	var tangent := Vector2(-dir.y, dir.x) * (1.0 if get_instance_id() % 2 == 0 else -1.0)
	var radial := 0.0
	if dist < preferred_range * 0.7:
		radial = -1.0
	elif dist > preferred_range * 1.3:
		radial = 1.0
	return (dir * radial + tangent * 0.85).normalized() * speed


func _keep_range(dir: Vector2, dist: float, _delta: float) -> Vector2:
	var want := preferred_range if preferred_range > 0.0 else 260.0
	var radial := 0.0
	if dist < want * 0.75:
		radial = -1.0
	elif dist > want * 1.25:
		radial = 1.0
	return dir * radial * speed


func _apply_separation(delta: float) -> void:
	var push := Vector2.ZERO
	for other in get_tree().get_nodes_in_group("enemy"):
		if other == self:
			continue
		var o := other as Node2D
		if o == null:
			continue
		var away := global_position - o.global_position
		var d := away.length()
		if d > 0.01 and d < SEPARATION_FORCE:
			push += away / d * (1.0 - d / SEPARATION_FORCE)
	if push != Vector2.ZERO:
		velocity += push * speed * delta * 2.0


func _clamp_to_arena() -> void:
	if _arena.size.length_squared() <= 0.0:
		return
	global_position.x = clampf(global_position.x, _arena.position.x, _arena.end.x)
	global_position.y = clampf(global_position.y, _arena.position.y, _arena.end.y)


func _update_sprite(dir: Vector2) -> void:
	if _flash > 0.0:
		_sprite.modulate = Color(2.4, 2.4, 2.4)
	elif _attack_anim > 0.0:
		_sprite.modulate = Color(1.5, 1.2, 0.8)
	else:
		_sprite.modulate = Color(1, 1, 1, 1)
	_sprite.flip_h = dir.x < -0.15
	if _attack_anim > 0.0:
		if _sprite.animation != "attack":
			_sprite.play("attack")
	elif _sprite.animation != "move":
		_sprite.play("move")


func _update_shooting(target: Node2D, dir: Vector2, dist: float) -> void:
	if bullet_dmg <= 0 or fire_interval <= 0.0:
		return
	if _fire_timer > 0.0:
		return
	if dist > (preferred_range if preferred_range > 0.0 else 620.0) * 1.6:
		return
	_fire_timer = fire_interval
	_attack_anim = 0.14
	var parent := get_parent()
	if parent == null:
		return
	var count := maxi(1, spread_count)
	for i in count:
		var angle := 0.0
		if count > 1:
			angle = deg_to_rad(spread_deg) * (float(i) / float(count - 1) - 0.5)
		var d := dir.rotated(angle)
		var b := _bullet_scene.instantiate() as Bullet
		b.setup(d, bullet_dmg, Bullet.Owner.ENEMY)
		b.speed = bullet_speed
		b.lifetime = 2.4
		b.position = global_position + d * 14.0
		if _arena.size.length_squared() > 0.0:
			b.set_bounds(_arena)
		parent.add_child(b)
	Sfx.play("shoot", -18.0, randf_range(0.8, 0.95), 0.04)


func take_damage(amount: int, from: Vector2 = Vector2.ZERO) -> void:
	if dead or amount <= 0:
		return
	hp -= amount
	_refresh_hp_bar()
	_flash = 0.09
	damaged.emit(amount, false)
	if from != Vector2.ZERO and knockback_resist < 1.0:
		velocity += (global_position - from).normalized() * (1.0 - knockback_resist) * 120.0
	if hp <= 0:
		_die()


func _die() -> void:
	dead = true
	set_physics_process(false)
	# 死亡爆炸：素材包无爆炸帧，这里用 fx_boom.gd 程序化合成（白闪 + 冲击环）
	var boom := Node2D.new()
	boom.set_script(BOOM_SCRIPT)
	boom.position = position
	boom.scale = Vector2.ONE * 0.6
	add_child(boom)
	var big := enemy_id == "boss"
	boom.call("setup", Vector2.ZERO, 3.2 if big else 1.4,
		Color(1.0, 0.55, 0.25) if big else Color(1.0, 0.85, 0.45))
	died.emit(enemy_id, gold_reward)
	Sfx.play("enemy_die", -8.0, randf_range(0.95, 1.1), 0.02)
	queue_free()


func is_enemy() -> bool:
	return true


func _on_hurtbox_hit_taken(amount: int, from: Vector2) -> void:
	take_damage(amount, from)


func _on_contact_made(_target: Area2D) -> void:
	# 接触伤害：每 CONTACT_DAMAGE_CD 秒一次，避免贴脸时每帧掉血
	if dead or contact_dmg <= 0 or _contact_cd > 0.0:
		return
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return
	var p := players[0] as Player
	if p == null or p.is_invulnerable():
		return
	_contact_cd = CONTACT_DAMAGE_CD
	p.take_damage(contact_dmg)