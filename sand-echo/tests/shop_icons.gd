extends Node
# 商店商品位图标目视检查。
# 起因是玩家提醒「枪械图标不要删，商店需要用到」——顺带查出 20 项升级里有
# 4 项两两共用同一图标（stat_up_4 与 icon_gem2 各被2 项使用），
# 商店里会出现两件顶着同一个图标的商品，玩家分不出区别。
# 恰好 bullet_t2..t5 这四张带色帧因玩家弹丸改形而闲置，正好补上这四个缺口。

func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_run()


func _run() -> void:
	RunState.reset_run()
	RunState.gold = 5000
	for id in ["w_smg", "w_sniper", "w_railgun", "w_hunter"]:
		RunState.buy_weapon(id, 100)

	var packed: PackedScene = load("res://scenes/shop.tscn")
	var shop := packed.instantiate()
	add_child(shop)
	await get_tree().process_frame
	shop.call("offer", RunState.weapons, RunState.gold)
	for i in 3:
		await get_tree().process_frame

	# 校验图标唯一性
	var seen := {}
	var dup: Array[String] = []
	for entry in RunState.table("upgrades"):
		var d := entry as Dictionary
		var p := String(d.get("icon", ""))
		if seen.has(p):
			dup.append("%s 与 %s 共用 %s" % [seen[p], d.get("id", ""), p.get_file()])
		else:
			seen[p] = String(d.get("id", ""))

	print("升级条目 %d，使用图标 %d 个" % [RunState.table("upgrades").size(), seen.size()])
	if dup.is_empty():
		print("无重复图标")
	else:
		for x in dup:
			print("  重复: " + x)

	# 回收行的按钮
	var row := shop.get_node_or_null("Root/Panel/VBox/Owned") as HBoxContainer
	print("我的武器行按钮数：%d" % (row.get_child_count() if row != null else -1))
	if row != null:
		for c in row.get_children():
			var b := c as Button
			if b != null:
				print("  回收按钮: %s" % b.text.replace("\n", " / "))

	for i in 4:
		await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("user://shop_icons.png")
		print("已保存 shop_icons.png")
	get_tree().quit(0)