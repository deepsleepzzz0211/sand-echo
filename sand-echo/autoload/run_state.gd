extends Node
# @trace WPN-001, WPN-002, WPN-003, UPG-001, NUM-001, NUM-003, SIG-001, SIG-002, SCENE-002, MECH-005, MECH-006
# 单局可变状态（@trace SCENE-002）。
# 谁写：Game / Player / Enemy / Weapon / UpgradeScreen；谁读：HUD / Shop / UpgradeScreen / DeathScreen / MetaProgress。
# 何时清：reset_run()（每局开始）。
#
# 【本轮重构】房间地牢制 → Brotato 式波次制（@trace WAVE-001）：
#   旧：floor_num + 随机生长树地图 + 清场开门 + 走到 Boss 房
#   新：wave_num + 单屏竞技场 + 清完一波进商店/三选一 + 每 10 波 Boss
#   遗物 → 升级池条目（@trace UPG-001），武器成为独立系统（@trace WPN-001）。

signal health_changed(current: int, maximum: int)
signal gold_changed(value: int)
signal wave_changed(value: int)
signal weapons_changed()
signal upgrade_taken(id: String)
signal player_died()
signal stats_changed()

const BASE_HEALTH := 20
const DASH_CD := 0.9
const DASH_IFRAME := 0.30
const DASH_TIME := 0.18
const BULLET_SPEED := 520.0
const BULLET_LIFETIME := 1.2
const GOLD_TO_EMBER_NUM := 1
const GOLD_TO_EMBER_DEN := 2
const MAX_WEAPONS := 6
const MAX_TIER := 4
## 回收退款比例：卖回累计投入的一半。
const SELL_REFUND_RATE := 0.5
const STARTING_WEAPON := "w_pistol"

# --- 玩家属性 ---
var max_health: int = BASE_HEALTH
var health: int = BASE_HEALTH
var gold: int = 0
var wave_num: int = 1
var damage_mult: float = 1.0
var fire_rate_mult: float = 1.0
var move_speed: float = 200.0
var bullet_count: int = 1
var spread_deg: float = 0.0
var pierce: int = 0
var ember_bonus: float = 0.0
var gold_mult: float = 1.0
var pickup_range: float = 1.0
var crit_chance: float = 0.0
var dash_cd_mult: float = 1.0
var heal_per_wave: int = 0
## 吸血：按造成伤害的比例回复生命（@trace NUM-006 吸血派生值）
var lifesteal: float = 0.0
var upgrades: Array[String] = []
var weapons: Array[Dictionary] = []
var stats: Dictionary = {}
var dead: bool = false

var _tables: Dictionary = {}
var character_id: String = "char1"   ## 当前选择的角色（主菜单切换）


func _ready() -> void:
	_tables["weapons"] = _load_table("res://data/weapons.json")
	_tables["upgrades"] = _load_table("res://data/upgrades.json")
	_tables["characters"] = _load_table("res://data/characters.json")


# --- 开局 / 重置 -------------------------------------------------------------

func reset_run() -> void:
	dead = false
	wave_num = 1
	gold = 0
	upgrades.clear()
	weapons = [{
		"id": STARTING_WEAPON,
		"tier": 1,
		"cd": 0.0,
	}]
	stats = {
		"waves_cleared": 0,
		"enemies_killed": 0,
		"bosses_killed": 0,
		"upgrades_taken": 0,
		"damage_taken": 0,
		"shots_fired": 0,
		"gold_earned": 0,
		"deepest_wave": 1,
	}
	_recalc_derived()
	health = max_health
	_emit_all()


func _recalc_derived() -> void:
	# 基础值 + 升级累积值 + 元进度加成（@trace NUM-001 乘性结构）
	max_health = BASE_HEALTH
	damage_mult = 1.0
	fire_rate_mult = 1.0
	move_speed = 200.0
	bullet_count = 1
	spread_deg = 0.0
	pierce = 0
	ember_bonus = 0.0
	gold_mult = 1.0
	pickup_range = 1.0
	crit_chance = 0.0
	dash_cd_mult = 1.0
	heal_per_wave = 0
	lifesteal = 0.0
	for id in upgrades:
		_apply_upgrade(upgrade_def(id))
	# 浮点归整：0.15 + 0.30 在二进制浮点里是 0.44999999999999996，
	# 于是 floor(100 x 0.4499999) = 44 而不是 45 —— 面板写着 45% 实际少回 1 点。
	# 累加完成后统一收敛到 4 位小数，让显示值与实际效果一致。
	lifesteal = snappedf(lifesteal, 0.0001)
	_apply_character()
	var mp := _meta()
	if mp != null:
		damage_mult *= mp.get_damage_bonus()
		move_speed += mp.get_move_bonus()
	max_health = maxi(1, max_health)
	health = mini(health, max_health)


## 角色初始修正（Brotato 式：开局选人决定基础强度）
func _apply_character() -> void:
	var c := character_def(character_id)
	if c.is_empty():
		return
	var m := c.get("mods", {}) as Dictionary
	max_health += int(m.get("max_health", 0))
	damage_mult += float(m.get("damage", 0.0))
	move_speed += float(m.get("move", 0))
	fire_rate_mult += float(m.get("fire_rate", 0.0))
	gold_mult += float(m.get("gold_mult", 0.0))


func character_def(id: String) -> Dictionary:
	for entry in table("characters"):
		if entry is Dictionary and String((entry as Dictionary).get("id", "")) == id:
			return entry as Dictionary
	return {}


func character_frames(id: String) -> SpriteFrames:
	var c := character_def(id)
	if c.is_empty():
		return null
	var p := String(c.get("frames", ""))
	return load(p) as SpriteFrames if ResourceLoader.exists(p) else null


func _apply_upgrade(def: Dictionary) -> void:
	match String(def.get("stat", "")):
		"damage":
			damage_mult += float(def.get("value", 0.0))
		"max_health":
			max_health += int(def.get("value", 0.0))
		"fire_rate":
			fire_rate_mult += float(def.get("value", 0.0))
		"move":
			move_speed += float(def.get("value", 0.0))
		"multishot":
			bullet_count += int(def.get("value", 0.0))
		"spread":
			spread_deg += float(def.get("value", 0.0))
		"pierce":
			pierce += int(def.get("value", 0.0))
		"ember":
			ember_bonus += float(def.get("value", 0.0))
		"gold_mult":
			gold_mult += float(def.get("value", 0.0))
		"pickup":
			pickup_range += float(def.get("value", 0.0))
		"crit":
			crit_chance += float(def.get("value", 0.0))
		"dash_cd":
			dash_cd_mult = maxf(0.25, dash_cd_mult + float(def.get("value", 0.0)))
		"heal_wave":
			heal_per_wave += int(def.get("value", 0.0))
		"lifesteal":
			lifesteal += float(def.get("value", 0.0))
	stats_changed.emit()


# --- 升级（@trace UPG-001）---------------------------------------------------

## 返回 false 表示该升级不可重复获取
func take_upgrade(id: String) -> bool:
	if upgrades.has(id):
		return false
	var def := upgrade_def(id)
	if def.is_empty():
		return false
	upgrades.append(id)
	_recalc_derived()
	stats["upgrades_taken"] = int(stats.get("upgrades_taken", 0)) + 1
	upgrade_taken.emit(id)
	health = mini(max_health, maxi(health, 1))
	health_changed.emit(health, max_health)
	return true


## 三选一候选池：排除已获取过的
func upgrade_pool() -> Array:
	var out: Array = []
	for entry in table("upgrades"):
		var d := entry as Dictionary
		if not upgrades.has(String(d.get("id", ""))):
			out.append(d)
	return out


func upgrade_def(id: String) -> Dictionary:
	for entry in table("upgrades"):
		if entry is Dictionary and String((entry as Dictionary).get("id", "")) == id:
			return entry as Dictionary
	return {}


# --- 武器（@trace WPN-001）---------------------------------------------------

func weapon_def(id: String) -> Dictionary:
	for entry in table("weapons"):
		if entry is Dictionary and String((entry as Dictionary).get("id", "")) == id:
			return entry as Dictionary
	return {}


## 已拥有同 id 的武器则升一级（@trace WPN-001 叠加规则），否则占一个新槽位
func add_weapon(id: String, spent: int = 0) -> bool:
	var def := weapon_def(id)
	if def.is_empty():
		return false
	for w in weapons:
		var wm := w as Dictionary
		if String(wm["id"]) == id:
			if int(wm.get("tier", 1)) >= MAX_TIER:
				return false   # 已满级，不再接受投入
			wm["tier"] = int(wm.get("tier", 1)) + 1
			# 记下累计投入，回收时按比例退款
			wm["invested"] = int(wm.get("invested", 0)) + spent
			weapons_changed.emit()
			return true
	if weapons.size() >= MAX_WEAPONS:
		return false
	weapons.append({"id": id, "tier": 1, "cd": 0.0, "invested": spent})
	weapons_changed.emit()
	return true


## 商店买入：同 id 升一级；槽位满时返回 false
func buy_weapon(id: String, spent: int = 0) -> bool:
	return add_weapon(id, spent)


## 回收：卖掉 index 号槽位的武器，换回金币并腾出槽位。
## 没有这条路径时，6 把槽位填满且全部满级之后就永远卡死——商店既买不进新武器，
## 也没有可强化的对象，玩家只能带着一套停滞的配打完一局。
## 约束：至少留一把，否则玩家能把自己卖到空手。
func sell_weapon(index: int) -> int:
	if index < 0 or index >= weapons.size() or weapons.size() <= 1:
		return 0
	var refund := sell_value(index)
	weapons.remove_at(index)
	# 退款不走 gold_mult：那是「获取金币」的加成，卖东西不该被自己的加成放大
	gold += refund
	stats["gold_earned"] = int(stats.get("gold_earned", 0)) + refund
	stats["weapons_sold"] = int(stats.get("weapons_sold", 0)) + 1
	gold_changed.emit(gold)
	weapons_changed.emit()
	return refund


## 回收报价 = 累计投入的一半，下限 1 金。
## 用投入额而不是当前商店价：商店价随波次通胀，同一把枪不同波次报价能差好几倍。
func sell_value(index: int) -> int:
	if index < 0 or index >= weapons.size():
		return 0
	var wm := weapons[index] as Dictionary
	var invested := int(wm.get("invested", 0))
	if invested <= 0:
		# 初始手枪 invested=0（免费获得），按商店基础价给个象征性回收价
		invested = int(weapon_def(String(wm["id"])).get("cost", 0))
	return maxi(1, int(floor(float(invested) * SELL_REFUND_RATE)))


## 是否还能买进新武器（占新槽位）
func can_add_new_weapon() -> bool:
	return weapons.size() < MAX_WEAPONS


# --- 波次（@trace WAVE-001）--------------------------------------------------

func wave_def(wave: int) -> Dictionary:
	# 1..N 用表内数据（表已生成到 60 波），之后按 count 曲线的封顶值外推。
	# 注意：旧版在这里对 Boss 波提前 return（budget=0），绕过了表数据，
	# 导致 Boss 波几乎不出杂兵。现在 Boss 波也走表，count 由 waves.json 给。
	var rows := _wave_rows()
	var idx := wave - 1
	if idx < rows.size():
		return (rows[idx] as Dictionary).duplicate()
	var base_count := int(wave_rules().get("count_cap", 90))
	return {
		"wave": wave,
		"count": base_count,
		"pool": ["e_chaser", "e_shooter", "e_burst", "e_brute"],
		"boss": wave % int(wave_rules().get("boss_every", 10)) == 0,
		"scale": 1.0,
	}


func wave_rules() -> Dictionary:
	var parsed: Variant = read_json("res://data/waves.json")
	if not (parsed is Dictionary):
		return {"boss_every": 10, "max_concurrent": 40, "spawn_interval": 0.12, "opening_burst": 5, "gold_per_wave_base": 12}
	return (parsed as Dictionary).get("rules", {})


func _wave_rows() -> Array:
	var parsed: Variant = read_json("res://data/waves.json")
	if not (parsed is Dictionary):
		return []
	return (parsed as Dictionary).get("waves", [])


func next_wave() -> void:
	wave_num += 1
	stats["deepest_wave"] = maxi(int(stats.get("deepest_wave", 1)), wave_num)
	if heal_per_wave > 0:
		heal(heal_per_wave)
	wave_changed.emit(wave_num)


func is_boss_wave(wave: int) -> bool:
	return wave % int(wave_rules().get("boss_every", 10)) == 0


# --- 数值公式 ---------------------------------------------------------------

func dash_cooldown() -> float:
	return DASH_CD * dash_cd_mult


## tier 差异化表：下标 = tier-1。
## 此前 tier 只放大伤害（恒定 +75%），射速/弹丸/贯穿/散布/弹丸大小从 T1 到 T4
## 完全不变，玩家反馈「买武器升级看不出来」。现在每个 tier 同时成长多个维度。
## damage 一列刻意保持 1.00/1.25/1.50/1.75 —— 那是既有数值红线，不擅改。
const TIER_DAMAGE := [1.00, 1.25, 1.50, 1.75]
const TIER_INTERVAL := [1.00, 0.92, 0.85, 0.78]   # 越小越快
const TIER_PIERCE := [0, 0, 1, 2]
const TIER_SPREAD := [1.00, 0.95, 0.90, 0.85]     # 越低越集中
const TIER_BULLET := [1.00, 1.06, 1.12, 1.20]
const TIER_EXTRA_PELLETS := [0, 0, 1, 1]
## 额外弹丸只给「本来就是多发武器」的（霰弹/散射/喷焰/游猎者）。
## 单发武器（手枪/狙击/轨道炮/法球）额外 +1 弹丸等于 DPS 直接翻倍，太跳；
## 它们改走贯穿 +2 这条成长线。
const PELLET_WEAPON_MIN := 2


static func _tier_idx(tier: int) -> int:
	return clampi(tier - 1, 0, 3)


## 武器实际射速：基础间隔 × tier 系数 / 全局射速倍率（@trace WPN-001）
func weapon_interval(def: Dictionary, tier: int = 1) -> float:
	var ivl := float(def.get("fire_interval", 0.25)) * float(TIER_INTERVAL[_tier_idx(tier)])
	return maxf(0.03, ivl / maxf(0.1, fire_rate_mult))


## 弹丸数：基础 + tier 额外弹丸（仅多发武器）+ 全局弹丸加成
func weapon_projectiles(def: Dictionary, tier: int = 1) -> int:
	var base := int(def.get("projectiles", 1))
	var extra := 0
	if base >= PELLET_WEAPON_MIN:
		extra = int(TIER_EXTRA_PELLETS[_tier_idx(tier)])
	return maxi(1, base + extra + bullet_count - 1)


## 散布：基础 × tier 集中系数 + 全局散布
func weapon_spread(def: Dictionary, tier: int = 1) -> float:
	return float(def.get("spread_deg", 0.0)) * float(TIER_SPREAD[_tier_idx(tier)]) + spread_deg


## 贯穿：基础 + tier + 全局
func weapon_pierce(def: Dictionary, tier: int = 1) -> int:
	return int(def.get("pierce", 0)) + int(TIER_PIERCE[_tier_idx(tier)]) + pierce


## 弹丸视觉大小：基础 × tier
func weapon_bullet_scale(def: Dictionary, tier: int = 1) -> float:
	return float(def.get("bullet_scale", 1.0)) * float(TIER_BULLET[_tier_idx(tier)])


## 单发实际伤害：base × 成长倍率 × 品质等级（@trace NUM-001）
func weapon_damage(def: Dictionary, tier: int) -> int:
	return maxi(1, int(round(float(def.get("damage", 1)) * damage_mult
		* float(TIER_DAMAGE[_tier_idx(tier)]))))


func roll_crit() -> bool:
	return randf() < crit_chance


func ember_from_gold() -> int:
	var raw := float(gold) * float(GOLD_TO_EMBER_NUM) / float(GOLD_TO_EMBER_DEN)
	return int(floor(raw * (1.0 + ember_bonus)))


# --- 变更接口 ---------------------------------------------------------------

func take_damage(amount: int) -> void:
	if dead:
		return
	health = maxi(0, health - maxi(0, amount))
	stats["damage_taken"] = int(stats.get("damage_taken", 0)) + amount
	health_changed.emit(health, max_health)
	stats_changed.emit()
	if health <= 0:
		dead = true
		player_died.emit()


func heal(amount: int) -> void:
	if dead:
		return
	health = mini(max_health, health + maxi(0, amount))
	health_changed.emit(health, max_health)


## 按伤害吸血：返回实际回复量，供表现层飘字。
## 钳到至少 1 点是有意的：低伤害武器（如初始手枪 8 伤害）在 8% 下取整为 0，
## 玩家会拿到属性却完全看不到任何反馈。不足 1 点时给 1 点，让效果立刻可感知。
## 不吃任何倍率——吸血是「战斗中的回复」，不该被余烬/金币那套经济加成影响。
func heal_from_damage(damage: int) -> int:
	if dead or lifesteal <= 0.0 or damage <= 0:
		return 0
	var before := health
	heal(maxi(1, int(floor(float(damage) * lifesteal))))
	return health - before


func add_gold(amount: int) -> void:
	# 金币获取受 gold_mult 加成（@trace NUM-003）
	var gained := maxi(0, int(round(float(amount) * gold_mult)))
	gold += gained
	stats["gold_earned"] = int(stats.get("gold_earned", 0)) + gained
	gold_changed.emit(gold)


func spend_gold(amount: int) -> bool:
	if gold < amount:
		return false
	gold -= amount
	gold_changed.emit(gold)
	return true


func bump_stat(key: String, amount: int = 1) -> void:
	stats[key] = int(stats.get(key, 0)) + amount
	stats_changed.emit()


func summary() -> Dictionary:
	var s := stats.duplicate()
	s["wave"] = wave_num
	s["gold"] = gold
	s["upgrades"] = upgrades.size()
	s["weapons"] = weapons.size()
	return s


func _emit_all() -> void:
	health_changed.emit(health, max_health)
	gold_changed.emit(gold)
	wave_changed.emit(wave_num)
	weapons_changed.emit()
	stats_changed.emit()


# --- 内部工具 ---------------------------------------------------------------

func table(name: String) -> Array:
	if _tables.has(name):
		return _tables[name]
	return []


## 读取 res:// 下的 JSON 数据表。
##
## 为什么两条路都试：Godot 4 起 JSON 被当作资源（godotengine/godot#65295），
## 但本工程的 data/*.json 没有 .import 文件、而 ResourceLoader.exists() 又返回 true，
## 编辑器里两种方式都读得通—— 只有导出后才能区分。若 JSON 走资源管线被打包成 .res，
## 则 FileAccess.open("res://data/waves.json") 返回 null，
## 于是升级池 / 武器表 / 波次表全空、游戏直接卡死。
## 先 FileAccess 后 ResourceLoader，两种打包行为下都能工作。
func read_json(path: String) -> Variant:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f != null:
		var text: String = f.get_as_text()
		f.close()
		var parsed: Variant = JSON.parse_string(text)
		if parsed != null:
			return parsed
	# 回退：走资源管线（导出后 JSON 被转成 .res 时才走到这里）
	if ResourceLoader.exists(path):
		var j: JSON = ResourceLoader.load(path) as JSON
		if j != null:
			return j.data
	push_error("RunState：数据表读不到 %s" % path)
	return null


func _load_table(path: String) -> Array:
	var parsed: Variant = read_json(path)
	return parsed as Array if parsed is Array else []


func _meta() -> Node:
	return get_node_or_null("/root/MetaProgress")