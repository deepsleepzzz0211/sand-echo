extends Node
# 整局运行时内存峰值实测。对应策划案第 4 章「内存峰值 ≤512MB」与待实测项「运行时内存峰值」。
#
# 与压测的关键区别：这里跑的是**真实场景切换**（主菜单 → 对局 → 死亡结算 → 主菜单 → 第二局），
# 因为要回答的不只是「一帧最多占多少」，还有「反复开局会不会涨」——即泄漏。
#
# 运行（必须窗口化，headless 没有渲染，显存与字体缓存恒为 0）：
#   Godot_v4.6.2-stable_win64_console.exe --path . --resolution 1920x1080 res://tests/memory_test.tscn
# 退出码：0 = 跑完全流程；1 = 流程中断；2 = 没采到样本
#
# 口径说明：
#  - MEMORY_STATIC 是 Godot 追踪的静态内存当前值；MEMORY_STATIC_MAX 是引擎启动以来的高水位，
#    它不会回落，所以「整局峰值」直接取它最可信。
#  - RENDER_VIDEO_MEM_USED 是显存（含纹理/缓冲），headless 下恒为 0，别拿它当结论。
#  - 操作系统实际驻留（RSS）由外部 PowerShell 采样进程工作集补充，引擎内部监视器看不到这块。

const GAME_SCENE := "res://scenes/game.tscn"
const MENU_SCENE := "res://scenes/main_menu.tscn"

## 每个阶段名 -> 该阶段各指标的峰值
var _phase_peak: Dictionary = {}
var _phase_order: Array[String] = []
var _current_phase := ""
var _sample_count := 0
var _reported := false

## 阶段切换时留档的静态内存当前值，用来判断「切场景后有没有回落」
var _phase_marks: Array[Dictionary] = []


## 当前挂着的对局/菜单场景。由本测试自己装卸，生命周期可控。
## 不能用 change_scene_to_file：主场景就是本测试节点，换场景会把它一起释放掉。
var _live: Node = null


func _goto(scene_path: String) -> Node:
	if _live != null and is_instance_valid(_live):
		_live.queue_free()
		_live = null
		# 多等几帧让 free 真正落地，否则读数是「释放中」而不是「释放后」
		await _settle(3)
	var res: PackedScene = load(scene_path)
	_live = res.instantiate()
	get_tree().root.add_child(_live)
	await _settle(2)
	await _settle(2)
	return _live


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	print("=== 沙之回响 · 整局内存峰值实测 ===")
	print("监控项：MEMORY_STATIC / MEMORY_STATIC_MAX / 显存 / 对象数 / 2D 物理规模")
	# root 还在装配子节点，此刻 add_child 会被拒；先让出一帧再装场景
	await get_tree().process_frame
	await _goto(MENU_SCENE)
	await _run_session()


func _process(_delta: float) -> void:
	if _current_phase != "":
		_sample()


# --- 采样 -------------------------------------------------------------------

## 取当前所有监控项；只保留引擎侧能看到的，OS 驻留由外部补
func _read_metrics() -> Dictionary:
	return {
		"static_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"static_max_mb": Performance.get_monitor(Performance.MEMORY_STATIC_MAX) / 1048576.0,
		"video_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		"texture_mb": Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		"buffer_mb": Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0,
		"objects": float(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"nodes": float(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"phys_active": float(Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS)),
		"phys_pairs": float(Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)),
		"phys_islands": float(Performance.get_monitor(Performance.PHYSICS_2D_ISLAND_COUNT)),
	}


func _sample() -> void:
	_sample_count += 1
	var m := _read_metrics()
	if not _phase_peak.has(_current_phase):
		_phase_peak[_current_phase] = m.duplicate()
		return
	var peak: Dictionary = _phase_peak[_current_phase]
	for k in m.keys():
		peak[k] = maxf(peak[k], float(m[k]))


func _phase(name: String) -> void:
	_current_phase = name
	if not _phase_peak.has(name):
		_phase_order.append(name)
		_phase_peak[name] = _read_metrics()


## 阶段结束留档：记录此刻的静态内存当前值（区别于高水位）
func _mark(label: String) -> void:
	_phase_marks.append({
		"label": label,
		"static_mb": Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
		"static_max_mb": Performance.get_monitor(Performance.MEMORY_STATIC_MAX) / 1048576.0,
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
	})


# --- 完整会话流程 -----------------------------------------------------------

## 每局都推进到第 4 层。三局不是为了「多测点」，而是为了区分两件长得一样的事：
## 一次性资源缓存（第一局加载过、之后常驻不再涨）与真正的泄漏（每局都涨一点）。
## 两局看不出区别，必须有第三局做对照。
const RUNS := 3
const DEPTH := 3


func _run_session() -> void:
	# 阶段 1：主菜单启动基线（此时只有菜单 UI 与字体缓存）
	_phase("01_主菜单")
	await _settle(30)
	_mark("主菜单稳定后")

	for run_index in range(1, RUNS + 1):
		await _play_run(run_index, DEPTH)
		_mark("第 %d 局结束（第 %d 层）" % [run_index, DEPTH + 1])
		if run_index < RUNS:
			# 回主菜单再开局：走真实的销毁 + 重建，才看得出释放是否干净
			_phase("%02d_回主菜单" % [run_index + 1])
			await _goto(MENU_SCENE)
			await _settle(45)
			_mark("第 %d 局后回到主菜单" % run_index)

	_report()


## 跑完 n 层。逐房清怪推进，制造真实的房间构建 / 敌人 / 弹幕 / 遗物负载。
func _play_run(run_index: int, floors: int) -> void:
	_phase("R%d_开局" % run_index)
	await _goto(GAME_SCENE)
	var game := _live
	if game == null or not game.has_method("next_floor"):
		push_error("内存实测：第 %d 局没能进入 game.tscn" % run_index)
		return

	for f in floors:
		var guard := 0
		while game != null and is_instance_valid(game) and not game.run_over and guard < 80:
			guard += 1
			if game.dungeon == null or game.current_room_id == game.dungeon.boss_id:
				break
			# 每进一间房先承受一小段真实战斗帧（敌人开火、玩家射击）再清场
			if not game.enemies.is_empty():
				await _settle(4)
				for e in game.enemies.duplicate():
					if is_instance_valid(e):
						e.take_damage(999999)
			await _settle(2)
			var dir := _step_toward_boss(game.dungeon, game.current_room_id, game.dungeon.boss_id)
			if dir < 0:
				break
			game._on_door_entered(dir)
			await _settle(2)
		if game == null or not is_instance_valid(game):
			break
		# Boss 房：打掉 Boss
		await _settle(4)
		for e in game.enemies.duplicate():
			if is_instance_valid(e):
				e.take_damage(999999)
		await _settle(6)
		if game == null or not is_instance_valid(game) or game.run_over:
			break
		game.next_floor()
		await _settle(8)
		# 每层单开一个阶段，便于看出「层数」对内存的影响
		_phase("R%d_F%d" % [run_index, f + 2])

	# 走到这里本局还活着；打死玩家以覆盖死亡结算层
	if game != null and is_instance_valid(game) and not game.run_over:
		RunState.take_damage(999999)
		await _settle(45)
		_phase("R%d_死亡结算" % run_index)
		await _settle(15)


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


## 沿最短路朝 to_id 走一步该开的门方向；不可达返回 -1（与冒烟测试同一实现）
func _step_toward_boss(d: Dungeon, from_id: int, to_id: int) -> int:
	if from_id == to_id:
		return -1
	var prev := {from_id: -1}
	var queue: Array[int] = [from_id]
	while not queue.is_empty():
		var cur: int = queue.pop_front()
		if cur == to_id:
			break
		for n in d.neighbors(cur):
			if not prev.has(n):
				prev[n] = cur
				queue.append(n)
	if not prev.has(to_id):
		return -1
	var step := to_id
	while int(prev[step]) != from_id and int(prev[step]) != -1:
		step = int(prev[step])
	if int(prev[step]) == -1:
		return -1
	var room := d.get_room(from_id)
	var nbrs: Array = room["nbr"]
	for dir in 4:
		if int(nbrs[dir]) == step:
			return dir
	return -1


# --- 字体缓存 ---------------------------------------------------------------

## 字体的实际常驻：TTF 是轮廓数据，9.8MB 是整份文件；真正进内存的是被渲染过的字形位图缓存
## 取每局最深那一层的静态内存当前值，算出跨局增量
func _leak_verdict() -> Dictionary:
	var per_run := {}
	for name in _phase_order:
		# 形如 "R2_F3"，即第 2 局第 3 层
		if name.begins_with("R") and name.contains("_F"):
			var run := int(name.substr(1, name.find("_F") - 1))
			var floor_n := int(name.substr(name.find("_F") + 2))
			var cur := float((_phase_peak[name] as Dictionary)["static_mb"])
			if not per_run.has(run) or floor_n > per_run[run]["floor"]:
				per_run[run] = {"floor": floor_n, "static_mb": cur}
	var out := {"text": "样本不足，无法判定", "d12": 0.0, "d23": 0.0, "per_run": per_run}
	if not (per_run.has(1) and per_run.has(2) and per_run.has(3)):
		return out
	var s1 := float(per_run[1]["static_mb"])
	var s2 := float(per_run[2]["static_mb"])
	var s3 := float(per_run[3]["static_mb"])
	var d12 := s2 - s1
	var d23 := s3 - s2
	out["d12"] = snappedf(d12, 0.01)
	out["d23"] = snappedf(d23, 0.01)
	# 阈值取 1 MB：小于它视作测量噪声内持平
	if absf(d12) < 1.0 and absf(d23) < 1.0:
		out["text"] = "三局持平，无泄漏"
	elif d12 > 1.0 and absf(d23) < 1.0:
		out["text"] = "第 1→2 局涨后持平 = 一次性资源缓存，非泄漏"
	elif d23 > 1.0:
		out["text"] = "第 2→3 局仍在涨 = 疑似泄漏"
	else:
		out["text"] = "跨局反而下降 = 释放正常"
	return out


func _font_report() -> Dictionary:
	var out := {}
	var theme: Theme = load("res://assets/ui/ui_theme.tres")
	var f: Font = theme.default_font
	if f == null:
		return {"error": "主题没有 default_font"}
	out["font_path"] = f.resource_path
	var ts := TextServerManager.get_primary_interface()
	var rids: Array = (f as FontFile).get_rids()
	if rids.is_empty():
		return out
	var rid: RID = rids[0]
	out["supported_chars"] = ts.font_get_supported_chars(rid).length() if ts.has_method("font_get_supported_chars") else -1
	# 字号按工程约定的 12/24/36/48/72 各查一遍，纹理页数就是字形缓存的规模
	var pages := {}
	for px in [12, 24, 36, 48, 72]:
		pages[str(px)] = ts.font_get_texture_count(rid, Vector2i(px, 0))
	out["cache_texture_pages_by_size"] = pages
	return out


# --- 报告 -------------------------------------------------------------------

func _report() -> void:
	if _reported:
		return
	_reported = true
	if _live != null and is_instance_valid(_live):
		_live.queue_free()
		_live = null
	if _sample_count == 0:
		push_error("内存实测：一个样本都没采到")
		get_tree().quit(2)
		return

	var font_info := _font_report()
	var report := {
		"samples": _sample_count,
		"phase_peaks": _phase_peak,
		"phase_order": _phase_order,
		"marks": _phase_marks,
		"font": font_info,
	}

	print("")
	print("---------------- 整局内存实测 ----------------")
	print("共采样 %d 帧，逐阶段峰值如下（MB）" % _sample_count)
	print("")
	print("%-22s %10s %10s %10s %8s %8s" % ["阶段", "静态当前", "静态高水位", "显存", "对象数", "2D碰撞对"])
	for name in _phase_order:
		var p: Dictionary = _phase_peak[name]
		print("%-22s %10.1f %10.1f %10.1f %8d %8d" % [
			name,
			float(p["static_mb"]), float(p["static_max_mb"]), float(p["video_mb"]),
			int(p["objects"]), int(p["phys_pairs"]),
		])

	print("")
	print("阶段留档（静态内存当前值，看切场景后是否回落）：")
	for mk in _phase_marks:
		print("  %-28s 静态 %7.1f MB | 高水位 %7.1f MB | 对象 %d" % [
			str(mk["label"]), float(mk["static_mb"]), float(mk["static_max_mb"]), int(mk["objects"])])

	var session_max := 0.0
	for name in _phase_order:
		session_max = maxf(session_max, float((_phase_peak[name] as Dictionary)["static_max_mb"]))

	# 泄漏判定：比较各局「同深度」的静态内存当前值。
	# 一次性资源缓存只会让第 1→2 局涨，第 2→3 局持平；真泄漏则每局都涨。
	var verdict := _leak_verdict()

	print("")
	print("整局静态内存高水位 : %.1f MB" % session_max)
	print("跨局增长判定       : %s" % verdict["text"])
	print("  第1局→第2局 %+.1f MB | 第2局→第3局 %+.1f MB" % [verdict["d12"], verdict["d23"]])
	if font_info.has("cache_texture_pages_by_size"):
		print("字体字形缓存页数   : %s" % str(font_info["cache_texture_pages_by_size"]))
	if font_info.has("supported_chars"):
		print("字体可渲染字符数   : %d" % int(font_info["supported_chars"]))
	print("-----------------------------------------")

	report["leak_verdict"] = verdict
	report["session_static_max_mb"] = snappedf(session_max, 0.01)

	var f := FileAccess.open("user://memory_report.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  "))
		f.close()
	get_tree().quit(0)