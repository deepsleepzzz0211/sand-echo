extends Node
# 复现并锁定：敌人弹丸视觉参数根本没生效。
#
# 根因：bullet.gd 的 _sprite 是普通 var，在 _ready() 里赋值；
# 而 game 侧的调用顺序是 setup() → add_child()，此时 _ready() 尚未运行，
# _sprite 仍是 null，于是 setup()/set_tier() 里所有
# `if _sprite != null:` 分支全部静默跳过。
# 结果：敌我双方都用 bullet.tscn 里写死的 bullet_player.png 默认贴图、
# modulate 从未设置（纯白）—— 这正是玩家最初报的
# 「敌人的子弹跟角色的子弹一个样式」。
#
# 早先的测试之所以没抓��：测试里是先 add_child() 再 setup()，顺序反了。
# 所以这个测试必须严格复刻 game 侧的真实顺序，否则等于自欺。

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("=== 弹丸视觉生效性（严格按 game 侧调用顺序）===")
	await _audit_real_order()
	_report()


func _ok(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  [通过] " + label)
	else:
		_fail += 1
		print("  [失败] " + label)


## 严格复刻 enemy.gd 的顺序：instantiate → setup → add_child
func _audit_real_order() -> void:
	print("\n-- setup() 先于 add_child() 时视觉是否生效 --")
	var world := Node2D.new()
	add_child(world)

	# --- 敌人弹 ---
	var eb := (load("res://scenes/bullet.tscn") as PackedScene).instantiate() as Node2D
	eb.call("setup", Vector2.LEFT, 5, 1, 0)      # 1 = Owner.ENEMY
	eb.position = Vector2(100, 100)
	world.add_child(eb)                          # ← 之后才进树

	var e_spr := eb.get_node("Sprite") as Sprite2D
	var want_tex: Texture2D = load("res://assets/art/fx/bullet_solo.png")
	print("     敌人弹实际贴图：%s" % e_spr.texture.resource_path.get_file())
	print("     敌人弹实际 modulate：%s" % str(e_spr.modulate))
	_ok(e_spr.texture == want_tex,
		"敌人弹在真实调用顺序下用上了 bullet_solo（实际 %s）"
			% e_spr.texture.resource_path.get_file())
	_ok(absf(e_spr.modulate.r - 1.0) > 0.01 or absf(e_spr.modulate.b - 1.0) > 0.01,
		"敌人弹在真实调用顺序下刷上了阵营色（实际 %s）" % str(e_spr.modulate))

	# --- 玩家弹 + tier ---
	var pb := (load("res://scenes/bullet.tscn") as PackedScene).instantiate() as Node2D
	pb.call("setup", Vector2.RIGHT, 5, 0, 0)    # 0 = Owner.PLAYER
	pb.call("set_tier", 4)
	pb.position = Vector2(200, 100)
	world.add_child(pb)

	var p_spr := pb.get_node("Sprite") as Sprite2D
	print("     玩家弹 T4 实际贴图：%s" % p_spr.texture.resource_path.get_file())
	print("     玩家弹 T4 modulate：%s节点 scale %.2f" % [str(p_spr.modulate), pb.scale.x])
	_ok(p_spr.texture == load("res://assets/art/fx/bullet_warm.png"),
		"玩家弹用上暖色弹丸贴图 bullet_warm（实际 %s）"
			% p_spr.texture.resource_path.get_file())
	_ok(pb.scale.x > 1.3,
		"玩家弹 T4 明显放大（scale %.2f，应> 1.3）" % pb.scale.x)
	_ok(p_spr.modulate.r > 1.0, "T4 比T1 更亮（modulate %s）" % str(p_spr.modulate))
	# 贴图已自带暖色，故 modulate 应接近中性白（若带色相会叠浑）
	_ok(absf(p_spr.modulate.r - p_spr.modulate.b) < 0.06,
		"T4 染色接近中性白、不叠浑（%s）" % str(p_spr.modulate))

	# 敌我贴图与颜色都不同
	_ok(p_spr.texture != e_spr.texture, "真实顺序下敌我贴图不同")
	_ok(absf(p_spr.modulate.r - e_spr.modulate.b) > 0.2,
		"真实顺序下敌我颜色不同（玩家 %s / 敌人 %s）"
			% [str(p_spr.modulate), str(e_spr.modulate)])

	# tier 尺寸阶梯必须单调递增
	var sizes: Array[float] = []
	for t in 4:
		var tb := (load("res://scenes/bullet.tscn") as PackedScene).instantiate() as Node2D
		tb.call("setup", Vector2.RIGHT, 5, 0, 0)
		tb.call("set_tier", t + 1)
		world.add_child(tb)
		sizes.append(tb.scale.x)
		tb.queue_free()
	var mono := true
	for i in range(1, sizes.size()):
		if sizes[i] <= sizes[i - 1]:
			mono = false
	_ok(mono, "T1→T4 尺寸单调递增（%s）" % str(sizes))

	eb.queue_free()
	pb.queue_free()


func _report() -> void:
	print("\n诊断：通过 %d 项，失败 %d 项" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)