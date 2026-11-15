extends SceneTree
const Terrain = preload("res://addons/stoem_terrain/nodes/terrain_3d.gd")
const Mat = preload("res://addons/stoem_terrain/core/terrain_material_table.gd")
func _initialize():
	for version in [1, 2]:
		var t = Terrain.new()
		t.sampling_version = version
		root.add_child(t)
		t.bake()
		var used = []
		var d = _find_flat(t, used)
		var w = _find_wet(t, used)
		print("VERSION", version, "DRY", d, "WET", w)
		if d != null and w != null:
			for spot in [d, w]:
				print("BEFORE", spot, "H", t.height_at(spot), "head", t.water_table_at(spot), "pore", t.pore_factor_at(spot))
				_override(t, spot, 8)
				_stamp(t, spot, 6, 0.9)
				t.stabilize_rect(Rect2(spot.x - 8.0, spot.y - 8.0, 16.0, 16.0))
				print("AFTER", spot, "pore", t.pore_factor_at(spot), "max", _max_slope(t, spot, 6), "repose", t.wet_repose_deg(2, t.pore_factor_at(spot)))
		t.queue_free()
	quit()
func _find_flat(t, used):
	for wz in range(-348,351,6):
		for wx in range(-348,351,6):
			var p=Vector2(float(wx),float(wz))
			var ok=true
			for e in used:
				if p.distance_to(e)<42: ok=false
			if not ok: continue
			for off in [Vector2.ZERO,Vector2(7,0),Vector2(-7,0),Vector2(0,7),Vector2(0,-7)]:
				var q=p+off
				if t.slope_deg_at(q)>7 or t.pore_factor_at(q)>0.15: ok=false
			if ok: used.append(p); return p
	return null
func _find_wet(t, used):
	for wz in range(-348,351,6):
		for wx in range(-348,351,6):
			var p=Vector2(float(wx),float(wz))
			var ok=true
			for e in used:
				if p.distance_to(e)<42: ok=false
			if not ok or t.water_table_at(p)-t.height_at(p)<0.35: continue
			for off in [Vector2(4,0),Vector2(-4,0),Vector2(0,4),Vector2(0,-4)]:
				if t.slope_deg_at(p+off)>9: ok=false
			if ok: used.append(p); return p
	return null
func _override(t,p,half):
	for z in range(int(p.y)-half,int(p.y)+half+1,4):
		for x in range(int(p.x)-half,int(p.x)+half+1,4): t.set_material_override(Vector2(x,z), Mat.ID_GRAVEL)
func _stamp(t,c,length,width):
	var steps=length*2+1
	for s in steps:
		var z=c.y-float(length)*0.5+float(s)*0.5
		var h=t.height_at(Vector2(c.x,z))
		t.sculpt_raise(Vector2(c.x,z), -(h-0.9), width*0.5, 1.0, 0.0)
func _max_slope(t,c,r):
	var m=0.0
	for z in range(int(c.y)-r,int(c.y)+r+1):
		for x in range(int(c.x)-r,int(c.x)+r+1): m=maxf(m,t.slope_deg_at(Vector2(x,z)))
	return m
