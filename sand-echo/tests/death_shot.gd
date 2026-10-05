extends Node
# 死亡结算画面截图：验证文案已从「遗物」改为「强化」，且画面确实弹出。
# 自动断言只能证明 text 非空，证明不了「玩家看到的是不是还在叫遗物」。

func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _run() -> void:
	RunState.reset_run()
	RunState.gold = 880
	# 造几个升级，让强化列表有内容可显示
	for id in ["r_atk", "r_multi", "r_hp"]:
		RunState.take_upgrade(id)
	RunState.bump_stat("enemies_killed", 23)
	RunState.bump_stat("waves_cleared", 3)
	RunState.take_damage(37)

	var packed: PackedScene = load("res://scenes/death_screen.tscn")
	var death := packed.instantiate()
	add_child(death)
	await get_tree().process_frame

	var ember := 42
	EventBus.run_ended.emit(ember, RunState.summary())
	death.call("show_summary", ember, RunState.summary())
	for i in 3:
		await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("user://death_text.png")
		print("已保存 death_text.png")

	# 同时把实际文案打进日志，便于文本核对
	var stats := death.get_node("Root/Panel/VBox/Stats") as Label
	var ups := death.get_node("Root/Panel/VBox/Relics") as Label
	print("Stats: ", stats.text.replace("\n", " | "))
	print("强化栏: ", ups.text.replace("\n", " | "))
	get_tree().quit(0)