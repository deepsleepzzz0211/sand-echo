extends Node
# 固定分辨率截图回归：把关键界面渲染到 1920×1080 SubViewport，
# 落盘到 docs/screenshots/ 作为视觉基线。
#
# 为什么不用真实窗口：窗口尺寸 / DPI / 焦点都会让像素不可比，
# SubViewport 固定 1920×1080 才能做逐次 diff。
#
# 取代旧的 tests/screenshot.gd —— 那份仍在驱动房间制地牢
# （game.dungeon / current_room_id / 沿门走到 Boss 房），
# 单屏竞技场重写后已整段失效（详见 docs/verification.md 的失效说明）。
#
# 运行：Godot_v4.6.2-stable_win64_console.exe --path . \
#         --resolution 1920x1080 res://tests/screenshot.tscn -- --shot-dir="<目录>/"

const VIEW_W := 1920
const VIEW_H := 1080
const OUT_DEFAULT := "res://docs/screenshots/"

var _sub: SubViewport
var _out := OUT_DEFAULT


func _ready() -> void:
	_out = _parse_out_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out))

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_sub = SubViewport.new()
	_sub.size = Vector2i(VIEW_W, VIEW_H)
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub.transparent_bg = false
	add_child(_sub)
	var holder := Node.new()
	_sub.add_child(holder)
	await get_tree().process_frame

	# 1) 主菜单：标题、元进度、角色选择、按钮、署名
	await _shot_main_menu(holder)

	# 2) 第 1 波开打：竞技场 + HUD + 刷怪
	await _shot_wave(holder, 1)

	# 3) 三选一
	await _shot_upgrade(holder)

	# 4) 商店
	await _shot_shop(holder)

	# 5) 暂停层
	await _shot_pause(holder)

	# 6) 死亡结算
	await _shot_death(holder)

	print("截图完成，输出目录：%s" % ProjectSettings.globalize_path(_out))
	get_tree().quit(0)


func _parse_out_dir() -> String:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		if args[i].begins_with("--shot-dir="):
			return args[i].substr(11)
		i += 1
	return OUT_DEFAULT


func _shot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := _sub.get_texture().get_image()
	if img == null:
		print("  [失败] %s 取不到画面" % tag)
		return
	img.save_png("%s%s.png" % [_out, tag])
	print("  截图 %s.png" % tag)


## 主菜单：加载真实主场景，拍完就换掉
func _shot_main_menu(holder: Node) -> void:
	holder.add_child((load("res://scenes/main_menu.tscn") as PackedScene).instantiate())
	for i in 20:
		await get_tree().process_frame
	await _shot("shot_1_main_menu")
	holder.get_child(0).queue_free()
	await get_tree().process_frame


## 战斗：建 game.tscn，等敌人刷出来
func _shot_wave(holder: Node, wave: int) -> void:
	var game := (load("res://scenes/game.tscn") as PackedScene).instantiate() as Node2D
	holder.add_child(game)
	var cam := game.get_node_or_null("Camera2D") as Camera2D
	if cam != null:
		cam.make_current()
	# 玩家血量拉满，避免等不到第 2 波就死
	RunState.max_health = 99999
	RunState.health = 99999
	for i in 40:
		await get_tree().process_frame
	var alive := 0
	for e in (game.get("enemies") as Array):
		if is_instance_valid(e):
			alive += 1
	print("  第 %d 波同屏敌人 %d 只" % [wave, alive])
	await _shot("shot_2_wave%d_combat" % wave)
	game.queue_free()
	await get_tree().process_frame


## 三选一：清掉场上敌人，让 game 推进到波间面板
func _shot_upgrade(holder: Node) -> void:
	var game := (load("res://scenes/game.tscn") as PackedScene).instantiate() as Node2D
	holder.add_child(game)
	var cam := game.get_node_or_null("Camera2D") as Camera2D
	if cam != null:
		cam.make_current()
	RunState.max_health = 99999
	RunState.health = 99999
	await _clear_wave(game)
	for i in 20:
		await get_tree().process_frame
	var layer := game.get_node_or_null("UpgradeLayer") as CanvasLayer
	print("  三选一可见=%s" % (layer != null and layer.visible))
	await _shot("shot_3_upgrade")
	game.queue_free()
	await get_tree().process_frame


## 商店：三选一之后紧接商店
func _shot_shop(holder: Node) -> void:
	var game := (load("res://scenes/game.tscn") as PackedScene).instantiate() as Node2D
	holder.add_child(game)
	var cam := game.get_node_or_null("Camera2D") as Camera2D
	if cam != null:
		cam.make_current()
	RunState.max_health = 99999
	RunState.health = 99999
	await _clear_wave(game)
	for i in 30:
		await get_tree().process_frame
	# 若卡在三选一，按流程选一张
	var up := game.get_node_or_null("UpgradeLayer")
	if up != null and up.visible:
		up.call("_on_card_pressed", 0)
	for i in 30:
		await get_tree().process_frame
	var shop := game.get_node_or_null("ShopLayer") as CanvasLayer
	print("  商店可见=%s" % (shop != null and shop.visible))
	await _shot("shot_4_shop")
	game.queue_free()
	await get_tree().process_frame


## 暂停层
func _shot_pause(holder: Node) -> void:
	var game := (load("res://scenes/game.tscn") as PackedScene).instantiate() as Node2D
	holder.add_child(game)
	var cam := game.get_node_or_null("Camera2D") as Camera2D
	if cam != null:
		cam.make_current()
	RunState.max_health = 99999
	RunState.health = 99999
	for i in 40:
		await get_tree().process_frame
	var pause := game.get_node_or_null("PauseMenu") as CanvasLayer
	if pause != null:
		pause.call("toggle")
	for i in 10:
		await get_tree().process_frame
	print("  暂停可见=%s" % (pause != null and pause.visible))
	await _shot("shot_5_pause")
	if pause != null:
		pause.call("toggle")
	game.queue_free()
	await get_tree().process_frame


## 死亡结算
func _shot_death(holder: Node) -> void:
	var game := (load("res://scenes/game.tscn") as PackedScene).instantiate() as Node2D
	holder.add_child(game)
	var cam := game.get_node_or_null("Camera2D") as Camera2D
	if cam != null:
		cam.make_current()
	RunState.health = 99999
	RunState.max_health = 99999
	for i in 40:
		await get_tree().process_frame
	RunState.take_damage(999999)
	for i in 30:
		await get_tree().process_frame
	var death := game.get_node_or_null("DeathScreen") as CanvasLayer
	print("  死亡结算可见=%s" % (death != null and death.visible))
	await _shot("shot_6_death")
	game.queue_free()
	await get_tree().process_frame


## 清掉全部敌人，让波次循环推进到波间阶段。
## 必须排空刷怪队列才算完 —— 固定轮数会在队列还有剩时中途停下，
## 于是 wave_active 仍为 true，永远等不到三选一面板（这正是首版
## 「三选一可见=false」的原因）。同 wave_smoke.gd 的 _clear_wave。
func _clear_wave(game: Node) -> void:
	var guard := 0
	while guard < 3000:
		guard += 1
		for e in (game.get("enemies") as Array).duplicate():
			if is_instance_valid(e):
				e.take_damage(999999)
		for i in 4:
			await get_tree().process_frame
		if not bool(game.get("wave_active")):
			break
	await get_tree().process_frame