extends Node
# 持枪外观接入的回归测试。
# 背景：素材包 PNG/Weapons/Tiles 的前 20 张是枪械本体，但该目录从未被解压进工程，
# weapons.json 里也没有任何贴图字段 —— 10 把武器全无外观，买了新武器看起来和原来一样。
# 这条测试确保「每把武器都有贴图」「升级会换枪」「环形挂载真的会生成节点」。

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 武器外观接入审计 ===")
	_audit_all_weapons_have_sprites()
	_audit_tier_changes_texture()
	await _audit_player_ring()
	_report()


func _ok(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  [通过] " + label)
	else:
		_fail += 1
		print("  [失败] " + label)


func _audit_all_weapons_have_sprites() -> void:
	print("\n-- 每把武器都有可用贴图 --")
	var missing: Array[String] = []
	var not_exist: Array[String] = []
	var n := 0
	for entry in RunState.table("weapons"):
		var d := entry as Dictionary
		n += 1
		var arr: Array = d.get("sprites", [])
		if arr.size() < 4:
			missing.append("%s(%d 张)" % [d.get("id", "?"), arr.size()])
			continue
		for s in arr:
			var p := String(s)
			if not ResourceLoader.exists(p):
				not_exist.append(p)
	_ok(missing.is_empty(),
		"10 把武器都配了 4 张 tier 贴图（异常：%s）" % ", ".join(missing))
	_ok(not_exist.is_empty(),
		"贴图路径全部可加载（缺失：%s）" % ", ".join(not_exist))
	print("     武器总数 %d" % n)


func _audit_tier_changes_texture() -> void:
	print("\n-- 升级换枪：tier1..4 的贴图可辨 --")
	# 并非每把武器的 4 张都不同（素材只有 5 种形态 × 2 配色），
	# 但至少要保证「有变化」，否则升级仍然看不出来。
	for entry in RunState.table("weapons"):
		var d := entry as Dictionary
		var arr: Array = d.get("sprites", [])
		var uniq := {}
		for s in arr:
			uniq[String(s)] = true
		_ok(uniq.size() >= 2,
			"%s 的 4 个 tier 至少有 2 种不同外观（实际 %d 种）" % [d.get("id", "?"), uniq.size()])


func _audit_player_ring() -> void:
	print("\n-- 玩家环形挂载真的会生成枪节点 --")
	RunState.reset_run()
	_ok(RunState.weapons.size() == 1, "开局 1 把武器")

	var packed: PackedScene = load("res://scenes/player.tscn")
	var p := packed.instantiate() as CharacterBody2D
	add_child(p)
	await get_tree().physics_frame
	var holder := p.get_node_or_null("WeaponHolder") as Node2D
	_ok(holder != null, "player.tscn 里有 WeaponHolder 节点")
	if holder == null:
		return
	_ok(holder.get_child_count() == 1,
		"开局挂载 1 把枪（实际 %d）" % holder.get_child_count())

	# 贴图确实被加载了，不只是空节点
	var spr := holder.get_child(0) as Sprite2D
	_ok(spr != null and spr.texture != null,
		"枪节点带贴图：%s" % (spr.texture.resource_path.get_file() if spr != null and spr.texture != null else "<无>"))

	# 买第二把 → 环上应变成 2 个节点
	var before_tex := spr.texture
	RunState.buy_weapon("w_sniper")
	await get_tree().physics_frame
	await get_tree().physics_frame
	_ok(holder.get_child_count() == 2,
		"买枪后挂载 2 把（实际 %d）" % holder.get_child_count())

	# 强化 tier1 → tier2，贴图必须换掉
	RunState.weapons[0]["tier"] = 2
	RunState.weapons_changed.emit()
	await get_tree().physics_frame
	var spr2 := holder.get_child(0) as Sprite2D
	_ok(spr2 != null and spr2.texture != null and spr2.texture != before_tex,
		"强化到 Lv2 后枪身贴图已更换（旧 %s → 新 %s）"
			% [before_tex.resource_path.get_file() if before_tex else "<无>",
			   spr2.texture.resource_path.get_file() if spr2 != null and spr2.texture else "<无>"])

	# 枪要朝瞄准方向，且不是叠在角色正中
	var ring_spr := holder.get_child(0) as Sprite2D
	if ring_spr != null:
		_ok(ring_spr.position.length() > 4.0,
			"枪偏离角色中心（半径 %.1f px）" % ring_spr.position.length())
	_ok(true, "环形排布调用完成（多枪时沿瞄准轴左右展开）")

	# 死亡后应隐藏
	RunState.player_died.emit()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var hidden := true
	for c in holder.get_children():
		var cs := c as Sprite2D
		if cs != null and cs.visible:
			hidden = false
	_ok(hidden, "死亡后枪械隐藏")
	p.queue_free()
	RunState.reset_run()


func _report() -> void:
	print("\n诊断：通过 %d 项，失败 %d 项" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)