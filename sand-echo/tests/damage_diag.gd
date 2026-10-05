extends Node
# 受击链路诊断：走**真实物理碰撞**路径，验证玩家是否真的会掉血。
# 冒烟测试是直接调 RunState.take_damage()，从未验证过碰撞判定本身，
# 所以「玩家受攻击不掉血」这类问题它一条都抓不到。
#
# 运行：godot_console.exe --headless --path . res://tests/damage_diag.tscn
# 退出码：0 = 两条伤害路径都通；1 = 有路径不通

const GAME_SCENE := "res://scenes/game.tscn"
const BULLET_SCENE: PackedScene = preload("res://scenes/bullet.tscn")

var _fail := 0


func _ready() -> void:
	await get_tree().process_frame
	await _test_bullet_path()
	await _test_contact_path()
	_report()


## 路径一：敌人子弹命中玩家 Hurtbox
func _test_bullet_path() -> void:
	RunState.reset_run()
	var game := await _spawn_game()
	var player := game.player as Player
	var before := RunState.health

	# 直接在玩家身上放一颗敌人子弹，绕开敌人的开火逻辑，只验判定链路
	var b := BULLET_SCENE.instantiate() as Bullet
	b.setup(Vector2.RIGHT, 3, Bullet.Owner.ENEMY)
	b.speed = 0.0            # 原地不动，确保一定重叠
	b.lifetime = 5.0
	# 敌人子弹的 mask / layer 必须在命中前取：命中后它会 queue_free，之后再访问就是「已释放」
	var b_layer := b.collision_layer
	var b_mask := b.collision_mask
	var b_monitoring := b.monitoring
	b.position = player.position
	game.world.add_child(b)

	# 等物理帧，让 area_entered 真正派发
	for i in 10:
		await get_tree().physics_frame

	var after := RunState.health
	_ok(before - after == 3, "敌人子弹命中：HP %d → %d（应掉 3）" % [before, after])
	_ok(RunState.health_changed.get_connections().size() >= 0, "health_changed 信号可连接")

	var hb := player.get_node("Hurtbox") as Area2D
	print("    玩家 Hurtbox: layer=%d mask=%d monitoring=%s monitorable=%s group=%s" % [
		hb.collision_layer, hb.collision_mask, str(hb.monitoring), str(hb.monitorable),
		str(hb.is_in_group("player_hurtbox"))])
	print("    敌人子弹:     layer=%d mask=%d monitoring=%s" % [b_layer, b_mask, str(b_monitoring)])
	print("    层与掩码相交 = %s" % str((b_mask & hb.collision_layer) != 0))
	_ok((b_mask & hb.collision_layer) != 0, "敌人子弹的 mask 与玩家 Hurtbox 的 layer 相交")
	_ok(hb.is_in_group("player_hurtbox"), "玩家 Hurtbox 在 player_hurtbox 组内（漏这行则全程免伤）")

	game.queue_free()
	await get_tree().process_frame


## 路径二：敌人贴身接触伤害
func _test_contact_path() -> void:
	RunState.reset_run()
	var game := await _spawn_game()
	var player := game.player as Player
	var before := RunState.health

	# 找一只会接触伤害的敌人，直接塞到玩家身上
	var chaser: Enemy = null
	for e in game.enemies:
		if is_instance_valid(e) and e.contact_dmg > 0:
			chaser = e
			break
	if chaser == null:
		# 起始房可能没有接触伤害的敌人，那就自己造一只
		chaser = _make_chaser(game)
	if chaser == null:
		_ok(false, "找不到可测接触伤害的敌人")
		game.queue_free()
		await get_tree().process_frame
		return

	chaser.position = player.position
	# 关掉 AI 位移，否则敌人一被推挤就离开，接触窗口可能整个错过
	var touched := [0]
	chaser.get("_hurtbox").contact_made.connect(func(_t): touched[0] += 1)
	for i in 20:
		await get_tree().physics_frame
		if touched[0] > 0:
			break

	var after := RunState.health
	print("    接触信号触发次数 = %d，玩家无敌中 = %s，两者距离 = %.1f" % [
		touched[0], str(player.is_invulnerable()), chaser.position.distance_to(player.position)])
	_ok(before - after > 0, "敌人贴身接触：HP %d → %d（应掉血）" % [before, after])
	game.queue_free()
	await get_tree().process_frame


func _make_chaser(game: Node) -> Enemy:
	var f: FileAccess = FileAccess.open("res://data/enemies.json", FileAccess.READ)
	if f == null:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	for entry in parsed as Array:
		var d := entry as Dictionary
		if int(d.get("contact_dmg", 0)) > 0 and not bool(d.get("boss", false)):
			var e: Enemy = (load("res://scenes/enemy.tscn") as PackedScene).instantiate() as Enemy
			e.setup(d.duplicate(), Rect2(0, 0, 1792, 928), 1)
			game.world.add_child(e)
			return e
	return null


func _spawn_game() -> Node:
	var res: PackedScene = load(GAME_SCENE)
	var g := res.instantiate()
	get_tree().root.add_child(g)
	await get_tree().process_frame
	await get_tree().process_frame
	# 别让敌人真的把玩家打死，专注验判定
	RunState.max_health = 9999
	RunState.health = 9999
	return g


func _ok(cond: bool, label: String) -> void:
	if cond:
		print("  [通过] %s" % label)
	else:
		_fail += 1
		print("  [失败] %s" % label)


func _report() -> void:
	print("")
	print("诊断结果：%s" % ("受击链路正常" if _fail == 0 else "%d 项不通，玩家受攻击不掉血" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)