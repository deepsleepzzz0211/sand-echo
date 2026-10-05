extends Node
# 吸血（lifesteal）行为测试。
#
# 这类效果最容易被「数值对但游戏里没反应」骗到：属性进了 _apply_upgrade、
# 派生字段也变了，但伤害结算链路上没人调用它。所以这里不只测数值，
# 还要走真实的「子弹命中敌人 → 回血」链路。

var _pass := 0
var _fail := 0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	print("=== 吸血审计 ===")
	_audit_no_leech_by_default()
	_audit_ratio()
	_audit_floor()
	_audit_two_tiers_stack()
	await _audit_real_hit_chain()
	_report()


func _ok(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  [通过] " + label)
	else:
		_fail += 1
		print("  [失败] " + label)


func _audit_no_leech_by_default() -> void:
	print("\n-- 默认无吸血 --")
	RunState.reset_run()
	_ok(is_zero_approx(RunState.lifesteal), "开局吸血为 0（实际 %.2f）" % RunState.lifesteal)
	RunState.health = 5
	_ok(RunState.heal_from_damage(100) == 0, "无吸血时命中不回血")
	_ok(RunState.health == 5, "血量未变（%d）" % RunState.health)


func _audit_ratio() -> void:
	print("\n-- 按伤害比例回复 --")
	RunState.reset_run()
	_ok(RunState.take_upgrade("r_leech"), "可选取 r_leech（血沙之吸）")
	_ok(absf(RunState.lifesteal - 0.15) < 0.001,
		"吸血比例 = 0.15（实际 %.3f）" % RunState.lifesteal)
	# 注意：每次都先把血量清零再测，否则第二次调用会因血量已满而返回 0，
	# 看起来像功能失效。
	RunState.health = 0
	var h1 := RunState.heal_from_damage(100)
	_ok(h1 == 15, "100 伤害回复 15（实际 %d）" % h1)
	RunState.health = 0
	var h2 := RunState.heal_from_damage(51)
	_ok(h2 == 7, "51 伤害回复 7（floor 7.65，实际 %d）" % h2)
	# 200× 15% = 30，但默认 max_health 只有 20，会被钳住。
	# 先把上限抬开再测比例本身，钳制行为单独测。
	RunState.max_health = 200
	RunState.health = 0
	var h3 := RunState.heal_from_damage(200)
	_ok(h3 == 30, "200 伤害回复 30（上限抬到 200 后，实际 %d）" % h3)


func _audit_floor() -> void:
	print("\n-- 下限 1 点（低伤害武器也要有反馈）--")
	RunState.reset_run()
	RunState.take_upgrade("r_leech")
	# 初始手枪单发 8 伤害：8 × 15%% = 1.2 → floor 1
	RunState.health = 0
	var a := RunState.heal_from_damage(8)
	_ok(a == 1, "初始手枪 8 伤害仍回复 1 点（实际 %d）" % a)
	# 若伤害为 1：1 × 15%% = 0.15 → floor 0 → 钳到 1
	RunState.health = 0
	var b := RunState.heal_from_damage(1)
	_ok(b == 1, "1 点伤害也回复 1 点，不会被取整吞掉（实际 %d）" % b)


func _audit_two_tiers_stack() -> void:
	print("\n-- 两档叠加 --")
	RunState.reset_run()
	RunState.take_upgrade("r_leech")
	_ok(RunState.take_upgrade("r_leech2"), "可再取 r_leech2（沉沙血密）")
	_ok(absf(RunState.lifesteal - 0.45) < 0.001,
		"15%% + 30%% = 45%%（实际 %.3f）" % RunState.lifesteal)
	RunState.max_health = 200
	RunState.health = 0
	var h := RunState.heal_from_damage(100)
	_ok(h == 45, "100 伤害回复 45（实际 %d）" % h)

	# 过量治疗应被钳到生命上限，且不结余——否则攒满血后一波吸回来
	print("\n-- 过量治疗的钳制 --")
	RunState.reset_run()
	RunState.take_upgrade("r_leech")
	RunState.max_health = 20
	RunState.health = 0
	var capped := RunState.heal_from_damage(1000)   # 想要 150
	_ok(RunState.health == 20, "过量回复被钳到生命上限 20（实际 %d）" % RunState.health)
	_ok(capped == 20, "返回的是实际回复量 20 而非请求量 150（实际 %d）" % capped)
	# 关键：不结余。扣掉 10 点后再吸一次，应该只回到 10 而不是 20
	RunState.take_damage(10)
	RunState.health = mini(20, RunState.health)
	RunState.take_damage(10)
	var after := RunState.heal_from_damage(1000)
	_ok(RunState.health <= 20 and after <= 10,
		"扣血后回复不超过缺口，不靠上次溢出攒血（回复 %d，血量 %d）"
			% [after, RunState.health])
	# 死亡后不回血
	RunState.dead = true
	RunState.health = 0
	_ok(RunState.heal_from_damage(100) == 0, "死亡后吸血不生效")
	RunState.dead = false


## 真实链路：造玩家 + 敌人 + 子弹，真的打出去，看血量涨没涨
func _audit_real_hit_chain() -> void:
	print("\n-- 真实命中链路（子弹打中敌人 → 回血）--")
	RunState.reset_run()
	RunState.take_upgrade("r_leech")
	RunState.health = 0

	var world := Node2D.new()
	add_child(world)

	var packed_e: PackedScene = load("res://scenes/enemy.tscn")
	var enemy := packed_e.instantiate() as Node2D
	enemy.call("setup", {"id": "e_chaser", "hp": 9999, "speed": 0, "contact_dmg": 0,
			"brain": "chaser", "gold": 0}, Rect2(0, 0, 4000, 4000), 0)
	world.add_child(enemy)

	var packed_p: PackedScene = load("res://scenes/player.tscn")
	var player := packed_p.instantiate() as Node2D
	world.add_child(player)
	player.position = Vector2(400, 400)
	for i in 4:
		await get_tree().physics_frame

	# 关键：玩家的瞄准方向来自鼠标位置，headless 下鼠标恒在 (0,0)，
	# 所以 aim_dir 指向左上。敌人必须放在这条线上，否则子弹打空、
	# 测试会误报「吸血没生效」。
	var aim: Vector2 = player.get("aim_dir")
	if aim.length() < 0.01:
		aim = Vector2.LEFT
	enemy.position = player.position + aim.normalized() * 160.0
	print("     玩家位置 %s瞄准 %s敌人放在 %s"
		% [str(player.position), str(aim.normalized()), str(enemy.position)])

	# 用玩家真实的开火路径
	var def: Dictionary = RunState.weapon_def("w_pistol")
	var hp_before := RunState.health
	player.call("_fire_weapon", def, 1)
	for i in 30:
		await get_tree().physics_frame
		if RunState.health > hp_before:
			break
	var gained := RunState.health - hp_before
	print("     命中敌人后血量 %d → %d（回复 %d）" % [hp_before, RunState.health, gained])
	_ok(gained > 0, "真实开火命中敌人后确实回血（+%d）" % gained)
	_ok(RunState.lifesteal > 0.0, "吸血属性在链路中仍为生效（%.2f）" % RunState.lifesteal)

	enemy.queue_free()
	player.queue_free()
	RunState.reset_run()


func _report() -> void:
	print("\n诊断：通过 %d 项，失败 %d 项" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)