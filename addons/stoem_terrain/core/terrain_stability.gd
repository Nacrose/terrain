@tool
class_name StoemTerrainStability
extends RefCounted
## Slope stability: Jacobi relaxation of too-steep faces down to the (pore-adjusted)
## angle of repose, and cave roof collapse from a cohesion x thickness / span limit.
## All writes go through the terrain's stroke buffer so collapses and slumps undo
## atomically with the edit that triggered them.

const Mat = preload("res://addons/stoem_terrain/core/terrain_material_table.gd")
const Water = preload("res://addons/stoem_terrain/core/terrain_water.gd")

# Calibrated so that, with default materials: a 12 m loam cavity 3 m under the
# surface collapses, a 4 m one holds, and granite cavities of any sane size hold.
const ROOF_K := 4.0
const GAMMA_KNM3 := 18.0
const RELAX_RATE := 0.8
const MAX_ITERATIONS := 48
# Per-iteration outflow cap: a cell never sheds more than this fraction of its
# height above its lowest neighbour, so it can never overshoot BELOW a
# neighbour. The old unbounded form diverged on checkerboard height noise
# (four 0.4-rate transfers per cell = 1.6x the difference per iteration,
# amplitude x2.2 per step, heights exploding to ~1e12 within 48 iterations on
# steep ground - "I dig one hole and the hillside melts").
const OUTFLOW_CAP := 0.45

## Relax every face steeper than its material's (wet) repose angle inside p_rect
## (world metres, grown internally by a margin). Runs only on the touched region.
## p_skip_center/p_skip_radius optionally exclude a disc (dig keeps its pit bowl
## while the spoil ring still settles to repose).
## p_donor_cells (height-grid indices) restricts FLOW SOURCES to ground the
## current edit actually disturbed. Baked hillsides can legitimately stand
## steeper than repose (compacted, cohesive terrain), so an unrelated dig next
## to a cliff must not start an avalanche. Empty array = every cell may flow
## (explicit stabilize_rect passes no mask).
static func relax(p_terrain, p_rect: Rect2, p_max_iterations: int = MAX_ITERATIONS,
                p_skip_center := Vector2(1e9, 1e9), p_skip_radius := 0.0,
                p_donor_cells := PackedInt32Array()) -> void:
        var data = p_terrain.data
        var x0 := maxi(int(floor(p_rect.position.x)) + int(data.HALF) - 2, 0)
        var x1 := mini(int(ceil(p_rect.end.x)) + int(data.HALF) + 2, data.N - 1)
        var z0 := maxi(int(floor(p_rect.position.y)) + int(data.HALF) - 2, 0)
        var z1 := mini(int(ceil(p_rect.end.y)) + int(data.HALF) + 2, data.N - 1)
        if x1 - x0 < 2 or z1 - z0 < 2:
                return
        var w := x1 - x0 + 1
        var d := z1 - z0 + 1
        # Skip mask (dig bowls keep their shape; the spoil ring still settles).
        var skip_mask := PackedByteArray()
        skip_mask.resize(w * d)
        if p_skip_radius > 0.0 and p_skip_center.x < 1e8:
                for j in d:
                        for i in w:
                                var sx: float = float(x0 + i) - data.HALF
                                var sz: float = float(z0 + j) - data.HALF
                                if (sx - p_skip_center.x) * (sx - p_skip_center.x) \
                                                + (sz - p_skip_center.y) * (sz - p_skip_center.y) \
                                                < p_skip_radius * p_skip_radius:
                                        skip_mask[i + j * w] = 1

        # Donor mask: only disturbed ground may initiate flow (see doc comment).
        var donor_mask := PackedByteArray()
        donor_mask.resize(w * d)
        donor_mask.fill(1)
        if p_donor_cells.size() > 0:
                donor_mask.fill(0)
                var cells: PackedInt32Array = p_donor_cells.duplicate()
                for k in cells.size():
                        var ci2: int = cells[k] % data.N
                        var cj2: int = cells[k] / data.N
                        var li := ci2 - x0
                        var lj := cj2 - z0
                        if li >= 0 and li < w and lj >= 0 and lj < d:
                                donor_mask[li + lj * w] = 1

        # Per-cell slope limits (tan), sampled once before relaxing (saturation
        # changes slower than shape).
        var tan_limit := PackedFloat32Array()
        tan_limit.resize(w * d)
        var mat_cache := {}
        for j in range(z0, z1 + 1):
                var wz: float = float(j) - data.HALF
                for i in range(x0, x1 + 1):
                        var wx: float = float(i) - data.HALF
                        var mk := Vector2i(clampi(floori((wx + data.HALF) / data.MAT_CELL), 0, data.MAT_N - 1),
                                        clampi(floori((wz + data.HALF) / data.MAT_CELL), 0, data.MAT_N - 1))
                        if not mat_cache.has(mk):
                                var mat_id: int = p_terrain.material_id_at(Vector2(wx, wz))
                                var pore := Water.pore_factor(p_terrain, wx, wz)
                                mat_cache[mk] = tan(deg_to_rad(p_terrain.wet_repose_deg(mat_id, pore)))
                        tan_limit[(i - x0) + (j - z0) * w] = mat_cache[mk]

        var snap := PackedFloat32Array()
        snap.resize(w * d)
        var delta := PackedFloat32Array()
        delta.resize(w * d)
        var want := PackedFloat32Array()
        want.resize(w * d)
        var scale := PackedFloat32Array()
        scale.resize(w * d)
        for it in p_max_iterations:
                for k in w * d:
                        snap[k] = data.heights[(x0 + k % w) + (z0 + k / w) * data.N]
                delta.fill(0.0)
                want.fill(0.0)
                scale.fill(1.0)
                # Pass 1: desired outflow per donor cell, from the frozen snapshot
                # (unbiased Jacobi).
                for j in d:
                        for i in w:
                                var kk := i + j * w
                                if skip_mask[kk] != 0 or donor_mask[kk] == 0:
                                        continue
                                var hc: float = snap[kk]
                                var tl: float = tan_limit[kk]
                                if i > 0 and skip_mask[kk - 1] == 0:
                                        want[kk] += _want(hc, snap[kk - 1], tl)
                                if i < w - 1 and skip_mask[kk + 1] == 0:
                                        want[kk] += _want(hc, snap[kk + 1], tl)
                                if j > 0 and skip_mask[kk - w] == 0:
                                        want[kk] += _want(hc, snap[kk - w], tl)
                                if j < d - 1 and skip_mask[kk + w] == 0:
                                        want[kk] += _want(hc, snap[kk + w], tl)
                # Pass 2: cap each donor's total outflow at OUTFLOW_CAP x (height
                # above its lowest neighbour) - the anti-divergence guarantee.
                for j in d:
                        for i in w:
                                var kk := i + j * w
                                if want[kk] <= 0.0:
                                        continue
                                var hc: float = snap[kk]
                                var min_h := hc
                                if i > 0:
                                        min_h = minf(min_h, snap[kk - 1])
                                if i < w - 1:
                                        min_h = minf(min_h, snap[kk + 1])
                                if j > 0:
                                        min_h = minf(min_h, snap[kk - w])
                                if j < d - 1:
                                        min_h = minf(min_h, snap[kk + w])
                                scale[kk] = minf(1.0, OUTFLOW_CAP * maxf(hc - min_h, 0.0) / want[kk])
                # Pass 3: apply the scaled transfers.
                var max_transfer := 0.0
                for j in d:
                        for i in w:
                                var kk := i + j * w
                                if skip_mask[kk] != 0 or donor_mask[kk] == 0:
                                        continue
                                var hc: float = snap[kk]
                                var tl: float = tan_limit[kk]
                                var sc: float = scale[kk]
                                if i > 0 and skip_mask[kk - 1] == 0:
                                        max_transfer = maxf(max_transfer, _give(hc, snap[kk - 1], tl, sc, kk, kk - 1, delta))
                                if i < w - 1 and skip_mask[kk + 1] == 0:
                                        max_transfer = maxf(max_transfer, _give(hc, snap[kk + 1], tl, sc, kk, kk + 1, delta))
                                if j > 0 and skip_mask[kk - w] == 0:
                                        max_transfer = maxf(max_transfer, _give(hc, snap[kk - w], tl, sc, kk, kk - w, delta))
                                if j < d - 1 and skip_mask[kk + w] == 0:
                                        max_transfer = maxf(max_transfer, _give(hc, snap[kk + w], tl, sc, kk, kk + w, delta))
                for k in w * d:
                        if delta[k] != 0.0:
                                var idx: int = (x0 + k % w) + (z0 + k / w) * data.N
                                p_terrain._stroke_set_height(idx, data.heights[idx] + delta[k])
                if max_transfer < 0.004:
                        break

## Desired transfer from the higher cell of a pair (before scaling).
static func _want(p_hc: float, p_hn: float, p_tan: float) -> float:
        var excess := p_hc - p_hn - p_tan
        return excess * 0.5 * RELAX_RATE if excess > 0.0 else 0.0

## Apply one scaled transfer. Returns the amount moved.
static func _give(p_hc: float, p_hn: float, p_tan: float, p_scale: float,
                p_ci: int, p_ni: int, r_delta: PackedFloat32Array) -> float:
        var excess := p_hc - p_hn - p_tan
        if excess <= 0.0:
                return 0.0
        var t := excess * 0.5 * RELAX_RATE * p_scale
        r_delta[p_ci] -= t
        r_delta[p_ni] += t
        return t

## Check unsupported cave roofs near p_rect (world metres) and collapse failures.
static func check_roofs(p_terrain, p_rect: Rect2, p_passes: int = 3) -> void:
        for pass_i in p_passes:
                var rect := p_rect.grow(16.0)
                var to_collapse := []
                var carve = p_terrain.carve_set
                for i in carve.sphere_count():
                        var o: int = i * 4
                        var c := Vector3(carve.spheres[o], carve.spheres[o + 1], carve.spheres[o + 2])
                        var r: float = carve.spheres[o + 3]
                        if not rect.has_point(Vector2(c.x, c.z)):
                                continue
                        if _sphere_fails(p_terrain, c, r):
                                var row := PackedFloat32Array()
                                for k in 4:
                                        row.append(carve.spheres[o + k])
                                to_collapse.append(row)
                for i in carve.capsule_count():
                        var o: int = i * 7
                        var a := Vector3(carve.capsules[o], carve.capsules[o + 1], carve.capsules[o + 2])
                        var b := Vector3(carve.capsules[o + 4], carve.capsules[o + 5], carve.capsules[o + 6])
                        var r: float = carve.capsules[o + 3]
                        var mid := (a + b) * 0.5
                        var hits_rect := rect.has_point(Vector2(a.x, a.z)) or rect.has_point(Vector2(b.x, b.z)) \
                                        or rect.has_point(Vector2(mid.x, mid.z))
                        if not hits_rect:
                                continue
                        # Check three stations along the bore; any unsupported station fails it.
                        var failed := false
                        for st in [a, mid, b]:
                                if _sphere_fails(p_terrain, st, r):
                                        failed = true
                                        break
                        if failed:
                                var row := PackedFloat32Array()
                                for k in 7:
                                        row.append(carve.capsules[o + k])
                                to_collapse.append(row)
                if to_collapse.is_empty():
                        return
                for row in to_collapse:
                        if row.size() == 4:
                                _collapse_sphere(p_terrain, row)
                        else:
                                _collapse_capsule(p_terrain, row)

## True if a spherical cavity (centre c, radius r) has an unsupported roof.
static func _sphere_fails(p_terrain, p_c: Vector3, p_r: float) -> bool:
        var data = p_terrain.data
        var top := p_c.y + p_r
        # Breaks the surface, or opens into carved air before reaching the sky
        # (e.g. the bottom of a carved pit or shaft) -> open hole, not a roof.
        for s in [[0.0, 0.0], [0.45, 0.0], [-0.45, 0.0], [0.0, 0.45], [0.0, -0.45]]:
                var x: float = p_c.x + s[0] * p_r
                var z: float = p_c.z + s[1] * p_r
                var h: float = p_terrain.height_at(Vector2(x, z))
                if h < top + 0.5:
                        return false
                var y := top + 0.6
                var steps := 0
                while y < h and steps < 80:
                        if p_terrain.carve_set.sdf(Vector3(x, y, z)) > 0.0:
                                return false    # carved air above: pit / shaft
                        y += 1.0
                        steps += 1
        # Roof thickness = thinnest cover over the cavity centre region.
        var t_min := 1e9
        for s in [[0.0, 0.0], [0.5, 0.0], [-0.5, 0.0], [0.0, 0.5], [0.0, -0.5]]:
                var x: float = p_c.x + s[0] * p_r
                var z: float = p_c.z + s[1] * p_r
                t_min = minf(t_min, p_terrain.height_at(Vector2(x, z)) - top)
        t_min = clampf(t_min, 0.5, 60.0)
        # Roof-bearing material: design override or baked geology. Spoil skins
        # (muck hoisted from a dig and dumped above the cavity) are ignored —
        # rubble on the surface cannot carry the roof span below it.
        var mat_id: int = p_terrain.roof_material_id_at(Vector2(p_c.x, p_c.z))
        var pore := Water.pore_factor(p_terrain, p_c.x, p_c.z)
        var coh: float = p_terrain.wet_cohesion_kpa(mat_id, pore)
        var material = p_terrain.material_definition(mat_id)
        var friction_deg: float = material.friction_deg if material != null else 0.0
        var shear_support: float = coh + (GAMMA_KNM3 * t_min * 0.001) * tan(deg_to_rad(friction_deg))
        var span_limit := ROOF_K * sqrt(shear_support * t_min / GAMMA_KNM3)
        return 2.0 * p_r > span_limit

## Collapse: remove the cavity, fill it with rubble. The fallen roof bulks, so the
## surface subsides by cavity_height / swell (mass-conserving in solid-equivalent
## terms: solid gained by filling the void equals solid lost from the overburden).
static func _collapse_sphere(p_terrain, p_row: PackedFloat32Array) -> void:
        var c := Vector3(p_row[0], p_row[1], p_row[2])
        var r: float = p_row[3]
        p_terrain._stroke_prim_removed_sphere(p_row)
        _fill_cavity(p_terrain, c, r, p_terrain.roof_material_id_at(Vector2(c.x, c.z)))

static func _collapse_capsule(p_terrain, p_row: PackedFloat32Array) -> void:
        var a := Vector3(p_row[0], p_row[1], p_row[2])
        var r: float = p_row[3]
        var b := Vector3(p_row[4], p_row[5], p_row[6])
        p_terrain._stroke_prim_removed_capsule(p_row)
        var mat_id: int = p_terrain.roof_material_id_at(Vector2(a.x, a.z))
        var steps := maxi(ceili(a.distance_to(b) / maxf(r, 0.5)), 1)
        for s in range(steps + 1):
                var c := a.lerp(b, float(s) / float(steps))
                _fill_cavity(p_terrain, c, r, mat_id)

static func _fill_cavity(p_terrain, p_c: Vector3, p_r: float, p_mat_id: int) -> void:
        var data = p_terrain.data
        var material = p_terrain.material_definition(p_mat_id)
        if material == null:
                return
        var swell: float = material.digging_spoil_ratio
        var i0 := maxi(floori(p_c.x - p_r + data.HALF), 0)
        var i1 := mini(ceili(p_c.x + p_r + data.HALF), data.N - 1)
        var j0 := maxi(floori(p_c.z - p_r + data.HALF), 0)
        var j1 := mini(ceili(p_c.z + p_r + data.HALF), data.N - 1)
        var floor_clamp := p_c.y - p_r + 0.1
        for j in range(j0, j1 + 1):
                for i in range(i0, i1 + 1):
                        var wx: float = float(i) - data.HALF
                        var wz: float = float(j) - data.HALF
                        var d2 := (wx - p_c.x) * (wx - p_c.x) + (wz - p_c.z) * (wz - p_c.z)
                        if d2 > p_r * p_r:
                                continue
                        var cavity := 2.0 * sqrt(p_r * p_r - d2)
                        var drop := cavity / swell
                        var idx: int = i + j * data.N
                        var h: float = data.heights[idx]
                        var new_h := maxf(h - drop, floor_clamp)
                        if new_h < h:
                                p_terrain._stroke_set_height(idx, new_h)
