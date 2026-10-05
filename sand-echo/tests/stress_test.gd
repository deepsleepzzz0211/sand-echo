extends Node
# @trace PLAT-003
# 性能压测（窗口化运行，关闭垂直同步后采原始墙钟帧间隔）。
# 口径对应策划案第 4 章 / 冻结条目 PLAT-003：目标 60fps，同屏 ≤40 单位、弹幕 ≤300 发。
# 运行：godot.exe --path . res://tests/stress_test.tscn
# 退出码：0 = 达标；1 = 未达标；2 = 参数错误。报告打到 stdout 并写 user://stress_report.json。

const GAME_SCENE := "res://scenes/game.tscn"
const BULLET_SCENE: PackedScene = preload("res://scenes/bullet.tscn")
const ENEMY_SCENE: PackedScene = preload("res://scenes/enemy.tscn")

## 压测参数（可用命令行覆盖）
var _target_units := 40        ## 同屏单位数上限（策划案 PLAT-003）
var _target_bullets := 300    ## 同屏弹幕数上限（策划案 PLAT-003）
var _warmup_frames := 90      ## 预热帧：着色器编译 / 资源首次光栅化，不计入
var _measure_frames := 600    ## 正式采样帧数（60fps 下约 10 秒）
var _duration_cap := 45.0     ## 兜底：无论帧率多低，最多跑这么久

## 运行期状态
var _game: Node2D = null
var _arena: Rect2 = Rect2()
var _bullets: Array[Bullet] = []
var _enemies: Array[Enemy] = []
var _samples: Array[float] = []      ## 毫秒
var _frames := 0
var _warmup_left := 0
var _last_usec := 0
var _rng := RandomNumberGenerator.new()
var _peak_bullets := 0
var _total_bullets := 0   ## 含敌人自己开的火：压测只维护玩家弹幕，敌人弹幕是额外负载，必须单独报
var _started := false      ## _build_scene 完成前不采样（否则会把空场景的帧算进去）
## A/B 用：关掉敌人之间的本体碰撞（只留与墙），用来区分「物理求解器」与「_apply_separation 的 O(n²)」
var _ab_no_enemy_collide := false
## 物理步耗时必须在采样窗口内累计：报告时刻的瞬时值会被截图/退出等一次性卡顿污染
var _physics_ms := 0.0
var _reported := false    ## get_tree().quit() 不会立刻停掉 _process，必须自己上锁，否则会重复出报告


func _ready() -> void:
	_parse_args()
	_rng.randomize()
	# 关键：关掉垂直同步并解除帧率上限，否则测出来永远是 16.67ms
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	print("=== 沙之回响 · 性能压测 ===")
	print("目标：%d 单位 + %d 弹幕，预热 %d 帧，采样 %d 帧" % [_target_units, _target_bullets, _warmup_frames, _measure_frames])
	await get_tree().process_frame
	_build_scene()


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var parts := arg.split("=")
		if parts.size() != 2:
			continue
		match parts[0]:
			"--units":
				_target_units = int(parts[1])
			"--bullets":
				_target_bullets = int(parts[1])
			"--frames":
				_measure_frames = int(parts[1])
			"--warmup":
				_warmup_frames = int(parts[1])
			"--no-enemy-collide":
				_ab_no_enemy_collide = true


# --- 搭建负载 ---------------------------------------------------------------

func _build_scene() -> void:
	var game_res: PackedScene = load(GAME_SCENE)
	_game = game_res.instantiate() as Node2D
	get_tree().root.add_child(_game)
	await get_tree().process_frame
	await get_tree().process_frame
	# game.gd 的成员是 arena（不是旧房间制的 room）。这里必须硬失败：
	# 之前写成 _game.get("room") 得到 null，紧接着调 interior_rect() 报错中断，
	# 但脚本仍以退出码 0 结束 —— 一个「什么都没测却显示通过」的假绿，
	# 比红结果更危险（PLAT-003 的性能结论就靠这个脚本产）。
	var arena_node: Arena = _game.get("arena") as Arena
	if arena_node == null:
		push_error("压测：Game 上取不到 arena（成员名是否又改了？），负载没搭起来")
		get_tree().quit(2)
		return
	_arena = arena_node.interior_rect()
	# 压测期间玩家不掉血，否则场景会被死亡结算接管，负载就变了
	RunState.max_health = 99999
	RunState.health = 99999
	# 清掉游戏自己按房间规则刷的敌人，改成受控的定额负载
	for e in _game.get("enemies") as Array:
		if is_instance_valid(e):
			e.queue_free()
	(_game.get("enemies") as Array).clear()
	_spawn_units()
	print("已生成 %d 个单位（含玩家），区域 %s" % [_enemies.size() + 1, str(_arena.size)])
	_warmup_left = _warmup_frames
	_last_usec = Time.get_ticks_usec()
	_started = true


func _spawn_units() -> void:
	var stats: Array = _read_json("res://data/enemies.json")
	var pool: Array = []
	for entry in stats:
		var d := entry as Dictionary
		if not bool(d.get("boss", false)):
			pool.append(d)
	if pool.is_empty():
		push_error("压测：没有可用敌人数据")
		return
	for i in _target_units:
		var def: Dictionary = (pool[i % pool.size()] as Dictionary).duplicate()
		# 压力场景统一按一层强度，避免血量差异影响行为
		def["hp"] = 100000
		def["boss"] = false
		var e := ENEMY_SCENE.instantiate() as Enemy
		e.setup(def, _arena, _rng.randi())
		e.position = Vector2(
			_rng.randf_range(_arena.position.x + 32.0, _arena.end.x - 32.0),
			_rng.randf_range(_arena.position.y + 32.0, _arena.end.y - 32.0)
		)
		_game.get("world").add_child(e)
		if _ab_no_enemy_collide:
			# 只保留与墙的碰撞，去掉敌人之间的本体接触，用于定位瓶颈归属
			e.collision_mask = 1
		_enemies.append(e)


# --- 主循环：维持弹幕数量 -----------------------------------------------------

func _process(_delta: float) -> void:
	if not _started:
		return
	var now := Time.get_ticks_usec()
	if _last_usec > 0:
		var dt_ms := float(now - _last_usec) / 1000.0
		if _warmup_left > 0:
			_warmup_left -= 1
		else:
			_samples.append(dt_ms)
			_frames += 1
			# 只取物理步：同一构建下 TIME_PROCESS 会报出大于帧时间的值（实测 77ms vs 1.84ms），不可用
			_physics_ms += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_last_usec = now
	_keep_bullets()
	# 敌人自己也会开火，这部分不在 _bullets 里，逐帧记下峰值一并报出来
	_total_bullets = maxi(_total_bullets, get_tree().get_nodes_in_group("bullet").size())
	if _frames >= _measure_frames or float(now) / 1e9 > _duration_cap:
		if _reported:
			return
		_reported = true
		await _take_shot()   # 截图放在采样窗口之外：save_png 会阻塞近 100ms，放进来会污染尾延迟
		_report()


func _keep_bullets() -> void:
	var world := _game.get("world") as Node2D
	# 回收出界/超龄的，避免数量只增不减导致曲线失真
	var i := _bullets.size() - 1
	while i >= 0:
		var b := _bullets[i]
		if not is_instance_valid(b) or not _arena.grow(-48.0).abs().has_point(b.position):
			if is_instance_valid(b):
				b.queue_free()
			_bullets.remove_at(i)
		i -= 1
	_bullets = _bullets.filter(func(b: Bullet) -> bool: return is_instance_valid(b)) as Array[Bullet]
	if _bullets.size() >= _target_bullets:
		return
	var need := _target_bullets - _bullets.size()
	for n in need:
		_spawn_bullet(world)


func _spawn_bullet(world: Node2D) -> void:
	var b := BULLET_SCENE.instantiate() as Bullet
	var dir := Vector2.RIGHT.rotated(_rng.randf() * TAU)
	b.setup(dir, 1, Bullet.Owner.PLAYER, 0)
	b.speed = RunState.BULLET_SPEED
	b.lifetime = 3.0
	b.position = Vector2(
		_rng.randf_range(_arena.position.x + 16.0, _arena.end.x - 16.0),
		_rng.randf_range(_arena.position.y + 16.0, _arena.end.y - 16.0)
	)
	b.set_bounds(_arena)
	world.add_child(b)
	_bullets.append(b)
	if _bullets.size() > _peak_bullets:
		_peak_bullets = _bullets.size()


func _take_shot() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img != null:
		var path := "user://stress_shot.png"
		if img.save_png(path) == OK:
			print("压测截图：%s" % ProjectSettings.globalize_path(path))


# --- 报告 -------------------------------------------------------------------

func _report() -> void:
	_samples.sort()
	var n := _samples.size()
	if n == 0:
		push_error("压测：没有采到样本")
		get_tree().quit(2)
		return
	var sum := 0.0
	var worst := 0.0
	for v in _samples:
		sum += v
		worst = maxf(worst, v)
	var avg := sum / float(n)
	var p50 := _pct(0.50)
	var p95 := _pct(0.95)
	var p99 := _pct(0.99)
	var p999 := _pct(0.999)
	var fps_avg := 1000.0 / avg
	var fps_p99 := 1000.0 / p99
	var budget := 1000.0 / 60.0

	# 掉帧统计：超过 16.67ms 预算的帧占比
	var over := 0
	for v in _samples:
		if v > budget:
			over += 1

	var report := {
		"units": _target_units,
		"bullets_target": _target_bullets,
		"bullets_peak": _peak_bullets,
		"bullets_peak_total_incl_enemy": _total_bullets,
		"frames_sampled": n,
		"frame_ms": {
			"avg": snappedf(avg, 0.001),
			"p50": snappedf(p50, 0.001),
			"p95": snappedf(p95, 0.001),
			"p99": snappedf(p99, 0.001),
			"p999": snappedf(p999, 0.001),
			"max": snappedf(worst, 0.001),
		},
		"fps": {
			"avg": snappedf(fps_avg, 0.01),
			"p99_worst": snappedf(fps_p99, 0.01),
		},
		"budget_ms_60fps": snappedf(budget, 0.001),
		"frames_over_budget_pct": snappedf(100.0 * float(over) / float(n), 0.01),
		"cpu_avg_ms": {
			"physics_step": snappedf(_physics_ms / float(n), 0.001),
			"physics_single_core_pct": snappedf(100.0 * (_physics_ms / float(n)) * 60.0 / 1000.0, 0.01),
		},
		"godot": _perf_snapshot(),
	}

	print("")
	print("---------------- 压测结果 ----------------")
	print("负载            : %d 单位 + 玩家弹幕 %d 发 | 全场弹幕峰值 %d 发（含敌人开火）" % [
		_target_units, _peak_bullets, _total_bullets])
	print("采样帧数        : %d 帧（预热 %d 帧已排除）" % [n, _warmup_frames])
	print("")
	print("帧时间          avg %.2f ms | p50 %.2f | p95 %.2f | p99 %.2f | p99.9 %.2f | max %.2f" % [avg, p50, p95, p99, p999, worst])
	print("换算 FPS        avg %.1f | p99 最差 %.1f" % [fps_avg, fps_p99])
	print("60fps 预算      %.2f ms　超预算帧占比 %.2f%%" % [budget, 100.0 * float(over) / float(n)])
	print("")
	var g := _perf_snapshot()
	print("Godot 监视器    绘制调用 %d | 可见对象 %d | 节点数 %d" % [
		int(g["draw_calls"]), int(g["visible_objects"]), int(g["nodes"])])
	print("显存            %.1f MB | 静态内存 %.1f MB | 资源数 %d" % [
		float(g["video_mem_mb"]), float(g["static_mem_mb"]), int(g["resources"])])
	print("物理步          %.2f ms/次 × 60 次/秒 = 单核占用 %.0f%%" % [
		_physics_ms / float(n), 100.0 * (_physics_ms / float(n)) * 60.0 / 1000.0])
	print("-----------------------------------------")

	var ok := fps_p99 >= 55.0 and 100.0 * float(over) / float(n) <= 1.0
	var verdict := "达标" if ok else "未达标"
	print("结论：%s（判据：p99 ≥ 55fps 且超预算帧 ≤ 1%%）" % verdict)

	var f := FileAccess.open("user://stress_report.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  "))
		f.close()
	get_tree().quit(0 if ok else 1)


func _pct(q: float) -> float:
	var idx := int(ceil(q * float(_samples.size()))) - 1
	return _samples[clampi(idx, 0, _samples.size() - 1)]


func _perf_snapshot() -> Dictionary:
	return {
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"visible_objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"static_mem_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
	}


func _read_json(path: String) -> Array:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed as Array if parsed is Array else []