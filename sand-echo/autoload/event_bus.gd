extends Node
# @trace SCENE-002, FLOW-001, WAVE-001, UPG-001, SIG-004
# 全局事件总线（@trace SCENE-002）。只放跨场景「解耦通知」：
# 谁写：任何场景/脚本；谁读：HUD、商店、三选一、场景层、特效层；何时清：本节点随引擎常驻，
# 信号连接随场景销毁自动断开。
#
# 【本轮重构】房间制信号换成波次制信号（@trace WAVE-001）：
#   删：floor_cleared / room_entered / room_cleared
#   增：wave_started / wave_cleared / upgrade_offered / shop_opened

signal run_started()
signal run_ended(ember_gained: int, summary: Dictionary)

# --- 波次（@trace WAVE-001）---
signal wave_started(wave: int, is_boss: bool)
signal wave_cleared(wave: int)

# --- 局内构筑（@trace UPG-001 / SHOP-001）---
signal upgrade_offered(options: Array)
signal upgrade_chosen(id: String)
signal shop_opened(weapons: Array, gold: int)
signal weapon_added(id: String, tier: int)

signal relic_picked(relic_id: String)
signal player_hurt(amount: int)
signal enemy_killed(enemy_id: String, gold_reward: int)
signal boss_spawned(boss_name: String)
signal hud_refresh_requested()
signal hitstop_requested(duration: float)
signal shake_requested(strength: float)
signal toast_requested(text: String)