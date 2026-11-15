@tool
class_name StoemTerrainWater
extends RefCounted
## Water table helpers: pore pressure factor, seepage detection after edits, and
## wet-adjusted material strength. The head field itself is static under edits
## (quasi-static water table, no flow simulation) and lives in StoemTerrainData.

const Mat = preload("res://addons/stoem_terrain/core/terrain_material_table.gd")

## Pore pressure factor in 0..1 at a world (x, z): 1 = saturated surface,
## 0 = dry. Uses a 0.3 m smooth band around the water table (dry land sits
## 0.12 m above the clamped head -> pore 0.1, i.e. effectively dry).
static func pore_factor(p_terrain, p_x: float, p_z: float) -> float:
        var head: float = p_terrain.water_table_at(Vector2(p_x, p_z))
        var h: float = p_terrain.height_at(Vector2(p_x, p_z))
        return clampf((head - h + 0.15) / 0.3, 0.0, 1.0)

## World positions of cells that an edit lowered below the water table (they
## start seeping). Only cells actually lowered by the edit are reported.
static func seepage_from_stroke(p_terrain, p_cells: PackedInt32Array,
                p_old: PackedFloat32Array, p_new: PackedFloat32Array) -> Array:
        var out := []
        var data = p_terrain.data
        for k in p_cells.size():
                var idx := p_cells[k]
                var i: int = idx % data.N
                var j: int = idx / data.N
                var wx: float = float(i) - data.HALF
                var wz: float = float(j) - data.HALF
                var head: float = p_terrain.water_table_at(Vector2(wx, wz))
                if p_new[k] < head - 0.05 and p_new[k] < p_old[k] - 0.05:
                        out.append(Vector3(wx, p_new[k] + 0.05, wz))
        return out

## Effective (repose_deg, cohesion_kpa) for a material id under a pore factor.
static func strength(p_terrain, p_mat_id: int, p_pore: float) -> Vector2:
        return Vector2(
                p_terrain.wet_repose_deg(p_mat_id, p_pore),
                p_terrain.wet_cohesion_kpa(p_mat_id, p_pore))

## Quasi-static drawdown: cells freshly exposed below the head pull it toward
## the new floor, scaled by the surface material's permeability (sand and
## gravel drain fast, clay and granite barely at all). Writes go through the
## terrain's stroke buffer so undo restores the table exactly.
static func drawdown(p_terrain, p_cells: PackedInt32Array,
                p_old: PackedFloat32Array, p_new: PackedFloat32Array) -> void:
        var data = p_terrain.data
        var floors := {}
        for k in p_cells.size():
                if p_new[k] >= p_old[k] - 0.05:
                        continue          # only freshly lowered cells drain
                var idx := p_cells[k]
                var i: int = idx % data.N
                var j: int = idx / data.N
                var mi := clampi(i / int(data.MAT_CELL), 0, data.MAT_N - 1)
                var mj := clampi(j / int(data.MAT_CELL), 0, data.MAT_N - 1)
                var midx: int = mi + mj * data.MAT_N
                var head: float = data.water_head[midx]
                if p_new[k] < head - 0.05:
                        if floors.has(midx):
                                floors[midx] = minf(floors[midx], p_new[k])
                        else:
                                floors[midx] = p_new[k]
        if floors.is_empty():
                return
        for midx in floors.keys():
                var floor_y: float = floors[midx] + 0.05
                var head2: float = data.water_head[midx]
                if head2 <= floor_y:
                        continue
                var i2: int = midx % data.MAT_N
                var j2: int = midx / data.MAT_N
                var wx: float = (float(i2) + 0.5) * data.MAT_CELL - data.HALF
                var wz: float = (float(j2) + 0.5) * data.MAT_CELL - data.HALF
                var material = p_terrain.material_definition(
                        p_terrain.material_id_at(Vector2(wx, wz)))
                var perm: float = material.permeability if material != null else 0.0
                var drain := clampf(pow(perm * 200.0, 0.25), 0.02, 1.0) * 0.35
                p_terrain._stroke_set_water(midx, lerpf(head2, floor_y, drain))
