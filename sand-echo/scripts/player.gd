class_name Player
extends CharacterBody2D
# @trace MECH-002, COL-001, COL-002, ART-004, WPN-001, WPN-003, UI-002, UI-004, NUM-001, NUM-002, PLAT-001
# 玩家角色（弹幕射击战斗 + 闪避无敌帧）。
# 碰撞层语义（project.godot [layer_names]）：本体 = player 层，只与世界层做移动碰撞；
# 受击判定交给 Hurtbox 子区域（enemy 层），攻击判定交给 Bullet（player_bullet 层）。
# 状态机用「枚举 + 转移表」实现（@trace MECH-002 状态表），不使用散落条件判断。
# 状态：IDLE/MOVE → SHOOT → IDLE；任意 → DASH（无敌 0.30s，冷却 0.90s）；HP≤0 → DEAD。
# 优先级：同帧多输入时 DASH 优先于 SHOOT（@trace MECH-002 边界情况）。
# 数据入口：Room 的 arena 矩形；数据出口：RunState 信号 + EventBus。

enum State { IDLE, MOVE, SHOOT, DASH, DEAD }

const DASH_SPEED := 700.0
const MUZZLE_OFFSET := 16.0
# 多发弹丸的最小角度间隔（度）。没有它，spread_deg=0 的武器（初始手枪、狙击、轨道炮）
# 拿到「弹丸+1」后所有弹丸会重叠在同一点，玩家看不出变化。
const MULTISHOT_MIN_STEP_DEG := 7.0
const MUZZLE_TEX: Texture2D = preload("res://assets/art/fx/muzzle_flash.png")
# 准星按武器等级换色，与弹丸配色一致，玩家一眼知道自己手上这把枪几级
const AIM_TEX := [
	preload("res://assets/art/fx/crosshair_1.png"),
	preload("res://assets/art/fx/crosshair_2.png"),
	preload("res://assets/art/fx/crosshair_3.png"),
	preload("res://assets/art/fx/crosshair_4.png"),
]
const HURT_INVULN_AFTER_HIT := 0.45
const ACCEL := 2400.0
const FRICTION := 2600.0
const HURTBOX_RADIUS := 11.0
const BODY_RADIUS := 9.0

@onready var _sprite: AnimatedSprite2D = $Sprite
@onready var _hurtbox: Area2D = $Hurtbox
@onready var _weapon_holder: Node2D = $WeaponHolder
## 当前挂了几把武器的枪（只为省掉每帧 count 查询）
var _ring_count := 0

var state: int = State.IDLE
var aim_dir: Vector2 = Vector2.RIGHT
var fire_cd: float = 0.0
var _aim_marker: Sprite2D = null
var dash_cd: float = 0.0
var dash_timer: float = 0.0
var dash_dir: Vector2 = Vector2.RIGHT
var invuln: float = 0.0
var arena: Rect2 = Rect2()
var doors_locked: bool = true
var _bullet_scene: PackedScene = preload("res://scenes/bullet.tscn")
var _shots_this_burst: int = 0
var _shoot_anim_left: float = 0.0


func _ready() -> void:
	add_to_group("player")
	collision_layer = 2   # player
	collision_mask = 1 | 4  # world | enemy
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var body_shape := CollisionShape2D.new()
	var body_circle := CircleShape2D.new()
	body_circle.radius = BODY_RADIUS
	body_shape.shape = body_circle
	body_shape.name = "Body"
	add_child(body_shape)
	_hurtbox.collision_layer = 2
	_hurtbox.collision_mask = 0
	_hurtbox.monitoring = false
	_hurtbox.monitorable = true
	# 必须入组：bullet.gd 与 hurtbox.gd 都用 player_hurtbox 组做阵营过滤，
	# 漏了这一行，玩家就永远免疫伤害（敌人能受伤是因为 enemy.gd 写了同样的 add_to_group）。
	_hurtbox.add_to_group("player_hurtbox")
	RunState.player_died.connect(_on_player_died)
	_hurtbox.hit_taken.connect(_on_hurtbox_hit_taken)
	# 商店买/强化武器后 RunState 会发 weapons_changed，据此重建环形枪外观
	if not RunState.weapons_changed.is_connected(_refresh_weapon_ring):
		RunState.weapons_changed.connect(_refresh_weapon_ring)
	_refresh_weapon_ring()
	_sprite.play("idle")


func _on_hurtbox_hit_taken(amount: int, _from: Vector2) -> void:
	# 无敌帧内免伤（@trace MECH-002 边界情况：闪避中受伤）
	if state == State.DEAD or invuln > 0.0:
		return
	RunState.take_damage(amount)
	invuln = maxf(invuln, HURT_INVULN_AFTER_HIT)
	EventBus.player_hurt.emit(amount)
	EventBus.shake_requested.emit(7.0)
	Sfx.play("hurt", -6.0, randf_range(0.95, 1.05), 0.08)


var _t: float = 0.0
var _toast_cd: float = 0.0


func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("interact"):
		_toast_cd = maxf(0.0, _toast_cd - delta)
	if state == State.DEAD:
		# 死亡后仍然要收枪：_physics_process 在这里提前返回，
		# 若不单独处理，环形挂载会停在最后一次的开火姿态上不消失。
		_update_weapon_ring()
		return
	_tick_timers(delta)
	_update_aim()
	match state:
		State.DASH:
			_process_dash(delta)
		_:
			_process_move(delta)
	_handle_dash_input()
	_handle_shoot_input()
	_clamp_to_arena()
	_update_sprite()


func _tick_timers(delta: float) -> void:
	_tick_weapon_cd(delta)
	dash_cd = maxf(0.0, dash_cd - delta)
	invuln = maxf(0.0, invuln - delta)
	dash_timer = maxf(0.0, dash_timer - delta)
	_shoot_anim_left = maxf(0.0, _shoot_anim_left - delta)
	if state == State.DASH and dash_timer <= 0.0:
		state = State.MOVE if _move_input() != Vector2.ZERO else State.IDLE


func _process_move(delta: float) -> void:
	var dir := _move_input()
	if dir == Vector2.ZERO:
		velocity = velocity.move_toward(Vector2.ZERO, FRICTION * delta)
		state = State.IDLE
	else:
		velocity = velocity.move_toward(dir * RunState.move_speed, ACCEL * delta)
		state = State.MOVE
	move_and_slide()


func _process_dash(delta: float) -> void:
	velocity = dash_dir * DASH_SPEED
	move_and_slide()


func _move_input() -> Vector2:
	var dir := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down")
	)
	if dir.length() > 1.0:
		dir = dir.normalized()
	return dir


func _update_aim() -> void:
	# 双摇杆口径（WAVE-001）：键鼠「移动与瞄准完全独立」——WASD 只管走，朝向永远跟鼠标。
	# aim_* 在输入映射里只绑了手柄右摇杆，键盘不再绑 WASD；
	# 早期版本两边都绑 WASD，结果按方向键就把朝向从鼠标拽走，角色看起来「朝向不对」。
	# 手柄：右摇杆有输入才接管，否则沿用鼠标朝向。
	var pad := Vector2(
		Input.get_axis("aim_left", "aim_right"),
		Input.get_axis("aim_up", "aim_down")
	)
	if pad.length() > 0.35:
		aim_dir = pad.normalized()
		return
	var to_mouse := get_global_mouse_position() - global_position
	if to_mouse.length() > 4.0:
		aim_dir = to_mouse.normalized()


func _handle_dash_input() -> void:
	if state == State.DASH or state == State.DEAD:
		return
	if not Input.is_action_just_pressed("dash") or dash_cd > 0.0:
		return
	var dir := _move_input()
	dash_dir = dir if dir != Vector2.ZERO else aim_dir
	dash_timer = RunState.DASH_TIME
	invuln = maxf(invuln, RunState.DASH_IFRAME)
	dash_cd = RunState.dash_cooldown()
	state = State.DASH
	Sfx.play("dash", -8.0, randf_range(0.95, 1.1), 0.05)


func _handle_shoot_input() -> void:
	if state == State.DEAD:
		return
	# 按住即连射（鼠标左键 / J / 手柄 X·右扳机），冷却未到则忽略（@trace MECH-002 边界情况）
	if not Input.is_action_pressed("shoot"):
		return
	# 多武器（@trace WPN-001）：每把武器各自独立冷却，各自射速不同
	var fired := false
	for w in RunState.weapons:
		var wm := w as Dictionary
		var cd := float(wm.get("cd", 0.0))
		if cd > 0.0:
			continue
		var def := RunState.weapon_def(String(wm["id"]))
		if def.is_empty():
			continue
		wm["cd"] = RunState.weapon_interval(def, int(wm.get("tier", 1)))
		_fire_weapon(def, int(wm.get("tier", 1)))
		fired = true
	if not fired:
		return
	state = State.SHOOT
	_shoot_anim_left = 0.16


## 推进所有武器冷却（@trace WPN-001）
func _tick_weapon_cd(delta: float) -> void:
	for w in RunState.weapons:
		var wm := w as Dictionary
		wm["cd"] = maxf(0.0, float(wm.get("cd", 0.0)) - delta)


func _fire_weapon(def: Dictionary, tier: int) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var count := RunState.weapon_projectiles(def, tier)
	var spread := RunState.weapon_spread(def, tier)
	var speed := float(def.get("bullet_speed", RunState.BULLET_SPEED))
	var pierce := RunState.weapon_pierce(def, tier)
	var dmg := RunState.weapon_damage(def, tier)
	var crit := RunState.roll_crit()
	if crit:
		dmg *= 2
	for i in count:
		var angle := 0.0
		if count > 1:
			var step := deg_to_rad(spread)
			# 多发弹丸必须有可见的角度间隔。初始手枪 spread_deg = 0，
			# 若直接用 0 当步长，count 颗弹丸会完全重叠在同一点，
			# 于是「弹丸 +1」实际生效了但看上去只有一颗（玩家报的效果没体现）。
			if step <= 0.0:
				step = deg_to_rad(MULTISHOT_MIN_STEP_DEG)
			angle = -step * float(count - 1) * 0.5 + step * float(i)
		elif spread > 0.0:
			angle = deg_to_rad(randf_range(-spread, spread)) * 0.5
		var b := _bullet_scene.instantiate() as Bullet
		b.setup(aim_dir.rotated(angle), dmg, Bullet.Owner.PLAYER, pierce)
		b.set_tier(tier)
		b.speed = speed
		b.scale = Vector2.ONE * RunState.weapon_bullet_scale(def, tier)
		b.position = global_position + aim_dir.rotated(angle) * MUZZLE_OFFSET
		if not arena.size.length_squared() > 0.0:
			b.set_bounds(arena)
		parent.add_child(b)
		_shots_this_burst = maxi(_shots_this_burst, count)
		RunState.bump_stat("shots_fired", 1)
	_muzzle_flash()
	Sfx.play("shoot", -10.0, randf_range(0.94, 1.08), 0.02)


## 枪口闪光：用上此前一直闲置的 muzzle_flash.png（素材审计里的未用项）
func _muzzle_flash() -> void:
	var parent := get_parent()
	if parent == null:
		return
	var fx := Sprite2D.new()
	fx.texture = MUZZLE_TEX
	fx.position = global_position + aim_dir * (MUZZLE_OFFSET + 10.0)
	fx.rotation = aim_dir.angle()
	fx.z_index = 6
	fx.modulate = Color(1.0, 0.92, 0.7, 1.0)
	parent.add_child(fx)
	var t := create_tween()
	t.tween_property(fx, "modulate:a", 0.0, 0.07)
	t.tween_callback(fx.queue_free)



func _clamp_to_arena() -> void:
	if arena.size.length_squared() <= 0.0:
		return
	global_position.x = clampf(global_position.x, arena.position.x, arena.end.x)
	global_position.y = clampf(global_position.y, arena.position.y, arena.end.y)


func _update_sprite() -> void:
	_sprite.flip_h = aim_dir.x < -0.15
	_update_weapon_ring()
	_update_aim_marker()
	if state == State.DASH:
		_sprite.modulate = Color(0.75, 0.95, 1.25)
	elif invuln > 0.0:
		# 无敌帧闪烁：0.06s 间隔交替（表现层去重，不做累加）
		var on := int(invuln / 0.06) % 2 == 0
		_sprite.modulate = Color(1.6, 0.7, 0.7) if invuln > RunState.DASH_IFRAME - 0.01 else (Color(1, 1, 1, 0.45) if on else Color(1, 1, 1, 1))
	else:
		_sprite.modulate = Color(1, 1, 1, 1)
	if _shoot_anim_left > 0.0:
		if _sprite.animation != "shoot":
			_sprite.play("shoot")
	elif state == State.MOVE and _sprite.animation != "move":
		_sprite.play("move")
	elif state != State.MOVE and _sprite.animation != "idle":
		_sprite.play("idle")


# 持枪外观（Brotato 式环形挂载）@trace ART-004, WPN-003
# 素材包PNG/Weapons/Tiles 的前 20 张是枪械本体（0020-0039 是弹幕/准星图案）。
# 接进来之前 weapons.json 里没有任何贴图字段，10 把武器全无外观 —— 买了新武器
# 看起来和原来那把一模一样。现在每把武器按 tier 取对应贴图，升级会换枪。
const WEAPON_RING_R := 20.0
const WEAPON_TIER_TINT := [
	Color(1, 1, 1, 1),#tier1 原色
	Color(1.10, 1.06, 0.92),# tier2 略亮偏暖
	Color(1.18, 1.00, 0.80),# tier3 更暖
	Color(1.30, 0.94, 0.62),# tier4 金橙
]


func _weapon_sprite_texture(def: Dictionary, tier: int) -> Texture2D:
	var arr: Array = def.get("sprites", [])
	if arr.is_empty():
		return null
	# sprites 是 4 张一组的 tier 序列；越界就取最后一张（不应发生）
	var path := String(arr[clampi(tier - 1, 0, arr.size() - 1)])
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


## 重建环形挂载：只在武器列表变化时跑
func _refresh_weapon_ring() -> void:
	if _weapon_holder == null:
		return
	for c in _weapon_holder.get_children():
		c.queue_free()
	_ring_count = 0
	for w in RunState.weapons:
		var wm := w as Dictionary
		var def: Dictionary = RunState.weapon_def(String(wm["id"]))
		if def.is_empty():
			continue
		var tier := int(wm.get("tier", 1))
		var tex := _weapon_sprite_texture(def, tier)
		if tex == null:
			continue
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		# 枪图统一朝右，环形排布时靠 rotation 对齐到 aim_dir
		spr.rotation = aim_dir.angle()
		spr.modulate = WEAPON_TIER_TINT[clampi(tier - 1, 0, WEAPON_TIER_TINT.size() - 1)]
		# 贴图是 24px 画布、枪身只占中段十几像素，按画布缩放会偏小；
		# 但放到 1.0 又会和相邻武器压叠（环上间距小于枪宽），0.62 是实测可读值。
		spr.scale = Vector2.ONE * float(def.get("sprite_scale", 0.62))
		spr.z_index = 1 if tier >= 3 else 0
		_weapon_holder.add_child(spr)
	_ring_count += 1


## 每帧把武器摆到瞄准方向上。
##排布方式：Brotato 里多把武器环绕角色、枪口统一指向光标。
## 关键约束：环上相邻两把的角度间距 = TAU/n，而枪身自身有十几像素宽。
## 早期版本用「窄扇形+ 半径 21 + 缩放 1.0」，4 把枪只有 86° 跨度、
## 弧长间距 ~8px 却各自 ~14px 宽，直接叠成一坨看不清。
## 现在改成整圈均分+ 缩小枪身，保证任意数量下都不互相压叠。
func _update_weapon_ring() -> void:
	if _weapon_holder == null or _ring_count <= 0:
		return
	var kids := _weapon_holder.get_children()
	var n := kids.size()
	if n == 0:
		return
	var aim := aim_dir.angle()
	for i in n:
		var spr := kids[i] as Sprite2D
		if spr == null:
			continue
		# 单把武器贴在正前方；多把沿整圈均分，从正前方开始逆时针排
		var ang := aim if n == 1 else aim + TAU * float(i) / float(n)
		spr.position = Vector2.RIGHT.rotated(ang) * WEAPON_RING_R
		# 枪口统一指向瞄准方向（而不是跟着环的角度转）
		spr.rotation = aim
		spr.visible = state != State.DEAD


func take_damage(amount: int) -> void:
	# 接触伤害入口（敌人本体调用）；无敌帧内免伤
	if state == State.DEAD or invuln > 0.0 or amount <= 0:
		return
	RunState.take_damage(amount)
	invuln = maxf(invuln, HURT_INVULN_AFTER_HIT)
	EventBus.player_hurt.emit(amount)
	EventBus.shake_requested.emit(7.0)
	Sfx.play("hurt", -6.0, randf_range(0.95, 1.05), 0.08)


func is_invulnerable() -> bool:
	return invuln > 0.0


func _on_player_died() -> void:
	# 统一走 die()：此前这里与 die() 各写了一份死亡逻辑，两处都调
	# set_physics_process(false)。die() 会关掉物理帧处理，所以任何依赖
	# 「死亡后还要再跑几帧」的收尾（如收枪）都不能只写在 _update_sprite 路径里。
	die()
	Sfx.play("death", -4.0, 1.0, 0.0)

## 准星指示器：双摇杆玩法下「朝哪打」必须一眼可见，
## 否则键鼠玩家只能靠猜子弹从哪飞出。用素材包 Weapons 里的准星帧（CC0）。
func _update_aim_marker() -> void:
	if state == State.DEAD:
		if _aim_marker != null:
			_aim_marker.visible = false
		return
	if _aim_marker == null:
		_aim_marker = Sprite2D.new()
		var top := 0
		var best := -1
		for w in RunState.weapons:
			var t := int((w as Dictionary).get("tier", 1))
			if t > best:
				best = t
		top = clampi(best, 1, AIM_TEX.size()) - 1
		_aim_marker.texture = AIM_TEX[top]
		_aim_marker.z_index = 4
		_aim_marker.modulate = Color(1.0, 0.95, 0.75, 0.5)
		_sprite.get_parent().add_child(_aim_marker)
	_aim_marker.visible = true
	_aim_marker.position = aim_dir * 22.0
	_aim_marker.rotation = aim_dir.angle()


## 主菜单选定的角色帧集（char1/char2）。换完要重播 idle，否则会停在上一套的动画名上。
func apply_character_frames(frames: SpriteFrames) -> void:
	if _sprite == null or frames == null:
		return
	_sprite.sprite_frames = frames
	if frames.has_animation("idle"):
		_sprite.play("idle")


## 死亡表现：停手 + 播倒地动画。由 Game 在收到 player_died 时调用。
func die() -> void:
	if state == State.DEAD:
		return
	state = State.DEAD
	velocity = Vector2.ZERO
	set_physics_process(false)
	if _sprite != null and _sprite.sprite_frames != null and _sprite.sprite_frames.has_animation("dead"):
		_sprite.play("dead")
	_sprite.modulate = Color(0.6, 0.55, 0.6, 0.85)
	# 这里必须显式收枪：set_physics_process(false) 之后不会再有 _update_weapon_ring()
	_hide_weapon_ring()


## 隐藏环形挂载的全部枪械
func _hide_weapon_ring() -> void:
	if _weapon_holder == null:
		return
	for c in _weapon_holder.get_children():
		var cs := c as Sprite2D
		if cs != null:
			cs.visible = false
