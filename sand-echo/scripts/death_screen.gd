extends CanvasLayer
# @trace MECH-005, MECH-006, UI-001, NUM-003, FLOW-001
# 死亡结算界面（@trace MECH-005 生命与死亡结算 / @trace MECH-006 元进度继承）。
# 数据入口：Game 调用 show_summary(ember_gained, summary)；数据出口：场景切换 + EventBus。

@onready var _root: Control = $Root
@onready var _ember: Label = $Root/Panel/VBox/Ember
@onready var _stats: Label = $Root/Panel/VBox/Stats
@onready var _relics: Label = $Root/Panel/VBox/Relics
@onready var _again: Button = $Root/Panel/VBox/Again
@onready var _menu: Button = $Root/Panel/VBox/Menu


func _ready() -> void:
	_again.pressed.connect(_on_again)
	_menu.pressed.connect(_on_menu)


func show_summary(ember_gained: int, summary: Dictionary) -> void:
	_ember.text = "余烬 +%d（累计 %d）" % [ember_gained, _meta_ember()]
	_stats.text = "抵达 第 %d 层　　清理房间 %d　　击杀 %d\n拾取遗物 %d　　承受伤害 %d" % [
		int(summary.get("wave", 1)),
		int(summary.get("waves_cleared", 0)),
		int(summary.get("enemies_killed", 0)) + int(summary.get("bosses_killed", 0)),
		int(summary.get("upgrades_taken", 0)),
		int(summary.get("damage_taken", 0)),
	]
	_relics.text = _relic_lines()
	_root.visible = true
	_again.grab_focus()
	Sfx.play("death", -2.0, 0.9, 0.0)


func _relic_lines() -> String:
	if RunState.upgrades.is_empty():
		return "本局未拾取遗物"
	var names: Array[String] = []
	for id in RunState.upgrades:
		var def: Dictionary = RunState.upgrade_def(id)
		names.append("%s（%s）" % [String(def.get("name", id)), String(def.get("desc", ""))])
	return "遗物：\n" + "、".join(names)


func _meta_ember() -> int:
	var mp := get_node_or_null("/root/MetaProgress")
	return mp.ember if mp != null else 0


func _on_again() -> void:
	Sfx.play("ui_select", -10.0, 1.0, 0.0)
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_menu() -> void:
	Sfx.play("ui_select", -10.0, 0.9, 0.0)
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")