extends Node
# @trace MECH-006, NUM-003, FLOW-002
# 注意：不写 class_name —— 名称与自动加载项 MetaProgress 同名会报「hides an autoload singleton」。
# 外部一律通过全局标识 MetaProgress 访问，不需要类型转换。
# 元进度（@trace SCENE-002）：跨局存活的唯一可变服务，存档落在 user://。
# 谁写：DeathScreen（余烬结算）、MainMenu（购买升级）；谁读：RunState.reset_run()；何时清：never。

const SAVE_PATH := "user://meta.json"
const BASE_COST := 50
const COST_GROWTH := 1.5
const SOFT_CAP := 10
const DAMAGE_PER_LEVEL := 0.06
const MOVE_PER_LEVEL := 4.0
const EMBER_SOFT_CAP := 9999
const SAVE_VERSION := 1

var ember: int = 0
var upgrade_level: int = 0
var runs_played: int = 0
var best_floor: int = 1
var total_kills: int = 0


func _ready() -> void:
	load_data()


func get_damage_bonus() -> float:
	return 1.0 + DAMAGE_PER_LEVEL * float(upgrade_level)


func get_move_bonus() -> float:
	return MOVE_PER_LEVEL * float(upgrade_level)


func upgrade_cost() -> int:
	# baseCost × 1.5^已购等级（@trace NUM-003）
	return int(round(float(BASE_COST) * pow(COST_GROWTH, float(upgrade_level))))


func soft_cap() -> int:
	return SOFT_CAP


func damage_per_level() -> float:
	return DAMAGE_PER_LEVEL


func can_upgrade() -> bool:
	return upgrade_level < SOFT_CAP and ember >= upgrade_cost()


func buy_upgrade() -> bool:
	if not can_upgrade():
		return false
	ember -= upgrade_cost()
	upgrade_level += 1
	save_data()
	return true


func add_ember(amount: int) -> void:
	ember = mini(EMBER_SOFT_CAP, ember + maxi(0, amount))
	save_data()


func record_run(summary: Dictionary) -> void:
	runs_played += 1
	best_floor = maxi(best_floor, int(summary.get("floor", 1)))
	total_kills += int(summary.get("enemies_killed", 0)) + int(summary.get("bosses_killed", 0))
	save_data()


func reset_all() -> void:
	ember = 0
	upgrade_level = 0
	runs_played = 0
	best_floor = 1
	total_kills = 0
	save_data()


func save_data() -> void:
	# 原子写：先写临时文件再改名（@trace FLOW-002）
	var payload := {
		"ember": ember,
		"upgrade_level": upgrade_level,
		"runs_played": runs_played,
		"best_floor": best_floor,
		"total_kills": total_kills,
		"version": SAVE_VERSION,
	}
	var tmp := SAVE_PATH + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("元进度：无法写入临时存档 %s" % tmp)
		return
	f.store_string(JSON.stringify(payload))
	f.close()
	var dir := DirAccess.open("user://")
	if dir == null:
		push_error("元进度：无法打开 user:// 目录")
		return
	if dir.file_exists(SAVE_PATH):
		dir.remove(SAVE_PATH)
	if dir.rename(tmp, SAVE_PATH) != OK:
		push_error("元进度：存档改名失败")


func load_data() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		push_error("元进度：无法读取存档，回退默认值")
		return
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_error("元进度：存档格式非法，回退默认值")
		return
	var d := parsed as Dictionary
	if int(d.get("version", 0)) != SAVE_VERSION:
		push_warning("元进度：存档版本不匹配，按默认值处理")
	ember = int(d.get("ember", 0))
	upgrade_level = int(d.get("upgrade_level", 0))
	runs_played = int(d.get("runs_played", 0))
	best_floor = int(d.get("best_floor", 1))
	total_kills = int(d.get("total_kills", 0))