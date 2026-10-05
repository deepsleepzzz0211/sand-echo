extends Node
# 专门用来目视定位「怪物头顶那根黑线」到底是什么。
# 之前只按推断改过一次（把血条底衬改成随血量显隐），但玩家反馈黑线仍在，
# 说明推断错了。这次直接把不同血量的敌人摆在一起拍下来，用眼睛确认。

func _ready() -> void:
	await get_tree().process_frame
	_build()
	for i in 4:
		await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("user://bar_probe.png")
		print("已保存 bar_probe.png")
	get_tree().quit(0)


func _build() -> void:
	# 深色背景，方便看清暗色线条
	var bg := ColorRect.new()
	bg.color = Color(0.16, 0.14, 0.20)
	bg.size = Vector2(760, 260)
	bg.position = Vector2(20, 20)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var cam := Camera2D.new()
	add_child(cam)
	cam.make_current()

	# 一排敌人，依次为：满血 / 3/4 血 / 1/2 血 / 1/4 血
	var fracs := [1.0, 0.75, 0.5, 0.25]
	var packed: PackedScene = load("res://scenes/enemy.tscn")
	for i in 4:
		var e := packed.instantiate()
		var hp := 40
		e.call("setup", {
			"id": "e_chaser", "name": "\u6c99\u86d9", "hp": hp, "speed": 0,
			"contact_dmg": 0, "brain": "chaser", "bullet_dmg": 0,
			"fire_interval": 0, "gold": 0, "hp_per_wave": 0,
		}, Rect2(0, 0, 760, 260), 0)
		add_child(e)
		e.position = Vector2(120 + i * 170, 150)
		print("敌人 %d：满血 %d" % [i, hp])

	# setup() 里 _hp_max 就是传入的 hp，所以直接传低血量会被当成满血、血条不显示。
	# 必须先按 40 满血 setup，再真的打掉一部分，才能看到血条的真实样子。
	await get_tree().process_frame
	for i in 4:
		var target := get_child(2 + i)   # 跳过 bg ColorRect 与 Camera
		if target != null and target.has_method("take_damage"):
			target.call("take_damage", int(40.0 * (1.0 - fracs[i])))
	await get_tree().process_frame
	for i in 4:
		var t2 := get_child(2 + i)
		if t2 != null:
			print("敌人 %d：实际剩余血量 %d / %d" % [i, int(t2.get("hp")), int(t2.get("_hp_max"))])