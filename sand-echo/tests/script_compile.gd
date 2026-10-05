extends Node
# 全工程脚本编译门禁。
#
# 为什么需要它：`godot --headless --import` 只导入资源、**不编译 .gd**，
# 所以解析错误会被静默跳过。我曾把 game.gd / shop.gd 改到加载失败，
# 却因为 --import 报「无错误」就以为解析通过，直到 wave_smoke 报
# 「竞技场未生成」「商店面板缺失」才暴露 —— 脚本没编译，节点根本没建。
# 这里逐个 load()：load 返回 null 即为编译/解析失败。
#
# 运行：godot_console.exe --headless --path . res://tests/script_compile.tscn

const ROOTS: Array[String] = [
	"res://autoload",
	"res://scripts",
	"res://tests",
	"res://tools",
]

var _bad: Array[String] = []
var _n := 0


func _ready() -> void:
	for r in ROOTS:
		_scan(r)
	if _bad.is_empty():
		print("  [通过] %d 个脚本全部编译通过" % _n)
		get_tree().quit(0)
		return
	for b in _bad:
		print("  [失败] %s 编译不过" % b)
	print("脚本编译门禁：%d / %d 个失败" % [_bad.size(), _n])
	get_tree().quit(1)


func _scan(dir_path: String) -> void:
	var d: DirAccess = DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		var full: String = dir_path.path_join(entry)
		if d.current_is_dir():
			if not entry.begins_with("."):
				_scan(full)
		elif entry.ends_with(".gd"):
			_check(full)
		entry = d.get_next()
	d.list_dir_end()


## 读取 res:// 下的 GDScript 是否编译通过。
##
## 注意：不能只判 load() 是否为 null —— Godot 4.6 在脚本解析失败时
## **仍会返回一个非 null 的 GDScript 对象**（只是处于错误态），
## 判 null 会漏掉。所以必须再用 can_instantiate() 确认它真的可用。
func _check(path: String) -> void:
	_n += 1
	var s: GDScript = ResourceLoader.load(path, "GDScript")
	if s == null or not s.can_instantiate():
		_bad.append(path)