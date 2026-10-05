extends Node
# 字体真实常驻成本：用「加载字体前 / 后」的进程驻留内存差值来回答。
#
# 为什么不在 Godot 内部测：实测把 9.8 MB 的 TTF 加载进来，MEMORY_STATIC 几乎不动，
# 缓存页数还恒为 0 —— 引擎的内部计数并没有如实反映字体开销，
# 所以只能从 OS 视角看进程工作集。
#
# 用法：
#   font_cost.tscn -- --font=off   只起空场景，渲染一个不含中文的标签
#   font_cost.tscn -- --font=on    加载 UI 主题并渲染工程里出现的全部汉字
# 两种情况都空转 IDLE_FRAMES 帧后自行退出，外部按固定间隔采进程工作集。

const FONT_THEME := "res://assets/ui/ui_theme.tres"
## 空转按墙钟计时而不是帧数：不限帧率时 900 帧只有一两秒，采样点不够测平台值
const IDLE_SECONDS := 14.0
const CJK := "[\u4e00-\u9fff]"

var _with_font := true
var _glyph_budget := 0   ## 0 = 只渲染工程里实际出现的汉字；>0 = 额外灌入 N 个字形
var _label: Label


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--font="):
			_with_font = arg.substr(7) == "on"
		if arg.begins_with("--glyphs="):
			_glyph_budget = int(arg.substr(9))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	_label = Label.new()
	_label.position = Vector2(0, 0)
	# 铺满窗口，让滑动窗口里的 400 个字都落在可视区内被真正光栅化
	_label.size = Vector2(1280, 700)
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	get_tree().root.add_child(_label)

	if _with_font:
		var chars := _scan_project_cjk()
		if _glyph_budget > 0:
			chars = _pad_with_supported(chars, _glyph_budget)
		# 用「滑动窗口」而不是 substr(0, i+n)：后者新增的字都排在文本末尾，
		# 落在 Label 可视矩形之外会被裁掉，根本不会进字形缓存 —— 那样测出来的是假的。
		var pos := 0
		while pos < chars.length():
			_label.text = chars.substr(pos, 400)
			await _frames(2)
			pos += 200   # 步长取窗口一半，保证重叠、不会漏字
		_log("FONTMODE=%s 字形数=%d" % [_with_font, chars.length()])
	# 空转到墙钟超时，外部在这段时间里采进程驻留，取平台值
	var deadline := Time.get_ticks_msec() + int(IDLE_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_log("FONTMODE=%s DONE" % _with_font)
	get_tree().quit(0)


## 用字体支持但工程没用到的汉字把字形集补足到 n，用来测「字形缓存的边际成本」
func _pad_with_supported(base: String, n: int) -> String:
	var have := {}
	for i in base.length():
		have[base[i]] = true
	var all := TextServerManager.get_primary_interface()
	var f: FontFile = load(FONT_THEME).default_font
	var rids: Array = f.get_rids()
	if rids.is_empty():
		return base
	var supported := all.font_get_supported_chars(rids[0])
	var out := base
	for i in supported.length():
		if out.length() >= n:
			break
		var c := supported[i]
		if c >= "\u4e00" and c <= "\u9fff" and not have.has(c):
			out += c
	return out


func _log(line: String) -> void:
	print(line)
	var f := FileAccess.open("user://font_cost_%s.log" % ("on" if _with_font else "off"),
		FileAccess.READ_WRITE if FileAccess.file_exists("user://font_cost_%s.log" % ("on" if _with_font else "off")) else FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_line(line)
		f.flush()
		f.close()


func _scan_project_cjk() -> String:
	var re := RegEx.new()
	re.compile(CJK)
	var found := {}
	for dir in ["res://scripts", "res://autoload", "res://scenes", "res://data"]:
		_scan_dir(dir, re, found)
	var out := ""
	for k in found.keys():
		out += str(k)
	return out


func _scan_dir(path: String, re: RegEx, found: Dictionary) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if dir.current_is_dir():
			if not name.begins_with("."):
				_scan_dir(path.path_join(name), re, found)
		elif name.ends_with(".gd") or name.ends_with(".tscn") or name.ends_with(".json"):
			var f := FileAccess.open(path.path_join(name), FileAccess.READ)
			if f != null:
				var text := f.get_as_text()
				f.close()
				for m in re.search_all(text):
					var s := m.get_string()
					for i in s.length():
						found[s[i]] = true
		name = dir.get_next()
	dir.list_dir_end()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame