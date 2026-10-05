extends Node
# @trace AUD-001, AUD-002, AUD-003, FLOW-001
# 音频服务（跨场景常驻的播放服务，不持有关卡状态）。
# AUD-001：12 条音效，取自 Kenney Desert Shooter Pack(CC0)。
# AUD-002：2 条 BGM，取自 OpenGameArt（均 CC0，见 assets/audio/bgm/LICENSE-bgm.txt）。
# 谁写：任何场景调用 play() / play_bgm()；谁读：无；何时清：本节点常驻，播放器池按需回收。

const BANK := {
	"shoot": preload("res://assets/audio/sfx/shoot.ogg"),
	"hit": preload("res://assets/audio/sfx/hit.ogg"),
	"enemy_die": preload("res://assets/audio/sfx/enemy_die.ogg"),
	"boss": preload("res://assets/audio/sfx/boss.ogg"),
	"hurt": preload("res://assets/audio/sfx/hurt.ogg"),
	"pickup": preload("res://assets/audio/sfx/pickup.ogg"),
	"dash": preload("res://assets/audio/sfx/dash.ogg"),
	"death": preload("res://assets/audio/sfx/death.ogg"),
	"ui_select": preload("res://assets/audio/sfx/ui_select.ogg"),
	"ui_move": preload("res://assets/audio/sfx/ui_move.ogg"),
	"error": preload("res://assets/audio/sfx/error.ogg"),
	"fall": preload("res://assets/audio/sfx/fall.ogg"),
}

const BGM := {
	"dungeon": preload("res://assets/audio/bgm/dungeon_loop.ogg"),
	"boss": preload("res://assets/audio/bgm/boss_battle.ogg"),
}

enum BgmMode { NONE, DUNGEON, BOSS }

const POOL_SIZE := 12
const BGM_FADE_SECONDS := 0.8
const BGM_VOLUME_DB := -9.0

var _pool: Array[AudioStreamPlayer] = []
var _next: int = 0
var _muted: bool = false
var _last_played: Dictionary = {}

var _bgm_a: AudioStreamPlayer = null
var _bgm_b: AudioStreamPlayer = null
var _bgm_active: AudioStreamPlayer = null
var _bgm_tween: Tween = null
var _bgm_mode: int = BgmMode.NONE
var _bgm_muted: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_pool.append(p)
	_bgm_a = _make_bgm_player()
	_bgm_b = _make_bgm_player()


func _make_bgm_player() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = "Master"
	p.volume_db = -40.0
	add_child(p)
	return p


func play(sound_id: String, volume_db: float = 0.0, pitch: float = 1.0, min_gap: float = 0.0) -> void:
	if _muted or not BANK.has(sound_id):
		return
	var now := Time.get_ticks_msec() / 1000.0
	if min_gap > 0.0 and now - float(_last_played.get(sound_id, -99.0)) < min_gap:
		return
	_last_played[sound_id] = now
	var player := _pool[_next]
	_next = (_next + 1) % _pool.size()
	player.stream = BANK[sound_id]
	player.volume_db = volume_db
	player.pitch_scale = clampf(pitch, 0.05, 4.0)
	player.play()


# --- BGM -------------------------------------------------------------------

func play_bgm(mode: int) -> void:
	if mode == _bgm_mode:
		return
	_bgm_mode = mode
	if mode == BgmMode.NONE or not BGM.has(_bgm_key(mode)):
		_fade_out_bgm()
		return
	var target: AudioStreamPlayer = _bgm_a if _bgm_active == _bgm_b else _bgm_b
	# 导入产物在导出包里是只读的，复制一份再开 loop，运行时改才不会被覆盖
	var stream: AudioStream = (BGM[_bgm_key(mode)] as AudioStream).duplicate()
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
	target.stream = stream
	target.volume_db = -40.0
	target.play()
	_crossfade_to(target)
	_bgm_active = target


func stop_bgm() -> void:
	play_bgm(BgmMode.NONE)


func set_bgm_muted(value: bool) -> void:
	_bgm_muted = value
	if _bgm_active != null:
		_bgm_active.volume_db = -40.0 if value else BGM_VOLUME_DB


func is_bgm_muted() -> bool:
	return _bgm_muted


func bgm_mode() -> int:
	return _bgm_mode


func _bgm_key(mode: int) -> String:
	match mode:
		BgmMode.DUNGEON:
			return "dungeon"
		BgmMode.BOSS:
			return "boss"
	return ""


func _crossfade_to(target: AudioStreamPlayer) -> void:
	if _bgm_tween != null and _bgm_tween.is_valid():
		_bgm_tween.kill()
	_bgm_tween = create_tween().set_parallel(true)
	_bgm_tween.tween_property(target, "volume_db", -40.0 if _bgm_muted else BGM_VOLUME_DB, BGM_FADE_SECONDS)
	var old := _bgm_active
	if old != null and old != target and old.playing:
		_bgm_tween.tween_property(old, "volume_db", -40.0, BGM_FADE_SECONDS)
		_bgm_tween.chain().tween_callback(old.stop)


func _fade_out_bgm() -> void:
	var old := _bgm_active
	_bgm_active = null
	if old == null or not old.playing:
		return
	if _bgm_tween != null and _bgm_tween.is_valid():
		_bgm_tween.kill()
	_bgm_tween = create_tween()
	_bgm_tween.tween_property(old, "volume_db", -40.0, BGM_FADE_SECONDS)
	_bgm_tween.tween_callback(old.stop)


# --- 总开关 -----------------------------------------------------------------

func set_muted(value: bool) -> void:
	_muted = value
	set_bgm_muted(value)


func is_muted() -> bool:
	return _muted