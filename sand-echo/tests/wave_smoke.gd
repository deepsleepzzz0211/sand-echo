extends Node
# 波次循环的冒烟 + 视觉验证（取代旧的地牢冒烟，见 tests/legacy_smoke_dungeon.txt）。
# 验的是「Brotato 式循环真的能跑起来」：
#   竞技场建出来了没有 → 摄像机有没有放大 → 刷怪 → 清波 → 三选一 → 商店 → 下一波
# 运行：Godot_v4.6.2-stable_win64_console.exe --path . --resolution 1920x1080 res://tests/wave_smoke.tscn

const VIEW_W := 1920
const VIEW_H := 1080
const GAME_SCENE := "res://scenes/game.tscn"

var _sub: SubViewport
var _game: Node2D
var _fail := 0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_sub = SubViewport.new()
	_sub.size = Vector2i(VIEW_W, VIEW_H)
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_sub.transparent_bg = false
	add_child(_sub)
	var holder := Node.new()
	_sub.add_child(holder)
	await get_tree().process_frame

	_game = (load(GAME_SCENE) as PackedScene).instantiate() as Node2D
	holder.add_child(_game)
	var cam := _game.get_node_or_null("Camera2D") as Camera2D
	if cam != null:
		cam.make_current()
	for i in 30:
		await get_tree().process_frame

	await _check_arena()
	await _check_camera()
	await _check_spawning()
	await _shot("01_第1波开打")
	await _clear_wave()
	await _shot("02_三选一")
	await _pick_upgrade()
	await _shot("03_商店")
	await _close_shop()
	await _shot("04_第2波")
	await _check_death()
	_report()


## 死亡结算：玩家死亡后必须弹出结算画面（重写 game.gd 时这条链路曾整段丢失）
func _check_death() -> void:
	var hp_before := RunState.health
	RunState.take_damage(999999)
	for i in 30:
		await get_tree().process_frame
	var death := _game.get_node_or_null("DeathScreen")
	_ok(RunState.health == 0, "玩家血量归零（%d → %d）" % [hp_before, RunState.health])
	_ok(bool(_game.get("run_over")), "本局标记为已结束")
	_ok(death != null, "场景里有 DeathScreen 节点")
	if death != null:
		var root := death.get_node_or_null("Root") as Control
		_ok(root != null and root.visible, "死亡结算画面已显示（此前的 bug：节点在但不显示）")
		var stats := death.get_node_or_null("Root/Panel/VBox/Stats") as Label
		_ok(stats != null and not stats.text.is_empty(), "结算统计已填内容：%s" % (stats.text.replace("\n", " / ") if stats != null else "<无>"))


func _check_arena() -> void:
	_ok(_game.get("arena") is Arena, "竞技场已生成（不再是房间地牢）")
	var a := _game.get("arena") as Arena
	if a != null:
		var floor_layer := a.get_node_or_null("FloorLayer") as TileMapLayer
		var cells := floor_layer.get_used_cells().size() if floor_layer != null else 0
		_ok(cells > 0, "地面已铺设（%d 格）" % cells)
		_ok(a.get_child_count() >= 4, "竞技场包含 4 个图层")
		_ok(a.get_node_or_null("WallBody") != null, "墙体碰撞体存在")
	# 竞技场尺寸必须与摄像机可视范围匹配，否则会露出场外
	if a != null:
		var s := a.size_px()
		print("    竞技场尺寸 %.0f×%.0f px（zoom 2.0 → 可视 960×540）" % [s.x, s.y])
		_ok(s.x <= 960.0 and s.y <= 540.0, "竞技场完整落在可视范围内（否则露出场外）")


func _check_camera() -> void:
	var cam := _game.get_node_or_null("Camera2D") as Camera2D
	_ok(cam != null and cam.zoom.x >= 1.9, "摄像机已放大到 %.1f 倍（角色 24px→%.0fpx）" % [
		cam.zoom.x if cam != null else 0.0, 24.0 * (cam.zoom.x if cam != null else 1.0)])


func _check_spawning() -> void:
	var game := _game
	_ok(int(game.get("enemies_alive")) > 0, "第 1 波已刷出敌人（%d 只）" % int(game.get("enemies_alive")))
	var e0: Enemy = (game.get("enemies") as Array)[0] if (game.get("enemies") as Array).size() > 0 else null
	if e0 != null:
		var bar := e0.get_node_or_null("HpBar")
		_ok(bar != null, "敌人头顶有血条节点")
	# 敌人数量：第 1 波应至少有 8 只（此前 budget 3 / cost=hp/4 只刷得出 1 只）
	# 按墙钟等：不限帧率时帧数与时间不成比例，用帧数会误判成「刷不出怪」
	var deadline := Time.get_ticks_msec() + 4000
	while int(_game.get("enemies_alive")) < 8 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_ok(int(_game.get("enemies_alive")) >= 8, "第 1 波敌人数量充足（%d 只）" % int(_game.get("enemies_alive")))
	_ok(_game.get("_spawn_queue").size() > 0, "第 1 波有后续刷怪队列（剩 %d 只待出）" % _game.get("_spawn_queue").size())
	# 怪物必须有碰撞体与受击组，否则玩家打不到、也打不死
	var groups := get_tree().get_nodes_in_group("enemy_hurtbox").size()
	_ok(groups > 0, "敌人受击区已注册（%d 个）" % groups)


## 必须循环清到 wave_active 为假：只杀一轮不够，
## 刷怪队列（_spawn_queue）会继续按节奏补怪，波次不会结束，面板也就不会弹。
func _clear_wave() -> void:
	# 敌人数量调高后，刷怪队列要排空才算完；固定轮数会在中途误判。
	var guard := 0
	while guard < 3000:
		guard += 1
		for e in (_game.get("enemies") as Array).duplicate():
			if is_instance_valid(e):
				e.take_damage(999999)
		for i in 4:
			await get_tree().process_frame
		if not bool(_game.get("wave_active")):
			break
	await get_tree().process_frame


func _pick_upgrade() -> void:
	var layer := _game.get_node_or_null("UpgradeLayer")
	# 必须断言 visible：CanvasLayer 的 visible=false 会连带隐藏所有子节点，
	# 上一版只查子节点数量，面板整个不可见也判了通过。
	_ok(layer != null and layer.visible, "清波后三选一面板可见")
	var scr := layer if layer != null else null
	if scr != null:
		_ok(RunState.upgrade_pool().size() > 0, "升级池非空（%d 项可选）" % RunState.upgrade_pool().size())
		var cards := scr.find_children("*", "Button", true, false)
		_ok(cards.size() == 3, "三选一给出 3 张卡（实际 %d）" % cards.size())
		# 直接调处理器，与真实点击同一条路径；find_children 的顺序不保证是 Card0
		var before := RunState.upgrades.size()
		scr.call("_on_card_pressed", 0)
		for i in 10:
			await get_tree().process_frame
		_ok(RunState.upgrades.size() == before + 1, "选卡后升级生效（%d → %d）" % [before, RunState.upgrades.size()])


func _close_shop() -> void:
	var layer := _game.get_node_or_null("ShopLayer")
	_ok(layer != null and layer.visible, "三选一后商店面板可见")
	var shop := layer if layer != null else null
	if shop != null:
		# 给钱再买，验证花钱变强真的生效
		RunState.add_gold(500)
		for i in 5:
			await get_tree().process_frame
		var gold0 := RunState.gold
		var w0 := RunState.weapons.size()
		var up0 := RunState.upgrades.size()
		var bought := false
		for i in 4:
			shop.call("_on_slot_pressed", i)
			await get_tree().process_frame
			if RunState.weapons.size() > w0 or RunState.upgrades.size() > up0 or RunState.gold < gold0:
				bought = true
				break
		_ok(bought, "商店可购买（金币 %d → %d）" % [gold0, RunState.gold])
		_ok(RunState.weapons.size() >= 1, "武器数 %d" % RunState.weapons.size())
		# 关闭商店进入下一波
		shop.call("_on_continue")
	for i in 30:
		await get_tree().process_frame


func _shot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := _sub.get_texture().get_image()
	if img != null:
		img.save_png("user://wave_%s.png" % tag)
		print("  截图：wave_%s.png" % tag)


func _ok(cond: bool, label: String) -> void:
	if cond:
		print("  [通过] %s" % label)
	else:
		_fail += 1
		print("  [失败] %s" % label)


func _report() -> void:
	print("")
	print("波次循环诊断：%s" % ("全部通过" if _fail == 0 else "%d 项失败" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)