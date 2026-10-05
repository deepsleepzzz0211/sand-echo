BGM 暂缺
========

Kenney Desert Shooter Pack 1.0 只提供音效（Sounds/），不含任何音乐。
策划案第 10 章要求「地牢循环 BGM + Boss 战 BGM」两条，当前版本留空待补。

补入方式
--------
1. 把两条 .ogg（或 .wav/.mp3）放进本目录，文件名建议 dungeon_loop.ogg / boss_battle.ogg。
2. 在 autoload/sfx.gd 里加两个常驻 AudioStreamPlayer，按场景切换（EventBus.boss_spawned / room_cleared）。
3. docs/asset-manifest.json 的「背景音乐」规则会自动命中这两个文件，届时 BGM 告警消失。
4. 在 docs/design-freeze.json 里把 AUD-002 的缺口说明同步改为已实现。
