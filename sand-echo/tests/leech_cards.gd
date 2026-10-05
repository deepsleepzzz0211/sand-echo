extends Node
# 三选一面板目视检查：确认吸血两项的图标与文案在卡片上正常显示。
# 附带校验：22 项升级的图标无重复（此前刚清理过这个问题，
# 新加的两条吸血若又共用图标就会回归）。

func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _run() -> void:
	RunState.reset_run()
	# 校验图标唯一性
	var seen := {}
	var dup: Array[String] = []
	for entry in RunState.table("upgrades"):
		var d := entry as Dictionary
		var p := String(d.get("icon", ""))
		if seen.has(p):
			dup.append("%s 与 %s" % [seen[p], d.get("id", "")])
		else:
			seen[p] = String(d.get("id", ""))
	print("升级 %d 项，图标 %d 个，重复 %d 处 %s"
		% [RunState.table("upgrades").size(), seen.size(), dup.size(), str(dup)])

	var packed: PackedScene = load("res://scenes/upgrade_screen.tscn")
	var up := packed.instantiate()
	add_child(up)
	await get_tree().process_frame

	# 强制把吸血两项排进候选，便于目视
	var pool: Array = []
	for entry in RunState.table("upgrades"):
		var d := entry as Dictionary
		if String(d.get("id", "")).begins_with("r_leech"):
			pool.append(d)
	up.call("offer", pool, 3)
	for i in 4:
		await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("user://leech_cards.png")
		print("已保存 leech_cards.png")
	get_tree().quit(0)