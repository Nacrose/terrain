@tool
class_name StoemTerrainEditStore
extends Resource
## Versioned persistence for edited terrain. Everything is stored sparse and
## absolute (exact restore). Old files that lack fields load with defaults:
## missing = empty arrays = "not edited", so old saves keep working as the format
## grows (field additions only, never reorder).

const COVER_LAYERS := 4

@export var version := 7
@export var seed_value := 0
# Missing in version 0–2 saves, which used corner-offset coarse sampling.
@export var sampling_version := 1

# Sparse absolute height samples: linear index = i + j * N into the height grid.
@export var height_cells := PackedInt32Array()
@export var height_values := PackedFloat32Array()

# Sparse absolute physical material overrides: linear index into the 769 x 769
# terrain sample grid. Versions 0–6 stored indices in the 192 x 192 4 m grid.
@export var material_cells := PackedInt32Array()
@export var material_values := PackedInt32Array()
# Version 4 maps the numeric material slots above to persistent material IDs.
@export var material_ids := PackedStringArray()
# Sparse appearance assignments are independent from physical material IDs.
@export var appearance_cells := PackedInt32Array()
@export var appearance_values := PackedStringArray() # empty = deterministic weighted random
@export var appearance_material_ids := PackedStringArray()
@export var appearance_variant_ids := PackedStringArray()

# Version 6: one four-layer surface cover stack per edited heightfield vertex.
# Material IDs are catalog slots translated through material_ids on load.
@export var cover_cells := PackedInt32Array()
@export var cover_material_values := PackedInt32Array() # four values per cell; -1 = empty
@export var cover_depth_values := PackedFloat32Array() # four metres values per cell

# Full 192 x 192 hydraulic head override (empty = from bake).
@export var water_head := PackedFloat32Array()

# Analytic carve primitives.
@export var carve_spheres := PackedFloat32Array()    # stride 4
@export var carve_capsules := PackedFloat32Array()   # stride 7

# Cumulative ledger (optional; old files load with zero defaults).
@export var dug_total := 0.0                         # compact m3 removed by dig()
@export var spoil_loose_total := 0.0                 # loose m3 placed as spoil
@export var collapse_count := 0
@export var seepage_total := 0

static func valid_sparse(p_cells: Variant, p_values: Variant, p_count: int,
                p_material: bool = false) -> bool:
        if not (p_cells is Array or p_cells is PackedInt32Array):
                return false
        if not (p_values is Array or p_values is PackedInt32Array or p_values is PackedFloat32Array):
                return false
        if p_cells.size() != p_values.size():
                return false
        for k in p_cells.size():
                if not p_cells[k] is int or p_cells[k] < 0 or p_cells[k] >= p_count:
                        return false
                if not (p_values[k] is int or p_values[k] is float) or not is_finite(p_values[k]):
                        return false
                if p_material and p_values[k] != floorf(p_values[k]):
                        return false
        return true

func is_valid() -> bool:
        const Carves = preload("res://addons/stoem_terrain/core/terrain_carve.gd")
        if version < 0 or version > 7 or sampling_version not in [1, 2]:
                return false
        if not valid_sparse(height_cells, height_values, 769 * 769):
                return false
        var material_sample_count: int = 769 * 769 if version >= 7 else 192 * 192
        if not valid_sparse(material_cells, material_values, material_sample_count):
                return false
        if version < 4:
                for value in material_values:
                        if value != floorf(value) or value < -8 or value > 6:
                                return false
        else:
                if material_ids.size() > 4096:
                        return false
                var seen_ids := {}
                for stable_id in material_ids:
                        if stable_id.is_empty() or seen_ids.has(stable_id):
                                return false
                        seen_ids[stable_id] = true
                for value in material_values:
                        if value != floorf(value):
                                return false
                        if value == -1:
                                continue
                        var material_slot := value if value >= 0 else -value - 2
                        if material_slot < 0 or material_slot >= material_ids.size():
                                return false
        if version >= 5:
                if appearance_cells.size() != appearance_values.size() \
                                or appearance_cells.size() != appearance_material_ids.size():
                        return false
                var appearance_ids := {}
                if appearance_variant_ids.size() > 16384:
                        return false
                for stable_id in appearance_variant_ids:
                        if stable_id.is_empty() or appearance_ids.has(stable_id):
                                return false
                        appearance_ids[stable_id] = true
                var seen_cells := {}
                for k in appearance_cells.size():
                        if appearance_cells[k] < 0 or appearance_cells[k] >= 192 * 192:
                                return false
                        if seen_cells.has(appearance_cells[k]):
                                return false
                        seen_cells[appearance_cells[k]] = true
                        if appearance_material_ids[k].is_empty() \
                                        or not material_ids.has(appearance_material_ids[k]):
                                return false
                        if not appearance_values[k].is_empty() \
                                        and not appearance_ids.has(appearance_values[k]):
                                return false
        elif not appearance_cells.is_empty() or not appearance_values.is_empty() \
                        or not appearance_material_ids.is_empty() or not appearance_variant_ids.is_empty():
                return false
        if version >= 6:
                if cover_cells.size() > 769 * 769 \
                                or cover_material_values.size() != cover_cells.size() * COVER_LAYERS \
                                or cover_depth_values.size() != cover_cells.size() * COVER_LAYERS:
                        return false
                var cover_seen := PackedByteArray()
                cover_seen.resize(769 * 769)
                for sparse_index in cover_cells.size():
                        var cell_index: int = cover_cells[sparse_index]
                        if cell_index < 0 or cell_index >= cover_seen.size() \
                                        or cover_seen[cell_index] != 0:
                                return false
                        cover_seen[cell_index] = 1
                        var saw_empty := false
                        for layer in COVER_LAYERS:
                                var index := sparse_index * COVER_LAYERS + layer
                                var material_slot: int = cover_material_values[index]
                                var depth: float = cover_depth_values[index]
                                if material_slot == -1:
                                        if not is_finite(depth) or absf(depth) > 0.0001:
                                                return false
                                        saw_empty = true
                                elif material_slot < 0 or material_slot >= material_ids.size() \
                                                or saw_empty or not is_finite(depth) or depth <= 0.0:
                                        return false
        elif not cover_cells.is_empty() or not cover_material_values.is_empty() \
                        or not cover_depth_values.is_empty():
                return false
        if not water_head.is_empty() and water_head.size() != 192 * 192:
                return false
        for value in water_head:
                if not is_finite(value):
                        return false
        return Carves.valid_rows(carve_spheres, 4) and Carves.valid_rows(carve_capsules, 7) \
                and is_finite(dug_total) and dug_total >= 0.0 \
                and is_finite(spoil_loose_total) and spoil_loose_total >= 0.0 \
                and collapse_count >= 0 and seepage_total >= 0
