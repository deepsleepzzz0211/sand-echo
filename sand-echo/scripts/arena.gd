class_name Arena
extends Node2D
# @trace WAVE-001, WAVE-002, ART-001, ART-002, COL-001, LEV-001, LEV-002
# 单屏竞技场（@trace WAVE-001）。取代原来的「随机生长树地牢 + 传送门房间」。
#
# 【为什么换掉房间制】
#  1) 房间制下整间房 1792×928 像素被 1:1 塞进 1920×1080 屏幕，摄像机无缩放，
#     角色只占屏高 2.2%，看起来极小（Brotato 的角色约占屏高 5~6%）。
#  2) 每次过门要在一帧里同步铺 15860 格 tile + 全部墙体碰撞体 = 单帧 58ms（17fps），
#     实测就这一帧把节奏打断；玩家还反馈看到白屏（不在游戏渲染里，是长帧期间的窗口闪烁）。
#  单屏竞技场把这两条从根上消掉：没有过门，就没有切房帧。
#
# 尺寸推导（数值红线，勿随手改）：
#   INTERIOR 52×29 格 × 16px = 832×464 px
#   四周 WALL_THICKNESS 2 格     → 竞技场整体 56×33 格 = 896×528 px
#   Camera2D zoom = 2.0          → 可视范围 960×540 px，完整包住竞技场且留边
#   角色 24px × 2.0 = 48px，占屏高 4.4%（改前是 24px / 2.2%）
signal built()

const TILE := 16
const WALL_THICKNESS := 2
const INTERIOR := Vector2i(52, 29)

var _tile_set_res: TileSet = null
var _wall_cells: Array[Vector2i] = []
var _solid_props: Array[Vector2i] = []
var _rng := RandomNumberGenerator.new()
var _wave: int = 1


func configure(tileset_res: TileSet, seed_value: int, wave: int = 1) -> void:
	_tile_set_res = tileset_res
	_rng.seed = seed_value
	_wave = maxi(1, wave)


## 按波次重建：每波用 wave 作种子重新摆障碍与掩体，让战场逐波变化。
## 只重建地面之上的层，墙与地面不变 —— 重建整场要铺 1500+ 格，没必要。
func rebuild_for_wave(wave: int) -> void:
	_rng.seed = hash("arena_wave_%d" % wave)
	for child in get_children():
		if child.name == "PropsLayer" or child.name == "WallBody":
			remove_child(child)
			child.queue_free()
	await get_tree().process_frame
	_paint_props()
	_build_wall_body()


func build() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	if _tile_set_res == null:
		_tile_set_res = _load_default_tileset()
	_paint_void(_make_layer("VoidLayer", -30))
	_paint_floor(_make_layer("FloorLayer", -20))
	_paint_walls(_make_layer("WallLayer", -10))
	_paint_props()
	_build_wall_body()
	built.emit()


func size_px() -> Vector2:
	return Vector2(INTERIOR + Vector2i(WALL_THICKNESS * 2, WALL_THICKNESS * 2)) * float(TILE)


func center() -> Vector2:
	return size_px() * 0.5


## 玩家可活动范围（不含墙）
func interior_rect() -> Rect2:
	return Rect2(
		Vector2(WALL_THICKNESS, WALL_THICKNESS) * float(TILE),
		Vector2(INTERIOR) * float(TILE))


func player_spawn_position() -> Vector2:
	return center()


## 敌方刷怪点：沿竞技场四周内圈取点，避开贴脸 spawn
func spawn_position(index: int) -> Vector2:
	var r := interior_rect().grow(-TILE * 1.5)
	var a := float(index) * TAU / 12.0 + _rng.randf() * 0.4
	return r.get_center() + Vector2(cos(a), sin(a) * 0.62) * r.size * 0.5


func _make_layer(node_name: String, z: int) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.name = node_name
	layer.tile_set = _tile_set_res
	layer.z_index = z
	layer.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(layer)
	return layer


func _paint_void(layer: TileMapLayer) -> void:
	var total := Vector2i(INTERIOR + Vector2i(WALL_THICKNESS * 2, WALL_THICKNESS * 2)) + Vector2i(8, 8)
	var base := Vector2i(-4, -4)
	var atlas_void := TileIds.atlas(TileIds.VOID)
	for y in total.y:
		for x in total.x:
			layer.set_cell(base + Vector2i(x, y), 0, atlas_void)


func _paint_floor(layer: TileMapLayer) -> void:
	var variants := TileIds.floor_variants()
	var weights := [84, 10, 6]
	for y in INTERIOR.y:
		for x in INTERIOR.x:
			layer.set_cell(Vector2i(x + WALL_THICKNESS, y + WALL_THICKNESS), 0, variants[_weighted(weights)])


func _paint_walls(layer: TileMapLayer) -> void:
	var total := INTERIOR + Vector2i(WALL_THICKNESS * 2, WALL_THICKNESS * 2)
	for y in total.y:
		for x in total.x:
			var at_left := x < WALL_THICKNESS
			var at_right := x >= total.x - WALL_THICKNESS
			var at_top := y < WALL_THICKNESS
			var at_bottom := y >= total.y - WALL_THICKNESS
			if not (at_left or at_right or at_top or at_bottom):
				continue
			layer.set_cell(Vector2i(x, y), 0, _wall_atlas(x, y, total))
			_wall_cells.append(Vector2i(x, y))


func _wall_atlas(x: int, y: int, total: Vector2i) -> Vector2i:
	var at_top := y < WALL_THICKNESS
	var at_bottom := y >= total.y - WALL_THICKNESS
	var at_left := x < WALL_THICKNESS
	var at_right := x >= total.x - WALL_THICKNESS
	if at_top and at_left:
		return TileIds.atlas(TileIds.WALL_TOPLEFT)
	if at_top and at_right:
		return TileIds.atlas(TileIds.WALL_TOPRIGHT)
	if at_bottom and at_left:
		return TileIds.atlas(TileIds.WALL_BOTTOMLEFT)
	if at_bottom and at_right:
		return TileIds.atlas(TileIds.WALL_BOTTOMRIGHT)
	if at_top:
		return TileIds.atlas(TileIds.WALL_TOP)
	if at_bottom:
		return TileIds.atlas(TileIds.WALL_BOTTOM)
	if at_left:
		return TileIds.atlas(TileIds.WALL_LEFT)
	if at_right:
		return TileIds.atlas(TileIds.WALL_RIGHT)
	return TileIds.atlas(TileIds.WALL_FILL)


func _paint_props() -> void:
	var props := _make_layer("PropsLayer", 0)
	var neutral := TileIds.prop_variants()
	var green := TileIds.green_prop_variants()
	var solid := TileIds.solid_prop_variants()
	var weights := [80, 14, 6]
	var taken := _reserved_cells()
	# 密度压低：弹幕游戏里地面必须一眼看清，装饰只做氛围（@trace ART-002）
	# 但掩体（solid）随波次递增：后期战场更碎、走位空间更小
	var solid_chance := clampf(0.06 + 0.012 * float(_wave), 0.06, 0.22)
	for i in int(INTERIOR.x * INTERIOR.y * (0.04 + 0.004 * float(_wave))):
		var cell := Vector2i(_rng.randi_range(WALL_THICKNESS, total_x() - WALL_THICKNESS - 1),
			_rng.randi_range(WALL_THICKNESS, total_y() - WALL_THICKNESS - 1))
		if taken.has(cell):
			continue
		var pool := neutral
		if _rng.randf() < 0.34:
			pool = green
		var is_solid := _rng.randf() < solid_chance
		if is_solid:
			pool = solid
		if pool.is_empty():
			continue
		props.set_cell(cell, 0, pool[_weighted(weights)])
		if is_solid:
			_solid_props.append(cell)


func total_x() -> int:
	return INTERIOR.x + WALL_THICKNESS * 2


func total_y() -> int:
	return INTERIOR.y + WALL_THICKNESS * 2


## 本波的实体障碍格（可打碎的油桶等会落在这里）
func obstacle_cells() -> Array[Vector2i]:
	return _solid_props


## 出生点与场地中心留空，避免装饰压住玩家与刷怪
func _reserved_cells() -> Dictionary:
	var out := {}
	var c := Vector2i(INTERIOR.x / 2, INTERIOR.y / 2)
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			out[Vector2i(c.x + dx + WALL_THICKNESS, c.y + dy + WALL_THICKNESS)] = true
	return out


func _weighted(weights: Array) -> int:
	var total := 0
	for w in weights:
		total += int(w)
	var r := _rng.randi_range(0, maxi(1, total - 1))
	for i in weights.size():
		r -= int(weights[i])
		if r < 0:
			return i
	return 0


func _build_wall_body() -> void:
	var body := StaticBody2D.new()
	body.name = "WallBody"
	body.collision_layer = 1  # world
	body.collision_mask = 0
	add_child(body)
	for cell in _wall_cells:
		_add_box(body, cell)
	for cell in _solid_props:
		_add_box(body, cell)


func _add_box(body: StaticBody2D, cell: Vector2i) -> void:
	var cs := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(TILE, TILE)
	cs.shape = shape
	body.add_child(cs)
	cs.position = (Vector2(cell) + Vector2(0.5, 0.5)) * float(TILE)


func _load_default_tileset() -> TileSet:
	var path := "res://assets/art/tiles/desert_tileset.tres"
	if ResourceLoader.exists(path):
		return load(path) as TileSet
	push_error("竞技场：找不到 TileSet %s" % path)
	return null