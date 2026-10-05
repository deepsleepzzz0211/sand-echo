extends CanvasLayer
# @trace UPG-001, UI-002
# 波间三选一（@trace UPG-001）。取代原来「房间里随机捡遗物」——
# 随机捡拾没有决策，玩家的构筑是被动的；Brotato 的肉鸽感来自「每波做一次选择」。
#
# 候选来自 RunState.upgrade_pool()，已获得的会从池里剔除，所以每次三选一都是真选择。
# UI 节点全部在 scenes/upgrade_screen.tscn 里声明，本脚本只连信号与填文本。

signal chosen(id: String)

const CARD_COUNT := 3

@onready var _title: Label = $Root/Panel/VBox/Title
@onready var _gold: Label = $Root/Panel/VBox/Gold
@onready var _cards: Array[Button] = [
	$Root/Panel/VBox/Cards/Card0, $Root/Panel/VBox/Cards/Card1, $Root/Panel/VBox/Cards/Card2,
]
@onready var _desc: Array[Label] = [
	$Root/Panel/VBox/Cards/Card0/Name, $Root/Panel/VBox/Cards/Card1/Name, $Root/Panel/VBox/Cards/Card2/Name,
]
@onready var _icons: Array[TextureRect] = [
	$Root/Panel/VBox/Cards/Card0/Icon, $Root/Panel/VBox/Cards/Card1/Icon, $Root/Panel/VBox/Cards/Card2/Icon,
]

var _options: Array = []


func _ready() -> void:
	visible = false
	for i in CARD_COUNT:
		_cards[i].pressed.connect(_on_card_pressed.bind(i))


## 由 Game 调用：pool 是全部未获得的升级，count 是要展示几张
func offer(pool: Array, count: int) -> void:
	_options = _pick(pool, count)
	visible = true
	_gold.text = "持有金币 %d" % RunState.gold
	_refresh_cards()


func _pick(pool: Array, count: int) -> Array:
	var shuffled := pool.duplicate()
	shuffled.shuffle()
	return shuffled.slice(0, mini(count, shuffled.size()))


func _refresh_cards() -> void:
	for i in CARD_COUNT:
		var has := i < _options.size()
		_cards[i].visible = has
		if not has:
			continue
		var d := _options[i] as Dictionary
		_desc[i].text = "%s\n%s" % [String(d.get("name", "")), String(d.get("desc", ""))]
		_icons[i].texture = _icon_for(String(d.get("icon", "")))


## 图标直接由 upgrades.json 的 icon 字段给路径 —— 20 项升级各用各的图，不再轮换重复。
## 素材来源：Kenney Desert Shooter Pack（CC0）的 Interface 图标 + 本工程原有遗物图标。
func _icon_for(path: String) -> Texture2D:
	if path == "" or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


func _on_card_pressed(index: int) -> void:
	if index >= _options.size():
		return
	var d := _options[index] as Dictionary
	var id := String(d.get("id", ""))
	if not RunState.take_upgrade(id):
		return
	EventBus.upgrade_chosen.emit(id)
	EventBus.toast_requested.emit("获得：%s" % String(d.get("name", "")))
	visible = false
	chosen.emit(id)




## 键盘选择：三选一必须选一个才能继续，不允许跳过。
## 数字键 1/2/3 选对应卡片；这条路径不经过 GUI 命中测试，作为鼠标失效时的兜底。
func _unhandled_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var kc := (event as InputEventKey).keycode
	var idx := -1
	if kc == KEY_1 or kc == KEY_KP_1:
		idx = 0
	elif kc == KEY_2 or kc == KEY_KP_2:
		idx = 1
	elif kc == KEY_3 or kc == KEY_KP_3:
		idx = 2
	if idx >= 0:
		if idx < _options.size():
			_on_card_pressed(idx)
		get_viewport().set_input_as_handled()
