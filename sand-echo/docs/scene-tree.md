# 场景清单与节点树

> 口径：Godot **4.6**（实测 4.6.2.stable.official）。一条场景一句话职责，出现「并且」就拆。
> 所有 UI 节点在 `.tscn` 里声明，脚本只做初始化与信号连接——不在 `_ready` 里现搭 UI。

## 1. 场景清单

| 场景 | 职责（一句话） | 根节点类 | 可复用 | 谁实例化 | 数据入口 | 数据出口 |
|---|---|---|---|---|---|---|
| `main_menu.tscn` | 展示元进度并发起新一局 | `Control` | 否 | 引擎主场景 | `MetaProgress` 存档 | `EventBus.run_started` + 场景切换 |
| `game.tscn` | 调度房间、结算战斗、编排表现层节流 | `Node2D` | 否 | MainMenu | `RunState` / `data/*.json` | `EventBus.run_ended` |
| `room.tscn` | 把一个房间画出来并给出碰撞与门口触发区 | `Node2D`(`DungeonRoom`) | **是**（每房一个） | Game | `Dungeon.get_room()` + TileSet | `door_entered(dir)` |
| `player.tscn` | 玩家角色的移动/瞄准/射击/闪避 | `CharacterBody2D`(`Player`) | 是 | Game | `RunState` 属性、`arena` 矩形 | `RunState` 信号 + `EventBus` |
| `enemy.tscn` | 一种敌人的 AI 与受击结算 | `CharacterBody2D`(`Enemy`) | 是（换 SpriteFrames） | Game | `setup(data/enemies.json 条目)` | `died(enemy_id, gold)` |
| `bullet.tscn` | 一颗弹丸的飞行与命中判定 | `Area2D`(`Bullet`) | 是 | Player / Enemy | `setup(方向, 伤害, 阵营, 穿透)` | `hit_target(area, dmg)` |
| `hurtbox.tscn`（内嵌于 player/enemy） | 把命中事件转交给本体 | `Area2D`(`Hurtbox`) | 是 | 场景内嵌 | 弹丸调用 `apply_hit()` | `hit_taken` / `contact_made` |
| `relic.tscn` | 一件遗物的拾取物 | `Area2D`(`Relic`) | 是 | Game | `setup(relic 定义, 图标序号)` | `picked(relic_id)` |
| `potion.tscn` | 一瓶药水的拾取物 | `Area2D`(`Potion`) | 是 | Game | `setup(回复量)` | `consumed(heal)` |
| `hud.tscn` | 局内信息显示 | `CanvasLayer` | 否 | Game | `RunState` 信号 / `EventBus` | 无（只读） |
| `pause_menu.tscn` | 暂停与放弃本局 | `CanvasLayer` | 否 | Game | `set_paused(bool)` | 场景切换 |
| `death_screen.tscn` | 死亡结算与余烬入账 | `CanvasLayer` | 否 | Game | `show_summary(ember, summary)` | 场景切换 |
| `fx_spark.gd`（纯脚本） | 命中火花 | `Node2D` | 是 | Game / Enemy | 位置 | 无 |
| `fx_popup.gd`（纯脚本） | 数值上浮 | `Node2D`(`FxPopup`) | 是 | Game | 文本 + 颜色 | 无 |

## 2. 节点树

### Game（`scenes/game.tscn`）

```
Game (Node2D)                       scripts/game.gd
├─ World (Node2D)                   当前房间与所有实体（房间切换时整体清理）
│  ├─ Room (Node2D)                ← room.tscn，运行时填充
│  ├─ Player (CharacterBody2D)     ← player.tscn（跨房间保留，只重定位）
│  ├─ Enemy ×N (CharacterBody2D)   ← enemy.tscn
│  ├─ Bullet ×M (Area2D)           ← bullet.tscn
│  └─ Relic / Potion (Area2D)
├─ Camera2D                         固定正交相机，落在房间中心
├─ Hud (CanvasLayer)               ← hud.tscn
├─ PauseMenu (CanvasLayer)         ← pause_menu.tscn
└─ DeathScreen (CanvasLayer)       ← death_screen.tscn
```

层级最深 3 层；`Room` 的子层（TileMapLayer ×4 + StaticBody2D + Doors）由 `DungeonRoom.build()` 运行时生成，见 `scripts/dungeon_room.gd` 头部注释。

### Player（`scenes/player.tscn`）

```
Player (CharacterBody2D)  layer=player(2)  mask=world|enemy
├─ Sprite (AnimatedSprite2D)   player_frames.tres，flip_h 跟随瞄准左右
└─ Hurtbox (Area2D)            layer=player(2)  mask=0  monitoring=false
   └─ Shape (CollisionShape2D) CircleShape2D r=11
```

### Enemy（`scenes/enemy.tscn`）

```
Enemy (CharacterBody2D)   layer=enemy(4)  mask=world|player|enemy
├─ Sprite (AnimatedSprite2D)   帧集按 enemy_id 在 setup() 时替换
└─ Hurtbox (Area2D)        layer=enemy(4)  mask=player(2)
   └─ Shape (CollisionShape2D) CircleShape2D r=13
```

### Room（`scenes/room.tscn`，运行时构建）

```
Room (Node2D)  scripts/dungeon_room.gd
├─ VoidLayer  (TileMapLayer) z=-30   124×70 格
├─ FloorLayer (TileMapLayer) z=-20   112×58 格
├─ WallLayer  (TileMapLayer) z=-10   116×62 格（门口处挖空 3 格）
├─ PropsLayer (TileMapLayer) z=0     装饰 + 障碍
├─ WallBody   (StaticBody2D) layer=world(1)
│  └─ CollisionShape2D ×N            每格一个矩形（墙 + 障碍物）
└─ Doors (Node2D)
   └─ Door_N / Door_E / Door_S / Door_W (Area2D) layer=door  mask=player
```

## 3. 碰撞层（`project.godot [layer_names]`）

| 层号 | 名称 | 谁在用 | 谁关心它 |
|---|---|---|---|
| 1 | `world` | 墙体、障碍物 StaticBody2D | Player / Enemy 的移动碰撞 |
| 2 | `player` | Player 本体、Player Hurtbox | 敌弹、拾取物 |
| 3 | `enemy` | Enemy 本体、Enemy Hurtbox | 玩家弹丸 |
| 4 | `player_bullet` | 玩家弹丸 | — |
| 5 | `enemy_bullet` | 敌人弹丸 | — |
| 6 | `pickup` | 遗物 / 药水 | Player |
| （7） | `door` | 门口触发区 | Player |

约定：**代码只写层语义、不裸写数字**——所有 `collision_layer` / `collision_mask` 都在脚本顶部或 `.tscn` 里配好常量与注释，逻辑代码不出现魔数（`Bullet.LAYER_PLAYER_BULLET` 等）。

## 4. 信号清单

| 信号 | 发出者 | 接收者 | 用途 |
|---|---|---|---|
| `RunState.health_changed` | RunState | HUD | 血条 |
| `RunState.gold_changed` | RunState | HUD | 金币 |
| `RunState.floor_changed` | RunState | HUD | 楼层 |
| `RunState.relic_changed` | RunState | HUD | 遗物数 |
| `RunState.player_died` | RunState | Game / Player | 死亡结算、死亡动画 |
| `EventBus.room_entered` | Game | HUD / Minimap | 房间进度 |
| `EventBus.room_cleared` | Game | 预留（统计/成就） | 清场 |
| `EventBus.relic_picked` | Game | HUD / 预留 | 遗物提示 |
| `EventBus.hitstop_requested` | 各处 | Game | 命中顿帧 50ms |
| `EventBus.shake_requested` | 各处 | Game | 震屏 |
| `EventBus.toast_requested` | 各处 | HUD | 底部提示条 |
| `EventBus.boss_spawned` | Game | HUD | Boss 血条 |
| `Enemy.died` | Enemy | Game | 掉落金币、计数、开门 |
| `Bullet.hit_target` | Bullet | 预留（伤害数字扩展点） | 命中反馈 |
| `Hurtbox.hit_taken` / `contact_made` | Hurtbox | Player / Enemy | 受伤、接触伤害 |
| `DungeonRoom.door_entered` | Room | Game | 换房 |

方向约定：**向上发信号、向下调方法**。HUD 只读不写；Game 不反向引用 Enemy 的内部状态（只调 `take_damage()`）。

## 5. Autoload 取舍

| 自动加载 | 放什么 | 谁写 | 谁读 | 何时清 |
|---|---|---|---|---|
| `RunState` | 单局可变状态（血/金币/楼层/遗物/统计/派生属性） | Player / Enemy / Relic / Game | HUD / DeathScreen / MetaProgress | `reset_run()` 每局开始 |
| `MetaProgress` | 余烬、永久升级等级、历史统计；`user://meta.json` | DeathScreen / MainMenu | RunState（开局加成） | 永不（跨局存活） |
| `EventBus` | 跨系统解耦通知（纯信号） | 任意 | 任意 | 场景销毁时自动断连 |
| `Sfx` | 12 条音效的播放器池 | 任意（`Sfx.play()`） | 无 | 永不 |

**不放进 Autoload 的东西**：地牢图、当前房间、敌人列表、子弹——这些属于关卡状态，生命周期 = 一次房间构建，交给 `Game` 与 `Room`。

---

## 6. 场景流

```
main_menu ──"开始新一局"──▶ game ──死亡──▶ death_screen（同一场景内叠层）
     ▲                        │  ▲                    │
     │                        │  └── Esc ──▶ pause_menu│
     └────"回到主菜单"────────┼────────────────────────┘
                              └── 击败 Boss ──▶ 重新生成地牢（不清 Autoload）
```