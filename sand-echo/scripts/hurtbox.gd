class_name Hurtbox
extends Area2D
# @trace MECH-002, MECH-007, COL-001, COL-002
# 受击代理：只做「把命中事件转交给本体」，自身不持有任何战斗状态。
# 这样弹丸、敌人、玩家三方的碰撞层可以彼此独立配置，互不干扰（@trace MECH-002 判定规则）。
# 层位：玩家 Hurtbox = layer2(2)，敌人 Hurtbox = layer3(4)；敌人 Hurtbox 额外 mask player(2) 以做接触伤害。

signal hit_taken(damage: int, from: Vector2)
signal contact_made(target: Area2D)


func _ready() -> void:
	monitorable = true
	area_entered.connect(_on_area_entered)


func apply_hit(damage: int, from: Vector2) -> void:
	if damage <= 0:
		return
	hit_taken.emit(damage, from)


func _on_area_entered(area: Area2D) -> void:
	# 只在「敌人 Hurtbox（mask = player）」上生效：玩家 Hurtbox 的 mask 为 0，
	# 因此不会反向触发，接触伤害是单向的。
	if area.is_in_group("player_hurtbox"):
		contact_made.emit(area)