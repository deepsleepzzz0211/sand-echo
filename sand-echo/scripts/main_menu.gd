extends Control
# @trace UI-001, MECH-006, FLOW-001, NUM-003, ART-003
# 主菜单（开始新一局 / 元进度 / 退出）。
# ART-003：中文与像素风不一致，走 assets/ui/ui_theme.tres 里的系统字体，缺口见 docs/asset-mapping.md。
# 数据入口：MetaProgress 存档；数据出口：EventBus.run_started + 场景切换。
# 节点树见 scenes/main_menu.tscn；所有 UI 节点在场景里声明，脚本只连信号。

@onready var _meta_text: Label = $MenuBox/VBox/MetaPanel/MetaMargin/MetaText
@onready var _char_buttons: Array[Button] = [$MenuBox/VBox/CharRow/Char1, $MenuBox/VBox/CharRow/Char2]
@onready var _char_info: Label = $MenuBox/VBox/CharInfo
@onready var _start: Button = $MenuBox/VBox/Start
@onready var _upgrade: Button = $MenuBox/VBox/Upgrade
@onready var _quit: Button = $MenuBox/VBox/Quit

var _meta: Node = null


func _ready() -> void:
	for i in _char_buttons.size():
		_char_buttons[i].pressed.connect(_on_char_picked.bind(i))
	_select_char(RunState.character_id)
	_meta = get_node_or_null("/root/MetaProgress")
	_start.pressed.connect(_on_start)
	_upgrade.pressed.connect(_on_upgrade)
	_quit.pressed.connect(_on_quit)
	_start.grab_focus()
	_refresh_meta()
	Sfx.play("ui_move", -18.0, 1.0, 0.05)


func _on_start() -> void:
	Sfx.play("ui_select", -8.0, 1.0, 0.0)
	Sfx.play_bgm(Sfx.BgmMode.DUNGEON)
	EventBus.run_started.emit()
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_upgrade() -> void:
	if _meta == null:
		return
	if _meta.can_upgrade():
		Sfx.play("pickup", -8.0, 1.1, 0.0)
		_meta.buy_upgrade()
	else:
		Sfx.play("error", -10.0, 1.0, 0.05)
	_refresh_meta()


func _on_quit() -> void:
	Sfx.play("ui_select", -10.0, 0.85, 0.0)
	get_tree().quit()


func _refresh_meta() -> void:
	if _meta == null:
		_meta_text.text = "元进度不可用"
		_upgrade.disabled = true
		return
	var cost: int = _meta.upgrade_cost()
	_meta_text.text = "余烬 %d　·　永久伤害 Lv.%d/%d（每级 +6%%）　·　下一级 %d 余烬　·　最深层 %d" % [
		_meta.ember, _meta.upgrade_level, _meta.soft_cap(), cost, _meta.best_floor
	]
	_upgrade.disabled = not _meta.can_upgrade()
	_upgrade.text = "永久升级" if _meta.can_upgrade() else "余烬不足（需 %d）" % cost

## 切换角色（Brotato 式开局选人）。角色基础强度由 data/characters.json 定义。
func _on_char_picked(index: int) -> void:
	_select_char(String(RunState.table("characters")[index].get("id", "char1")))


func _select_char(id: String) -> void:
	RunState.character_id = id
	for i in _char_buttons.size():
		var cid := String((RunState.table("characters")[i] as Dictionary).get("id", ""))
		_char_buttons[i].set_pressed_no_signal(cid == id)
		_char_buttons[i].text = String((RunState.table("characters")[i] as Dictionary).get("name", cid))
	var def := RunState.character_def(id)
	_char_info.text = String(def.get("desc", "")) if not def.is_empty() else ""
