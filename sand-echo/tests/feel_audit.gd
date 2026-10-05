extends Node
# 手感层回归：暂停 与 打击顿帧。
#
# 这两条都是玩家实机反馈发现的，靠读代码不容易看出问题，所以各配了断言：
# ① ESC 暂停曾经「按了没反应」，而且是三层同时坏：
#    game.gd 没有任何 _unhandled_input 调 toggle_pause；
#    toggle_pause() 找的 pause.toggle() 方法根本不存在；
#    pause_menu.set_paused() 只切界面可见性，从不设 get_tree().paused。
#    结果是菜单就算显示出来，游戏也在后面照跑。
# ② 顿帧曾经「每次命中卡掉三分之一秒」：Tween 受 Engine.time_scale 影响，
#    0.05 秒的间隔在 time_scale=0.15 下实际走 0.33 秒；
#    而且多发武器每秒触发几十次，几乎永久慢动作。

var _fail := 0
var _pass := 0
var _game: Node2D
var _sub: SubViewport


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_sub = SubViewport.new()
	_sub.size = Vector2i(1920, 1080)
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sub)
	var holder := Node.new()
	_sub.add_child(holder)
	await get_tree().process_frame

	print("=== 手感层审计（暂停 / 顿帧）===")
	_game = (load("res://scenes/game.tscn") as PackedScene).instantiate() as Node2D
	add_child(_game)   # 不能放进 _sub：SubViewport 输入通道独立，ESC 收不到
	await get_tree().process_frame
	await get_tree().process_frame

	await _audit_pause()
	_audit_hitstop_constants()
	await _audit_hitstop_behaviour()
	await _audit_enemy_has_no_dark_track()
	_report()


func _ok(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  [通过] " + label)
	else:
		_fail += 1
		print("  [失败] " + label)


func _audit_pause() -> void:
	print("\n-- ESC 暂停 --")
	_ok(InputMap.has_action("ui_cancel"), "输入表里存在 ui_cancel 动作")
	var pause := _game.get_node_or_null("PauseMenu")
	_ok(pause != null, "场景里有 PauseMenu")
	if pause == null:
		return
	_ok(pause.has_method("toggle"), "PauseMenu 有 toggle()（game.gd 一直在找它）")
	_ok(pause.get("_game") == _game, "PauseMenu 已 setup(game)，「继续」按钮能找到回调")

	_ok(not get_tree().paused, "初始未暂停")
	_ok(not (pause.get_node("Root") as Control).visible, "初始暂停界面不可见")

	# 模拟按下 ESC
	var ev := InputEventAction.new()
	ev.action = "ui_cancel"
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	await get_tree().process_frame

	_ok(get_tree().paused, "按 ESC 后 get_tree().paused = true（场景真的停住了）")
	_ok((pause.get_node("Root") as Control).visible, "按 ESC 后暂停界面可见")

	# 再按一次恢复
	var ev2 := InputEventAction.new()
	ev2.action = "ui_cancel"
	ev2.pressed = true
	Input.parse_input_event(ev2)
	await get_tree().process_frame
	await get_tree().process_frame
	_ok(not get_tree().paused, "再按 ESC 恢复运行")
	_ok(not (pause.get_node("Root") as Control).visible, "恢复后暂停界面隐藏")


func _audit_hitstop_constants() -> void:
	print("\n-- 顿帧参数 --")
	_ok(_game.HITSTOP_CD_MS >= 60, "普通命中有冷却限频（%d ms）" % _game.HITSTOP_CD_MS)
	_ok(_game.KILLSTOP_CD_MS >= _game.HITSTOP_CD_MS, "击杀冷却不短于命中冷却")
	_ok(_game.HITSTOP_SCALE > 0.5, "普通命中不再是重停顿（scale=%.2f）" % _game.HITSTOP_SCALE)
	_ok(_game.HITSTOP_SEC <= 0.05, "普通命中顿帧很短（%.3f 秒）" % _game.HITSTOP_SEC)
	_ok(_game.KILLSTOP_SEC <= 0.10, "击杀顿帧短（%.3f 秒）" % _game.KILLSTOP_SEC)
	_ok(not _game.has_method("_on_hitstop"),
		"旧的「每次命中都压 time_scale=0.15」实现已移除")


func _audit_hitstop_behaviour() -> void:
	print("\n-- 顿帧实际行为 --")
	Engine.time_scale = 1.0
	_game.set("_last_hitstop_ms", 0)
	_game.call("_try_hitstop", _game.HITSTOP_CD_MS, _game.HITSTOP_SCALE,
			_game.HITSTOP_SEC, 0)
	_ok(Engine.time_scale < 1.0, "触发后 time_scale 被压低（%.2f）" % Engine.time_scale)

	# 关键：必须按真实时间恢复。旧实现里 0.03 秒的 tween 在 0.55 倍速下
	# 要走 0.055 秒，更糟的情况是 0.05/0.15 = 0.33 秒。
	var t0 := Time.get_ticks_msec()
	while Engine.time_scale < 1.0 and Time.get_ticks_msec() - t0 < 2000:
		await get_tree().process_frame
	var elapsed := Time.get_ticks_msec() - t0
	_ok(Engine.time_scale == 1.0, "time_scale 已复位为 1.0")
	_ok(elapsed < 400,
		"真实耗时 %d ms（应接近 %.0f ms，旧实现会被 time_scale 拖成数倍）"
			% [elapsed, _game.HITSTOP_SEC * 1000.0])

	# 限频：连打 20 次，实际生效次数应远少于 20
	Engine.time_scale = 1.0
	_game.set("_last_hitstop_ms", Time.get_ticks_msec())
	var applied := 0
	for i in 20:
		var before := Engine.time_scale
		_game.set("_last_hitstop_ms",
				int(_game.call("_try_hitstop", _game.HITSTOP_CD_MS, _game.HITSTOP_SCALE,
						_game.HITSTOP_SEC, int(_game.get("_last_hitstop_ms")))))
		if Engine.time_scale != before or Engine.time_scale < 1.0:
			applied += 1
	Engine.time_scale = 1.0
	_ok(applied <= 2,
		"连续 20 次命中只触发 %d 次顿帧（限频生效）" % applied)


func _audit_enemy_has_no_dark_track() -> void:
	print("\n-- 血条不再有黑色底衬 --")
	var src := FileAccess.get_file_as_string("res://scripts/enemy.gd")
	_ok(not src.contains("0.08, 0.07, 0.10"),
		"enemy.gd 里已无近黑色底衬色（玩家反馈的「黑线」来源）")
	# 实测：受伤敌人的 HpBar 下只能有一个子节点（红条）
	var packed: PackedScene = load("res://scenes/enemy.tscn")
	var e := packed.instantiate()
	add_child(e)
	await get_tree().process_frame
	e.call("setup", {"id": "e_chaser", "hp": 40, "speed": 0, "contact_dmg": 0,
			"brain": "chaser", "gold": 0}, Rect2(0, 0, 400, 400), 0)
	await get_tree().process_frame
	if e.has_method("take_damage"):
		e.call("take_damage", 20)
	await get_tree().process_frame
	var bar := e.get_node_or_null("HpBar")
	_ok(bar != null, "敌人有 HpBar 节点")
	if bar != null:
		_ok(bar.get_child_count() == 1,
			"HpBar 下只有 1 个子节点（实际 %d，应无底衬）" % bar.get_child_count())
		_ok(bar.visible, "受伤后血条可见")
	e.queue_free()
	Engine.time_scale = 1.0


func _report() -> void:
	Engine.time_scale = 1.0
	get_tree().paused = false
	print("\n诊断：通过 %d 项，失败 %d 项" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)