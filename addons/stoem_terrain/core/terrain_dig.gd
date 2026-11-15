@tool
class_name StoemTerrainDig
extends RefCounted
## Volume-conserving dig with spoil.
##
## Contract: heights are edited through the terrain's stroke buffer so one undo
## restores both the pit and the spoil exactly. Volume bookkeeping is done in
## compact (solid-equivalent) cubic metres; the spoil cone is stored loose, i.e.
## geometric volume = cut volume * digging_spoil_ratio (swell factor).
##
## Everything is MEASURED, never assumed: dig() returns the volume actually
## removed and the spoil ring is sized from that measurement, so the mass
## balance holds even when hard or shallow ground caps the cut.
##
## dig() inside a carved void (tunnel) extends the carve set analytically
## instead of touching the heightfield: no voxels involved, just another sphere
## primitive. The removed muck is hoisted to the surface above the face and
## deposited there as a spoil ring.

const Mat = preload("res://addons/stoem_terrain/core/terrain_material_table.gd")
const CarveSet = preload("res://addons/stoem_terrain/core/terrain_carve.gd")

## Remove material at world position. Returns compact cubic metres actually removed.
## p_target_volume <= 0 -> default scoop of (2/3) * PI * r_eff^3.
static func dig(p_terrain, p_world: Vector3, p_radius: float,
                p_target_volume: float = -1.0) -> float:
        var mat_id: int = p_terrain.dig_material_id(p_world)
        var mat = p_terrain.material_definition(mat_id)
        if mat == null:
                return 0.0
        if p_terrain.dig_mask.size() == p_terrain.material_catalog.count() and p_terrain.dig_mask[mat_id] == 0:
                return 0.0    # material protected by the per-material dig mask
        var r_e: float = p_terrain.effective_dig_radius(p_radius, mat_id)

        # --- tunnel case: brush head works against carved air (inside a bore, at
        # a face, or on a wall/floor) -> extend the carve set analytically ---
        if p_terrain.dig_hits_carve(p_world, p_radius):
                var r_c := maxf(p_radius * 0.9, 0.3)
                # Estimate BEFORE adding the primitive, while the rock is still there.
                var est := _estimate_tunnel_removal(p_terrain, p_world, r_c)
                if not p_terrain._carve_add_sphere_quiet(p_world, r_c):
                        return 0.0   # spot already carved: nothing removed, nothing booked
                if est > 0.01:
                        # Muck is hoisted: spoil appears as a ring on the surface above the face.
                        var surf := Vector3(p_world.x,
                                        p_terrain.height_at(Vector2(p_world.x, p_world.z)), p_world.z)
                        _place_spoil_ring(p_terrain, surf, r_c, est * float(mat.digging_spoil_ratio), mat_id)
                p_terrain.dug_total += est
                return est

        var target: float = p_target_volume if p_target_volume > 0.0 else (2.0 / 3.0) * PI * r_e * r_e * r_e
        var data = p_terrain.data
        var ci := _cell_index(p_terrain, p_world.x, p_world.z)
        var h_c: float = data.heights[ci]

        # Collect cells within spoil reach, with distance from brush centre.
        var reach: float = r_e * 1.75 + 1.0
        var i0 := maxi(int(floor((p_world.x - reach) + data.HALF)), 0)
        var i1 := mini(int(ceil((p_world.x + reach) + data.HALF)), data.N - 1)
        var j0 := maxi(int(floor((p_world.z - reach) + data.HALF)), 0)
        var j1 := mini(int(ceil((p_world.z + reach) + data.HALF)), data.N - 1)
        var cells := PackedInt32Array()
        var qs := PackedFloat32Array()
        for j in range(j0, j1 + 1):
                for i in range(i0, i1 + 1):
                        var wx: float = float(i) - data.HALF
                        var wz: float = float(j) - data.HALF
                        var q := sqrt((wx - p_world.x) * (wx - p_world.x) + (wz - p_world.z) * (wz - p_world.z))
                        if q <= reach:
                                cells.append(i + j * data.N)
                                qs.append(q)

        # --- carve-aware cut: a bowl that reaches a tunnel stops at the void
        # ceiling and books only the solid it actually removed (the old code
        # dug straight through carved air, booking phantom mass as spoil and
        # trenching the tunnel away) ---
        var first_air := _first_air_column(p_terrain, cells, qs, r_e, h_c - r_e * 2.4)

        # --- cut: solve stamp depth so removed volume == target (bisection) ---
        var depth := _solve_cut_depth(p_terrain, cells, qs, h_c, r_e, target, first_air)
        var removed := 0.0
        var cover_consumed := {}
        for k in cells.size():
                var q := qs[k]
                if q > r_e:
                        continue
                var floor_y := h_c - depth * (1.0 - smoothstep(0.0, 1.0, q / r_e))
                var idx := cells[k]
                var old: float = data.heights[idx]
                var stop := _stop_y(floor_y, old, first_air[k])
                if old > stop:
                        removed += old - stop     # measure what we actually take
                        p_terrain._stroke_set_height(idx, stop)
                        cover_consumed[idx] = p_terrain._consume_cover(idx, old - stop)
        # subsurface material under the pit
        for k in cells.size():
                var q := qs[k]
                if q > r_e * 0.9:
                        continue
                var idx := cells[k]
                var cut_depth: float = h_c - data.heights[idx]
                if cut_depth > 0.25:
                        var sub := _subsurface_id(p_terrain, idx, mat_id, cut_depth,
                                float(cover_consumed.get(idx, 0.0)))
                        p_terrain._stroke_set_material(idx, sub)

        # --- spoil: annulus cone at the material's repose angle, mass-conserving ---
        _place_spoil_ring(p_terrain, p_world, r_e, removed * float(mat.digging_spoil_ratio), mat_id)
        p_terrain.dug_total += removed
        return removed

## Spoil ring around p_center (surface point): a cone frustum strip from
## 0.85 r to 1.75 r at the material's repose angle, peak solved so the placed
## loose volume equals p_loose_target. Adds to the ledger what it actually placed.
static func _place_spoil_ring(p_terrain, p_center: Vector3, p_r_base: float,
                p_loose_target: float, p_mat_id: int) -> void:
        if p_loose_target < 1e-4 or p_r_base <= 0.05:
                return
        var mat = p_terrain.material_definition(p_mat_id)
        if mat == null:
                return
        var data = p_terrain.data
        var r_in := p_r_base * 0.85
        var r_out := p_r_base * 1.75
        var tan_repose := tan(deg_to_rad(mat.repose_deg))
        if tan_repose <= 0.05:
                return
        var disc: Array = p_terrain._disc_cells(p_center.x, p_center.z, r_out)
        var cells: PackedInt32Array = disc[0]
        var qs: PackedFloat32Array = disc[1]
        var peak := _solve_spoil_peak(p_terrain, cells, qs, r_in, r_out, tan_repose, p_loose_target)
        var added := 0.0
        for k in cells.size():
                var q: float = qs[k]
                if q < r_in or q > r_out:
                        continue
                var add := peak - (q - r_in) * tan_repose
                if add > 0.0:
                        var idx := cells[k]
                        p_terrain._stroke_set_height(idx, data.heights[idx] + add)
                        # Generated single-material spoil reclassifies the local
                        # surface stack to its source material while preserving
                        # total cover thickness, then adds the new loose layer.
                        p_terrain._deposit_cover_at_vertex(idx, p_mat_id, add, true)
                        var i: int = idx % data.N
                        var j: int = idx / data.N
                        var mi := clampi(i / int(data.MAT_CELL), 0, data.MAT_N - 1)
                        var mj := clampi(j / int(data.MAT_CELL), 0, data.MAT_N - 1)
                        p_terrain._set_appearance_cell(mi + mj * data.MAT_N, &"")
                        added += add
        p_terrain.spoil_loose_total += added

static func _cell_index(p_terrain, p_wx: float, p_wz: float) -> int:
        var data = p_terrain.data
        var i := clampi(roundi(p_wx + data.HALF), 0, data.N - 1)
        var j := clampi(roundi(p_wz + data.HALF), 0, data.N - 1)
        return i + j * data.N

## Removed volume for a stamp of depth d: sum of positive height drops, 1 m^2 cells.
## Carved air inside the bowl is not rock: the cut stops at the first void.
static func _cut_volume(p_terrain, p_cells: PackedInt32Array, p_qs: PackedFloat32Array,
                p_hc: float, p_r: float, p_depth: float,
                p_first_air: PackedFloat32Array) -> float:
        var data = p_terrain.data
        var vol := 0.0
        for k in p_cells.size():
                var q: float = p_qs[k]
                if q > p_r:
                        continue
                var floor_y := p_hc - p_depth * (1.0 - smoothstep(0.0, 1.0, q / p_r))
                var old: float = data.heights[p_cells[k]]
                var stop := _stop_y(floor_y, old, p_first_air[k])
                if old > stop:
                        vol += old - stop
        return vol

static func _solve_cut_depth(p_terrain, p_cells: PackedInt32Array, p_qs: PackedFloat32Array,
                p_hc: float, p_r: float, p_target: float,
                p_first_air: PackedFloat32Array) -> float:
        var lo := 0.0
        var hi := p_r * 2.4
        if _cut_volume(p_terrain, p_cells, p_qs, p_hc, p_r, hi, p_first_air) < p_target:
                return hi  # shallow pad of very hard material: take what we can get
        for k in range(26):
                var mid := (lo + hi) * 0.5
                if _cut_volume(p_terrain, p_cells, p_qs, p_hc, p_r, mid, p_first_air) < p_target:
                        lo = mid
                else:
                        hi = mid
        return (lo + hi) * 0.5

## Where the cut through one column stops: at the profile floor, or at the
## first carved air above it (breakthrough into a tunnel). Air BELOW the
## floor is out of reach and ignored.
static func _stop_y(p_floor: float, p_old: float, p_first_air: float) -> float:
        if p_first_air < p_old and p_first_air >= p_floor:
                return p_first_air
        return p_floor

## For each brush cell (within the cut radius): the Y of the first carved air
## below the current surface, 1e9 when the column is solid. Only cells whose
## 12 m carve-hash cell contains primitives are scanned, so digs far from any
## carve pay nothing.
static func _first_air_column(p_terrain, p_cells: PackedInt32Array, p_qs: PackedFloat32Array,
                p_r: float, p_y_min: float) -> PackedFloat32Array:
        var out := PackedFloat32Array()
        out.resize(p_cells.size())
        out.fill(1e9)
        var carve = p_terrain.carve_set
        if not carve.has_carve():
                return out
        var data = p_terrain.data
        for k in p_cells.size():
                if p_qs[k] > p_r:
                        continue
                var idx := p_cells[k]
                var i: int = idx % data.N
                var j: int = idx / data.N
                var wx: float = float(i) - data.HALF
                var wz: float = float(j) - data.HALF
                var rows: Dictionary = carve.rows_near_cell(Vector2i(
                                floori(wx / CarveSet.CELL), floori(wz / CarveSet.CELL)))
                var sph_rows: PackedInt32Array = rows["sph"]
                var cap_rows: PackedInt32Array = rows["cap"]
                if sph_rows.is_empty() and cap_rows.is_empty():
                        continue
                var y: float = data.heights[idx] - 0.125
                while y > p_y_min:
                        if carve.sdf_rows(Vector3(wx, y, wz), sph_rows, cap_rows) > 0.0:
                                # refine to the exact ceiling (within 1 cm) so the
                                # resting sheet does not dip into the void
                                var solid_y := y + 0.25
                                for it in 5:
                                        var mid := (solid_y + y) * 0.5
                                        if carve.sdf_rows(Vector3(wx, mid, wz), sph_rows, cap_rows) > 0.0:
                                                y = mid
                                        else:
                                                solid_y = mid
                                out[k] = y
                                break
                        y -= 0.25
        return out

static func _spoil_volume(p_terrain, p_cells: PackedInt32Array, p_qs: PackedFloat32Array,
                p_rin: float, p_rout: float, p_tan: float, p_peak: float) -> float:
        var vol := 0.0
        for k in p_cells.size():
                var q: float = p_qs[k]
                if q < p_rin or q > p_rout:
                        continue
                var add := p_peak - (q - p_rin) * p_tan
                if add > 0.0:
                        vol += add
        return vol

static func _solve_spoil_peak(p_terrain, p_cells: PackedInt32Array, p_qs: PackedFloat32Array,
                p_rin: float, p_rout: float, p_tan: float, p_target: float) -> float:
        var lo := 0.0
        var hi := (p_rout - p_rin) * p_tan + 2.0
        if _spoil_volume(p_terrain, p_cells, p_qs, p_rin, p_rout, p_tan, hi) < p_target:
                return hi
        for k in range(26):
                var mid := (lo + hi) * 0.5
                if _spoil_volume(p_terrain, p_cells, p_qs, p_rin, p_rout, p_tan, mid) < p_target:
                        lo = mid
                else:
                        hi = mid
        return (lo + hi) * 0.5

## Subsurface material exposed by a cut: deeper and rockier cells use the
## terrain's configured substrate material.
static func _subsurface_id(p_terrain, p_idx: int, p_parent_id: int,
                p_cut_depth: float, p_cover_consumed: float = 0.0) -> int:
        var data = p_terrain.data
        var i: int = p_idx % data.N
        var j: int = p_idx / data.N
        var xz := Vector2(float(i) - data.HALF, float(j) - data.HALF)
        if p_terrain.cover_depth_at(xz) > 0.0001:
                return p_terrain.material_id_at(xz)
        var depth_into_base := maxf(p_cut_depth - p_cover_consumed, 0.0)
        var rock_fraction: float = data.sample_coarse(data.rock_frac, float(i), float(j))
        if p_terrain._uses_deep_substrate(depth_into_base,
                        rock_fraction + depth_into_base * 0.06) \
                        and p_terrain.material_catalog.is_valid_id(p_terrain.deep_substrate_material_id):
                return p_terrain.deep_substrate_material_id
        var base_id: int = p_terrain._base_material_id_at(xz)
        return base_id if base_id >= 0 else p_parent_id

## Deterministic 4^3 sampling estimate of solid volume removed by a tunnel dig.
## Must run BEFORE the carve primitive is added (afterwards the rock is air).
static func _estimate_tunnel_removal(p_terrain, p_center: Vector3, p_r: float) -> float:
        var solid := 0
        var total := 0
        for dz in 4:
                for dy in 4:
                        for dx in 4:
                                var p := p_center + Vector3(
                                                (float(dx) + 0.5) / 4.0 - 0.5,
                                                (float(dy) + 0.5) / 4.0 - 0.5,
                                                (float(dz) + 0.5) / 4.0 - 0.5) * (2.0 * p_r)
                                total += 1
                                if p_terrain.is_solid(p):
                                        solid += 1
        return (4.0 / 3.0) * PI * p_r * p_r * p_r * (float(solid) / float(total))
