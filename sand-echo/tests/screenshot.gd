extends Node
# 开发用截图工具（非游戏逻辑）。渲染到固定 1920×1080 的 SubViewport，
# 结果与窗口大小/DPI 无关，可用于稳定的视觉回归对比。
# 运行：godot.exe --path . res://tests/screenshot.tscn -- --shot-dir="<目录>/"

const VIEW_W := 1920
const VIEW_H := 1080

var _out_dir := "user://"
var _shot_index := 0
var _plan: Array = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot-dir="):
			_out_dir = arg.substr(11)
	_plan = [
		{"scene": "res://scenes/main_menu.tscn", "wait": 30, "name": "main_menu"},
		{"scene": "res://scenes/game.tscn", "wait": 60, "name": "game_start"},
		{"scene": "res://scenes/game.tscn", "wait": 60, "name": "game_floor2", "warp": true},
		{"scene": "res://scenes/game.tscn", "wait": 60, "name": "pause", "warp": true, "pause": true},
		{"scene": "res://scenes/game.tscn", "wait": 60, "name": "death", "warp": true, "die": true},
	]
	await get_tree().process_frame
	_run_plan()


func _run_plan() -> void:
	for step in _plan:
		await _capture(step)
	print("截图完成，目录：%s" % _out_dir)
	get_tree().quit(0)


func _capture(step: Dictionary) -> void:
	var scene_path := String(step["scene"])
	var packed: PackedScene = load(scene_path)
	if packed == null:
		push_error("截图工具：场景不存在 %s" % scene_path)
		return
	var sub := SubViewport.new()
	sub.size = Vector2i(VIEW_W, VIEW_H)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sub.transparent_bg = false
	add_child(sub)
	var holder := Node.new()
	holder.name = "Holder"
	sub.add_child(holder)
	var node := packed.instantiate()
	holder.add_child(node)
	var cam := node.get_node_or_null("Camera2D") as Camera2D
	if cam != null:
		cam.make_current()
	for i in int(step["wait"]):
		await get_tree().process_frame
	if bool(step.get("warp", false)):
		await _warp_to_floor2(node)
		for i in 20:
			await get_tree().process_frame
	_dump_diagnostics(node, String(step["name"]))
	if bool(step.get("die", false)):
		RunState.take_damage(999999)
		for i in 20:
			await get_tree().process_frame
	if bool(step.get("pause", false)):
		node.call("toggle_pause")
		for i in 20:
			await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := sub.get_texture().get_image()
	_shot_index += 1
	var path := "%sshot_%d_%s.png" % [_out_dir, _shot_index, String(step["name"])]
	if img.save_png(path) != OK:
		push_error("截图工具：保存失败 %s" % path)
	else:
		print("已保存 %s (%dx%d)" % [path, img.get_width(), img.get_height()])
	sub.queue_free()
	await get_tree().process_frame


func _dump_diagnostics(node: Node, tag: String) -> void:
	var p := node.get("player") as Node2D
	if p == null:
		print("  诊断 %s：player 为空" % tag)
		return
	var spr := p.get_node_or_null("Sprite") as AnimatedSprite2D
	print("  诊断 %s：player pos=%s visible=%s sprite=%s anim=%s frames=%s" % [
		tag, str(p.global_position), str(p.visible),
		str(spr != null and spr.visible),
		str(spr.animation if spr != null else "-"),
		str(spr.sprite_frames != null if spr != null else false)])
	var count := 0
	for c in (node.get("world") as Node2D).get_children():
		if c is Enemy:
			count += 1
			if count <= 3:
				print("    enemy %s pos=%s" % [str(c.get("enemy_id")), str((c as Node2D).global_position)])
	print("  诊断 %s：enemies=%d" % [tag, count])


func _warp_to_floor2(node: Node) -> void:
	# 演示用：直接把玩家送进第 2 层的一个战斗房
	var game := node as Node2D
	if game == null or not game.has_method("next_floor"):
		return
	var d_before: int = RunState.floor_num
	game.next_floor()
	# 走进第二个房间，制造有敌人的画面
	var guard := 0
	while int(game.get("current_room_id")) == int(game.get("dungeon").start_id) and guard < 10:
		guard += 1
		for dir in 4:
			if bool((game.get("dungeon").get_room(int(game.get("current_room_id")))["doors"] as Array)[dir]):
				game.call("_on_door_entered", dir)
				break
	print("  warp：第 %d 层 → 第 %d 层，房间 %s" % [d_before, RunState.floor_num, str(game.get("current_room_id"))])