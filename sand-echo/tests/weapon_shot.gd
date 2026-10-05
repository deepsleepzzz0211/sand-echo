extends Node
# 武器外观的目视验证：把同一把武器的 4 个 tier 并排画出来，
# 再画一个 4 武器齐备的环形挂载，确认「买了新武器看起来不一样」真的成立。
# 自动断言只能证明贴图换了，证明不了「画出来能分辨」——这一步靠眼睛。

const SHOT_DIR := "user://"


func _ready() -> void:
	await get_tree().process_frame
	_build_tier_strip()
	await _shoot("tier_strip")
	_build_ring_demo()
	await _shoot("ring_demo")
	print("诊断：截图完成")
	get_tree().quit(0)


## 把每把武器的 tier1..4 并排画成一张对照图
func _build_tier_strip() -> void:
	var rows: Array = []
	for entry in RunState.table("weapons"):
		rows.append(entry as Dictionary)

	var Z := 3
	var CW := 24 * Z#每格宽
	var CH := 24 * Z + 22# 每格高（图+ 标签）
	var COLS := 5# tier1..4 + 名称列
	var W := COLS * CW
	var H := rows.size() * CH
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.10, 0.09, 0.13, 1.0))

	var font := ThemeDB.fallback_font
	for r in rows.size():
		var def: Dictionary = rows[r]
		var y := r * CH
		# 左列写武器名
		var name_img := Image.create(90, 16, false, Image.FORMAT_RGBA8)
		name_img.fill(Color(0.16, 0.15, 0.2, 1.0))
		img.blend_rect(name_img, Rect2i(0, 0, 90, 16), Vector2i(2, y + 3))
		for ci in mini(String(def.get("name", "")).length(), 8):
			# 点阵字太麻烦，直接用色块表示名字长度不划算；改为在下方打印文字
			pass
		for t in 4:
			var arr: Array = def.get("sprites", [])
			if t >= arr.size():
				continue
			var path := String(arr[t])
			if not ResourceLoader.exists(path):
				continue
			var tex: Texture2D = load(path)
			var src := tex.get_image()
			if src == null:
				continue
			if src.is_compressed():
				src.decompress()
			src.convert(Image.FORMAT_RGBA8)
			# 最近邻放大 Z 倍
			var big := src.duplicate() as Image
			big.resize(24 * Z, 24 * Z, Image.INTERPOLATE_NEAREST)
			# tier 越高越亮的 tint，与 player.gd 的 WEAPON_TIER_TINT 对齐
			var tint: Color = ([Color(1, 1, 1), Color(1.10, 1.06, 0.92),
					Color(1.18, 1.00, 0.80), Color(1.30, 0.94, 0.62)] as Array)[t]
			big.convert(Image.FORMAT_RGBA8)
			# 手工乘 tint（只作用于 RGB，保留 A）
			for py in big.get_height():
				for px in big.get_width():
					var c := big.get_pixel(px, py)
					if c.a > 0.0:
						big.set_pixel(px, py, Color(
							minf(c.r * tint.r, 1.0), minf(c.g * tint.g, 1.0),
							minf(c.b * tint.b, 1.0), c.a))
			img.blend_rect(big, Rect2i(0, 0, big.get_width(), big.get_height()),
					Vector2i(90 + t * CW, y))
	# 图例行
	print("对照图：每行一把武器，从左到右 tier1 → tier4")
	img.save_png(SHOT_DIR + "weapon_tier_strip.png")
	_print_names(rows)


## 真实玩家 + 4 把武器的环形挂载。
## 刻意不手动摆位置：让 player.gd 自己的 _update_weapon_ring() 去排布，
## 否则测的是我摆的姿势而不是游戏实际跑出来的姿势（上一版就踩了这个坑）。
func _build_ring_demo() -> void:
	RunState.reset_run()
	RunState.weapons = [
		{"id": "w_pistol", "tier": 4, "cd": 0.0},
		{"id": "w_smg", "tier": 1, "cd": 0.0},
		{"id": "w_orb", "tier": 2, "cd": 0.0},
		{"id": "w_hunter", "tier": 3, "cd": 0.0},
	]
	var packed: PackedScene = load("res://scenes/player.tscn")
	var p := packed.instantiate() as CharacterBody2D
	add_child(p)
	p.position = Vector2(450, 350)
	# 让瞄准方向稳定指向右：直接写 aim_dir（它是玩家内部状态）
	for i in 8:
		await get_tree().physics_frame
	var holder := p.get_node("WeaponHolder") as Node2D
	print("环形挂载：%d 把武器" % holder.get_child_count())
	for c in holder.get_children():
		var s := c as Sprite2D
		if s != null:
			print("    枪 @ (%.0f, %.0f) 角度 %.0f° 缩放 %.2f 可见 %s"
				% [s.position.x, s.position.y, rad_to_deg(s.rotation),
				   s.scale.x, str(s.visible)])


func _shoot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png(SHOT_DIR + "wpn_%s.png" % tag)
		print("  截图 wpn_%s.png" % tag)


func _print_names(rows: Array) -> void:
	for r in rows:
		var def: Dictionary = r
		print("    %-11s %s" % [def.get("id", ""), def.get("name", "")])