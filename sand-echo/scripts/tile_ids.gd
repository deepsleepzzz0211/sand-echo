class_name TileIds
extends RefCounted
# @trace ART-002
# Kenney Desert Shooter 地块索引 → 图集坐标的唯一映射表（@trace ART-002）。
# 图集：assets/art/tiles/desert_tiles.png，18 列 × 13 行，tile 16×16，间距 1px。
# 索引即 Kenney 包内 PNG/Tiles/Tiles/tile_XXXX.png 的 XXXX。
# 生成脚本：tools/gen_resources.py（一次性），改图集列数必须同步改这里与生成脚本。

const ATLAS_COLS := 18

# @trace ART-001
# 沙漠调色板锚点（策划案第 9 章）：UI / 特效 / 清屏色统一从这里取，不在逻辑里裸写色值。
const PALETTE := {
	"sand": Color("#e3c16f"),
	"dune_shadow": Color("#c29b52"),
	"sky": Color("#3a7ca5"),
	"blood": Color("#c0392b"),
	"ember": Color("#f1c40f"),
	"bone": Color("#ede6d6"),
	"void": Color("#161220"),
}

const FLOOR_PLAIN := 64
const FLOOR_DUNE := 173
const FLOOR_PEBBLE := 176
const WALL_TOP := 52
const WALL_BOTTOM := 120
const WALL_LEFT := 87
const WALL_RIGHT := 89
const WALL_TOPLEFT := 51
const WALL_TOPRIGHT := 53
const WALL_BOTTOMLEFT := 104
const WALL_BOTTOMRIGHT := 121
const WALL_FILL := 88
const VOID := 140
const PROP_CORAL := 39
const PROP_CACTUS_A := 62
const PROP_CACTUS_B := 63
const PROP_DEAD_TREE := 75
const PROP_ROCKS := 76
const PROP_BONES := 84
const PROP_SHRUB := 44
const PROP_CRYSTAL := 45
const PROP_PALM := 80
const PROP_CACTUS_C := 81
const PROP_DUNE := 66
const PROP_CRATE_A := 206
const PROP_CRATE_B := 212
const PROP_BARREL := 216
const PROP_PEBBLE := 226
const PROP_CHEST := 229


static func atlas(tile_index: int) -> Vector2i:
	return Vector2i(tile_index % ATLAS_COLS, tile_index / ATLAS_COLS)


static func floor_variants() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for i in [FLOOR_PLAIN, FLOOR_DUNE, FLOOR_PEBBLE]:
		out.append(atlas(i))
	return out


static func prop_variants() -> Array[Vector2i]:
	# 中性色装饰（默认池）：与敌人配色区分，保证弹幕可读
	var out: Array[Vector2i] = []
	for i in [PROP_ROCKS, PROP_BONES, PROP_CRATE_A, PROP_CRATE_B, PROP_BARREL, PROP_PEBBLE, PROP_DUNE, PROP_DEAD_TREE]:
		out.append(atlas(i))
	return out


static func green_prop_variants() -> Array[Vector2i]:
	# 绿植池：只做点缀，低权重使用，避免和绿色系敌人混淆
	var out: Array[Vector2i] = []
	for i in [PROP_SHRUB, PROP_CACTUS_A, PROP_CACTUS_B, PROP_CACTUS_C, PROP_PALM, PROP_CORAL]:
		out.append(atlas(i))
	return out


static func solid_prop_variants() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for i in [PROP_ROCKS, PROP_CRATE_A, PROP_CRATE_B, PROP_BARREL, PROP_CHEST, PROP_CACTUS_A, PROP_CACTUS_B, PROP_CACTUS_C]:
		out.append(atlas(i))
	return out