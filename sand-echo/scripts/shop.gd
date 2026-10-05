extends CanvasLayer
# @trace SHOP-001, UI-002
# 波间商店（@trace SHOP-001）。Brotato 肉鸽闭环的另一半：**花钱变强**。
# 原工程完全没有消费环节（审计确认零 shop 标识），金币只能躺到死。
#
# 商品三类：武器 / 属性小件 / 回复。买武器时若同 id 已拥有则升一级（@trace WPN-001）。
# UI 节点全部在 scenes/shop.tscn 里声明，本脚本只连信号与填文本。

signal closed()

const OFFER_COUNT := 4
## 商品类型配比。旧版 ["weapon","stat","stat","heal"] 只有 1/4 是武器，
## 玩家反馈「看不到可以买其他武器的界面」——按 Brotato 的做法（商店是武器的唯一来源）
## 改成至少 2 个武器位。
const OFFER_KINDS := ["weapon", "weapon", "stat", "heal"]
## Brotato 官方 wiki：Tier 2 从第 2 波起、Tier 3 从第 4 波、Tier 4 从第 8 波才进商店池。
const TIER_UNLOCK_WAVE := {1: 1, 2: 2, 3: 4, 4: 8}
## Brotato 商店按波次通胀定价：Final = (Base + Wave + Base×0.1×Wave)，
## 取整并设下限（旧版只有固定价，高波次金币花不出去）。
const REROLL_BASE_COST := 15

@onready var _title: Label = $Root/Panel/VBox/Title
@onready var _gold: Label = $Root/Panel/VBox/Gold
@onready var _hint: Label = $Root/Panel/VBox/Hint
@onready var _continue: Button = $Root/Panel/VBox/Continue
var _slots: Array[Button] = []
var _names: Array[Label] = []
var _costs: Array[Label] = []
var _icons: Array[TextureRect] = []
@onready var _owned_row: HBoxContainer = $Root/Panel/VBox/Owned

var _offers: Array[Dictionary] = []
var _weapon_rows: Array = []


func _ready() -> void:
	visible = false
	for i in OFFER_COUNT:
		_slots.append(get_node(NodePath("Root/Panel/VBox/Offers/Slot%d" % i)) as Button)
		_names.append(get_node(NodePath("Root/Panel/VBox/Offers/Slot%d/Name" % i)) as Label)
		_costs.append(get_node(NodePath("Root/Panel/VBox/Offers/Slot%d/Cost" % i)) as Label)
		_icons.append(get_node(NodePath("Root/Panel/VBox/Offers/Slot%d/Icon" % i)) as TextureRect)
		_slots[i].pressed.connect(_on_slot_pressed.bind(i))
	_continue.pressed.connect(_on_continue)
	var f := FileAccess.open("res://data/weapons.json", FileAccess.READ)
	if f != null:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if parsed is Array:
			_weapon_rows = parsed


# 注意：参数名不能叫 _gold —— 会遮蔽同名的成员变量 _gold: Label，
# 症状是 _gold.text 报「Cannot find member text in base int」。
func offer(_owned: Array, _current_gold: int) -> void:
	visible = true
	_offers = _roll_offers()
	_gold.text = "持有金币 %d" % RunState.gold
	var full := RunState.weapons.size() >= RunState.MAX_WEAPONS and not _has_upgradable()
	var slots_full := RunState.weapons.size() >= RunState.MAX_WEAPONS
	if full:
		_hint.text = "武器栏已满且全部满级：卖掉一把方能继续强化"
	elif slots_full:
		_hint.text = "武器栏已满：只能强化已有武器，或卖掉一把腾出槽位"
	else:
		_hint.text = "点击商品购买，或按「继续」进入下一波"
	_refresh()


func _has_upgradable() -> bool:
	for w in RunState.weapons:
		if int((w as Dictionary).get("tier", 1)) < RunState.MAX_TIER:
			return true
	return false


func _roll_offers() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	# 抽池先按波次过滤 tier（Brotato：T2 第2波、T3 第4波、T4 第8波才解锁）
	var wave := RunState.wave_num
	var pool: Array = []
	for w in _weapon_rows:
		var wd := w as Dictionary
		var need := int(TIER_UNLOCK_WAVE.get(int(wd.get("tier", 1)), 1))
		if wave >= need:
			pool.append(wd)
	pool.shuffle()
	var wi := 0
	for kind in OFFER_KINDS:
		if kind == "weapon":
			# 武器是商店的主要商品（Brotato 里武器只能从商店买）。
			# 槽位满时退化为「只能强化已拥有的」；已满级 4 的也跳过，否则会
			# 生成一件点了没用的商品（旧版 cost=0 被当「已满」显示，买不了）。
			while wi < pool.size():
				var wd2 := pool[wi] as Dictionary
				var id2 := String(wd2.get("id", ""))
				var ok := RunState.weapons.size() < RunState.MAX_WEAPONS
				if not ok:
					var tier := _tier_of(id2)
					ok = tier > 0 and tier < 4
				if ok:
					out.append({
						"kind": "weapon",
						"id": id2,
						"name": _weapon_label(id2),
						"desc": String(wd2.get("desc", "")),
						"cost": _weapon_cost(wd2),
					})
					wi += 1
					break
				wi += 1
		elif kind == "heal":
			out.append({"kind": "heal", "id": "heal", "name": "沙泉（一口）",
				"desc": "立刻回复 40% 生命", "cost": _heal_cost()})
		else:
			out.append(_random_stat())
	return out


func _owns(weapon_id: String) -> bool:
	return _tier_of(weapon_id) > 0


## 该武器当前等级；未持有返回 0
func _tier_of(weapon_id: String) -> int:
	for w in RunState.weapons:
		var wm := w as Dictionary
		if String(wm["id"]) == weapon_id:
			return int(wm.get("tier", 1))
	return 0


## 商品标题带上「已持有 LvN」，让玩家一眼看出买的是新武器还是强化
func _weapon_label(weapon_id: String) -> String:
	for w in _weapon_rows:
		var wd := w as Dictionary
		if String(wd.get("id", "")) == weapon_id:
			var t := _tier_of(weapon_id)
			var base := String(wd.get("name", ""))
			return "%s Lv%d→Lv%d" % [base, t, t + 1] if t > 0 else base
	return weapon_id


## 定价：Brotato 官方公式 Final = (Base + Wave + Base×0.1×Wave)，向下取整。
## 已持有的武器走 0.55 折的「强化价」。下限 1 金 —— 旧版对 cost=0 的武器
## （初始手枪 w_pistol base cost 就是 0）算出 0，而 _refresh 把 cost<=0 一律
## 显示成「已满」并禁用，导致免费武器的强化路径完全买不了。
func _weapon_cost(def: Dictionary) -> int:
	var base := int(def.get("cost", 100))
	var wave := float(maxi(1, RunState.wave_num))
	var final_price := (float(base) + wave + float(base) * 0.1 * wave)
	if _owns(String(def.get("id", ""))):
		final_price *= 0.55
	return maxi(1, int(floor(final_price)))


func _heal_cost() -> int:
	var missing := RunState.max_health - RunState.health
	if missing <= 0:
		return 0
	return maxi(10, int(round(float(missing) * 0.8)))


## 商店属性小件：从升级池里抽纯 stat 条目，按效果给个价
func _random_stat() -> Dictionary:
	var pool: Array = []
	for entry in RunState.upgrade_pool():
		var d := entry as Dictionary
		if String(d.get("kind", "")) == "stat":
			pool.append(d)
	if pool.is_empty():
		return {"kind": "stat", "id": "heal", "name": "沙泉（一口）",
			"desc": "立刻回复 40% 生命", "cost": _heal_cost()}
	var pick := (pool[randi() % pool.size()] as Dictionary).duplicate()
	pick["kind"] = "stat"
	# 同样按波次通胀，避免高波次金币过剩
	var wave := float(maxi(1, RunState.wave_num))
	pick["cost"] = maxi(5, int(floor(90.0 * (1.0 + wave * 0.08))))
	return pick


func _refresh() -> void:
	_gold.text = "持有金币 %d" % RunState.gold
	for i in OFFER_COUNT:
		var has := i < _offers.size()
		_slots[i].visible = has
		if not has:
			continue
		var o := _offers[i]
		_names[i].text = "%s\n%s" % [String(o["name"]), String(o["desc"])]
		_icons[i].texture = _offer_texture(o)
		_icons[i].visible = _icons[i].texture != null
		var cost := int(o["cost"])
		# cost<=0 之前被当成「已满」显示，但它现在的唯一来源是 _heal_cost 在满血时返回 0。
		# 拆成两个独立判断：sold 是「已售出」，heal 且 cost<=0 是「生命已满」。
		var sold := bool(o.get("sold", false))
		var no_effect := cost <= 0
		if sold:
			_costs[i].text = "已售出"
		elif no_effect:
			_costs[i].text = "生命已满" if String(o["kind"]) == "heal" else "不可用"
		else:
			_costs[i].text = "%d 金" % cost
		# 买不起就置灰，让玩家一眼看出哪些买得起
		_slots[i].modulate = Color(1, 1, 1, 1) if RunState.gold >= cost and not no_effect else Color(0.55, 0.55, 0.6, 1)
		_slots[i].disabled = no_effect or RunState.gold < cost or sold
	_refresh_owned()

## 重建「我的武器」行：每把武器一个按钮，显示名称/等级/回收价，点击即卖。
## 没有这一行时，6 把槽位填满且全满级后玩家彻底卡死——既买不进新武器也没法强化。
func _refresh_owned() -> void:
	if _owned_row == null:
		return
	for c in _owned_row.get_children():
		c.queue_free()
	var can_sell := RunState.weapons.size() > 1
	for i in RunState.weapons.size():
		var wm := RunState.weapons[i] as Dictionary
		var def: Dictionary = RunState.weapon_def(String(wm["id"]))
		if def.is_empty():
			continue
		var tier := int(wm.get("tier", 1))
		var value := RunState.sell_value(i)
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(176, 74)
		btn.disabled = not can_sell
		btn.text = "%s Lv%d\n卖 %d 金" % [String(def.get("name", "")), tier, value]
		btn.tooltip_text = "若不能卖：至少要留一把武器" if not can_sell else "回收入的 %.0f%%" % (RunState.SELL_REFUND_RATE * 100.0)
		btn.pressed.connect(_on_sell_pressed.bind(i))
		_owned_row.add_child(btn)
		# 等级越高按钮越金，与场内枪械染色一致
		var tier_tint: Color = ([Color(1, 1, 1), Color(1.10, 1.06, 0.92),
				Color(1.18, 1.00, 0.80), Color(1.30, 0.94, 0.62)] as Array)[clampi(tier - 1, 0, 3)]
		btn.add_theme_color_override("font_color", tier_tint)


func _on_sell_pressed(index: int) -> void:
	var before := RunState.weapons.size()
	var refund := RunState.sell_weapon(index)
	if refund <= 0 or RunState.weapons.size() >= before:
		return
	EventBus.toast_requested.emit("\u5356\u6389\u6b66\u5668\uff0c\u9000\u6b3e %d \u91d1" % refund)
	Sfx.play("pickup", -6.0, 0.9, 0.0)
	_gold.text = "\u6301\u6709\u91d1\u5e01 %d" % RunState.gold
	_refresh()


func _on_slot_pressed(index: int) -> void:
	if index >= _offers.size():
		return
	var o := _offers[index]
	if bool(o.get("sold", false)):
		return
	var cost := int(o["cost"])
	if cost <= 0 or not RunState.spend_gold(cost):
		return
	match String(o["kind"]):
		"weapon":
			var id := String(o["id"])
			# 传入实际花费，回收时按投入额退款
			if RunState.buy_weapon(id, cost):
				var tier := 1
				for w in RunState.weapons:
					if String((w as Dictionary)["id"]) == id:
						tier = int((w as Dictionary).get("tier", 1))
				EventBus.weapon_added.emit(id, tier)
				EventBus.toast_requested.emit("获得武器：%s Lv%d" % [String(o["name"]), tier])
				Sfx.play("pickup", -4.0, 1.0, 0.0)
		"heal":
			RunState.heal(int(round(float(RunState.max_health) * 0.4)))
			EventBus.toast_requested.emit("回复了生命")
			Sfx.play("pickup", -4.0, 1.2, 0.0)
		"stat":
			RunState.take_upgrade(String(o["id"]))
			EventBus.toast_requested.emit("获得：%s" % String(o["name"]))
			Sfx.play("pickup", -4.0, 1.0, 0.0)
	o["sold"] = true
	_refresh()


func _on_continue() -> void:
	visible = false
	Sfx.play("ui_move", -14.0, 1.0, 0.0)
	closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
		get_viewport().set_input_as_handled()
		_on_continue()

## 商品图标：武器用其当前等级的枪身图，属性件用升级图标。
## 接武器贴图之前商店全是纯文字，玩家看不到要买的东西长什么样。
func _offer_texture(o: Dictionary) -> Texture2D:
	var kind := String(o.get("kind", ""))
	if kind == "weapon":
		var def: Dictionary = RunState.weapon_def(String(o.get("id", "")))
		if def.is_empty():
			return null
		return _weapon_texture(def, _tier_of(String(o.get("id", ""))))
	# 属性件沿用 upgrades.json 里的 icon 字段
	var ud: Dictionary = RunState.upgrade_def(String(o.get("id", "")))
	var p := String(ud.get("icon", ""))
	if p.is_empty() or not ResourceLoader.exists(p):
		return null
	return load(p) as Texture2D


## 取武器指定等级的贴图；level<=0 表示未持有，取最低级
func _weapon_texture(def: Dictionary, level: int) -> Texture2D:
	var arr: Array = def.get("sprites", [])
	if arr.is_empty():
		return null
	var path := String(arr[clampi(maxi(1, level) - 1, 0, arr.size() - 1)])
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D
