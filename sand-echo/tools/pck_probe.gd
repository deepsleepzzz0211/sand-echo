extends SceneTree
# 挂载导出的 exe（内嵌 PCK）并列出真实包内容。
#
# 为什么要挂在「空工程」下跑：如果用本工程跑，res://data 里本来就有源文件，
# 列出来的是编辑器侧的东西，等于什么都没验证。空工程里 res:// 的任何文件
# 只可能来自被挂载的包。
#
# 运行：godot_console.exe --headless --path <空工程> --script tools/pck_probe.gd -- <exe路径>

func _init() -> void:
	var exe := ""
	for a in OS.get_cmdline_user_args():
		exe = a
	if exe == "":
		push_error("用法：-- <导出的 exe 路径>")
		quit(1)
		return

	print("挂载：%s" % exe)
	if not ProjectSettings.load_resource_pack(exe):
		print("  [失败] load_resource_pack 返回 false —— 包没挂上")
		quit(1)
		return
	print("  [通过] 包已挂载")
	print("")

	var all: Array[String] = []
	_walk("res://", all)
	all.sort()
	print("包内文件总数：%d" % all.size())
	print("")

	print("=== res://data/（关键：JSON 是否真在包里）===")
	var n := 0
	for f in all:
		if f.begins_with("res://data/"):
			print("  %-44s %9d 字节" % [f, _size(f)])
			n += 1
	if n == 0:
		print("  !! 包里没有任何 data/ 文件 —— 运行时 FileAccess 必然读不到数据表")
	else:
		print("  -> %d 个数据文件已进包" % n)
	print("")

	print("=== 抽查 data/waves.json 能否真的读出内容 ===")
	var f := FileAccess.open("res://data/waves.json", FileAccess.READ)
	if f == null:
		print("  [失败] FileAccess 打开 res://data/waves.json 返回 null")
		print("         -> RunState.read_json 会退回 ResourceLoader；")
		print("         -> 但若包里存的是 .res 形态而非原始 JSON，这里也会失败")
	else:
		var txt := f.get_as_text()
		f.close()
		var parsed: Variant = JSON.parse_string(txt)
		print("  [通过] 读到 %d 字节，JSON 解析=%s" % [txt.length(), "成功" if parsed != null else "失败"])
		if parsed is Dictionary:
			var w: Array = (parsed as Dictionary).get("waves", [])
			var r: Dictionary = (parsed as Dictionary).get("rules", {})
			print("         waves 条目=%d   rules 键=%d" % [w.size(), r.size()])
	print("")

	print("=== res://tests/ docs/ tools/ 是否被 exclude_filter 排除 ===")
	print("  tests 文件数: %d（应为 0）" % _count(all, "res://tests/"))
	print("  docs  文件数: %d（应为 0）" % _count(all, "res://docs/"))
	print("  tools  文件数: %d（应为 0）" % _count(all, "res://tools/"))
	print("")
	print("=== 前 12 条包内文件 ===")
	for one in all.slice(0, 12):
		print("  %s" % one)
	quit(0)


func _walk(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var e := d.get_next()
	while e != "":
		var full: String = dir_path.path_join(e)
		if d.current_is_dir():
			if e != "addons":
				_walk(full, out)
		else:
			out.append(full)
		e = d.get_next()
	d.list_dir_end()


func _count(all: Array[String], prefix: String) -> int:
	var n := 0
	for f in all:
		if f.begins_with(prefix):
			n += 1
	return n


func _size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n