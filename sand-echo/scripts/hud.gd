extends CanvasLayer
# @trace UI-001, SIG-001, ART-002, UI-003
# 游戏内 HUD。只读 RunState / EventBus，不反向写状态。
# 节点树：见 scenes/hud.tscn（全部节点在场景里声明，脚本只连信号与更新文本）。
# 反反模式：不在 _process 里做字符串拼接以外的分配；数值变化才更新。

@onready var _hp_bar: ProgressBar = $Root/TopLeft/VBox/HpRow/HpBar
@onready var _hp_text: Label = $Root/TopLeft/VBox/HpRow/HpText
@onready var _alert: TextureRect = $Root/TopLeft/VBox/HpRow/Alert
@onready var _gold_bar: ProgressBar = $Root/TopLeft/VBox/GoldRow/GoldBar
@onready var _gold_text: Label = $Root/TopLeft/VBox/GoldRow/GoldText
@onready var _wave_text: Label = $Root/TopRight/WaveText
@onready var _alive_text: Label = $Root/TopRight/AliveText
@onready var _toast: Label = $Root/Toast
@onready var _boss_bar: ProgressBar = $Root/BossBar
@onready var _dash_bar: ProgressBar = $Root/DashBar

const GOLD_BAR_FULL := 200
const TOAST_SECONDS := 2.4

var _toast_left: float = 0.0
var _boss_ref: Enemy = null


func _ready() -> void:
	_hp_bar.max_value = 1
	_gold_bar.max_value = float(GOLD_BAR_FULL)
	_dash_bar.max_value = RunState.DASH_CD
	RunState.health_changed.connect(_on_health_changed)
	RunState.gold_changed.connect(_on_gold_changed)
	RunState.wave_changed.connect(_on_wave_changed)
	EventBus.wave_started.connect(_on_wave_started)
	EventBus.toast_requested.connect(_on_toast)
	EventBus.boss_spawned.connect(_on_boss_spawned)
	EventBus.enemy_killed.connect(_on_enemy_killed)
	_on_health_changed(RunState.health, RunState.max_health)
	_on_gold_changed(RunState.gold)
	_on_wave_changed(RunState.wave_num)




func _on_health_changed(current: int, maximum: int) -> void:
	_hp_bar.max_value = maxi(1, maximum)
	_hp_bar.value = current
	_hp_text.text = "%d / %d" % [current, maximum]
	_update_alert(current, maximum)


## 低血告警：低于 30% 时闪 badge_alert（素材审计里的闲置项）。
## 血量是弹幕游戏最重要的信息，不能只靠数字，玩家要能余光看到。
func _update_alert(current: int, maximum: int) -> void:
	if _alert == null:
		return
	var low := maximum > 0 and float(current) / float(maximum) <= 0.3
	_alert.visible = low
	_alert.modulate.a = 1.0 if (low and int(low_t) % 2 == 0) else (0.35 if low else 0.0)


var low_t: float = 0.0


func _process(delta: float) -> void:
	low_t += delta
	if _alert != null and _alert.visible:
		_update_alert(RunState.health, RunState.max_health)
	if _toast_left > 0.0:
		_toast_left = maxf(0.0, _toast_left - delta)
		if _toast_left <= 0.0:
			_toast.text = ""


func _on_gold_changed(value: int) -> void:
	_gold_bar.value = mini(float(value), float(GOLD_BAR_FULL))
	_gold_text.text = str(value)


func _on_wave_changed(value: int) -> void:
	_wave_text.text = "第 %d 波" % value


func _on_wave_started(_wave: int, is_boss: bool) -> void:
	_alive_text.text = "BOSS 波" if is_boss else "敌人生成中"
	EventBus.toast_requested.emit("第 %d 波开始" % _wave)


func _on_toast(text: String) -> void:
	_toast.text = text
	_toast_left = TOAST_SECONDS


func _on_boss_spawned(_boss_name: String) -> void:
	_boss_bar.visible = true
	_boss_bar.value = 100.0


func _on_enemy_killed(enemy_id: String, _gold: int) -> void:
	if enemy_id == "boss":
		_boss_bar.visible = false


func bind_dash_ratio(ratio: float) -> void:
	_dash_bar.value = clampf(ratio, 0.0, 1.0) * RunState.DASH_CD