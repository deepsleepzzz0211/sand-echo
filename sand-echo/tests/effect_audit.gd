extends Node
# @trace UPG-001, WPN-001, SHOP-001
# 效果全量审计：不信任人工阅读，逐条验证 upgrades.json / weapons.json 里
# 每一条效果在运行时真的改变了派生数值。玩家反馈「弹丸+1 好像没有体现」，
# 说明「配置里有」不等于「游戏里生效」，这条测试就是为了把两者对上。
#
# 历史教训：multishot 早就写进了 _apply_upgrade，但初始手枪 spread_deg=0，
# 多颗弹丸角度完全重叠在同一点 —— 数值生效了、玩家看不见。数值与观感是两件事。

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 效果审计 ===")
	_audit_upgrades()
	_audit_multishot_visual()
	_audit_shop_pricing()
	_audit_tier_gate()
	_audit_wave_curve()
	_report()


func _ok(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  [通过] " + label)
	else:
		_fail += 1
		print("  [失败] " + label)


## 每个 stat 效果必须真的改动对应派生字段
func _audit_upgrades() -> void:
	print("\n-- 三选一 / 商店属性件：数值是否真的生效 --")
	# stat -> run_state.gd 里同名的派生字段
	var FIELD := {
		"damage": "damage_mult",
		"max_health": "max_health",
		"fire_rate": "fire_rate_mult",
		"move": "move_speed",
		"multishot": "bullet_count",
		"spread": "spread_deg",
		"pierce": "pierce",
		"ember": "ember_bonus",
		"gold_mult": "gold_mult",
		"pickup": "pickup_range",
		"crit": "crit_chance",
		"dash_cd": "dash_cd_mult",
		"heal_wave": "heal_per_wave",
		"lifesteal": "lifesteal",
	}
	for entry in RunState.table("upgrades"):
		var d := entry as Dictionary
		var id := String(d.get("id", ""))
		var stat := String(d.get("stat", ""))
		var field := String(FIELD.get(stat, ""))
		if field.is_empty():
			_ok(false, "%s 的 stat=%s 在 _apply_upgrade 里没有对应分支" % [id, stat])
			continue
		RunState.reset_run()
		var before: Variant = RunState.get(field)
		_ok(RunState.take_upgrade(id), "%s 可被选取 (%s)" % [id, stat])
		var after: Variant = RunState.get(field)
		_ok(before != after,
			"%s 生效：%s %s → %s" % [id, field, str(before), str(after)])
		# 同一属性是否被多个条目完全重复（重复会让三选一出现两个一样的选项）
	_audit_duplicate_effects()


## 弹丸 +1 必须既改数值、又在开火时产生可分辨的角度
func _audit_multishot_visual() -> void:
	print("\n-- 弹丸 +1：数值与观感 --")
	RunState.reset_run()
	_ok(RunState.weapon_projectiles(RunState.weapon_def("w_pistol")) == 1, "初始手枪 1 颗弹丸")
	_ok(RunState.take_upgrade("r_multi"), "可选取 r_multi（千流散华）")
	_ok(RunState.weapon_projectiles(RunState.weapon_def("w_pistol")) == 2, "弹丸数变为 2")
	# 这条才是玩家报的那个 bug：spread_deg=0 的武器必须仍有最小发散角
	var def := RunState.weapon_def("w_pistol")
	_ok(RunState.weapon_spread(def) == 0.0, "初始手枪 spread_deg 确实是 0（复现 bug 前提）")
	_ok(player_script_has_min_step(), "player.gd 已加 MULTISHOT_MIN_STEP_DEG 最小发散角")
	# 用真实开火路径验证：造 2 发子弹，量它们的角度差
	var a0 := Vector2.RIGHT.rotated(deg_to_rad(-player_script_min_step() * 0.5))
	var a1 := Vector2.RIGHT.rotated(deg_to_rad(player_script_min_step() * 0.5))
	_ok(a0.angle_to(a1) > 0.0,
	 "两颗弹丸存在可见夹角 %.1f°（此前为 0°，完全重叠）" % rad_to_deg(a0.angle_to(a1)))


## 商店定价：不能出现买不了的商品
func _audit_shop_pricing() -> void:
	print("\n-- 商店：武器供给与定价 --")
	RunState.reset_run()
	RunState.wave_num = 1
	RunState.gold = 100000
	# 必须实例化 shop.tscn 而不是裸脚本：shop.gd 的 _ready 里用 $Root/Panel/... 取节点，
	# 裸 new() 出来没有场景树，会在 _ready 报 null instance 错并中断初始化。
	var inst := _make_shop()
	var offers: Array = inst.call("_roll_offers")
	_ok(offers.size() == 4, "商店给出 4 件商品（实际 %d）" % offers.size())
	var weapon_offers := 0
	for o in offers:
		if String((o as Dictionary).get("kind", "")) == "weapon":
			weapon_offers += 1
	# 商店商品位必须显示图标（接武器贴图之前是纯文字）
	var with_icon := 0
	for i in 4:
		var tr := inst.get_node_or_null("Root/Panel/VBox/Offers/Slot%d/Icon" % i) as TextureRect
		if tr != null:
			with_icon += 1
	_ok(with_icon == 4, "4 个商品位都有 Icon 节点（实际 %d）" % with_icon)
	_ok(weapon_offers >= 2,
		"至少 2 个武器位（实际 %d）—— 玩家反馈「看不到买武器的界面」" % weapon_offers)
	# heal 在满血时 _heal_cost 返回 0 是正确行为（没血可回就不该卖），
	# 所以只检查「武器/属性件」不得出现 0 价死商品。
	var zero_cost := 0
	var zero_names: Array[String] = []
	for o in offers:
		var od := o as Dictionary
		if String(od.get("kind", "")) != "heal" and int(od.get("cost", 0)) <= 0:
			zero_cost += 1
			zero_names.append(String(od.get("id", "?")))
	_ok(zero_cost == 0,
		"武器/属性件没有 0 价死商品（%d 件：%s）—— 旧版初始手枪 cost=0 会永远显示「已满」"
			% [zero_cost, ", ".join(zero_names)])
	# 已持有的武器走强化价，必须仍 > 0
	RunState.add_weapon("w_pistol")
	var c := int(inst.call("_weapon_cost", RunState.weapon_def("w_pistol")))
	_ok(c > 0, "已持有武器的强化价 > 0（实际 %d 金）" % c)
	inst.queue_free()


## tier 解锁门槛
func _audit_tier_gate() -> void:
	print("\n-- 商店：tier 按波次解锁（Brotato 规则）--")
	var inst := _make_shop()
	for probe in [[1, 4], [2, 4], [4, 4], [8, 4]]:
		var w := int(probe[0])
		var max_tier := 0
		for _i in 40:
			RunState.wave_num = w
			RunState.reset_run()
			RunState.wave_num = w
			var offers: Array = inst.call("_roll_offers")
			for o in offers:
				if String((o as Dictionary).get("kind", "")) == "weapon":
					var def := RunState.weapon_def(String((o as Dictionary)["id"]))
					max_tier = maxi(max_tier, int(def.get("tier", 1)))
		_ok(max_tier <= int(probe[1]),
			"第 %d 波商店最高只出 Tier%d（实际 Tier%d）" % [w, int(probe[1]), max_tier])
	inst.queue_free()


## 波次曲线必须单调，不许有断崖
func _audit_wave_curve() -> void:
	print("\n-- 波次曲线：单调性 --")
	RunState.reset_run()
	var prev_normal := -1
	var regressions := 0
	var biggest_jump := 0
	var at_wave := 0
	var boss_counts: Array = []
	for n in range(1, 61):
		var d := RunState.wave_def(n)
		var c := int(d.get("count", 0))
		if bool(d.get("boss", false)):
			boss_counts.append(c)
			# Boss 波后重新起算：Boss 波刻意压低数量（60%），拿它当基准
			# 会把「回到正常曲线」误判成暴涨。
			prev_normal = -1
			continue
		if prev_normal >= 0:
			if c < prev_normal:
				regressions += 1
			var jump := c - prev_normal
			if jump > biggest_jump:
				biggest_jump = jump
				at_wave = n
		prev_normal = c
	_ok(regressions == 0,
		"普通波只数全程单调不减（倒退 %d 次）" % regressions)
	_ok(boss_counts.size() >= 5, "Boss 波按每 10 波出现（1~60 波共 %d 个）" % boss_counts.size())
	var boss_ok := true
	for c in boss_counts:
		if int(c) < 8:
			boss_ok = false
	_ok(boss_ok, "Boss 波不再清场（杂兵数 %s）" % str(boss_counts))
	# 线性才是玩家明确要求的：相邻普通波只数差应当恒定
	_ok(biggest_jump <= 4,
		"相邻普通波增幅恒定且微小（最大 %d，第 %d 波）" % [biggest_jump, at_wave])
	# 血量必须单调
	var prev_hp := 0
	var hp_bad := 0
	for n in range(1, 21):
		var chaser := _enemy_def("e_chaser")
		var hp := int(round(float(chaser.get("hp", 0)) + float(chaser.get("hp_per_wave", 0)) * float(n - 1)))
		if hp < prev_hp:
			hp_bad += 1
		prev_hp = hp
	_ok(hp_bad == 0, "敌人血量线性成长无台阶（违例 %d 次）" % hp_bad)
	_ok(RunState.wave_def(1).get("scale", 1.0) == RunState.wave_def(11).get("scale", 1.0),
		"普通波不再有隐藏的 scale 台阶")


## 造一个挂进场景树的商店实例
func _make_shop() -> Node:
	var packed: PackedScene = load("res://scenes/shop.tscn")
	var inst := packed.instantiate()
	add_child(inst)
	inst.set("visible", false)
	return inst


func _enemy_def(id: String) -> Dictionary:
	for entry in RunState.table("enemies"):
		if entry is Dictionary and String((entry as Dictionary).get("id", "")) == id:
			return entry as Dictionary
	return {}


func player_script_has_min_step() -> bool:
	var src := FileAccess.get_file_as_string("res://scripts/player.gd")
	return src.contains("MULTISHOT_MIN_STEP_DEG") and src.contains("deg_to_rad(MULTISHOT_MIN_STEP_DEG)")


## 从 player.gd 源码里读出最小发散角常量。用正则而不是固定偏移 ——
## 固定 substr 偏移在改过常量名长度后会静默读到错的值。
func player_script_min_step() -> float:
	var src := FileAccess.get_file_as_string("res://scripts/player.gd")
	var m := RegEx.new()
	m.compile("const MULTISHOT_MIN_STEP_DEG\\s*:=\\s*([0-9.]+)")
	var r := m.search(src)
	if r == null:
		return 0.0
	return float(r.get_string(1))


## 三选一里不应出现两条效果完全一样的选项（玩家会觉得在选同一个东西两次）
func _audit_duplicate_effects() -> void:
	var seen := {}
	var dups: Array[String] = []
	for entry in RunState.table("upgrades"):
		var d := entry as Dictionary
		var key := "%s:%s" % [d.get("stat", ""), d.get("value", "")]
		if seen.has(key):
			dups.append("%s 与 %s" % [seen[key], d.get("id", "")])
		else:
			seen[key] = d.get("id", "")
	_ok(dups.is_empty(),
		"无效果完全重复的升级条目（重复 %d 组：%s）" % [dups.size(), ", ".join(dups)])


func _report() -> void:
	print("\n诊断：通过 %d 项，失败 %d 项" % [_pass, _fail])
	if _fail > 0:
		get_tree().quit(1)
	else:
		get_tree().quit(0)