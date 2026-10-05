extends CanvasLayer
# @trace FLOW-001, FLOW-003, FLOW-004, UI-001, PLAT-002, AUD-003, MECH-009
# 暂停界面（场景跳转）。process_mode = ALWAYS，能在 get_tree().paused 时接收输入。
# 数据入口：Game.setup(game) / set_paused()；数据出口：EventBus + 场景切换。

@onready var _root: Control = $Root
@onready var _stats: Label = $Root/Panel/VBox/Stats
@onready var _resume: Button = $Root/Panel/VBox/Resume
@onready var _restart: Button = $Root/Panel/VBox/Restart
@onready var _mute: Button = $Root/Panel/VBox/Mute
@onready var _bgm_mute: Button = $Root/Panel/VBox/BgmMute

var _game: Node = null
var _paused := false


func setup(game: Node) -> void:
	_game = game


## 切换暂停。Game.toggle_pause() 早就在找这个方法，但它一直不存在，
## 于是 has_method("toggle") 为 false、按ESC 静默无效。
func toggle() -> void:
	set_paused(not _paused)


func set_paused(paused: bool) -> void:
	_paused = paused
	_root.visible = paused
	# 必须真的把场景树停下来：以前只切了界面可见性，游戏在暂停菜单后面照跑，
	# 看起来就像「按了ESC 没反应」。
	get_tree().paused = paused
	# 复位时间缩放：若在顿帧窗口里按下暂停，未完成的 tween 会被暂停冻结，
	# 恢复后 time_scale 永远停在 0.55，整个游戏都是慢动作。
	Engine.time_scale = 1.0
	if paused:
		var mp := get_node_or_null("/root/MetaProgress")
		if mp != null:
			_stats.text = "余烬 %d　　永久升级 Lv.%d　　历史最深层 %d" % [mp.ember, mp.upgrade_level, mp.best_floor]
	_mute.text = "音效：%s" % ("关" if Sfx.is_muted() else "开")
	_bgm_mute.text = "音乐：%s" % ("关" if Sfx.is_bgm_muted() else "开")


## 暂停中的 ESC 解除暂停。
## 必须放在这个 process_mode = ALWAYS 的节点上：Game 把自己 pause 之后
## 就收不到 _unhandled_input 了，解除暂停这一半它天然接不到。
func _unhandled_input(event: InputEvent) -> void:
	if not _paused:
		return
	if event.is_action_pressed("ui_cancel"):
		toggle()
		get_viewport().set_input_as_handled()


func _ready() -> void:
	_resume.pressed.connect(_on_resume)
	_restart.pressed.connect(_on_restart)
	_mute.pressed.connect(_on_mute)
	_bgm_mute.pressed.connect(_on_bgm_mute)


func _on_resume() -> void:
	Sfx.play("ui_select", -10.0, 1.0, 0.0)
	if _game != null and _game.has_method("toggle_pause"):
		_game.toggle_pause()


func _on_restart() -> void:
	Sfx.play("ui_select", -10.0, 0.9, 0.0)
	get_tree().paused = false
	Engine.time_scale = 1.0
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_mute() -> void:
	Sfx.set_muted(not Sfx.is_muted())
	_mute.text = "音效：%s" % ("关" if Sfx.is_muted() else "开")


func _on_bgm_mute() -> void:
	Sfx.set_bgm_muted(not Sfx.is_bgm_muted())
	_bgm_mute.text = "音乐：%s" % ("关" if Sfx.is_bgm_muted() else "开")
