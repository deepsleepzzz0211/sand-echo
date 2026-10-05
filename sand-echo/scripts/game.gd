extends Node2D
# @trace MECH-001, MECH-009, SCENE-001, SIG-001, SIG-002, SIG-005, SCENE-002, LEV-001, AUD-002, ART-003, WAVE-001, WAVE-002, WAVE-003, WPN-001, WPN-002, UPG-001, SHOP-001, FLOW-004
# 单局主控：Brotato 式波次循环（@trace WAVE-001）。
#
# 【本轮重构】房间地牢制 → 单屏竞技场 + 波次
#   旧循环：进房间 → 清场 → 开门 → 走到 Boss 房 → 下一层
#   新循环：开波 → 清场 → 三选一升级 → 商店花钱 → 下一波（每 10 波 Boss）
#   遗物不再随机掉落，改为波间三选一（@trace UPG-001）；武器独立成系统（@trace WPN-001）。
#
# 节点树（scenes/game.tscn）：
#   Game(Node2D)
#   ├─ World(Node2D)        ← Arena / 敌人 / 弹幕 / 特效
#   ├─ Camera2D             ← zoom 固定 2.0，不再跟随（单屏竞技场整体可见）
#   ├─ Hud                  ← 波次 / 血条 / 金币 / 武器栏
#   ├─ ShopLayer            ← 商店面板（@trace SHOP-001）
#   └─ UpgradeLayer         ← 三选一面板（@trace UPG-001）
#   ├─ PauseMenu
#   └─ DeathScreen

const ENEMY_SCENE: PackedScene = preload("res://scenes/enemy.tscn")
const BOSS_TARGET_FIGHT_SECONDS := 20.0
const BOSS_COEF_BASE := 6.0
const BOSS_COEF_PER_WAVE := 0.6
const BOSS_COEF_MAX := 14.0

@onready var world: Node2D = $World
@onready var camera: Camera2D = $Camera2D
@onready var _hud: CanvasLayer = $Hud
@onready var _shop_layer: CanvasLayer = $ShopLayer
@onready var _upgrade_layer: CanvasLayer = $UpgradeLayer

var player: Player = null
var arena: Arena = null
var enemies: Array[Enemy] = []
var enemies_alive: int = 0
var run_over: bool = false

var _tileset_res: TileSet = null
var _rng := RandomNumberGenerator.new()
var _enemy_stats: Array = []

# --- 波次状态（@trace WAVE-001）---
var wave_active: bool = false
var _spawn_queue: Array[String] = []
var _spawn_timer: float = 0.0
var _wave_def: Dictionary = {}
var _intermission: bool = false


func _ready() -> void:
	_rng.randomize()
	# 必须先重置单局状态：否则武器列表是空的（上一版由 main_menu 负责，本版主控自己兜住）
	RunState.reset_run()
	_load_static()
	_build_arena()
	_spawn_player()
	_connect_signals()
	# PauseMenu 需要反向引用才能在「继续」按钮里调回来；以前从没调用过 setup()，
	# 于是 _game 一直是 null，暂停菜单里的按钮全是死的。
	var pause := get_node_or_null("PauseMenu")
	if pause != null and pause.has_method("setup"):
		pause.call("setup", self)
	_begin_wave(1)
	# BGM：先按波次类型定，开局是普通波
	Sfx.play_bgm(Sfx.BgmMode.DUNGEON)  # @trace AUD-002


func _load_static() -> void:
	var path := "res://assets/art/tiles/desert_tileset.tres"
	if ResourceLoader.exists(path):
		_tileset_res = load(path) as TileSet
	var parsed: Variant = RunState.read_json("res://data/enemies.json")
	if parsed is Array:
		_enemy_stats = parsed


## 单屏竞技场只建一次：没有过门，也就没有切房帧（这是换掉房间制的核心收益）
func _build_arena() -> void:
	arena = Arena.new()
	arena.name = "Arena"
	arena.configure(_tileset_res, _rng.randi(), 1)
	world.add_child(arena)
	arena.build()
	camera.position = arena.center()
	camera.zoom = Vector2.ONE * 2.0   # 角色 24px → 屏幕 48px，占屏高 4.4%（改前 2.2%）
	camera.make_current()


func _spawn_player() -> void:
	var res: PackedScene = load("res://scenes/player.tscn")
	player = res.instantiate() as Player
	# 按所选角色换帧集（@trace WPN-001 之外的独立选择维度）
	var frames := RunState.character_frames(RunState.character_id)
	if frames != null:
		player.call("apply_character_frames", frames)
	player.position = arena.player_spawn_position()
	world.add_child(player)


func _connect_signals() -> void:
	# 注意：_on_enemy_died 只由各敌人的 died 信号驱动，绝不能再连 EventBus.enemy_killed ——
	# 它内部会 emit(enemy_killed)，连上就是自己调自己，递归到爆栈（实测 1000+ 层），
	# 结果是波次结算那几行永远执行不到，三选一与商店都不会弹。
	EventBus.boss_spawned.connect(_on_boss_spawned)
	EventBus.shake_requested.connect(_on_shake)
	EventBus.player_hurt.connect(_on_player_hurt)
	# 死亡链路（重写本文件时漏掉，导致死亡后没有结算画面）：
	# RunState.player_died → 停手 → 结算余烬入账 → 通知死亡结算层
	RunState.player_died.connect(_on_player_died)
	_upgrade_layer.connect("chosen", _on_upgrade_chosen)
	_shop_layer.connect("closed", _on_shop_closed)


# --- 波次流程（@trace WAVE-001）-----------------------------------------------

func _begin_wave(wave: int) -> void:
	_wave_def = RunState.wave_def(wave)
	var rules := RunState.wave_rules()
	_spawn_queue.clear()
	var pool: Array = _wave_def.get("pool", [])
	var scale := float(_wave_def.get("scale", 1.0))
	var is_boss := bool(_wave_def.get("boss", false))

	if is_boss:
		# Boss 波：Boss 直接登场 + waves.json 给的杂兵（count 已是全波总量，
		# 旧版这里 budget=0 导致第 9→10 波从 34 只掉到 7 只，是个断崖）
		_spawn_boss(scale)
		var boss_free := pool.has("boss")
		var guards := int(_wave_def.get("count", 8))
		for i in guards:
			var id: String = String(pool[_rng.randi_range(0, pool.size() - 1)])
			if boss_free and id == "boss":
				id = String(pool[_rng.randi_range(1, pool.size() - 1)])
			_spawn_queue.append(id)
	else:
		# 普通波：count 就是这一波要出的总只数（不是「血量点数」）。
		# 旧版用 budget + cost=hp/12 的贪心购买，cost=2 的甲壳兽会挤掉一只沙蜥，
		# 导致第 6→7 波实际只数反而下降。现在只数直接由 waves.json 的 count 给出。
		var count := int(_wave_def.get("count", 12))
		# 同屏上限是性能红线，队列总量给 4 倍余量让刷怪持续到清场
		var cap := maxi(int(rules.get("max_concurrent", 40)) * 4, count)
		for i in mini(count, cap):
			_spawn_queue.append(String(pool[_rng.randi_range(0, pool.size() - 1)]))

	_spawn_queue.shuffle()
	_spawn_timer = 0.0
	# 开局直接放一批，否则前几秒空场，玩家会以为「敌人数量太少」
	if not is_boss:
		var burst := mini(int(RunState.wave_rules().get("opening_burst", 5)), _spawn_queue.size())
		for i in burst:
			_spawn_one()
	# 每波战场不同：按波次作种子重摆掩体与障碍（只重建地面之上的层）
	await arena.rebuild_for_wave(wave)
	wave_active = true
	_intermission = false
	EventBus.wave_started.emit(wave, is_boss)
	if is_boss:
		Sfx.play_bgm(Sfx.BgmMode.BOSS)  # @trace AUD-002
	else:
		Sfx.play_bgm(Sfx.BgmMode.DUNGEON)
	Sfx.play("ui_move", -20.0, 1.15, 0.05)
	# 明确告知清波后的收益，否则玩家不知道有商店/三选一
	EventBus.toast_requested.emit("清空本波 → 三选一强化 → 商店买武器")



func _enemy_def(id: String) -> Dictionary:
	for entry in _enemy_stats:
		if entry is Dictionary and String((entry as Dictionary).get("id", "")) == id:
			return entry as Dictionary
	return {}


func _process(delta: float) -> void:
	if run_over or not wave_active:
		return
	# 按节奏持续补怪，直到本波队列出完且场上清空
	if not _spawn_queue.is_empty():
		_spawn_timer -= delta
		var rules := RunState.wave_rules()
		if _spawn_timer <= 0.0 and enemies_alive < int(rules.get("max_concurrent", 40)):
			_spawn_one()
			_spawn_timer = float(rules.get("spawn_interval", 0.45))
	elif enemies_alive <= 0:
		_on_wave_cleared()


func _spawn_one() -> void:
	if _spawn_queue.is_empty():
		return
	var id: String = String(_spawn_queue.pop_back())
	_spawn_enemy(id, float(_wave_def.get("scale", 1.0)))


func _spawn_enemy(id: String, scale_hp: float) -> void:
	var def := _enemy_def(id)
	if def.is_empty() or player == null:
		return
	var d := def.duplicate()
	# 血量线性成长：hp = base + hp_per_wave × (wave-1)（Brotato 官方 wiki 的规则）。
	# 旧版是 base × scale，而 scale 在 waves.json 里第 1~9 波是 null、第 11 波突然 1.15，
	# 于是第 10 波有个玩家看不见的血量台阶。改成每波固定增量后全程单调。
	var wave := int(_wave_def.get("wave", RunState.wave_num))
	d["hp"] = maxi(1, int(round(
		(float(d.get("hp", 6)) + float(d.get("hp_per_wave", 10)) * float(maxi(0, wave - 1))) * scale_hp)))
	var e := ENEMY_SCENE.instantiate() as Enemy
	e.setup(d, arena.interior_rect(), _rng.randi())
	e.position = _find_spawn_point()
	world.add_child(e)
	e.died.connect(_on_enemy_died)
	e.damaged.connect(_on_enemy_damaged)
	enemies.append(e)
	enemies_alive += 1


func _spawn_boss(scale_hp: float) -> void:
	var def := _enemy_def("boss")
	if def.is_empty():
		push_error("Game：缺少 Boss 数据")
		return
	var d := def.duplicate()
	d["hp"] = _boss_hp(scale_hp)
	var e := ENEMY_SCENE.instantiate() as Enemy
	e.setup(d, arena.interior_rect(), _rng.randi())
	e.scale = Vector2.ONE * float(d.get("scale", 2.0))
	e.position = arena.center() - Vector2(0, arena.interior_rect().size.y * 0.2)
	world.add_child(e)
	e.died.connect(_on_enemy_died)
	e.damaged.connect(_on_enemy_damaged)
	enemies.append(e)
	enemies_alive += 1
	EventBus.boss_spawned.emit(String(d.get("name", "Boss")))
	Sfx.play("boss", -6.0, 1.0, 0.0)
	EventBus.shake_requested.emit(10.0)


## Boss HP = 玩家期望每秒输出 × 目标战斗时长 × Boss 系数（@trace NUM-004，可复算）
func _boss_hp(scale_hp: float) -> int:
	var dps := 0.0
	for w in RunState.weapons:
		var wm := w as Dictionary
		var def: Dictionary = RunState.weapon_def(String(wm["id"]))
		if def.is_empty():
			continue
		var per_shot := float(RunState.weapon_damage(def, int(wm.get("tier", 1))))
		var wt := int(wm.get("tier", 1))
		per_shot *= float(RunState.weapon_projectiles(def, wt))
		dps += per_shot / RunState.weapon_interval(def, wt)
	var wave := RunState.wave_num
	var coef := minf(BOSS_COEF_BASE + BOSS_COEF_PER_WAVE * float(wave - 1) / 10.0, BOSS_COEF_MAX)
	return clampi(int(round(dps * BOSS_TARGET_FIGHT_SECONDS * coef * scale_hp)), 300, 60000)


func _find_spawn_point() -> Vector2:
	var r := arena.interior_rect().grow(-40.0)
	for attempt in 40:
		var p := Vector2(_rng.randf_range(r.position.x, r.end.x), _rng.randf_range(r.position.y, r.end.y))
		if player == null or p.distance_to(player.global_position) > 220.0:
			return p
	return r.get_center()


# --- 波次结束 → 三选一 → 商店 → 下一波 ----------------------------------------

func _on_wave_cleared() -> void:
	wave_active = false
	_intermission = true
	RunState.bump_stat("waves_cleared")
	# 波次基础金币（Brotato 式：清波就有收入）
	var rules := RunState.wave_rules()
	RunState.add_gold(int(rules.get("gold_per_wave_base", 12)))
	_show_upgrade_screen()


func _show_upgrade_screen() -> void:
	# 每波一次三选一（@trace UPG-001）。
	# 注意：ShopLayer / UpgradeLayer 已在 game.tscn 里实例化，这里直接复用，
	# 不要再 instantiate —— CanvasLayer 的 visible=false 会连带隐藏子节点，二次实例化必然看不见。
	_upgrade_layer.call("offer", RunState.upgrade_pool(), 3)


func _on_upgrade_chosen(_id: String) -> void:
	_show_shop()


func _show_shop() -> void:
	_shop_layer.call("offer", RunState.weapons, RunState.gold)


func _on_shop_closed() -> void:
	_intermission = false
	RunState.next_wave()
	_begin_wave(RunState.wave_num)


# --- 战斗回调 ---------------------------------------------------------------

func _on_enemy_damaged(amount: int, _is_crit: bool) -> void:
	_last_hitstop_ms = _try_hitstop(HITSTOP_CD_MS, HITSTOP_SCALE, HITSTOP_SEC, _last_hitstop_ms)
	EventBus.shake_requested.emit(2.0)


func _on_boss_spawned(_boss_name: String) -> void:
	Sfx.play_bgm(Sfx.BgmMode.BOSS)  # @trace AUD-002


func _on_enemy_died(enemy_id: String, gold_reward: int) -> void:
	# 击杀顿帧比普通命中有分量得多，但仍走限频：BOSS 波一次几十只怪同时死，
	# 不限频就会把时间缩放压死。
	_last_killstop_ms = _try_hitstop(KILLSTOP_CD_MS, KILLSTOP_SCALE, KILLSTOP_SEC, _last_killstop_ms)
	enemies_alive = maxi(0, enemies_alive - 1)
	RunState.add_gold(gold_reward)
	RunState.bump_stat("enemies_killed")
	if enemy_id == "boss":
		RunState.bump_stat("bosses_killed")
		EventBus.shake_requested.emit(14.0)
		Sfx.stop_bgm()
	EventBus.enemy_killed.emit(enemy_id, gold_reward)
	if not is_instance_valid(player):
		return
	if enemies_alive <= 0 and _spawn_queue.is_empty() and wave_active:
		_on_wave_cleared()


func _on_player_died() -> void:
	if run_over:
		return
	run_over = true
	wave_active = false
	# 复位时间缩放：否则死在顿帧窗口里会让结算界面变成慢动作
	if _hitstop_tween != null and _hitstop_tween.is_valid():
		_hitstop_tween.kill()
	Engine.time_scale = 1.0
	_spawn_queue.clear()
	# 关掉可能正开着的面板，否则玩家在结算界面上还能点三选一/商店
	if _upgrade_layer != null:
		_upgrade_layer.visible = false
	if _shop_layer != null:
		_shop_layer.visible = false
	if is_instance_valid(player):
		player.call("die")
	Sfx.stop_bgm()
	# 金币按比例折成余烬并写入元进度（Brotato 的局外成长线）
	var ember := RunState.ember_from_gold()
	var summary := RunState.summary()
	var mp := get_node_or_null("/root/MetaProgress")
	if mp != null:
		mp.add_ember(ember)
		mp.record_run(summary)
	EventBus.run_ended.emit(ember, summary)
	var death := get_node_or_null("DeathScreen")
	if death != null:
		death.call("show_summary", ember, summary)
	else:
		push_error("Game：找不到 DeathScreen，死亡结算无法显示")


func _on_player_hurt(_amount: int) -> void:
	EventBus.shake_requested.emit(7.0)


func _on_shake(strength: float) -> void:
	camera.offset = Vector2(_rng.randf_range(-strength, strength), _rng.randf_range(-strength, strength))
	var t := create_tween()
	t.tween_property(camera, "offset", Vector2.ZERO, 0.18)


## --- 打击顿帧（hitstop）--------------------------------------------------
# 原实现有两个叠加的严重问题：
# ① 每次敌人受击都触发，而多发武器每秒能命中几十次（灼沙喷焰 T4 约 91 次/秒），
#    于是 time_scale 被反复压到 0.15，几乎永久处于慢动作。
# ② Tween 默认受 Engine.time_scale 影响，所以「0.05 秒」的间隔实际持续
#    0.05 / 0.15 ≈ 0.33 秒真实时间——每次命中都真的卡掉三分之一秒。
#    玩家反馈的「射击击中怪物时画面短暂停滞」就是这条。
# 现在：限频 + 真实秒数 + 命中/击杀分级 + 复用同一个 Tween。
const HITSTOP_CD_MS := 90       # 两次普通命中的最小间隔
const HITSTOP_SCALE := 0.55
const HITSTOP_SEC := 0.03
const KILLSTOP_CD_MS := 170     # 两次击杀顿帧的最小间隔
const KILLSTOP_SCALE := 0.25
const KILLSTOP_SEC := 0.07

var _last_hitstop_ms := 0
var _last_killstop_ms := 0
var _hitstop_tween: Tween = null


## 尝试触发顿帧。now_ms 用墙钟而不是 delta：delta 受 time_scale 影响，
## 而这里恰恰是在修改 time_scale，用 delta 会自激。
func _try_hitstop(cd_ms: int, scale: float, seconds: float, last_ms: int) -> int:
	var now := Time.get_ticks_msec()
	if now - last_ms < cd_ms:
		return last_ms
	Engine.time_scale = scale
	# 复用同一个 Tween：否则每次命中都新建一个，它们互相覆盖 time_scale，
	# 最后结束的那个才生效，时间缩放状态完全不可预测。
	if _hitstop_tween != null and _hitstop_tween.is_valid():
		_hitstop_tween.kill()
	_hitstop_tween = create_tween()
	# 关键：不加这一行，Tween 会被自己刚设的 time_scale 拖慢，
	# 0.03 秒的间隔实际会走 0.03/0.55 ≈ 0.055 秒，甚至更久。
	_hitstop_tween.set_ignore_time_scale(true)
	_hitstop_tween.tween_interval(seconds)
	_hitstop_tween.tween_callback(func(): Engine.time_scale = 1.0)
	return now


func toggle_pause() -> void:
	if run_over:
		return
	var pause := get_node_or_null("PauseMenu")
	if pause != null and pause.has_method("toggle"):
		pause.call("toggle")


## ESC 暂停。此前 game.gd 完全没有 _input / _unhandled_input，
## toggle_pause() 写好了却没有任何入口能调用它，所以按 ESC 没有反应。
##
## 职责拆分：Game 的 process_mode 是默认的 PAUSABLE，
## 一旦自己把 get_tree().paused 置为 true，它就再也收不到 _unhandled_input，
## 于是出现「按 ESC 暂停成功、再按 ESC 却退不出来」——只能靠鼠标点「继续」。
## 所以解除暂停的那一半交给 PauseMenu（process_mode = ALWAYS）。
func _unhandled_input(event: InputEvent) -> void:
	if get_tree().paused:
		return   # 暂停中由 PauseMenu 接手
	if event.is_action_pressed("ui_cancel"):
		toggle_pause()
		get_viewport().set_input_as_handled()
