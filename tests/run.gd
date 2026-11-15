extends SceneTree
## Headless acceptance probes for the Terrain plugin. Run:
##   godot --headless --path <project> --script res://tests/run.gd
## Prints one PASS/FAIL line per assertion; exit code 0 iff everything passes.

const Terrain = preload("res://addons/stoem_terrain/nodes/terrain_3d.gd")
const Mat = preload("res://addons/stoem_terrain/core/terrain_material_table.gd")
const Data = preload("res://addons/stoem_terrain/core/terrain_data.gd")
const Carve = preload("res://addons/stoem_terrain/core/terrain_carve.gd")
const MeshUtil = preload("res://addons/stoem_terrain/core/terrain_mesh.gd")
const RayUtil = preload("res://addons/stoem_terrain/core/terrain_ray.gd")
const Water = preload("res://addons/stoem_terrain/core/terrain_water.gd")
const Dig = preload("res://addons/stoem_terrain/core/terrain_dig.gd")
const Stability = preload("res://addons/stoem_terrain/core/terrain_stability.gd")
const EditStore = preload("res://addons/stoem_terrain/core/terrain_edits.gd")

var failures := 0
var used_spots: Array = []

func _initialize() -> void:
        print("=== Terrain acceptance probes ===")
        var t = _make_terrain(20261113)
        _p0_queries(t)
        _p2_dig(t)
        _p3_stability(t)
        _p4_water(t)
        _p5_tunnels(t)
        _px_infra(t)
        _p7_bugfixes(t)
        _p8_mesh_and_mass(t)
        _p9_paint(t)
        _p1_materials()
        _p6_persistence()
        if failures == 0:
                print("RESULT: ALL PROBES PASS")
        else:
                print("RESULT: %d FAILURES" % failures)
        quit(1 if failures > 0 else 0)

func _make_terrain(p_seed: int):
        var t := Terrain.new()
        t.name = "Terrain%d" % p_seed
        t.seed_value = p_seed
        root.add_child(t)
        # In --script mode _ready does not fire when parenting to root; bake explicitly.
        t.bake()
        return t

func _check(p_cond: bool, p_msg: String) -> void:
        if p_cond:
                print("  PASS  %s" % p_msg)
        else:
                failures += 1
                print("  FAIL  %s" % p_msg)

# ---------------------------------------------------------------- find helpers

func _find_flat(t, p_mat_id: int, p_slope_deg: float, p_half: int,
                p_pore_min: float, p_pore_max: float) -> Variant:
        for wz in range(-348, 351, 6):
                for wx in range(-348, 351, 6):
                        var p := Vector2(float(wx), float(wz))
                        var near := false
                        for e in used_spots:
                                if p.distance_to(e) < 42.0:
                                        near = true
                                        break
                        if near:
                                continue
                        var ok := true
                        for off in [Vector2(0, 0), Vector2(p_half, 0), Vector2(-p_half, 0),
                                        Vector2(0, p_half), Vector2(0, -p_half)]:
                                var q: Vector2 = p + off
                                if absf(q.x) > 380.0 or absf(q.y) > 380.0:
                                        ok = false
                                        break
                                if t.slope_deg_at(q) > p_slope_deg:
                                        ok = false
                                        break
                                if p_mat_id >= 0 and t.material_id_at(q) != p_mat_id:
                                        ok = false
                                        break
                                var pore: float = t.pore_factor_at(q)
                                if pore < p_pore_min or pore > p_pore_max:
                                        ok = false
                                        break
                        if ok:
                                used_spots.append(p)
                                return p
        return null

func _find_wet(t, p_head_above: float) -> Variant:
        for wz in range(-348, 351, 6):
                for wx in range(-348, 351, 6):
                        var p := Vector2(float(wx), float(wz))
                        var near := false
                        for e in used_spots:
                                if p.distance_to(e) < 42.0:
                                        near = true
                                        break
                        if near:
                                continue
                        if t.water_table_at(p) - t.height_at(p) < p_head_above:
                                continue
                        var ok := true
                        for off in [Vector2(4, 0), Vector2(-4, 0), Vector2(0, 4), Vector2(0, -4)]:
                                if t.slope_deg_at(p + off) > 9.0:
                                        ok = false
                                        break
                        if ok:
                                used_spots.append(p)
                                return p
        return null

func _find_hill(t) -> Variant:
        # A hill that stays above the bore for 28 m, then drops away: a proper tunnel
        # with a mouth. Bore depth 8 m under the summit line, cohesive material only.
        for wz in range(-330, 331, 12):
                for wx in range(-320, 281, 8):
                        var p := Vector2(float(wx), float(wz))
                        var near := false
                        for e in used_spots:
                                if p.distance_to(e) < 42.0:
                                        near = true
                                        break
                        if near:
                                continue
                        var h0: float = t.height_at(p)
                        if h0 < 16.0 or t.slope_deg_at(p) > 30.0:
                                continue
                        if Mat.get_material(t.material_id_at(p)).cohesion_kpa < 10.0:
                                continue
                        var y_bore := h0 - 8.0
                        var covered := true
                        for k in [0.0, 6.0, 12.0, 18.0, 24.0, 28.0]:
                                if t.height_at(p + Vector2(k, 0.0)) < y_bore + 1.7:
                                        covered = false
                                        break
                        if not covered:
                                continue
                        if t.height_at(p + Vector2(36.0, 0.0)) > y_bore - 2.0:
                                continue
                        used_spots.append(p)
                        return p
        return null

## The dry stability control must stay above the water table after the test's
## 0.9 m trench is cut. Surface pore pressure alone is not enough to establish
## that; require at least 1.1 m of unsaturated clearance around the trench.
func _find_dry_trench_spot(t) -> Variant:
        for wz in range(-348, 351, 6):
                for wx in range(-348, 351, 6):
                        var p := Vector2(float(wx), float(wz))
                        var near := false
                        for e in used_spots:
                                if p.distance_to(e) < 42.0:
                                        near = true
                                        break
                        if near:
                                continue
                        var ok := true
                        for off in [Vector2(0, 0), Vector2(7, 0), Vector2(-7, 0),
                                        Vector2(0, 7), Vector2(0, -7)]:
                                var q: Vector2 = p + off
                                if t.slope_deg_at(q) > 7.0 \
                                                or t.pore_factor_at(q) > 0.15 \
                                                or t.water_table_at(q) - t.height_at(q) > -1.1:
                                        ok = false
                                        break
                        if ok:
                                used_spots.append(p)
                                return p
        return null

func _copy_region(t, p_center: Vector2, p_half: int) -> PackedFloat32Array:
        var out := PackedFloat32Array()
        var data = t.data
        for j in range(int(p_center.y) - p_half, int(p_center.y) + p_half + 1):
                for i in range(int(p_center.x) - p_half, int(p_center.x) + p_half + 1):
                        var ii := clampi(i + int(data.HALF), 0, data.N - 1)
                        var jj := clampi(j + int(data.HALF), 0, data.N - 1)
                        out.append(data.heights[ii + jj * data.N])
        return out

func _max_slope_deg(t, p_center: Vector2, p_half: int) -> float:
        var data = t.data
        var worst := 0.0
        for j in range(int(p_center.y) - p_half, int(p_center.y) + p_half + 1):
                for i in range(int(p_center.x) - p_half, int(p_center.x) + p_half + 1):
                        var ii := clampi(i + int(data.HALF), 0, data.N - 2)
                        var jj := clampi(j + int(data.HALF), 0, data.N - 2)
                        var h: float = data.heights[ii + jj * data.N]
                        worst = maxf(worst, absf(data.heights[ii + 1 + jj * data.N] - h))
                        worst = maxf(worst, absf(data.heights[ii + (jj + 1) * data.N] - h))
        return rad_to_deg(atan(worst))

func _stamp_step(t, p_center: Vector2, p_half: int, p_rise: float) -> void:
        # Raise the west half of a box by p_rise, leaving the east half at ground.
        t.begin_stroke()
        var data = t.data
        for j in range(int(p_center.y) - p_half, int(p_center.y) + p_half + 1):
                for i in range(int(p_center.x) - p_half, int(p_center.x) + p_half + 1):
                        var ii := clampi(i + int(data.HALF), 0, data.N - 1)
                        var jj := clampi(j + int(data.HALF), 0, data.N - 1)
                        var idx: int = ii + jj * data.N
                        var h: float = data.heights[idx]
                        if i < int(p_center.x):
                                t._stroke_set_height(idx, h + p_rise)
        t.end_stroke("sculpt")

func _stamp_trench(t, p_center: Vector2, p_half: int, p_drop: float) -> void:
        # Lower the west half of a box by p_drop.
        t.begin_stroke()
        var data = t.data
        for j in range(int(p_center.y) - p_half, int(p_center.y) + p_half + 1):
                for i in range(int(p_center.x) - p_half, int(p_center.x) + p_half + 1):
                        var ii := clampi(i + int(data.HALF), 0, data.N - 1)
                        var jj := clampi(j + int(data.HALF), 0, data.N - 1)
                        var idx: int = ii + jj * data.N
                        if i < int(p_center.x):
                                t._stroke_set_height(idx, data.heights[idx] - p_drop)
        t.end_stroke("sculpt")

func _override_material_box(t, p_center: Vector2, p_half: int, p_mat_id: int) -> void:
        for wz in range(int(p_center.y) - p_half, int(p_center.y) + p_half + 1, 2):
                for wx in range(int(p_center.x) - p_half, int(p_center.x) + p_half + 1, 2):
                        t.set_material_override(Vector2(float(wx), float(wz)), p_mat_id)

# ------------------------------------------------------------------ P0

func _p0_queries(t) -> void:
        print("[P0] canonical query surface")
        var p: Variant = _find_flat(t, -1, 5.0, 6, 0.0, 1.0)
        _check(p != null, "found gentle probe point")
        if p == null:
                return
        var c: Vector2 = p
        var h: float = t.height_at(c)
        # Signal contract: legacy edited has NO arguments (main.gd hook), the new
        # edited_region carries the invalidation rect. Both must fire per commit.
        # NOTE: GDScript lambdas capture ints BY VALUE, so the counters live in
        # a Dictionary (captured by reference).
        var sig := {"edited": 0, "region": 0, "rect": Rect2()}
        t.edited.connect(func() -> void: sig.edited = int(sig.edited) + 1)
        t.edited_region.connect(func(r: Rect2) -> void:
                        sig.region = int(sig.region) + 1
                        sig.rect = r)
        t.sculpt(c.x, c.y, 2.0, 1.0, 0, 0.6)
        _check(int(sig.edited) >= 1 and int(sig.region) >= 1,
                        "edited (0-arg) + edited_region(rect) both emitted")
        _check((sig.rect as Rect2).has_point(c),
                        "edited_region rect covers the edit (%s)" % sig.rect)
        t.undo()
        _check(absf(h - t.sample_height_world(c.x, c.y)) < 1e-6,
                "height_at matches sample_height_world")
        _check(absf(t.sample_height(c.x + 384.0, c.y + 384.0) - h) < 1e-6,
                "sample_height (terrain space) wrapper agrees")
        _check(t.is_solid(Vector3(c.x, h - 1.0, c.y)), "is_solid below surface")
        _check(not t.is_solid(Vector3(c.x, h + 1.0, c.y)), "is_solid above surface")
        var n: Vector3 = t.normal_at(c)
        _check(n.y > 0.9, "normal_at points up on gentle ground (%.2f)" % n.y)
        _check(t.slope_deg_at(c) >= 0.0 and t.slope_deg_at(c) < 8.0,
                "slope_deg_at gentle (%.1f)" % t.slope_deg_at(c))
        _check(Mat.id_for_key(t.material_at(c)) >= 0, "material_at returns a known key")
        _check(t.water_table_at(c) > -1e8, "water_table_at finite (%.2f)" % t.water_table_at(c))
        _check(t.pore_factor_at(c) >= 0.0 and t.pore_factor_at(c) <= 1.0, "pore_factor_at in 0..1")

        # Carve a hole and exercise the open-surface + solidity contract.
        var added: bool = t.carve(Vector3(c.x, h, c.y), 2.5)
        _check(added, "carve adds an analytic void")
        _check(t.surface_is_open_world(c.x, c.y), "surface_is_open_world true after carve")
        _check(t.surface_open_rect(Rect2(c.x - 4.0, c.y - 4.0, 8.0, 8.0)),
                "surface_open_rect true around the hole")
        _check(not t.surface_open_rect(Rect2(c.x - 60.0, c.y - 60.0, 8.0, 8.0)),
                "surface_open_rect false far from the hole")
        _check(not t.is_solid(Vector3(c.x, h - 0.5, c.y)), "void interior is not solid")
        _check(t.is_solid(Vector3(c.x, h - 6.0, c.y)), "below the void floor is solid")
        _check(t.material_at_3d(Vector3(c.x, h - 2.0, c.y)) != &"", "material_at_3d inside bore")
        _check(t.undo(), "undo the carve")
        _check(not t.surface_is_open_world(c.x, c.y), "surface closed after undo")
        _check(t.is_solid(Vector3(c.x, h - 0.5, c.y)), "solid restored after undo")
        _check(not t.carve_set.has_carve(), "carve set empty after undo")
        _check(t.get_volume_chunks().size() == 2, "get_volume_chunks empty payload")

# ------------------------------------------------------------------ P2

func _p2_dig(t) -> void:
        print("[P2] volume-conserving dig with spoil")
        var spot: Variant = _find_flat(t, Mat.ID_SAND, 9.0, 6, 0.0, 0.2)
        _check(spot != null, "found flat dry sand")
        if spot == null:
                return
        var c: Vector2 = spot
        var before := _copy_region(t, c, 6)
        var v: float = t.dig(Vector3(c.x, t.height_at(c), c.y), 0.9, 1.0)
        _check(absf(v - 1.0) < 0.02, "dig returns the requested 1.0 m3 (got %.3f)" % v)
        var after := _copy_region(t, c, 6)
        var dpos := 0.0
        var dneg := 0.0
        for k in before.size():
                var d := after[k] - before[k]
                if d > 0.0:
                        dpos += d
                else:
                        dneg += d
        var swell: float = Mat.get_material(Mat.ID_SAND).digging_spoil_ratio
        # Mass balance (slump-invariant): net = spoil(loose) - cut(compact) = V*(swell-1).
        _check(absf((dpos + dneg) - v * (swell - 1.0)) < 0.06,
                "mass balance: net %.3f ~ V*(swell-1) = %.3f" % [dpos + dneg, v * (swell - 1.0)])
        _check(dneg < -0.55, "pit cut exists (%.2f m3 compact)" % -dneg)
        _check(dpos > 0.5, "spoil ring exists (%.2f m3 loose)" % dpos)
        _check(t.undo(), "undo dig")
        _check(_copy_region(t, c, 6) == before, "one undo restores pit + spoil exactly")
        _check(t.redo(), "redo dig")
        _check(_copy_region(t, c, 6) == after, "redo restores post-dig state exactly")
        # Per-material dig mask: protected material refuses the dig entirely.
        var gspot: Variant = _find_flat(t, -1, 6.0, 6, 0.0, 1.0)
        if gspot == null:
                gspot = c + Vector2(0.0, 60.0)
        var gp: Vector2 = gspot
        for off in [Vector2(0, 0), Vector2(3, 0), Vector2(-3, 0), Vector2(0, 3), Vector2(0, -3)]:
                t.set_material_override(gp + off, Mat.ID_GRANITE)
        var pre_mask := _copy_region(t, gp, 4)
        t.dig_mask[Mat.ID_GRANITE] = 0
        var gv: float = t.dig(Vector3(gp.x, t.height_at(gp), gp.y), 1.2, 3.0)
        t.dig_mask[Mat.ID_GRANITE] = 1
        _check(gv == 0.0, "masked granite refuses the dig (returned %.2f m3)" % gv)
        _check(_copy_region(t, gp, 4) == pre_mask, "masked dig changed nothing")

# ------------------------------------------------------------------ P3

func _p3_stability(t) -> void:
        print("[P3] stability and slump")
        # 60-degree sand cut slumps to ~34 and stops.
        var sand: Variant = _find_flat(t, Mat.ID_SAND, 9.0, 6, 0.0, 0.2)
        _check(sand != null, "found sand for slump test")
        if sand != null:
                var c: Vector2 = sand
                _stamp_step(t, c, 5, 2.6)
                var pre := _max_slope_deg(t, c, 5)
                _check(pre > 55.0, "stamped cut is ~60+ degrees (%.1f)" % pre)
                t.stabilize_rect(Rect2(c.x - 7.0, c.y - 7.0, 14.0, 14.0))
                var post := _max_slope_deg(t, c, 5)
                _check(post >= 29.0 and post <= 37.5,
                        "sand slumped to 34 +/- 3 deg and stopped (%.1f)" % post)
        # The same cut in granite holds.
        var rock: Variant = _find_flat(t, -1, 5.0, 6, 0.0, 0.2)
        _check(rock != null, "found spot for granite control")
        if rock != null:
                var g: Vector2 = rock
                _override_material_box(t, g, 7, Mat.ID_GRANITE)
                _stamp_step(t, g, 5, 2.6)
                t.stabilize_rect(Rect2(g.x - 7.0, g.y - 7.0, 14.0, 14.0))
                var gpost := _max_slope_deg(t, g, 5)
                _check(gpost > 55.0, "granite holds the same cut (%.1f deg)" % gpost)
        # Cave roofs: 12 m loam cavity collapses, 4 m holds.
        var loam: Variant = _find_flat(t, Mat.ID_LOAM, 6.0, 9, 0.0, 0.5)
        _check(loam != null, "found loam for roof test")
        if loam != null:
                var l: Vector2 = loam
                var hl: float = t.height_at(l)
                var collapsed_rects: Array = []
                t.collapsed.connect(func(r: Rect2) -> void: collapsed_rects.append(r))
                t.carve(Vector3(l.x, hl - 9.0, l.y), 6.0)
                _check(t.carve_set.sphere_count() == 0, "12 m loam roof collapsed (primitive removed)")
                _check(collapsed_rects.size() >= 1 and collapsed_rects[0].has_point(l),
                                "collapsed(rect) fired and covers the cavity (%d)" % collapsed_rects.size())
                _check(t.height_at(l) < hl - 4.0,
                        "collapse subsided the surface (%.1f -> %.1f)" % [hl, t.height_at(l)])
        var loam2: Variant = _find_flat(t, Mat.ID_LOAM, 6.0, 9, 0.0, 0.5)
        _check(loam2 != null, "found second loam spot")
        if loam2 != null:
                var l2: Vector2 = loam2
                var hl2: float = t.height_at(l2)
                t.carve(Vector3(l2.x, hl2 - 5.0, l2.y), 2.0)
                _check(t.carve_set.sphere_count() == 1, "4 m loam roof holds (cavity survives)")
                _check(absf(t.height_at(l2) - hl2) < 0.05, "surface above the 4 m cavity unchanged")

# ------------------------------------------------------------------ P4

func _p4_water(t) -> void:
        print("[P4] water table, seepage, pore pressure")
        var pond: Variant = _find_wet(t, 0.35)
        _check(pond != null, "found saturated pond spot")
        if pond == null:
                return
        var c: Vector2 = pond
        var seep: Array = []
        t.seepage_cells.connect(func(cells: Array) -> void: seep.append_array(cells))
        # Force a free-draining material so the drawdown is unambiguous.
        for off in [Vector2(0, 0), Vector2(4, 0), Vector2(-4, 0), Vector2(0, 4), Vector2(0, -4)]:
                t.set_material_override(c + off, Mat.ID_SAND)
        var head_before: float = t.water_table_at(c)
        var v: float = t.dig(Vector3(c.x, t.height_at(c), c.y), 2.0, 6.0)
        var head_after: float = t.water_table_at(c)
        _check(head_after < head_before - 0.05,
                        "water table drew down toward the pit floor (%.2f -> %.2f)" % [head_before, head_after])
        _check(v > 5.0, "dug below the water table (V=%.2f m3)" % v)
        _check(seep.size() >= 6, "seepage_cells reported >= 6 cells (%d)" % seep.size())
        var all_in_pit := true
        for p in seep:
                if Vector2(p.x, p.z).distance_to(c) > 5.0:
                        all_in_pit = false
        _check(all_in_pit, "seepage_cells non-empty exactly in the pit")
        var sat := 0
        for wz in range(int(c.y) - 2, int(c.y) + 3):
                for wx in range(int(c.x) - 2, int(c.x) + 3):
                        if t.pore_factor_at(Vector2(float(wx), float(wz))) >= 0.8:
                                sat += 1
        _check(sat >= 6, "pit + surrounding cells saturated (%d)" % sat)
        # Wet walls fail at a lower angle than the dry control (same material).
        var dry: Variant = _find_dry_trench_spot(t)
        var wet: Variant = _find_wet(t, 0.35)
        _check(dry != null and wet != null, "found dry + wet control spots")
        if dry != null and wet != null:
                var d: Vector2 = dry
                var w: Vector2 = wet
                _override_material_box(t, d, 8, Mat.ID_GRAVEL)
                _override_material_box(t, w, 8, Mat.ID_GRAVEL)
                _stamp_trench(t, d, 6, 0.9)
                _stamp_trench(t, w, 6, 0.9)
                t.stabilize_rect(Rect2(d.x - 8.0, d.y - 8.0, 16.0, 16.0))
                t.stabilize_rect(Rect2(w.x - 8.0, w.y - 8.0, 16.0, 16.0))
                var dry_deg := _max_slope_deg(t, d, 6)
                var wet_deg := _max_slope_deg(t, w, 6)
                _check(dry_deg > 33.0, "dry gravel trench walls hold ~repose (%.1f)" % dry_deg)
                _check(wet_deg < dry_deg - 10.0,
                        "wet walls fail at a lower angle (%.1f < %.1f)" % [wet_deg, dry_deg])

# ------------------------------------------------------------------ P5

func _p5_tunnels(t) -> void:
        print("[P5] walkable tunnels")
        var hill: Variant = _find_hill(t)
        _check(hill != null, "found tunnelling hillside")
        if hill == null:
                return
        var c: Vector2 = hill
        var x0 := c.x
        var z0 := c.y
        var y_bore: float = t.height_at(c) - 8.0
        t.carve_capsule(Vector3(x0, y_bore, z0), Vector3(x0 + 32.0, y_bore, z0), 1.5)
        _check(t.carve_set.capsule_count() == 1, "3 m bore carved as one capsule")
        _check(t.surface_open_rect(Rect2(x0 + 28.0, z0 - 4.0, 10.0, 8.0)),
                "bore mouth opens the surface")
        var r := 0.45
        var p := Vector3(x0 + 1.0, y_bore - 1.05, z0)
        var clean := true
        var floored := true
        var ceilinged := true
        var steps := 0
        while steps < 300:
                steps += 1
                if p.x >= x0 + 36.0 and t.is_solid(p - Vector3(0, r + 0.25, 0)):
                        break  # out of the bore and standing on the heightfield
                var grounded: bool = t.is_solid(p - Vector3(0, r + 0.25, 0))
                var vy := 0.0 if grounded else -0.45
                var want := p + Vector3(0.55, vy, 0.0)
                if t.capsule_solid(want, r):
                        # Blocked ahead (bore mouth lip): step up instead of fighting it.
                        var want_up := want + Vector3(0.0, 0.4, 0.0)
                        if not t.capsule_solid(want_up, r):
                                want = want_up
                var res: Dictionary = t.resolve_capsule(want, r)
                p = res.position
                if p.x < x0 + 30.5:
                        if t.capsule_solid(p, 0.35):
                                clean = false
                        if t.is_solid(p + Vector3(0, 0.95, 0)):
                                ceilinged = false
                        if not t.is_solid(p - Vector3(0, r + 0.25, 0)):
                                floored = false
        _check(clean, "walker capsule never penetrates solid (30 m through the bore)")
        _check(ceilinged, "walker stays under the ceiling (headroom check)")
        _check(floored, "walker stays on the bore floor")
        _check(p.x > x0 + 33.0, "walker exited the mouth (x %.1f)" % p.x)
        var ground_h: float = t.height_at(Vector2(p.x, p.z))
        _check(absf(p.y - (ground_h - r)) < 1.2,
                "walker returned to heightfield walking outside (y %.2f vs ground %.2f)" % [p.y, ground_h - r])

        # Tunnel dig: digging inside carved air extends the bore, reports the mass
        # and hoists spoil to the surface above the face.
        # Wall rock rules apply inside the bore: 2 m in, the wall sits under ~8 m
        # of cover (granite by the depth rule), so masking granite must refuse
        # the dig even though the hill's surface cover is loam/clay.
        var wall := Vector3(x0 + 2.0, y_bore - 1.2, z0)
        var sph0: int = t.carve_set.sphere_count()
        t.dig_mask[Mat.ID_GRANITE] = 0
        var masked: float = t.dig(wall, 1.2)
        t.dig_mask[Mat.ID_GRANITE] = 1
        _check(masked == 0.0, "masked granite wall refuses the tunnel dig (%.2f m3)" % masked)
        _check(t.carve_set.sphere_count() == sph0, "masked tunnel dig carved nothing")
        var face := Vector3(x0 + 26.0, y_bore - 1.2, z0)
        var face_spot := Vector2(face.x, face.z)
        var pre_face := _copy_region(t, face_spot, 3)
        var stats0: Dictionary = t.get_stats()
        var dug_face: float = t.dig(face, 1.2)
        var post_face := _copy_region(t, face_spot, 3)
        var gain := 0.0
        for k in pre_face.size():
                gain += post_face[k] - pre_face[k]
        _check(dug_face > 0.05, "tunnel dig removes and reports mass (%.2f m3)" % dug_face)
        _check(t.get_stats().dug_m3 > stats0.dug_m3, "tunnel mass entered the ledger")
        _check(gain > 0.05, "spoil hoisted to the surface above the face (+%.2f m3 loose)" % gain)

# ------------------------------------------------------------------ PX

func _px_infra(t) -> void:
        print("[PX] collision lifecycle, mesh resolution, cave cache")
        # 1 m ground mesh: a sub-2-m dig bowl must actually appear in the mesh.
        var spot: Variant = _find_flat(t, Mat.ID_SAND, 9.0, 6, 0.0, 0.2)
        _check(spot != null, "found spot for mesh fidelity probe")
        if spot != null:
                var c: Vector2 = spot
                t.dig(Vector3(c.x, t.height_at(c), c.y), 0.9, 1.0)
                t.flush_dirty()
                var found := false
                for n in t.get_children():
                        if n is MeshInstance3D and String(n.name).begins_with("Ground_"):
                                var mi: MeshInstance3D = n
                                if mi.get_aabb().has_point(Vector3(c.x, t.height_at(c), c.y)):
                                        found = true
                                        var vc: int = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
                                        _check(vc == 49 * 49, "ground chunk built at 1 m resolution (%d verts)" % vc)
                                        break
                _check(found, "found the chunk containing the pit")
                t.undo()
        # Collision lifecycle: enabling builds shapes, disabling removes them.
        var g2: Variant = _find_flat(t, -1, 6.0, 6, 0.0, 1.0)
        if g2 == null:
                g2 = Vector2(60.0, -60.0)
        var gp: Vector2 = g2
        for off in [Vector2(0, 0), Vector2(3, 0), Vector2(-3, 0)]:
                t.set_material_override(gp + off, Mat.ID_GRANITE)
        var gh: float = t.height_at(gp)
        var sph0: int = t.carve_set.sphere_count()
        t.carve(Vector3(gp.x, gh - 5.0, gp.y), 2.0)
        _check(t.carve_set.sphere_count() == sph0 + 1, "granite cavity holds for the collision probe")
        t.enable_collision = true
        var shapes := 0
        if t.has_node("TerrainCollision"):
                shapes = t.get_node("TerrainCollision").get_child_count()
        _check(shapes == 16 * 16 + 1, "collision built 256 chunk shapes + cave shape (%d)" % shapes)
        t.enable_collision = false
        var shapes_after := 0
        if t.has_node("TerrainCollision"):
                shapes_after = t.get_node("TerrainCollision").get_child_count()
        _check(shapes_after == 0, "collision fully removed when disabled (%d left)" % shapes_after)
        # Cave mesh cache: a no-change remesh reproduces identical cached arrays.
        t.enable_collision = true
        var cave: MeshInstance3D = t.get_node("CaveSurface")
        var v0: int = cave.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
        t._cave_dirty = true
        t.flush_dirty()
        var cave2: MeshInstance3D = t.get_node("CaveSurface")
        var v1: int = cave2.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
        _check(v1 == v0 and v0 > 0, "cave mesh cached rebuild is identical (%d verts)" % v1)
        t.enable_collision = false

# ------------------------------------------------------------------ P9

func _p9_paint(t) -> void:
        print("[P9] material paint brush")
        var spot: Variant = _find_flat(t, -1, 6.0, 5, 0.0, 0.9)
        _check(spot != null, "found a spot for the paint probe")
        if spot == null:
                return
        var p: Vector2 = spot
        var i := clampi(int(p.x + t.data.HALF), 0, t.data.N - 1)
        var j := clampi(int(p.y + t.data.HALF), 0, t.data.N - 1)
        var bidx: int = i + j * t.data.N
        var before_id: int = t.material_id_at(p)
        var before_biome: int = t.data.biome[bidx]
        var before_col: Color = MeshUtil.vertex_color(t.data, i, j)
        var target := Mat.ID_GRANITE
        if before_id == Mat.ID_GRANITE:
                target = Mat.ID_SNOW    # paint something visibly different

        t.paint_material(p.x, p.y, 6.0, target)
        _check(t.material_id_at(p) == target, "painted cell reads %s" % Mat.key_for_id(target))
        _check(t.material_at(p) == Mat.key_for_id(target), "material_at reports the paint")
        _check(t.roof_material_id_at(p) == target,
                        "paint is a design layer (roof-bearing, not a spoil skin)")
        _check(t.data.biome[bidx] == target,
                        "biome grid synced (vertex-colour source updated)")
        _check(not MeshUtil.vertex_color(t.data, i, j).is_equal_approx(before_col),
                        "ground colour changed at the spot")
        _check(t.can_undo(), "paint pushed an undo op")

        _check(t.undo(), "undo the paint")
        _check(t.material_id_at(p) == before_id and t.data.biome[bidx] == before_biome,
                        "undo restored material + colour exactly")
        _check(t.redo(), "redo the paint")
        _check(t.material_id_at(p) == target, "redo re-applied the paint")

        # Painted ground plays by the painted material's dig rules.
        var h: float = t.height_at(p)
        t.dig_mask[target] = 0
        var masked: float = t.dig(Vector3(p.x, h, p.y), 1.2, 3.0)
        t.dig_mask[target] = 1
        _check(masked == 0.0, "masked paint refuses the dig (%.2f m3)" % masked)
        _check(t.height_at(p) == h, "refused dig left the ground untouched")

        # Persistence: painted materials survive save/quit/load with visuals.
        var path := "res://review_state/stoem_p9_paint.res"
        _check(t.save_edits(path) == OK, "saved the painted world")
        var t2 = _make_terrain(t.seed_value)
        _check(t2.load_edits(path) == OK, "loaded the painted world")
        _check(t2.material_id_at(p) == target, "paint survived the round trip")
        _check(t2.roof_material_id_at(p) == target, "paint still roof-bearing after reload")
        var i2 := clampi(int(p.x + t2.data.HALF), 0, t2.data.N - 1)
        var j2 := clampi(int(p.y + t2.data.HALF), 0, t2.data.N - 1)
        _check(t2.data.biome[i2 + j2 * t2.data.N] == target,
                        "reloaded world shows the painted colour")

# ------------------------------------------------------------------ P1

func _p1_materials() -> void:
        print("[P1] material layers")
        var a = _make_terrain(424242)
        var b = _make_terrain(424242)
        _check(a.data.materials == b.data.materials, "material grid stable across same-seed rebakes")
        _check(a.data.water_head == b.data.water_head, "water table stable across rebakes")
        _check(a.data.heights == b.data.heights, "heights stable across rebakes")
        var pts := []
        for gy in 5:
                for gx in 5:
                        pts.append(Vector2(-300.0 + float(gx) * 150.0, -300.0 + float(gy) * 150.0))
        pts.append(Vector2(0.0, 0.0))
        pts.append(Vector2(-60.0, 100.0))
        pts.append(Vector2(120.0, -60.0))
        var ids := {}
        var keys := {}
        for p in pts:
                ids[a.material_id_at(p)] = true
                keys[a.material_at(p)] = true
        _check(ids.size() >= 4, "materials differ across at least 4 regions (%d distinct)" % ids.size())
        _check(keys.size() >= 4, "material keys differ across regions (%s)" % [", ".join(keys.keys())])

# ------------------------------------------------------------------ P6

func _p6_persistence() -> void:
        print("[P6] persistence and exact undo/redo")
        var a = _make_terrain(777)
        var pristine: PackedFloat32Array = a.data.heights.duplicate()
        var pristine_water: PackedFloat32Array = a.data.water_head.duplicate()
        var s: Variant = _find_flat(a, -1, 6.0, 8, 0.0, 1.0)
        _check(s != null, "found sculpt spot")
        if s == null:
                return
        var c: Vector2 = s
        a.sculpt(c.x, c.y, 6.0, 1.5, Terrain.TOOL_RAISE, 0.6)
        _check(a.can_undo(), "sculpt stroke pushed one undo op")
        var carve_x := c.x + 40.0
        # Force granite so the cavity provably holds (wet weak roofs would collapse).
        a.set_material_override(Vector2(carve_x, c.y), Mat.ID_GRANITE)
        a.set_material_override(Vector2(carve_x + 4.0, c.y), Mat.ID_GRANITE)
        a.set_material_override(Vector2(carve_x - 4.0, c.y), Mat.ID_GRANITE)
        var carve_h: float = a.height_at(Vector2(carve_x, c.y))
        a.carve(Vector3(carve_x, carve_h - 6.0, c.y), 2.5)
        _check(a.carve_set.sphere_count() == 1, "carve persisted a sphere primitive")
        var d: Variant = _find_flat(a, Mat.ID_SAND, 9.0, 6, 0.0, 0.3)
        if d == null:
                d = c + Vector2(0, 60)
                a.set_material_override(d, Mat.ID_SAND)
        _check(d != null, "found dig spot")
        var dv: Vector2 = d
        a.dig(Vector3(dv.x, a.height_at(dv), dv.y), 1.0, 1.5)
        var stats_pre: Dictionary = a.get_stats()
        _check(stats_pre.dug_m3 > 0.0, "dig recorded in the mass ledger (%.2f m3)" % stats_pre.dug_m3)
        var post_heights: PackedFloat32Array = a.data.heights.duplicate()
        var post_water: PackedFloat32Array = a.data.water_head.duplicate()
        var post_spheres: PackedFloat32Array = a.carve_set.spheres.duplicate()
        var post_mats: PackedInt32Array = a.data.materials.duplicate()
        var path := "res://review_state/stoem_p6_store.res"
        var err: int = a.save_edits(path)
        _check(err == OK, "save_edits returned OK")
        var b = _make_terrain(777)
        var err2: int = b.load_edits(path)
        _check(err2 == OK, "load_edits returned OK")
        _check(b.data.heights == post_heights, "heights identical after save/quit/reload")
        _check(b.data.water_head == post_water, "water table identical after reload")
        _check(b.carve_set.spheres == post_spheres, "carve primitives identical after reload")
        _check(b.data.materials == post_mats, "baked material grid identical after reload")
        _check(b.material_id_at(dv) == a.material_id_at(dv), "dig material overrides survive reload")
        _check(not b.is_solid(Vector3(carve_x, carve_h - 6.0, c.y)), "cave air survives reload")
        _check(b.get_stats().dug_m3 == stats_pre.dug_m3, "dug ledger survived reload")
        _check(b.get_stats().collapses == stats_pre.collapses, "collapse ledger survived reload")
        var ops := 0
        while a.can_undo():
                a.undo()
                ops += 1
        _check(ops >= 3, "undo stack held sculpt + carve + dig (%d ops)" % ops)
        _check(a.data.heights == pristine, "undo chain restores pristine terrain exactly")
        _check(a.data.water_head == pristine_water, "water table untouched by undo chain")
        while a.can_redo():
                a.redo()
        _check(a.data.heights == post_heights, "redo chain restores post-edit state exactly")
        _check(a.carve_set.spheres == post_spheres, "redo restores the carve primitive")
        # Backward compatibility: a store missing the new fields still loads.
        var old := EditStore.new()
        old.version = 0
        old.seed_value = 777
        var old_path := "res://review_state/stoem_p6_old_store.res"
        ResourceSaver.save(old, old_path)
        var b2 = _make_terrain(777)
        var err3: int = b2.load_edits(old_path)
        _check(err3 == OK, "legacy store without new fields loads")
        _check(b2.data.heights == pristine, "legacy store leaves terrain at bake state")

# ------------------------------------------------------------------ P7

## (total rise, total drop) between two region copies.
func _region_delta(p_a: PackedFloat32Array, p_b: PackedFloat32Array) -> Vector2:
        var pos := 0.0
        var neg := 0.0
        for k in p_a.size():
                var d := p_b[k] - p_a[k]
                if d > 0.0:
                        pos += d
                else:
                        neg += d
        return Vector2(pos, neg)

# ------------------------------------------------------------------ P8

## Count ground-sheet indices of the chunk containing a world point.
func _ground_indices(t, p_wx: float, p_wz: float) -> int:
        var ci := clampi(int(floor((p_wx + 384.0) / 48.0)), 0, 15)
        var cj := clampi(int(floor((p_wz + 384.0) / 48.0)), 0, 15)
        return (MeshUtil.ground_chunk_arrays(t, ci, cj)[3] as PackedInt32Array).size()

## Gentle spot beside a >55 degree cliff (the relax-divergence country).
func _find_cliff_edge(t) -> Variant:
        for wz in range(-330, 331, 6):
                for wx in range(-330, 331, 6):
                        var p := Vector2(float(wx), float(wz))
                        var near := false
                        for e in used_spots:
                                if p.distance_to(e) < 42.0:
                                        near = true
                                        break
                        if near:
                                continue
                        if t.slope_deg_at(p) > 7.0 or t.pore_factor_at(p) > 0.3:
                                continue
                        var cliff := false
                        for off in [Vector2(4, 0), Vector2(-4, 0), Vector2(0, 4), Vector2(0, -4),
                                        Vector2(8, 0), Vector2(-8, 0), Vector2(0, 8), Vector2(0, -8),
                                        Vector2(6, 6), Vector2(-6, -6)]:
                                if t.slope_deg_at(p + off) > 55.0:
                                        cliff = true
                                        break
                        if cliff:
                                used_spots.append(p)
                                return p
        return null

func _p8_mesh_and_mass(t) -> void:
        print("[P8] sheet cuts, dig mass vs tunnels, relax stability")
        var full := 48 * 48 * 6

        # --- A: a carve at the surface cuts the ground sheet (visible pit + open
        # collision); undo heals the sheet exactly ---
        var ga: Variant = _find_flat(t, -1, 6.0, 6, 0.0, 0.4)
        _check(ga != null, "found granite-able spot for the sheet-cut probe")
        if ga != null:
                var ca: Vector2 = ga
                _override_material_box(t, ca, 5, Mat.ID_GRANITE)
                var ha: float = t.height_at(ca)
                t.carve(Vector3(ca.x, ha, ca.y), 3.0)
                var cut_idx := _ground_indices(t, ca.x, ca.y)
                _check(cut_idx <= full - 6 * 8,
                                "ground sheet cut at the pit (%d of %d indices)" % [cut_idx, full])
                _check(t.surface_is_open_world(ca.x, ca.y), "pit reports open")
                var ray: Dictionary = t.raycast(Vector3(ca.x, ha + 40.0, ca.y), Vector3.DOWN, 80.0)
                _check(not ray.is_empty() and float(ray.position.y) < ha - 1.5,
                                "down-ray through the hole hits the pit floor (%.2f)" % float(ray.position.y))
                _check(t.undo(), "undo the surface carve")
                _check(_ground_indices(t, ca.x, ca.y) == full,
                                "undo re-closed the ground sheet (%d)" % _ground_indices(t, ca.x, ca.y))

        # --- B: digging over a tunnel books solid only (no phantom air mass,
        # no sheet suspended inside the void) ---
        var gb: Variant = _find_flat(t, -1, 6.0, 6, 0.0, 0.4)
        _check(gb != null, "found spot for the dig-over-tunnel probe")
        if gb != null:
                var cb: Vector2 = gb
                _override_material_box(t, cb, 5, Mat.ID_GRANITE)
                var hb: float = t.height_at(cb)
                t.carve(Vector3(cb.x, hb - 4.5, cb.y), 1.5)   # holding cavity, 3 m roof
                var pre_b := _copy_region(t, cb, 8)
                t.forced_dig_material = Mat.ID_LOAM
                var v_b: float = t.dig(Vector3(cb.x, hb, cb.y), 2.0, 45.0)
                t.forced_dig_material = -1
                var post_b := _copy_region(t, cb, 8)
                var drop_b := 0.0
                for q in pre_b.size():
                        drop_b += maxf(0.0, pre_b[q] - post_b[q])
                _check(v_b > 2.0, "deep dig over the tunnel removed mass (%.2f m3)" % v_b)
                _check(absf(drop_b - v_b) < 0.1,
                                "height drop equals booked mass, no phantom air (%.2f vs %.2f)" % [drop_b, v_b])
                var suspended := 0
                for dj in range(-8, 9):
                        for di in range(-8, 9):
                                var old_b: float = pre_b[(dj + 8) * 17 + (di + 8)]
                                var ii := clampi(int(cb.x) + di + 384, 0, t.data.N - 1)
                                var jj := clampi(int(cb.y) + dj + 384, 0, t.data.N - 1)
                                var new_b: float = t.data.heights[ii + jj * t.data.N]
                                if new_b < old_b - 0.1 and t.carve_set.sdf(Vector3(
                                                float(int(cb.x) + di), new_b + 0.05, float(int(cb.y) + dj))) > 0.0:
                                        suspended += 1
                _check(suspended == 0, "no cut column suspended inside carved air (%d)" % suspended)
                var hmin := 1e9
                var hmax := -1e9
                for q in t.data.heights.size():
                        hmin = minf(hmin, t.data.heights[q])
                        hmax = maxf(hmax, t.data.heights[q])
                _check(hmin > -60.0 and hmax < 300.0,
                                "heights stayed finite after the steep-country dig (%.1f..%.1f)" % [hmin, hmax])
                _check(t.undo() and t.undo(), "undo the dig + carve")
                _check(_copy_region(t, cb, 8) == pre_b, "undo restored the dig-over-tunnel state")

        # --- C: dig beside a cliff cannot melt the hillside (relax divergence
        # + baked-slope avalanche regressions) ---
        var cliff: Variant = _find_cliff_edge(t)
        _check(cliff != null, "found a cliff-edge spot")
        if cliff != null:
                var cc: Vector2 = cliff
                var pre_c := _copy_region(t, cc, 10)
                var v_c: float = t.dig(Vector3(cc.x, t.height_at(cc), cc.y), 2.0, 8.0)
                _check(v_c > 0.5, "cliff-edge dig worked (%.2f m3)" % v_c)
                var cmin := 1e9
                var cmax := -1e9
                for q in t.data.heights.size():
                        cmin = minf(cmin, t.data.heights[q])
                        cmax = maxf(cmax, t.data.heights[q])
                _check(cmin > -60.0 and cmax < 300.0,
                                "no relax divergence beside the cliff (%.1f..%.1f)" % [cmin, cmax])
                _check(t.undo(), "undo the cliff-edge dig")
                _check(_copy_region(t, cc, 10) == pre_c, "cliff dig undone exactly")

        # --- D: overlapping carve stamps produce zero duplicated cave triangles
        # (z-fighting walls) and zero sheet-coincident apron quads ---
        var gd: Variant = _find_flat(t, -1, 6.0, 8, 0.0, 0.4)
        _check(gd != null, "found spot for the cave-mesh probe")
        if gd != null:
                var cd: Vector2 = gd
                _override_material_box(t, cd, 7, Mat.ID_GRANITE)
                var hd: float = t.height_at(cd)
                t.carve(Vector3(cd.x, hd, cd.y), 2.5)          # surface pit (apron country)
                for s in 5:
                        t.carve_void(Vector3(cd.x + 20.0 + float(s) * 1.2, hd - 8.0, cd.y), 1.6)
                var cave: Array = MeshUtil.cave_mesh_arrays(t, {}, Rect2())
                var cverts: PackedVector3Array = cave[0]
                var cidx: PackedInt32Array = cave[3]
                _check(cidx.size() > 60, "cave mesh has geometry (%d indices)" % cidx.size())
                var seen := {}
                var dupes := 0
                var apron := 0
                var k := 0
                while k + 2 < cidx.size():
                        var tri := []
                        for q in 3:
                                var p: Vector3 = cverts[cidx[k + q]]
                                tri.append("%.2f,%.2f,%.2f" % [p.x, p.y, p.z])
                        tri.sort()
                        var key := "|".join(tri)
                        if seen.has(key):
                                dupes += 1
                        seen[key] = true
                        var va: Vector3 = cverts[cidx[k]]
                        var vb: Vector3 = cverts[cidx[k + 1]]
                        var vc: Vector3 = cverts[cidx[k + 2]]
                        var cen := (va + vb + vc) * (1.0 / 3.0)
                        var on_sheet := true
                        for q in 3:
                                var pv: Vector3 = [va, vb, vc][q]
                                if absf(pv.y - t.height_at(Vector2(pv.x, pv.z))) > 0.02:
                                        on_sheet = false
                                        break
                        if on_sheet and (vb - va).cross(vc - va).normalized().y > 0.35 \
                                        and t.carve_set.sdf(cen) < -0.05:
                                apron += 1
                        k += 3
                _check(dupes == 0, "no duplicated cave triangles (%d)" % dupes)
                _check(apron == 0, "no cave triangles coincident with the ground sheet (%d)" % apron)
                while t.can_undo():
                        t.undo()

        # --- E: edited_region reports the stroke's own rect, not the whole map ---
        var ge: Variant = _find_flat(t, -1, 6.0, 4, 0.0, 0.4)
        var ge2: Variant = _find_flat(t, -1, 6.0, 4, 0.0, 0.4)
        _check(ge != null and ge2 != null, "found two spots for the rect probe")
        if ge != null and ge2 != null:
                _override_material_box(t, ge, 4, Mat.ID_GRANITE)
                _override_material_box(t, ge2, 4, Mat.ID_GRANITE)
                var rects: Array = []
                var handler := func(r: Rect2) -> void: rects.append(r)
                t.edited_region.connect(handler)
                t.carve(Vector3(ge.x, t.height_at(ge) - 5.0, ge.y), 1.0)
                t.carve(Vector3(ge2.x, t.height_at(ge2) - 5.0, ge2.y), 1.0)
                t.edited_region.disconnect(handler)
                if rects.size() >= 2:
                        var r2: Rect2 = rects[1]
                        _check(not r2.has_point(ge) and r2.size.x < 40.0,
                                        "second carve rect is local (%s)" % r2)
                else:
                        _check(false, "edited_region fired per carve (%d)" % rects.size())
                while t.can_undo():
                        t.undo()

        # --- F: chained capsule bores: dedupe, walkability, exact undo ---
        var gf: Variant = _find_flat(t, -1, 6.0, 8, 0.0, 0.4)
        _check(gf != null, "found spot for the capsule-chain probe")
        if gf != null:
                var cf: Vector2 = gf
                _override_material_box(t, cf, 20, Mat.ID_GRANITE)
                var hf: float = t.height_at(cf)
                var a := Vector3(cf.x, hf - 8.0, cf.y)
                var b := a + Vector3(8.0, 0.0, 0.0)
                var c := b + Vector3(8.0, 0.0, 0.0)
                t.carve_capsule(a, b, 1.5)
                t.carve_capsule(b, c, 1.5)
                _check(t.carve_set.capsule_count() == 2, "two chained capsules carved")
                _check(not t.carve_capsule(a, b, 1.5), "re-carving the same segment is refused")
                _check(t.carve_set.capsule_count() == 2, "refused segment added nothing")
                var walk_ok := true
                for s in [2.0, 6.0, 11.0, 14.0]:
                        var p := a + Vector3(s, 0.0, 0.0)
                        if t.is_solid(p) or t.capsule_solid(p, 0.45):
                                walk_ok = false
                _check(walk_ok, "chained bore is walkable end to end")
                _check(t.undo() and t.undo(), "undo both capsules")
                _check(t.carve_set.capsule_count() == 0, "chain undone completely")

        # --- G: a hillside bore opens its mouth in the ground MESH ---
        var hill: Variant = _find_hill(t)
        _check(hill != null, "found hill for the mouth-mesh probe")
        if hill != null:
                var ch: Vector2 = hill
                var y_bore: float = t.height_at(ch) - 8.0
                t.carve_capsule(Vector3(ch.x, y_bore, ch.y), Vector3(ch.x + 32.0, y_bore, ch.y), 1.5)
                var mouth_x := -1e9
                for x in range(int(ch.x) + 1, int(ch.x) + 37):
                        if t.surface_is_open_world(float(x), ch.y):
                                mouth_x = float(x)
                                break
                _check(mouth_x > -1e8, "bore mouth opens the surface query (x %.0f)" % mouth_x)
                if mouth_x > -1e8:
                        _check(_ground_indices(t, mouth_x, ch.y) < full,
                                        "ground sheet cut at the tunnel mouth (%d < %d)" % [
                                                        _ground_indices(t, mouth_x, ch.y), full])
                _check(t.undo(), "undo the hill bore")
                _check(_ground_indices(t, ch.x + 20.0, ch.y) == full,
                                "sheet healed along the bore after undo")

        # --- H: re-bake is a new world (stale tunnels must not survive it) ---
        var gh: Variant = _find_flat(t, -1, 6.0, 4, 0.0, 0.4)
        if gh != null:
                var chh: Vector2 = gh
                _override_material_box(t, chh, 3, Mat.ID_GRANITE)
                t.carve(Vector3(chh.x, t.height_at(chh) - 5.0, chh.y), 2.0)
                _check(t.carve_set.sphere_count() == 1, "carved before re-bake")
                t.bake()
                _check(t.carve_set.sphere_count() == 0 and t.carve_set.capsule_count() == 0,
                                "bake() cleared the carve set")
                _check(not t.surface_is_open_world(chh.x, chh.y), "surface closed after re-bake")

func _p7_bugfixes(t) -> void:
        print("[P7] tunnel + dig bugfixes")
        var hill: Variant = _find_hill(t)
        _check(hill != null, "found hill for the bugfix probes")
        if hill == null:
                return
        var c: Vector2 = hill
        var h0: float = t.height_at(c)
        var y_bore: float = h0 - 8.0
        # Keep the whole probe hill granitic so roofs provably hold here.
        _override_material_box(t, Vector2(c.x - 30.0, c.y), 50, Mat.ID_GRANITE)

        # --- A: the cave surface is a real triangle soup, wound towards the air ---
        t.carve_capsule(Vector3(c.x, y_bore, c.y), Vector3(c.x + 30.0, y_bore, c.y), 1.5)
        var arrays: Array = MeshUtil.cave_mesh_arrays(t, {}, Rect2())
        var idx: PackedInt32Array = arrays[3]
        _check(idx.size() > 60, "cave mesh has geometry (%d indices)" % idx.size())
        _check(idx.size() % 3 == 0, "cave indices form whole triangles (%d %% 3 == %d)" % [idx.size(), idx.size() % 3])
        var cverts: PackedVector3Array = arrays[0]
        var checked := 0
        var inverted := 0
        var k := 0
        while k + 2 < idx.size():
                var va := cverts[idx[k]]
                var vb := cverts[idx[k + 1]]
                var vc := cverts[idx[k + 2]]
                var tn := (vb - va).cross(vc - va)
                if tn.length_squared() > 1.0e-10:
                        var cen := (va + vb + vc) * (1.0 / 3.0)
                        # Skip crease bridges: triangles spanning the concave seam
                        # where carve meets heightfield have a buried centroid and
                        # no meaningful geometric orientation (both sides solid).
                        if absf(t.implicit_F(cen)) < 0.1:
                                checked += 1
                                if tn.normalized().dot(t.implicit_normal(cen)) <= 0.0:
                                        inverted += 1
                k += 3
        _check(checked > 50, "winding sampled enough triangles (%d)" % checked)
        _check(inverted == 0, "every cave triangle faces the air (%d/%d inverted)" % [inverted, checked])

        # --- B: cave collision shape is a valid, double-sided triangle soup ---
        t.enable_collision = true
        var poly: ConcavePolygonShape3D = t._cave_shape.shape if t._cave_shape != null else null
        _check(poly != null, "cave collision shape exists")
        if poly != null:
                var nfaces: int = poly.get_faces().size()
                _check(nfaces > 0 and nfaces % 3 == 0, "cave collision faces are whole triangles (%d)" % nfaces)
                _check(poly.backface_collision, "cave collision catches backfaces (tunnel floors)")
        t.enable_collision = false

        # --- C: digging at a tunnel FACE advances the bore, not the surface above ---
        var y_blind: float = h0 - 11.0
        t.carve_capsule(Vector3(c.x - 20.0, y_blind, c.y), Vector3(c.x + 5.0, y_blind, c.y), 1.5)
        var face := Vector3(c.x + 6.5, y_blind, c.y)   # on the blind bore's end cap
        _check(absf(t.carve_set.sdf(face)) < 0.15, "face point sits on the bore boundary (sdf %.2f)" % t.carve_set.sdf(face))
        var sc0: int = t.carve_set.sphere_count()
        var pre_face := _copy_region(t, Vector2(face.x, face.z), 9)
        var v_face: float = t.dig(face, 1.2)
        var d_face := _region_delta(pre_face, _copy_region(t, Vector2(face.x, face.z), 9))
        _check(v_face > 0.05, "face dig removed mass (%.2f m3)" % v_face)
        _check(t.carve_set.sphere_count() == sc0 + 1, "face dig extended the carve set")
        _check(not t.is_solid(face + Vector3(0.6, 0.0, 0.0)), "bore advanced past the old face")
        _check(d_face.y == 0.0, "face dig cut nothing on the surface above (drop %.3f m3)" % d_face.y)
        _check(d_face.x > 0.05, "spoil hoisted above the face (+%.2f m3)" % d_face.x)

        # --- D: digging the same tunnel spot twice books nothing the second time ---
        var stats_pre2: Dictionary = t.get_stats()
        var v_again: float = t.dig(face, 1.2)
        _check(v_again == 0.0, "repeat dig at a carved spot returns 0 (%.2f)" % v_again)
        _check(t.get_stats().dug_m3 == stats_pre2.dug_m3, "repeat dig books no mass")

        # --- E: digging the bore FLOOR deepens the void; undo restores exactly ---
        var floor_p := Vector3(c.x - 8.0, y_blind - 1.5, c.y)
        _check(absf(t.carve_set.sdf(floor_p)) < 0.15, "floor point sits on the bore floor (sdf %.2f)" % t.carve_set.sdf(floor_p))
        var sc_e: int = t.carve_set.sphere_count()
        var pre_floor := _copy_region(t, Vector2(floor_p.x, floor_p.z), 9)
        t.dig(floor_p, 1.2)
        _check(t.carve_set.sphere_count() == sc_e + 1, "floor dig extended the carve set")
        _check(not t.is_solid(floor_p - Vector3(0.0, 0.8, 0.0)), "floor dig deepened the bore")
        var d_floor := _region_delta(pre_floor, _copy_region(t, Vector2(floor_p.x, floor_p.z), 9))
        _check(d_floor.y == 0.0, "floor dig cut nothing on the surface above (drop %.3f m3)" % d_floor.y)
        _check(t.undo(), "undo the floor dig")
        _check(_copy_region(t, Vector2(floor_p.x, floor_p.z), 9) == pre_floor, "undo restored heights exactly")
        _check(t.carve_set.sphere_count() == sc_e, "undo removed the floor sphere")
        _check(t.is_solid(floor_p - Vector3(0.0, 0.8, 0.0)), "floor solid again after undo")

        # --- F: editor-style carving walks a tunnel into the hillside ---
        var cam := Vector3(c.x - 45.0, h0 + 25.0, c.y)
        var dir := (Vector3(c.x + 10.0, y_bore - 1.0, c.y) - cam).normalized()
        var sc_f: int = t.carve_set.sphere_count()
        var hits: Array = []
        for i in 12:
                var hit: Dictionary = t.raycast(cam, dir, 400.0)
                if hit.is_empty():
                        break
                t.carve_void(hit.position, 1.6)
                t.flush_dirty()
                hits.append(hit.position)
        _check(hits.size() == 12, "every editor carve stamp found a wall (%d hits)" % hits.size())
        _check(t.carve_set.sphere_count() == sc_f + 12, "twelve carve stamps accepted (%d added)" % (t.carve_set.sphere_count() - sc_f))
        if hits.size() == 12:
                var first: Vector3 = hits[0]
                var last: Vector3 = hits[11]
                var mid: Vector3 = hits[6]
                _check(last.distance_to(cam) - first.distance_to(cam) > 6.0,
                                "tunnel advanced into the hill (%.1f m)" % (last.distance_to(cam) - first.distance_to(cam)))
                _check(t.height_at(Vector2(mid.x, mid.z)) > mid.y + 1.0,
                                "mid-tunnel still under cover (%.1f m)" % (t.height_at(Vector2(mid.x, mid.z)) - mid.y))
                _check(not t.surface_open_rect(Rect2(mid.x - 2.0, mid.z - 2.0, 4.0, 4.0)),
                                "surface above the mid-tunnel stayed closed")

        # --- G: tunnel digs under thin loam cover collapse (and undo cleanly) ---
        var loam: Variant = _find_flat(t, Mat.ID_LOAM, 7.0, 9, 0.0, 0.35)
        _check(loam != null, "found dry loam for the collapse probe")
        if loam != null:
                var l: Vector2 = loam
                var hl: float = t.height_at(l)
                var cl := Vector3(l.x, hl - 8.0, l.y)
                _check(t.carve_void(cl, 1.5), "pilot bore holds in loam")
                var pre_g := _copy_region(t, l, 12)
                var sc_g: int = t.carve_set.sphere_count()
                var coll0: int = t.get_stats().collapses
                var v_g: float = t.dig(cl, 5.0)
                _check(v_g > 1.0, "wide tunnel dig removed mass (%.1f m3)" % v_g)
                _check(t.get_stats().collapses > coll0, "thin loam roof collapsed on the tunnel dig")
                _check(t.carve_set.sphere_count() == sc_g, "collapsed sphere cancelled out (no phantom void)")
                _check(t.height_at(l) < hl - 1.5, "collapse subsided the surface (%.1f -> %.1f)" % [hl, t.height_at(l)])
                _check(t.undo(), "undo the tunnel dig + collapse")
                _check(_copy_region(t, l, 12) == pre_g, "undo restored heights exactly after collapse")
                _check(t.carve_set.sphere_count() == sc_g, "undo left the pilot bore intact")
                _check(not t.is_solid(cl), "pilot bore still open after undo")

        # --- H: digging at the floor of an open pit in cohesionless ground ---
        # (regression: the pit floor used to read as a covered roof and the dig
        # collapsed into the surface instead of extending the hole)
        var sand: Variant = _find_flat(t, Mat.ID_SAND, 9.0, 6, 0.0, 0.2)
        _check(sand != null, "found sand for the pit-floor probe")
        if sand != null:
                var sp: Vector2 = sand
                var sh: float = t.height_at(sp)
                _check(t.carve_void(Vector3(sp.x, sh, sp.y), 3.0), "carved an open sand pit")
                var floor_pt := Vector3(sp.x, sh - 3.0, sp.y)   # pit floor, sdf ~ 0
                var sc_h: int = t.carve_set.sphere_count()
                var coll_h: int = t.get_stats().collapses
                var v_h: float = t.dig(floor_pt, 1.2)
                _check(v_h > 0.05, "pit-floor dig removed mass (%.2f m3)" % v_h)
                _check(t.carve_set.sphere_count() == sc_h + 1, "pit-floor dig extended the void")
                _check(t.get_stats().collapses == coll_h,
                                "open pit floor did not collapse (cohesionless)")
