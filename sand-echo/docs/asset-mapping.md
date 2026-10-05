# 素材映射表（Kenney Desert Shooter Pack → 工程资源）

> 素材包：**Kenney Desert Shooter Pack 1.0**（CC0 / Public Domain），原始压缩包 `kenney_desert-shooter-pack_1.0.zip`。
> 许可：CC0 1.0，允许商用与修改，本作仅做署名。原始许可全文见 `assets/art/LICENSE-kenney.txt`。
> 生成脚本：`_tools/gen_resources.py`（一次性生成 TileSet / SpriteFrames，改图集列数时必须同步 `scripts/tile_ids.gd`）。

---

## 1. 为什么这样切素材

| 素材包内容 | 规格 | 本作用途 |
|---|---|---|
| `PNG/Tiles/Tilemap/tilemap.png` | 305×220，18 列 × 13 行，tile 16×16，**间距 1px** | 唯一的地块图集，生成 `desert_tileset.tres` |
| `PNG/Players/Tiles/*.png` | 24×24，已拆帧 | 玩家（`player_1..4`）与备用敌对角色（`rival_1..4`，当前未用） |
| `PNG/Enemies/Tiles/*.png` | 24×24，已拆帧，每行一种敌人：3 帧待机 + 1 帧倒地 | 4 种敌人 |
| `PNG/Weapons/Tiles/*.png` | 24×24 | 弹丸、枪口、命中火花 |
| `PNG/Interface/Tiles/*.png` | 16×16 | HUD 图标与面板 |
| `Sounds/*.ogg` | 8-bit | 12 条音效 |

**图集间距**：Kenney 的 `tilemap.png` 每格之间有 1px 空隙，TileSet 必须声明 `separation = Vector2i(1,1)`，否则整张图会错位抽帧。
**图集形状**：`tile_shape` 必须是 0（正方形）。曾经误设成 1（半偏移）导致竖直方向每格只画 8px，整间房被压扁一半——已修复并写入 `gen_resources.py`。

---

## 2. 地块索引 → 玩法用途

索引即素材包里 `PNG/Tiles/Tiles/tile_XXXX.png` 的 `XXXX`；图集坐标 = `(XXXX % 18, XXXX / 18)`。

| 索引 | 用途 | 工程常量 | 说明 |
|---|---|---|---|
| 64 / 173 / 176 | 沙地（权重 84 / 10 / 6） | `FLOOR_PLAIN` `FLOOR_DUNE` `FLOOR_PEBBLE` | 纯沙地，可无缝平铺 |
| 51 / 52 / 53 | 墙：上边 / 上中 / 右上 | `WALL_TOPLEFT` `WALL_TOP` `WALL_TOPRIGHT` | 九宫格墙体 |
| 87 / 88 / 89 | 墙：左边 / 中间 / 右边 | `WALL_LEFT` `WALL_FILL` `WALL_RIGHT` | |
| 104 / 120 / 121 | 墙：下左 / 下中 / 下右 | `WALL_BOTTOMLEFT` `WALL_BOTTOM` `WALL_BOTTOMRIGHT` | |
| 140 | 房间外虚空 | `VOID` | |
| 76 / 206 / 212 / 216 / 229 / 62 / 63 / 81 | 障碍物（带碰撞） | `solid_prop_variants()` | 岩堆、木箱、油桶、宝箱、仙人掌 |
| 76 / 84 / 206 / 212 / 216 / 226 / 66 / 75 | 装饰（无碰撞） | `prop_variants()` | 中性色为主 |
| 39 / 44 / 62 / 63 / 80 / 81 | 绿植点缀（低权重 22%） | `green_prop_variants()` | 刻意压低，避免和绿色系敌人混淆 |
| 60 | 药水图标 | `assets/art/pickups/potion.png` | |
| 45 / 57 / 59 / 75 / 80 / 81 / 44 / 62 | 遗物图标 ×8 | `assets/art/pickups/relic_icon_1..8.png` | |

### 房间布局口径

```
内部可玩区 112 × 58 tile
墙厚      2 tile
整间      116 × 62 tile = 1856 × 992 px   ← 单屏容纳（1920×1080 视口，固定正交相机）
```

密度参数（`DungeonRoom._paint_props`）：`密度 = 0.013 + 0.002 × 楼层`，其中 25% 的装饰带碰撞。
出生点与四条门口通道各留空 5 格，避免生成物堵死移动与刷怪。

---

## 3. 角色帧

| 素材包位置 | 工程文件 | 动画 |
|---|---|---|
| `Players/tile_0000..0003` | `assets/art/actors/player_1..4.png` → `player_frames.tres` | `idle`(1,2) / `move`(1,2,3) / `shoot`(3) / `dead`(4) |
| `Enemies/tile_0000..0003` | `enemy_chaser_1..4.png` → `enemy_chaser_frames.tres` | 沙蜥 `e_chaser`（追击） |
| `Enemies/tile_0004..0007` | `enemy_shooter_1..4.png` → `enemy_shooter_frames.tres` | 喷沙者 `e_burst`（环绕 + 5 向散射） |
| `Enemies/tile_0008..0011` | `enemy_burst_1..4.png` → `enemy_burst_frames.tres` | 沙炮手 `e_shooter`（拉开距离 + 单发） |
| `Enemies/tile_0012..0015` | `enemy_boss_1..4.png` → `enemy_boss_frames.tres` | Boss「沙之王·图勒」（scale 2.0 + 12 向环射） |

> 注意：`enemy_shooter` / `enemy_burst` 两组文件名与玩法角色是**交叉**的（素材第 2 行是紫褐色怪、策划案里当作「喷沙者」用），映射以本表为准，不要按文件名直觉改。

朝向：素材是 3/4 视角俯视，只做**左右翻转**（`Sprite2D.flip_h`），不做 4 向旋转——这是刻意的取舍，避免拉伸变形。

---

## 4. 特效与 UI

| 工程文件 | 素材包位置 | 用途 |
|---|---|---|
| `assets/art/fx/bullet_player.png` | `Weapons/tile_0023` | 玩家弹丸 |
| `assets/art/fx/bullet_enemy.png` | `Weapons/tile_0034` | 敌弹 |
| `assets/art/fx/muzzle_flash.png` | `Weapons/tile_0025` | 枪口闪光 |
| `assets/art/fx/hit_spark.png` | `Weapons/tile_0027` | 命中火花 |
| `assets/art/fx/gun_orange.png` | `Weapons/tile_0005` | 预留（枪械表现，当前未接） |
| `assets/art/ui/icon_skull.png` | `Interface/tile_0054` | HP 条图标 |
| `assets/art/ui/icon_coin.png` | `Interface/tile_0058` | 金币图标 |
| `assets/art/ui/icon_heart.png` | `Interface/tile_0077` | 预留 |
| `assets/art/ui/badge_alert.png` | `Interface/tile_0060` | 预留 |
| `assets/art/ui/bar_fill.png` / `bar_fill_blue.png` | `Interface/tile_0140` / `0193` | 预留条形图 |
| `assets/art/ui/panel_orange.png` / `panel_purple.png` | `Interface/tile_0079` / `0083` | 16×16 太小，做九宫格拉伸会撕裂，改用 `assets/ui/panel_frame.tres`（StyleBoxFlat） |

### 音效映射

| 工程 id | 素材包文件 | 触发点 |
|---|---|---|
| `shoot` | `shoot-a.ogg` | 玩家射击（冷却 20ms 去重）、敌人开火 |
| `hit` | `explosion-a.ogg` | 敌人受击 |
| `enemy_die` | `explosion-b.ogg` | 敌人死亡 |
| `boss` | `explosion-c.ogg` | Boss 登场 |
| `hurt` | `hurt-a.ogg` | 玩家受伤 |
| `pickup` | `coin-a.ogg` | 拾取遗物 / 药水 / 房间清空 |
| `dash` | `jump-a.ogg` | 闪避 |
| `death` | `lose-a.ogg` | 玩家死亡 |
| `ui_select` | `select-a.ogg` | 菜单确认 / 暂停 |
| `ui_move` | `move-a.ogg` | 换房 / 菜单移动 |
| `error` | `error-a.ogg` | 元进度余烬不足 |
| `fall` | `fall-a.ogg` | 预留 |

---

## 5. 背景音乐（后补，非 Kenney 素材包）

Kenney Desert Shooter Pack 不含音乐，BGM 从 OpenGameArt 单独取，均为 **CC0 1.0**，可商用、无需署名。详见 `assets/audio/bgm/LICENSE-bgm.txt`。

| 工程文件 | 原曲 | 作者 | 协议 | 时长 | 处理 |
|---|---|---|---|---|---|
| `assets/audio/bgm/dungeon_loop.ogg` | [Desert Theme - 8bit Chiptune Theme](https://opengameart.org/content/desert-theme-8bit-chiptune-theme) | Wolfgang_ (Ted Kerr) | CC0 | 39.7s | 原 wav 转 Vorbis q3，**保持单声道**（保留 Famitracker 原始质感） |
| `assets/audio/bgm/boss_battle.ogg` | [Great Boss](https://opengameart.org/content/great-boss) | Spring Spring | CC0 | 111.0s | 转 Vorbis q3 立体声 |

**为什么是这两首**：Desert Theme 的 OGA 标签直接是 `desert` · `Pyramids` · `sand`，40 秒长度能在单局 15–25 分钟里循环 20 遍不腻；Great Boss 是站上该站 Boss 曲下载榜首的 CC0 作品，源文件本就是 ogg，Godot 可直接吃。

**接入方式**（`autoload/sfx.gd`）：两个常驻 `AudioStreamPlayer` 交叉淡入淡出 0.8s，`EventBus.boss_spawned` 切 Boss 曲，击败 Boss / 死亡时淡出。循环开关在运行时对 `stream.duplicate()` 设 `loop = true`——导入产物在导出包里是只读的，复制一份再设才不会在导出后失效。暂停界面可分别静音音效与音乐。

> 备选池（同样是 CC0）：[8-bit - Perilous Dungeon](https://opengameart.org/content/8-bit-perilous-dungeon)（作者明说无缝循环、适配射击）、[8-Bit Cave Loop](https://opengameart.org/content/8-bit-cave-loop)（更压抑，深层替换用）。
>
> ⚠️ 明确排除：Egyptian Fortress Boss——页面 License 字段为空，同作者虽在另一曲评论区提过 CC0，但页面未标注就不能算数。

## 6. 中文字体（后补）

| 项 | 值 |
|---|---|
| 字体 | [方舟像素字体 / Ark Pixel Font](https://github.com/TakWolf/ark-pixel-font) 12px 比例版 zh_hans |
| 协议 | **SIL Open Font License 1.1** —— 免费、可商用、可嵌入分发，只需保留 OFL 声明 |
| 字号 | **12px**（注意：官方已废弃 16px，最后含 16px 的版本为 `2026.09.01`） |
| 文件 | `assets/ui/fonts/ark-pixel-12px-proportional-zh_hans.ttf`（4.9 MB）+ `OFL.txt` |
| 接入 | `assets/ui/ui_theme.tres` 的 `default_font`，全工程只改这一个 `.tres` |

**两个必须知道的坑**：

1. **导入设置要关抗锯齿**。Godot 默认给动态字体 `antialiasing=Grayscale` + `hinting=Light`，会把 12px 像素字糊掉。工程改的是 Godot 生成的 `.ttf.import` 里的 `[params]`：`antialiasing=0`（None）、`hinting=0`（None）、`subpixel_positioning=1`（IntegerOnly）。
2. **字号一律取 12 的整数倍**（12 / 24 / 36 / 48 / 72）。非整数倍会让像素落在半格上，出现虚边。全工程已统一：16 处 24px、2 处 36px、2 处 48px、1 处 72px。

> 备选：[缝合像素字体 / Fusion Pixel Font](https://github.com/TakWolf/fusion-pixel-font)（同作者 OFL-1.1，8/10/12px）。Ark Pixel README 明确建议 **10px 和 12px 缺字时改用 Fusion Pixel**，两者是配套的。
>
> ⚠️ 排掉 **Zpix（最像素）**：社区常推荐，但它是**收费**的——商业产品单个 ￥7000 / USD $1000，仅教育与个人项目免费，且禁止修改/反编译/转换/拆分。

## 7. 剩余已知缺口

| 缺口 | 现状 | 补法 | 关联条目 |
|---|---|---|---|
| **遗物图标语义化** | 8 张遗物图标按索引轮换，与具体遗物无强绑定 | 为 12 种遗物各画一张 16×16 图标 | `MECH-004` |
| **枪械朝向表现** | 玩家不随瞄准角旋转，只有左右翻转 | 接入 `assets/art/fx/gun_orange.png` 做独立旋转的枪口节点 | `ART-002` |
| **面板九宫格** | 16×16 的 UI 面板拉伸会撕裂，改用 StyleBoxFlat | 切到 32×32 以上的面板图 | `ART-002` |
| **运行时内存峰值** | 只测了静态资源，运行时未用 `--verbose` 取 ObjectDB 统计 | 性能监视器 + `--verbose` 跑一局 | `PLAT-003` |

---

## 8. 预算实测

| 项 | 实测 | 预算 | 结论 |
|---|---|---|---|
| 贴图未压缩字节 | **344.4 KB**（47 张 PNG，含 262 KB 的地块图集） | 256 MB（策划案第 4 章） | 差 3 个数量级，无压力 |
| 脚本口径估算 | 0.5 MB（× 1.33 渐远系数） | 8 MB（`docs/asset-manifest.json`） | 通过 |
| 音效 + BGM | 1.49 MB（12 条音效 118 KB + 2 条 BGM 1.45 MB） | 64 MB | 通过 |
| 中文字体 | 9.8 MB（zh_hans + latin 两个 ttf） | 未单列 | 见下 |
| 仓库总体积 | **11.64 MB**（不含 `.godot/`） | 200 MB 首包 | 通过 |

字体占了仓库体积的 84%，但它是**纯文本轮廓**，Godot 导入后按需光栅化字形缓存，真正常驻内存只跟「界面实际用到的字符」走，不是 9.8 MB 全量。

`docs/asset-manifest.json` 把 8 MB 定为本工程的贴图预算（远低于策划案的 256 MB 上限），这样一旦有人误放大图能立刻被门禁拦下。