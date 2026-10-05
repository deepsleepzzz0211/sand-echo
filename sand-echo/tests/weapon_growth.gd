extends Node
# tier 差异化 + 武器回收 的回归测试。
#
# 引入这两条功能的原因：
# ① tier 此前只放大伤害（恒定 +75%），射速/弹丸/贯穿/散布从 T1 到 T4 完全不变，
#    玩家反馈「买武器升级看不出来」。
# ② 没有回收路径时，6 把槽位填满且全部满级后彻底卡死：商店买不进新武器，
#    也没有可强化的对象。

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 武器成长与回收审计 ===")
	_audit_tier_table()
	_audit_tier_differentiation()
	_audit_pellet_rule()
	_audit_sell_frees_slot()
	_audit_sell_guards()
	await _audit_shop_sell_row()
	_report()


func _ok(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  [通过] " + label)
	else:
		_fail += 1
		print("  [失败] " + label)


## tier 必须同时成长多个维度，而不只是伤害
## tier 倍率表本身：伤害那一列是既有红线，不能被顺手改掉
func _audit_tier_table() -> void:
	print("\n-- tier 倍率表 --")
	_ok(RunState.TIER_DAMAGE == [1.00, 1.25, 1.50, 1.75],
		"伤害倍率表保持 1.00/1.25/1.50/1.75（数值红线）")
	_ok(RunState.TIER_INTERVAL[3] < RunState.TIER_INTERVAL[0], "射速倍率随 tier 递减")
	_ok(RunState.TIER_PIERCE[3] > RunState.TIER_PIERCE[0], "贯穿随 tier 递增")
	_ok(RunState.TIER_SPREAD[3] <= RunState.TIER_SPREAD[0], "散布随 tier 收拢")
	_ok(RunState.TIER_BULLET[3] > RunState.TIER_BULLET[0], "弹丸尺寸随 tier 递增")


func _audit_tier_differentiation() -> void:
	print("\n-- tier 差异化：每级都要有可感知的成长 --")
	RunState.reset_run()
	for entry in RunState.table("weapons"):
		var def := entry as Dictionary
		var id := String(def.get("id", ""))
		var d1 := RunState.weapon_damage(def, 1)
		var d4 := RunState.weapon_damage(def, 4)
		var i1 := RunState.weapon_interval(def, 1)
		var i4 := RunState.weapon_interval(def, 4)
		var p1 := RunState.weapon_pierce(def, 1)
		var p4 := RunState.weapon_pierce(def, 4)
		var s1 := RunState.weapon_spread(def, 1)
		var s4 := RunState.weapon_spread(def, 4)
		var b1 := RunState.weapon_bullet_scale(def, 1)
		var b4 := RunState.weapon_bullet_scale(def, 4)
		# 伤害那一列是既有红线，必须仍是 +75%。
		# 用比值而不是 round(d1*1.75)：d1/d4 都是取整后的整数，
		# 再取整一次会引入第二层误差（轨道炮 58→61→108 就这么挂的）。
		# 从 base 与 damage_mult 独立算一遍期望值，而不是拿 d1 反推比值：
		# 低伤害武器（base 5~8）取整误差能到 ±1，用比值判会误报
		# （手枪 8→15 看起来是 +87%，其实公式就是 1.75 倍）。
		var base := float(def.get("damage", 1))
		var mult := float(RunState.damage_mult)
		var exp1 := int(round(base * mult * 1.00))
		var exp4 := int(round(base * mult * 1.75))
		_ok(d1 == exp1 and d4 == exp4,
			"%s 伤害符合 base×倍率×tier（期望 %d→%d，实际 %d→%d）" % [id, exp1, exp4, d1, d4])
		_ok(i4 < i1, "%s 射速随tier 变快（%.3fs → %.3fs）" % [id, i1, i4])
		_ok(p4 > p1, "%s 贯穿随 tier 增长（%d → %d）" % [id, p1, p4])
		_ok(s4 <= s1, "%s 散布随 tier 收拢（%.1f° → %.1f°）" % [id, s1, s4])
		_ok(b4 > b1, "%s 弹丸随 tier 变大（%.2f → %.2f）" % [id, b1, b4])
		# 单发武器不该靠弹丸数成长
		if int(def.get("projectiles", 1)) < RunState.PELLET_WEAPON_MIN:
			_ok(RunState.weapon_projectiles(def, 1) == RunState.weapon_projectiles(def, 4),
				"%s 是单发武器，tier 不加弹丸（防 DPS 翻倍）" % id)


## 多发武器才吃 tier 额外弹丸
func _audit_pellet_rule() -> void:
	print("\n-- 额外弹丸只给多发武器 --")
	var shotgun := RunState.weapon_def("w_shotgun")   # 基础 5 发
	_ok(RunState.weapon_projectiles(shotgun, 1) == 5, "霰弹枪 T1 = 5 发")
	_ok(RunState.weapon_projectiles(shotgun, 3) == 6, "霰弹枪 T3 = 6 发（+1 弹丸）")
	_ok(RunState.weapon_projectiles(shotgun, 4) == 6, "霰弹枪 T4 = 6 发")
	var pistol := RunState.weapon_def("w_pistol")      # 基础 1 发
	_ok(RunState.weapon_projectiles(pistol, 4) == 1, "手枪 T4 仍是 1 发")


func _audit_sell_frees_slot() -> void:
	print("\n-- 回收：腾槽位 + 退款 --")
	RunState.reset_run()
	RunState.gold = 0
	# 开局已持有初始手枪（槽位 1/6），所以这里只能再买 5 把才刚好填满
	var ids := ["w_smg", "w_shotgun", "w_sniper", "w_spread", "w_orb"]
	for id in ids:
		_ok(RunState.buy_weapon(id, 100), "买入 %s" % id)
	_ok(RunState.weapons.size() == RunState.MAX_WEAPONS,
		"槽位已满（%d/%d）" % [RunState.weapons.size(), RunState.MAX_WEAPONS])
	_ok(not RunState.can_add_new_weapon(), "满槽位时买不进新武器（此前的卡死状态）")

	# 回收第 1 把
	var gold_before := RunState.gold
	var refund := RunState.sell_weapon(1)
	_ok(refund > 0, "回收报价 %d 金" % refund)
	_ok(RunState.weapons.size() == RunState.MAX_WEAPONS - 1,
		"槽位已腾出（%d/%d）" % [RunState.weapons.size(), RunState.MAX_WEAPONS])
	_ok(RunState.gold == gold_before + refund, "金币到账 %d → %d" % [gold_before, RunState.gold])
	_ok(RunState.can_add_new_weapon(), "腾出槽位后又能买新武器了")

	# 退款应约为投入的一半
	_ok(refund == 50, "投入 100 的武器回收价 = 50（实际 %d）" % refund)

	# 满级武器不能被继续投入；把全部武器拉满才能验证「无可强化对象」
	for w in RunState.weapons:
		(w as Dictionary)["tier"] = RunState.MAX_TIER
	_ok(not RunState.buy_weapon(String((RunState.weapons[0] as Dictionary)["id"]), 50),
		"满级武器拒绝继续投入")
	var any_upgradable := false
	for w in RunState.weapons:
		if int((w as Dictionary).get("tier", 1)) < RunState.MAX_TIER:
			any_upgradable = true
	_ok(not any_upgradable, "全部满级时无可强化对象")


func _audit_sell_guards() -> void:
	print("\n-- 回收边界条件 --")
	RunState.reset_run()
	_ok(RunState.sell_weapon(0) == 0, "只剩一把时拒绝出售（不能卖到空手）")
	_ok(RunState.weapons.size() == 1, "武器仍在（%d 把）" % RunState.weapons.size())
	_ok(RunState.sell_value(99) == 0, "越界索引报价为 0")
	RunState.buy_weapon("w_smg", 90)
	_ok(RunState.sell_value(1) == 45, "投入 90 的武器回收价 45（实际 %d）" % RunState.sell_value(1))
	# 初始手枪 invested=0，应给象征性回收价而不是 0
	_ok(RunState.sell_value(0) >= 1,
		"初始手枪（invested=0）仍有回收价 %d" % RunState.sell_value(0))
	# 退款不吃 gold_mult
	RunState.reset_run()
	RunState.gold = 0
	RunState.buy_weapon("w_smg", 200)
	RunState.take_upgrade("r_greed")   # 金币获取 +30%
	var g_before := RunState.gold
	var got := RunState.sell_weapon(1)
	_ok(RunState.gold == g_before + got and got == 100,
		"退款不受 gold_mult 放大（应得 100，实际 %d）" % got)


func _audit_shop_sell_row() -> void:
	print("\n-- 商店 UI：回收行 --")
	RunState.reset_run()
	RunState.buy_weapon("w_smg", 100)
	RunState.buy_weapon("w_sniper", 200)
	var inst := _make_shop()
	inst.call("offer", RunState.weapons, RunState.gold)
	await get_tree().process_frame
	var row := inst.get_node_or_null("Root/Panel/VBox/Owned") as HBoxContainer
	_ok(row != null, "商店里有 Owned 行")
	if row != null:
		# 开局手枪 + 买的两把 = 3
		_ok(row.get_child_count() == 3,
			"Owned 行渲染 3 把武器（初始手枪 + 2， 实际 %d）" % row.get_child_count())
		var b0 := row.get_child(0) as Button
		_ok(b0 != null and b0.text.contains("卖"), "按钮带回收价：%s"
			% (b0.text.replace("\n", " ") if b0 != null else "<无>"))
		# 点一下应该真的卖掉
		var n0 := RunState.weapons.size()
		if b0 != null:
			b0.pressed.emit()
			await get_tree().process_frame
		_ok(RunState.weapons.size() == n0 - 1,
			"点击后真的卖掉（%d → %d）" % [n0, RunState.weapons.size()])
	# 只剩一把时按钮应禁用
	RunState.reset_run()
	inst.call("offer", RunState.weapons, RunState.gold)
	await get_tree().process_frame
	if row != null:
		await get_tree().process_frame
		var only := row.get_child(0) as Button
		_ok(only != null and only.disabled, "只剩一把时回收按钮禁用")
	inst.queue_free()
	RunState.reset_run()


func _make_shop() -> Node:
	var packed: PackedScene = load("res://scenes/shop.tscn")
	var inst := packed.instantiate()
	add_child(inst)
	inst.set("visible", false)
	return inst


func _report() -> void:
	print("\n诊断：通过 %d 项，失败 %d 项" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)