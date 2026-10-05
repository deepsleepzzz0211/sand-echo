extends Node
# 敌我弹道可辨性测试。
#
# 起因：玩家反馈「敌人的子弹跟角色的子弹一个样式」。查下来确实是真问题——
# bullet_enemy 与 bullet_player 的主色都是纯白 255,255,255，缩到屏幕尺寸后
# 都退化成一个白点；敌弹那张还是「四向散射」图案，语义上不是一颗子弹。
# 弹幕游戏里「敌我弹道一眼可辨」是可读性底线，所以单独立一条门禁。

var _pass := 0
var _fail := 0


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	print("=== 敌我弹道可辨性审计 ===")
	_audit_color_distance()
	_audit_shape()
	await _audit_runtime()
	await _shoot()
	_report()


func _ok(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  [通过] " + label)
	else:
		_fail += 1
		print("  [失败] " + label)


## 敌我弹丸的显示色必须在感知上明显不同
func _audit_color_distance() -> void:
	print("\n-- 敌我配色 --")
	var B := preload("res://scripts/bullet.gd")
	var pc: Color = B.COLOR_PLAYER
	var ec: Color = B.COLOR_ENEMY
	print("     玩家 %s   敌人 %s" % [str(pc), str(ec)])
	# 感知亮度差异（Rec.709）
	var lp := 0.2126 * pc.r + 0.7152 * pc.g + 0.0722 * pc.b
	var le := 0.2126 * ec.r + 0.7152 * ec.g + 0.0722 * ec.b
	_ok(lp != le, "敌我亮度不同（玩家 %.2f / 敌人 %.2f）" % [lp, le])
	# 饱和度方向相反：玩家偏暖（红>蓝），敌人偏冷/品红（蓝>绿）
	_ok(pc.r > pc.b, "玩家弹偏暖色（红 %.2f > 蓝 %.2f）" % [pc.r, pc.b])
	_ok(ec.b > ec.g, "敌人弹偏品红/冷色（蓝 %.2f > 绿 %.2f）" % [ec.b, ec.g])
	_ok(pc.r - pc.b > 0.3 and ec.b - ec.g > 0.2,
		"敌我色相方向相反，肉眼不会混淆")


## 敌人弹丸不该是散射图案
func _audit_shape() -> void:
	print("\n-- 弹丸形状 --")
	var solo: Texture2D = preload("res://assets/art/fx/bullet_solo.png")
	_ok(solo != null, "存在单颗弹丸贴图 bullet_solo.png")
	var img := solo.get_image()
	if img.is_compressed():
		img.decompress()
	var opaque := 0
	var xs := 0
	var xmin := 999
	var xmax := -1
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.1:
				opaque += 1
				xmin = mini(xmin, x)
				xmax = maxi(xmax, x)
	xs = xmax - xmin + 1
	_ok(opaque > 0, "弹丸贴图非空（%d 个不透明像素）" % opaque)
	# 单颗子弹应当是紧凑小团；若宽高都接近 20 则说明是散射图案
	var w := xmax - xmin + 1
	_ok(w <= 8, "弹丸横向宽度 %d px（散射图案会是 18~20 px）" % w)


## 运行时：实际生成两种弹丸，确认贴图与颜色都对
func _audit_runtime() -> void:
	print("\n-- 运行时实际表现 --")
	var world := Node2D.new()
	add_child(world)

	var pb := _make(world, Vector2(120, 120), Vector2.RIGHT, 0)
	var eb := _make(world, Vector2(240, 120), Vector2.LEFT, 1)

	_ok(pb.get("_sprite").texture != null, "玩家弹丸有贴图")
	_ok(eb.get("_sprite").texture != null, "敌人弹丸有贴图")
	_ok(pb.get("_sprite").texture != eb.get("_sprite").texture,
		"敌我贴图不同（玩家 %s / 敌人 %s）"
			% [pb.get("_sprite").texture.resource_path.get_file(),
			   eb.get("_sprite").texture.resource_path.get_file()])

	var pc: Color = pb.get("_sprite").modulate
	var ec: Color = eb.get("_sprite").modulate
	print("     运行时玩家 modulate=%s敌人 modulate=%s" % [str(pc), str(ec)])
	_ok(absf(pc.r - ec.r) > 0.05 or absf(pc.g - ec.g) > 0.05 or absf(pc.b - ec.b) > 0.05,
		"运行时敌我颜色不同")

	# set_tier 不能把阵营色冲掉
	pb.call("set_tier", 4)
	var after: Color = pb.get("_sprite").modulate
	_ok(after.r > after.b,
		"玩家弹设tier4 后仍偏暖（红 %.2f > 蓝 %.2f）——set_tier 没冲掉阵营色"
			% [after.r, after.b])
	_ok(after.r >= 0.9, "tier 提亮后亮度未塌陷（红 %.2f）" % after.r)

	pb.queue_free()
	eb.queue_free()


## 严格复刻 game 侧顺序：instantiate → setup/set_tier → add_child。
## 早先这个辅助是先 add_child 再 setup，顺序反了，把「setup 里视觉赋值
## 因 _sprite 为 null 而静默跳过」这个 bug 一起盖住了 —— 测试自己骗了自己。
func _make(parent: Node, pos: Vector2, dir: Vector2, kind: int) -> Node:
	var packed: PackedScene = load("res://scenes/bullet.tscn")
	var b := packed.instantiate()
	b.set("lifetime", 99.0)
	b.call("setup", dir, 5, kind, 0)
	b.position = pos
	parent.add_child(b)
	return b


## 出图目视确认：敌我弹丸摆在沙地色背景上。
## 必须按 1920x1080 视口出图：工程视口就是 1920x1080，用小窗口会被整体压缩，
## 6x6 的弹丸会缩成 2px，看不出颜色对不对。
func _shoot() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.24, 0.20, 0.14)
	bg.size = Vector2(1760, 520)
	bg.position = Vector2(80, 280)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var world := Node2D.new()
	add_child(world)
	var label := Label.new()
	label.text = "玩家弹 T1→T4（上排，黄）　　敌人弹（下排，品红）"
	label.position = Vector2(90, 240)
	add_child(label)

	# 上排：玩家弹四个等级；下排：敌人弹三发
	for i in 4:
		var packed: PackedScene = load("res://scenes/bullet.tscn")
		var b := packed.instantiate()
		b.set("lifetime", 99.0)
		b.call("setup", Vector2.RIGHT, 5, 0, 0)
		b.call("set_tier", i + 1)
		b.position = Vector2(400 + i * 320, 440)
		world.add_child(b)
	for i in 3:
		_make(world, Vector2(400 + i * 320, 660), Vector2.LEFT, 1)
	for i in 3:
		await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("user://bullet_faction.png")
		print("  已保存 bullet_faction.png")


func _report() -> void:
	print("\n诊断：通过 %d 项，失败 %d 项" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)