@tool
class_name StoemTerrain3D
extends Node3D
## Stoem Terrain: continuous heightfield (768 x 768 m @ 1 m) + analytic carved
## caves/tunnels (spheres & capsules, implicit CSG). NO voxel data anywhere.
##
## Coordinate conventions:
##   - Core queries, edits and region signals use centred terrain-local metres.
##   - Explicit *_world helpers transform scene-world positions and normals.
##   - Legacy terrain-space helpers (0..768) are thin compatibility wrappers.
##
## The one implicit that defines solidity:
##   F(p) = max(p.y - height(x, z), carve_sdf(p));  solid  <=>  F(p) < 0.
## Rays, capsule sweeps and cave meshing all evaluate F analytically.

signal baked
signal edited                       # legacy no-argument hook (main.gd grass mask rebuild)
signal edited_region(rect: Rect2)   # centred world metres; invalidation hint
signal collapsed(rect: Rect2)       # a roof failed inside this rect (world metres)
signal seepage_cells(cells: Array)  # world positions that began seeping after an edit

enum { TOOL_RAISE = 0, TOOL_LOWER = 1, TOOL_SMOOTH = 2, TOOL_FLATTEN = 3, TOOL_CARVE = 4, TOOL_DIG = 5, TOOL_PAINT = 6 }

const Data = preload("res://addons/stoem_terrain/core/terrain_data.gd")
const CarveSet = preload("res://addons/stoem_terrain/core/terrain_carve.gd")
const Mat = preload("res://addons/stoem_terrain/core/terrain_material_table.gd")
const MeshUtil = preload("res://addons/stoem_terrain/core/terrain_mesh.gd")
const RayUtil = preload("res://addons/stoem_terrain/core/terrain_ray.gd")
const Water = preload("res://addons/stoem_terrain/core/terrain_water.gd")
const Dig = preload("res://addons/stoem_terrain/core/terrain_dig.gd")
const Stability = preload("res://addons/stoem_terrain/core/terrain_stability.gd")
const EditStore = preload("res://addons/stoem_terrain/core/terrain_edits.gd")
const MaterialCatalog = preload("res://addons/stoem_terrain/core/terrain_material_catalog.gd")
const COVER_LAYERS := 4

@export var seed_value: int = 20261113
@export_storage var sampling_version := 2
@export var auto_stabilize := false       # slump sculpt strokes too (dig always settles)
@export var forced_dig_material := -1     # -1 = use surface material under the brush
@export var deep_substrate_material_id := Mat.ID_GRANITE
@export_range(0.0, 100.0, 0.1) var deep_substrate_depth_m := 6.0
@export_range(0.0, 1.0, 0.01) var rock_substrate_threshold := 0.6
@export var dig_mask := PackedByteArray() # per-material dig permission (1 = diggable)
@export var enable_collision := false : set = _set_collision
@export var debug_water_table := false : set = _set_water_debug
@export var material_catalog: Resource
@export var edits_resource: Resource
var _observed_material_catalog: Resource = null
var _material_resources_connected := false

var data: Resource = null                 # StoemTerrainData
var carve_set := CarveSet.new()
var last_pick := {}                       # info for the editor panel

var _ground_nodes: Array = []             # 256 MeshInstance3D (or null)
var _ground_shapes: Array = []            # 256 CollisionShape3D (or null)
var _cave_node: MeshInstance3D = null
var _cave_shape: CollisionShape3D = null
var _collision_body: StaticBody3D = null
var _water_node: MeshInstance3D = null
var _cursor_ring: MeshInstance3D = null
var _cursor_sphere: MeshInstance3D = null
var _dirty_chunks := {}
var _cave_dirty := false
var _cave_dirty_rect := Rect2()      # union of regions changed since the last cave remesh
var _cave_cache := {}                # cave tile key (Vector2i) -> cached tile mesh arrays
var _ground_surface_material_cache := {} # material slot -> shared render resource
var _stroke_prim_rect := Rect2()     # XZ rect of carve primitives added/removed this stroke

# --- stroke buffer: every height/material/prim write during a stroke is captured
# --- so one undo op restores the exact prior state (pit, spoil, slump, collapse).
var _stroke_active := false
var _stroke_ledger_before := {}
var _stroke_cells := PackedInt32Array()
var _stroke_old := PackedFloat32Array()
var _stroke_new := PackedFloat32Array()
var _stroke_index := {}
var _stroke_mat_cells := PackedInt32Array()
var _stroke_mat_old := PackedInt32Array()
var _stroke_mat_new := PackedInt32Array()
var _stroke_mat_index := {}
var _stroke_appearance_cells := PackedInt32Array()
var _stroke_appearance_old := PackedStringArray()
var _stroke_appearance_new := PackedStringArray()
var _stroke_appearance_index := {}
var _stroke_cover_old := {} # vertex index -> {"materials": PackedInt32Array, "depths": PackedFloat32Array}
var _stroke_cover_new := {}
var _stroke_water_cells := PackedInt32Array()
var _stroke_water_old := PackedFloat32Array()
var _stroke_water_new := PackedFloat32Array()
var _stroke_water_index := {}
var _stroke_collapsed := false
var _stroke_collapse_rect := Rect2()
var _stroke_sph_added: Array = []
var _stroke_sph_removed: Array = []
var _stroke_cap_added: Array = []
var _stroke_cap_removed: Array = []
var _flatten_anchor := NAN

var _undo_stack: Array = []
var _redo_stack: Array = []
var _edited_cells := {}                   # height idx -> true (persistence)
var _edited_mat_cells := {}               # 1 m material sample idx -> true
var _edited_appearance_cells := {}        # material idx -> true
var _edited_cover_cells := {}             # height vertex idx -> true
var _mat_override := PackedInt32Array()   # 769 x 769, -1 = bake value
var _appearance_override := PackedStringArray() # 192 x 192, stable variant ID or empty=weighted random
var _cover_material_stack := PackedInt32Array() # N*N*4, top layer first, -1 = empty
var _cover_depth_stack := PackedFloat32Array() # N*N*4, metres from layer top
var _material_usage_cache: Dictionary = {}
var _material_usage_cache_valid := false

# Cumulative ledger (life-of-terrain totals; undo does not rewind them).
var dug_total := 0.0                 # compact m3 actually removed by dig()
var spoil_loose_total := 0.0         # loose m3 actually placed as spoil
var collapse_count := 0              # roof failures
var seepage_total := 0               # cells that began seeping

func stoem_is_terrain() -> bool:
        return true

func _ready() -> void:
        _ensure_material_catalog()
        if (data == null or data.heights.is_empty()) and edits_resource == null:
                bake()
        if edits_resource != null:
                var restore_error := _load_edits_store(edits_resource)
                if restore_error != OK:
                        push_warning("Stoem Terrain could not restore its linked edit resource (%s)." % error_string(restore_error))
                        if data == null or data.heights.is_empty():
                                bake()

func _ensure_material_catalog() -> void:
        if material_catalog == null or not material_catalog is MaterialCatalog:
                material_catalog = MaterialCatalog.new()
        if _observed_material_catalog != material_catalog:
                if _observed_material_catalog != null \
                                and _observed_material_catalog.changed.is_connected(_on_material_catalog_changed):
                        _observed_material_catalog.changed.disconnect(_on_material_catalog_changed)
                _observed_material_catalog = material_catalog
                _material_resources_connected = false
                if not material_catalog.changed.is_connected(_on_material_catalog_changed):
                        material_catalog.changed.connect(_on_material_catalog_changed)
        if not _material_resources_connected:
                _connect_material_resources()
        _resize_dig_mask()

func _connect_material_resources() -> void:
        for material in material_catalog.materials:
                if material == null:
                        continue
                if material.has_signal("changed") and not material.changed.is_connected(_on_material_catalog_changed):
                        material.changed.connect(_on_material_catalog_changed)
                for response_curve in [material.wet_repose_response, material.wet_cohesion_response]:
                        if response_curve != null and response_curve.has_signal("changed") \
                                        and not response_curve.changed.is_connected(_on_material_catalog_changed):
                                response_curve.changed.connect(_on_material_catalog_changed)
                for variant in material.variants:
                        if variant != null and variant.has_signal("changed") \
                                        and not variant.changed.is_connected(_on_material_catalog_changed):
                                variant.changed.connect(_on_material_catalog_changed)
        _material_resources_connected = true

func _resize_dig_mask() -> void:
        var count: int = material_catalog.count()
        if dig_mask.size() == count:
                return
        var resized := PackedByteArray()
        resized.resize(count)
        resized.fill(1)
        for i in mini(dig_mask.size(), count):
                resized[i] = dig_mask[i]
        dig_mask = resized

func material_definition(p_material_id: int) -> Resource:
        _ensure_material_catalog()
        return material_catalog.get_material(p_material_id)

func material_key_for_id(p_material_id: int) -> StringName:
        _ensure_material_catalog()
        return material_catalog.key_for_id(p_material_id)

func effective_dig_radius(p_radius: float, p_material_id: int) -> float:
        var material = material_definition(p_material_id)
        if material == null:
                return maxf(p_radius, 0.3)
        return maxf(p_radius / (1.0 + 0.6 * material.hardness), 0.3)

func wet_repose_deg(p_material_id: int, p_pore: float) -> float:
        var material = material_definition(p_material_id)
        if material == null:
                return 30.0
        var response := _material_moisture_response(material.wet_repose_response, p_pore)
        return material.repose_deg * (1.0 - material.wet_repose_reduction * response)

func wet_cohesion_kpa(p_material_id: int, p_pore: float) -> float:
        var material = material_definition(p_material_id)
        if material == null:
                return 0.0
        var response := _material_moisture_response(material.wet_cohesion_response, p_pore)
        return material.cohesion_kpa * (1.0 - material.wet_cohesion_reduction * response)

## Curve Y values scale the maximum wet reduction. Null/invalid curves fall back
## to the legacy linear saturation response; runtime results stay normalized.
func _material_moisture_response(p_curve: Curve, p_pore: float) -> float:
        var saturation := clampf(p_pore if is_finite(p_pore) else 0.0, 0.0, 1.0)
        if p_curve == null:
                return saturation
        var response: float = p_curve.sample_baked(saturation)
        return clampf(response, 0.0, 1.0) if is_finite(response) else saturation

func surface_physics_at(p_xz: Vector2) -> Dictionary:
        var id := material_id_at(p_xz)
        var material = material_definition(id)
        if material == null:
                return {}
        return {
                "material_id": id,
                "stable_id": material.stable_id,
                "surface_friction": material.surface_friction,
                "bulk_density_kg_m3": material.bulk_density_kg_m3,
                "porosity": material.porosity,
                "permeability_m_s": material.permeability,
                "base_material_id": _base_material_id_at(p_xz),
                "cover_depth_m": cover_depth_at(p_xz),
        }

func surface_layers_at(p_xz: Vector2) -> Dictionary:
        if data == null or not p_xz.is_finite():
                return {}
        var stack := _cover_stack_at_vertex(_height_vertex_index(p_xz))
        var layers: Array[Dictionary] = []
        for layer in COVER_LAYERS:
                var material_id: int = stack.materials[layer]
                if material_id < 0:
                        break
                var material = material_definition(material_id)
                layers.append({
                        "material_id": material_id,
                        "stable_id": material.stable_id if material != null else &"",
                        "thickness_m": stack.depths[layer],
                })
        return {
                "cover": layers,
                "base_material_id": _base_material_id_at(p_xz),
                "cover_depth_m": cover_depth_at(p_xz),
        }

func material_mass_kg(p_material_id: int, p_solid_volume_m3: float) -> float:
        var material = material_definition(p_material_id)
        if material == null or not is_finite(p_solid_volume_m3) or p_solid_volume_m3 < 0.0:
                return 0.0
        return material.bulk_density_kg_m3 * p_solid_volume_m3

func _on_material_catalog_changed() -> void:
        _material_resources_connected = false
        _connect_material_resources()
        _resize_dig_mask()
        _ground_surface_material_cache.clear()
        if data == null or data.heights.is_empty():
                return
        # Physical resource edits affect future simulation. Rebuild only
        # currently visible ground colors; collision is unchanged.
        _dirty_chunks.clear()
        for i in MeshUtil.CHUNKS * MeshUtil.CHUNKS:
                _dirty_chunks[i] = true
        _flush_dirty()

# ------------------------------------------------------------------ lifecycle

func bake(p_emit_signal: bool = true) -> void:
        _ensure_material_catalog()
        _cancel_stroke()
        _undo_stack.clear()
        _redo_stack.clear()
        _edited_cells.clear()
        _edited_mat_cells.clear()
        _edited_appearance_cells.clear()
        _edited_cover_cells.clear()
        _material_usage_cache.clear()
        _material_usage_cache_valid = false
        carve_set.clear()      # a re-bake is a new world: stale tunnels must not survive it
        data = Data.new(seed_value, sampling_version)
        data.build()
        _mat_override.resize(data.N * data.N)
        _mat_override.fill(-1)
        _appearance_override.resize(data.MAT_N * data.MAT_N)
        _appearance_override.fill("")
        var cover_value_count: int = data.N * data.N * COVER_LAYERS
        _cover_material_stack.resize(cover_value_count)
        _cover_material_stack.fill(-1)
        _cover_depth_stack.resize(cover_value_count)
        _cover_depth_stack.fill(0.0)
        if dig_mask.size() != material_catalog.count():
                dig_mask = PackedByteArray()
                dig_mask.resize(material_catalog.count())
                dig_mask.fill(1)
        dug_total = 0.0
        spoil_loose_total = 0.0
        collapse_count = 0
        seepage_total = 0
        _cave_cache.clear()
        _cave_dirty_rect = Rect2()
        _dirty_chunks.clear()
        for ci in MeshUtil.CHUNKS * MeshUtil.CHUNKS:
                _dirty_chunks[ci] = true
        _cave_dirty = true
        _flush_dirty()
        _rebuild_water_overlay_if_visible()
        if p_emit_signal:
                baked.emit()

# ------------------------------------------------------------------ queries (Phase 0)
# All in centred world metres; Vector2 means (x, z).

func height_at(p_xz: Vector2) -> float:
        return data.sample_height(p_xz.x + data.HALF, p_xz.y + data.HALF)

func normal_at(p_xz: Vector2) -> Vector3:
        var e := 0.5
        var hl := height_at(p_xz + Vector2(-e, 0.0))
        var hr := height_at(p_xz + Vector2(e, 0.0))
        var hd := height_at(p_xz + Vector2(0.0, -e))
        var hu := height_at(p_xz + Vector2(0.0, e))
        return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()

func slope_deg_at(p_xz: Vector2) -> float:
        var e := 0.5
        var gx := (height_at(p_xz + Vector2(e, 0.0)) - height_at(p_xz + Vector2(-e, 0.0))) / (2.0 * e)
        var gz := (height_at(p_xz + Vector2(0.0, e)) - height_at(p_xz + Vector2(0.0, -e))) / (2.0 * e)
        return rad_to_deg(atan(sqrt(gx * gx + gz * gz)))

func material_id_at(p_xz: Vector2) -> int:
        if data == null or not p_xz.is_finite():
                return -1
        var vertex_index := _height_vertex_index(p_xz)
        var offset := vertex_index * COVER_LAYERS
        if offset >= 0 and offset < _cover_material_stack.size():
                var top_id: int = _cover_material_stack[offset]
                if top_id >= 0 and _cover_depth_stack[offset] > 0.0001:
                        return top_id
        return _base_material_id_at(p_xz)

## Summarizes references on this terrain only. 1 m samples include baked,
## painted and spoil identities; cover layers count each occupied 1 m sample.
func material_usage_for(p_material_id: int) -> Dictionary:
        if data == null or not material_catalog.is_valid_id(p_material_id):
                return {}
        if not _material_usage_cache_valid:
                _rebuild_material_usage_cache()
        var counts: Dictionary = _material_usage_cache.get(p_material_id, {
                "material_cells": 0, "cover_layers": 0,
        })
        var result: Dictionary = counts.duplicate()
        result["deep_substrate"] = deep_substrate_material_id == p_material_id
        result["forced_dig"] = forced_dig_material == p_material_id
        return result

func _rebuild_material_usage_cache() -> void:
        _material_usage_cache.clear()
        for material_id in material_catalog.count():
                _material_usage_cache[material_id] = {"material_cells": 0, "cover_layers": 0}
        for cell_index in _mat_override.size():
                var override_id: int = _mat_override[cell_index]
                var base_id: int = _baked_material_id_at_index(cell_index)
                if override_id >= 0:
                        base_id = override_id
                elif override_id <= -2:
                        base_id = -override_id - 2
                if _material_usage_cache.has(base_id):
                        _material_usage_cache[base_id].material_cells += 1
        for vertex_index in data.heights.size():
                var offset: int = vertex_index * COVER_LAYERS
                for layer in COVER_LAYERS:
                        var cover_id: int = _cover_material_stack[offset + layer]
                        if cover_id < 0:
                                break
                        if _material_usage_cache.has(cover_id):
                                _material_usage_cache[cover_id].cover_layers += 1
        _material_usage_cache_valid = true

func _invalidate_material_usage_cache() -> void:
        _material_usage_cache_valid = false

func surface_material_id_at_vertex(p_i: int, p_j: int) -> int:
        if data == null:
                return -1
        var i: int = clampi(p_i, 0, data.N - 1)
        var j: int = clampi(p_j, 0, data.N - 1)
        var vertex_index: int = i + j * data.N
        var offset: int = vertex_index * COVER_LAYERS
        if offset < _cover_material_stack.size() and _cover_material_stack[offset] >= 0 \
                        and _cover_depth_stack[offset] > 0.0001:
                return _cover_material_stack[offset]
        return data.biome[vertex_index]

func _base_material_id_at(p_xz: Vector2) -> int:
        var midx := _height_vertex_index(p_xz)
        # Spoil skins (dig muck dumped on the surface) are stored as -(mat + 2)
        # so readers can tell loose rubble from designed/baked ground.
        if _mat_override[midx] <= -2:
                return -_mat_override[midx] - 2
        if _mat_override[midx] >= 0:
                return _mat_override[midx]
        return _baked_material_id_at_index(midx)

## The procedural geology remains generated at 4 m resolution. Resolve its
## default material at a full-resolution sample without coupling its array to
## the finer painted override field.
func _baked_material_id_at_index(p_vertex_index: int) -> int:
        var i: int = p_vertex_index % data.N
        var j: int = p_vertex_index / data.N
        var mi := clampi(i / int(data.MAT_CELL), 0, data.MAT_N - 1)
        var mj := clampi(j / int(data.MAT_CELL), 0, data.MAT_N - 1)
        return data.materials[mi + mj * data.MAT_N]

func _appearance_cell_for_vertex(p_vertex_index: int) -> int:
        var i: int = p_vertex_index % data.N
        var j: int = p_vertex_index / data.N
        var mi := clampi(i / int(data.MAT_CELL), 0, data.MAT_N - 1)
        var mj := clampi(j / int(data.MAT_CELL), 0, data.MAT_N - 1)
        return mi + mj * data.MAT_N

func _height_vertex_index(p_xz: Vector2) -> int:
        var i := clampi(roundi(p_xz.x + data.HALF), 0, data.N - 1)
        var j := clampi(roundi(p_xz.y + data.HALF), 0, data.N - 1)
        return i + j * data.N

func cover_depth_at(p_xz: Vector2) -> float:
        if data == null or not p_xz.is_finite():
                return 0.0
        var offset := _height_vertex_index(p_xz) * COVER_LAYERS
        var total := 0.0
        for layer in COVER_LAYERS:
                if _cover_material_stack[offset + layer] < 0:
                        break
                total += _cover_depth_stack[offset + layer]
        return total

## Resolves the material at a depth below the current surface. Cover layers are
## consumed from top to bottom; the underlying painted/baked material follows,
## then the configured deep substrate rule applies below the cover interface.
func material_id_at_depth(p_xz: Vector2, p_depth_m: float) -> int:
        if data == null or not p_xz.is_finite() or not is_finite(p_depth_m):
                return -1
        var remaining := maxf(p_depth_m, 0.0)
        var offset := _height_vertex_index(p_xz) * COVER_LAYERS
        for layer in COVER_LAYERS:
                var id: int = _cover_material_stack[offset + layer]
                if id < 0:
                        break
                var thickness: float = _cover_depth_stack[offset + layer]
                if remaining < thickness:
                        return id
                remaining -= thickness
        var base_id := _base_material_id_at(p_xz)
        if remaining > 0.05:
                var rock_fraction: float = data.sample_coarse(data.rock_frac,
                        p_xz.x + data.HALF, p_xz.y + data.HALF)
                if _uses_deep_substrate(remaining, rock_fraction) \
                                and material_catalog.is_valid_id(deep_substrate_material_id):
                        return deep_substrate_material_id
        return base_id

## Roof-bearing material for the stability model: the designed override or the
## baked geology, never the spoil skin. Granite muck hoisted from a tunnel and
## dumped on a loam meadow displays as granite but must not make the loam roof
## below "hold"; only ground the level designer painted (plain ids) or the
## bake produced counts as load-bearing.
func roof_material_id_at(p_xz: Vector2) -> int:
        var midx := _height_vertex_index(p_xz)
        if _mat_override[midx] >= 0:
                return _mat_override[midx]
        return _baked_material_id_at_index(midx)

func material_at(p_xz: Vector2) -> StringName:
        return material_key_for_id(material_id_at(p_xz))

func appearance_variant_index_for_cell(p_material_cell: int, p_material_id: int) -> int:
        var material = material_definition(p_material_id)
        if material == null or material.variants.is_empty():
                return -1
        var explicit_id := _appearance_override[p_material_cell]
        if not explicit_id.is_empty():
                for i in material.variants.size():
                        var appearance = material.variants[i]
                        if appearance != null and appearance.stable_id == StringName(explicit_id):
                                return i
                # Stable-ID sorting keeps the random choice independent of shelf order.
        var candidates: Array = []
        for appearance in material.variants:
                if appearance != null and is_finite(appearance.weight) and appearance.weight > 0.0:
                        candidates.append(appearance)
        if candidates.is_empty():
                return -1
        candidates.sort_custom(func(a, b) -> bool:
                return String(a.stable_id) < String(b.stable_id))
        var total_weight := 0.0
        for candidate in candidates:
                total_weight += candidate.weight
        if total_weight <= 0.0:
                return -1
        # A single deterministic pick is shared by neighboring coarse cells in
        # the same patch, preventing a noisy cell-by-cell checkerboard. The
        # material resource owns the patch scale; identity does not depend on
        # shelf order, rendering chunk ownership or frame timing.
        var patch_size := maxf(material.appearance_patch_size_m, data.MAT_CELL)
        var cell_x: int = p_material_cell % data.MAT_N
        var cell_z: int = floori(float(p_material_cell) / data.MAT_N)
        var patch_x := floori(((float(cell_x) + 0.5) * data.MAT_CELL) / patch_size)
        var patch_z := floori(((float(cell_z) + 0.5) * data.MAT_CELL) / patch_size)
        var rng := RandomNumberGenerator.new()
        rng.seed = int(seed_value) ^ (patch_x * 73856093) ^ (patch_z * 19349663) \
                ^ (p_material_id * 83492791)
        var target := rng.randf() * total_weight
        for candidate in candidates:
                target -= candidate.weight
                if target < 0.0:
                        return material.variants.find(candidate)
        return material.variants.find(candidates.back())

func appearance_variant_id_at(p_xz: Vector2) -> StringName:
        var mi := clampi(floori((p_xz.x + data.HALF) / data.MAT_CELL), 0, data.MAT_N - 1)
        var mj := clampi(floori((p_xz.y + data.HALF) / data.MAT_CELL), 0, data.MAT_N - 1)
        var midx: int = mi + mj * data.MAT_N
        var material_id := material_id_at(p_xz)
        var variant_index := appearance_variant_index_for_cell(midx, material_id)
        if variant_index < 0:
                return &""
        return material_definition(material_id).variants[variant_index].stable_id

## Surface material, or the wall material when sampled inside a bore/cavity.
func material_at_3d(p: Vector3) -> StringName:
        if carve_set.sdf(p) > 0.0:
                var xz := Vector2(p.x, p.z)
                var depth := maxf(height_at(xz) - p.y, 0.0)
                return material_key_for_id(material_id_at_depth(xz, depth))
        return material_at(Vector2(p.x, p.z))

func _uses_deep_substrate(p_depth_m: float, p_rock_fraction: float) -> bool:
        return p_depth_m > deep_substrate_depth_m or p_rock_fraction > rock_substrate_threshold

func water_table_at(p_xz: Vector2) -> float:
        return data.sample_coarse(data.water_head, p_xz.x + data.HALF, p_xz.y + data.HALF)

func pore_factor_at(p_xz: Vector2) -> float:
        return Water.pore_factor(self, p_xz.x, p_xz.y)

func is_saturated(p_xz: Vector2) -> bool:
        return pore_factor_at(p_xz) >= 0.8

func is_solid(p: Vector3) -> bool:
        return contains_local_xz(Vector2(p.x, p.z)) and implicit_F(p) < 0.0

func contains_local_xz(p: Vector2) -> bool:
        return data != null and p.is_finite() \
                and absf(p.x) <= data.HALF and absf(p.y) <= data.HALF

func surface_is_open_world(p_x: float, p_z: float) -> bool:
        var h := height_at(Vector2(p_x, p_z))
        return carve_set.sdf(Vector3(p_x, h + 0.05, p_z)) > -0.12

## True if any carved opening breaks the ground surface inside p_rect (world m).
func surface_open_rect(p_rect: Rect2) -> bool:
        var x0 := maxi(int(floor(p_rect.position.x)), -383)
        var x1 := mini(int(ceil(p_rect.end.x)), 383)
        var z0 := maxi(int(floor(p_rect.position.y)), -383)
        var z1 := mini(int(ceil(p_rect.end.y)), 383)
        var step := maxi((x1 - x0) / 32, 1)
        for z in range(z0, z1 + 1, step):
                for x in range(x0, x1 + 1, step):
                        if surface_is_open_world(float(x), float(z)):
                                return true
        return false

# --- legacy / compatibility wrappers -----------------------------------------

func sample_height(p_tx: float, p_tz: float) -> float:
        return data.sample_height(p_tx, p_tz)

func sample_height_world(p_x: float, p_z: float) -> float:
        var hit := _heightfield_world_hit(p_x, p_z)
        return NAN if hit.is_empty() else float(hit.position.y)

func normal_at_world(p_x: float, p_z: float) -> Vector3:
        var hit := _heightfield_world_hit(p_x, p_z)
        return Vector3.ZERO if hit.is_empty() else hit.normal

func biome_at_world(p_x: float, p_z: float) -> StringName:
        var hit := _heightfield_world_hit(p_x, p_z)
        if hit.is_empty():
                return &""
        var local: Vector3 = hit.local_position
        var i := clampi(roundi(local.x + data.HALF), 0, data.N - 1)
        var j := clampi(roundi(local.z + data.HALF), 0, data.N - 1)
        return material_key_for_id(data.biome[i + j * data.N])

func _query_transform() -> Transform3D:
        return global_transform if is_inside_tree() else transform

## Heightfield samples deliberately describe the surface sheet, including over
## caves. Use raycast_world() to find the first solid floor through an opening.
func _heightfield_world_hit(p_x: float, p_z: float) -> Dictionary:
        if data == null or not is_finite(p_x) or not is_finite(p_z):
                return {}
        var world := _query_transform()
        if is_zero_approx(world.basis.determinant()):
                return {}
        var inverse := world.affine_inverse()
        var hit: Dictionary
        if is_zero_approx(world.basis.y.x) and is_zero_approx(world.basis.y.z):
                var local := inverse * Vector3(p_x, world.origin.y, p_z)
                if not contains_local_xz(Vector2(local.x, local.z)):
                        return {}
                local.y = height_at(Vector2(local.x, local.z))
                hit = {"position": local, "normal": normal_at(Vector2(local.x, local.z))}
        else:
                # Tilted heightfields require a vertical world ray. The chunk
                # AABBs bound all current heights, including sculpted ground.
                if _ground_nodes.is_empty():
                        return {}
                var bounds: AABB = world * _ground_nodes[0].mesh.get_aabb()
                for node in _ground_nodes:
                        bounds = bounds.merge(world * node.mesh.get_aabb())
                var origin := Vector3(p_x, bounds.end.y + 1.0, p_z)
                var direction := inverse.basis * Vector3.DOWN
                hit = RayUtil.pick(self, inverse * origin, direction,
                        (bounds.size.y + 2.0) * direction.length(), true)
                if hit.is_empty():
                        return {}
        hit.local_position = hit.position
        hit.position = world * hit.position
        hit.normal = (inverse.basis.transposed() * hit.normal).normalized()
        return hit

func raycast_world(p_from: Vector3, p_dir: Vector3, p_max_dist: float = 800.0) -> Dictionary:
        var world := _query_transform()
        if data == null or is_zero_approx(world.basis.determinant()):
                return {}
        var inverse := world.affine_inverse()
        var direction := inverse.basis * p_dir.normalized()
        var hit := RayUtil.pick(self, inverse * p_from, direction, p_max_dist * direction.length())
        if not hit.is_empty():
                hit.position = world * hit.position
                hit.normal = (inverse.basis.transposed() * hit.normal).normalized()
        return hit

## Grayscale hole mask (open surface = white) at p_size x p_size resolution.
func build_hole_mask(p_size: int) -> Image:
        var img := Image.create(p_size, p_size, false, Image.FORMAT_L8)
        for py in p_size:
                var wz: float = (float(py) / float(p_size)) * data.MAP - data.HALF
                for px in p_size:
                        var wx: float = (float(px) / float(p_size)) * data.MAP - data.HALF
                        var v := 1.0 if surface_is_open_world(wx, wz) else 0.0
                        img.set_pixel(px, py, Color(v, v, v))
        return img

# ------------------------------------------------------------------ implicit + capsule

## The terrain implicit: negative inside solid, positive in open air.
func implicit_F(p: Vector3) -> float:
        return maxf(p.y - height_at(Vector2(p.x, p.z)), carve_set.sdf(p))

## Outward surface normal (towards air) of the implicit.
func implicit_normal(p: Vector3) -> Vector3:
        var e := 0.35
        var n := Vector3(
                implicit_F(p + Vector3(e, 0, 0)) - implicit_F(p + Vector3(-e, 0, 0)),
                implicit_F(p + Vector3(0, e, 0)) - implicit_F(p + Vector3(0, -e, 0)),
                implicit_F(p + Vector3(0, 0, e)) - implicit_F(p + Vector3(0, 0, -e)))
        if n.length_squared() < 1e-12:
                return Vector3.UP
        return n.normalized()

func raycast(p_from: Vector3, p_dir: Vector3, p_max_dist: float = 800.0) -> Dictionary:
        if data == null:
                return {}
        return RayUtil.pick(self, p_from, p_dir, p_max_dist)

## Conservative capsule overlap test against the implicit (multi-point sampling).
func capsule_solid(p: Vector3, p_radius: float) -> bool:
        if implicit_F(p) < p_radius:
                return true
        var r6 := p_radius * 0.6
        for off in [Vector3(r6, 0, 0), Vector3(-r6, 0, 0), Vector3(0, r6, 0),
                        Vector3(0, -r6, 0), Vector3(0, 0, r6), Vector3(0, 0, -r6)]:
                if implicit_F(p + off) < 0.0:
                        return true
        return false

## Sweep a capsule from p_from to p_to. Returns
## {"blocked": bool, "position": Vector3, "normal": Vector3}.
func capsule_sweep(p_from: Vector3, p_to: Vector3, p_radius: float) -> Dictionary:
        var dir := p_to - p_from
        var dist := dir.length()
        if dist < 1e-6:
                return {"blocked": capsule_solid(p_from, p_radius), "position": p_from,
                        "normal": implicit_normal(p_from)}
        var n := dir / dist
        var steps := maxi(ceili(dist / 0.25), 1)
        var prev := p_from
        for s in range(1, steps + 1):
                var p := p_from + n * (dist * float(s) / float(steps))
                if capsule_solid(p, p_radius):
                        var lo := prev
                        var hi := p
                        for k in range(10):
                                var mid := (lo + hi) * 0.5
                                if capsule_solid(mid, p_radius):
                                        hi = mid
                                else:
                                        lo = mid
                        return {"blocked": true, "position": lo, "normal": implicit_normal(hi)}
                prev = p
        return {"blocked": false, "position": p_to, "normal": Vector3.UP}

## Depenetrate a capsule against the terrain and report ground contact.
func resolve_capsule(p_pos: Vector3, p_radius: float) -> Dictionary:
        var p := p_pos
        for it in 6:
                var worst := p
                var worst_f := implicit_F(p)
                var r6 := p_radius * 0.6
                for off in [Vector3(r6, 0, 0), Vector3(-r6, 0, 0), Vector3(0, r6, 0),
                                Vector3(0, -r6, 0), Vector3(0, 0, r6), Vector3(0, 0, -r6)]:
                        var q: Vector3 = p + off
                        var fq := implicit_F(q)
                        if fq < worst_f:
                                worst_f = fq
                                worst = q
                if worst_f >= 0.0:
                        break
                var nrm := implicit_normal(worst)
                p += nrm * (p_radius - worst_f)
        var grounded := implicit_F(p - Vector3(0, p_radius + 0.25, 0)) < 0.0
        return {"position": p, "normal": implicit_normal(p - Vector3(0, p_radius * 0.5, 0)),
                "grounded": grounded}

# ------------------------------------------------------------------ editing: sculpt

## Brush stamp. mode: 0 raise, 1 lower, 2 smooth, 3 flatten, 4 carve (delegates).
func sculpt(p_wx: float, p_wz: float, p_radius: float, p_strength: float,
                p_mode: int, p_falloff: float) -> void:
        if data == null or data.heights.is_empty():
                return
        if not Vector2(p_wx, p_wz).is_finite() or not is_finite(p_radius) or p_radius <= 0.0 \
                        or not is_finite(p_strength) or not is_finite(p_falloff):
                return
        if p_mode == TOOL_CARVE:
                carve_void(Vector3(p_wx, height_at(Vector2(p_wx, p_wz)), p_wz), p_radius)
                return
        var auto := not _stroke_active
        if auto:
                begin_stroke()
        if is_nan(_flatten_anchor):
                _flatten_anchor = height_at(Vector2(p_wx, p_wz))
        var disc := _disc_cells(p_wx, p_wz, p_radius)
        var cells: PackedInt32Array = disc[0]
        var qs: PackedFloat32Array = disc[1]
        for k in cells.size():
                var idx := cells[k]
                var w := _brush_weight(qs[k], p_radius, p_falloff)
                if w <= 0.0:
                        continue
                var h: float = data.heights[idx]
                match p_mode:
                        TOOL_RAISE:
                                _stroke_set_height(idx, h + 0.32 * p_strength * w)
                        TOOL_LOWER:
                                _stroke_set_height(idx, h - 0.32 * p_strength * w)
                        TOOL_SMOOTH:
                                var avg := _neighbour_average(idx)
                                _stroke_set_height(idx, lerpf(h, avg, clampf(0.9 * p_strength * w, 0.0, 1.0)))
                        TOOL_FLATTEN:
                                var d := clampf(_flatten_anchor - h, -0.35 * p_strength, 0.35 * p_strength) * w
                                _stroke_set_height(idx, h + d)
        if auto:
                end_stroke("sculpt")

func _brush_weight(p_q: float, p_r: float, p_falloff: float) -> float:
        if p_q >= p_r:
                return 0.0
        var inner := p_r * (1.0 - 0.75 * clampf(p_falloff, 0.0, 1.0))
        if p_q <= inner:
                return 1.0
        return 1.0 - smoothstep(inner, p_r, p_q)

func _disc_cells(p_wx: float, p_wz: float, p_r: float) -> Array:
        var cells := PackedInt32Array()
        var qs := PackedFloat32Array()
        var i0 := maxi(int(floor(p_wx - p_r + data.HALF)), 0)
        var i1 := mini(int(ceil(p_wx + p_r + data.HALF)), data.N - 1)
        var j0 := maxi(int(floor(p_wz - p_r + data.HALF)), 0)
        var j1 := mini(int(ceil(p_wz + p_r + data.HALF)), data.N - 1)
        for j in range(j0, j1 + 1):
                for i in range(i0, i1 + 1):
                        var wx: float = float(i) - data.HALF
                        var wz: float = float(j) - data.HALF
                        var q := sqrt((wx - p_wx) * (wx - p_wx) + (wz - p_wz) * (wz - p_wz))
                        if q <= p_r:
                                cells.append(i + j * data.N)
                                qs.append(q)
        return [cells, qs]

func _neighbour_average(p_idx: int) -> float:
        var i: int = p_idx % data.N
        var j: int = p_idx / data.N
        var sum := 0.0
        var cnt := 0
        for dj in range(-1, 2):
                for di in range(-1, 2):
                        var ii := clampi(i + di, 0, data.N - 1)
                        var jj := clampi(j + dj, 0, data.N - 1)
                        sum += data.heights[ii + jj * data.N]
                        cnt += 1
        return sum / float(cnt)

# ------------------------------------------------------------------ editing: carve

## Carve a spherical void at world position. Pure air-void operation (analytic
## primitive; no voxel, no heightfield change). Returns true if anything was added.
func carve_void(p_world: Vector3, p_radius: float) -> bool:
        if data == null:
                return false
        var auto := not _stroke_active
        if auto:
                begin_stroke()
        var added := _carve_add_sphere_quiet(p_world, p_radius)
        if auto:
                end_stroke("carve")
        return added

## Compatibility name from the original API contract.
func carve(p_world: Vector3, p_radius: float) -> bool:
        return carve_void(p_world, p_radius)

## Carve a capsule bore (tunnels). One primitive, one undo step. Segments
## already fully carved (dragging back over the same stroke) are refused.
func carve_capsule(p_a: Vector3, p_b: Vector3, p_radius: float) -> bool:
        if data == null or not p_a.is_finite() or not p_b.is_finite() \
                        or not is_finite(p_radius) or p_radius <= 0.05:
                return false
        var mid := (p_a + p_b) * 0.5
        if carve_set.sdf(p_a) > p_radius - 0.05 and carve_set.sdf(mid) > p_radius - 0.05 \
                        and carve_set.sdf(p_b) > p_radius - 0.05:
                return false    # segment already inside carved air
        var auto := not _stroke_active
        if auto:
                begin_stroke()
        carve_set.add_capsule(p_a, p_b, p_radius)
        var row := PackedFloat32Array([p_a.x, p_a.y, p_a.z, p_radius, p_b.x, p_b.y, p_b.z])
        _stroke_cap_added.append(row)
        var bmin := p_a.min(p_b) - Vector3.ONE * (p_radius + 1.5)
        var bmax := p_a.max(p_b) + Vector3.ONE * (p_radius + 1.5)
        _carves_changed(bmin, bmax)
        _cave_dirty = true
        if auto:
                end_stroke("carve")
        return true

func _carve_add_sphere_quiet(p_center: Vector3, p_radius: float) -> bool:
        if not carve_set.carve_sphere(p_center, p_radius):
                return false
        _stroke_sph_added.append(PackedFloat32Array(
                [p_center.x, p_center.y, p_center.z, p_radius]))
        _carves_changed(p_center - Vector3.ONE * (p_radius + 1.5),
                        p_center + Vector3.ONE * (p_radius + 1.5))
        _cave_dirty = true
        return true

# ------------------------------------------------------------------ editing: dig (Phase 2)

## True when a dig at p_world works against carved air (inside a bore, at a
## tunnel face, or on the wall/floor of any carved void). The brush centre can
## sit exactly ON the carve boundary (ray hits land there), so the test accepts
## a small negative sdf margin instead of requiring strictly-inside points.
func dig_hits_carve(p_world: Vector3, p_radius: float) -> bool:
        var near := clampf(p_radius * 0.5, 0.2, 1.0)
        return carve_set.sdf(p_world) > -near \
                        or carve_set.sdf(p_world + Vector3(0.0, -0.4, 0.0)) > -near

## Volume-conserving dig. Returns compact cubic metres removed. Spoil is deposited
## at the material's repose angle (loose volume = cut x swell); pit + spoil +
## settling + any roof collapse share ONE undo op. Inside a carved void the dig
## extends the carve set instead of touching the heightfield.
func dig(p_world: Vector3, p_radius: float, p_target_volume: float = -1.0) -> float:
        if data == null or data.heights.is_empty():
                return 0.0
        if not p_world.is_finite() or not is_finite(p_radius) or p_radius <= 0.0 \
                        or not is_finite(p_target_volume):
                return 0.0
        var auto := not _stroke_active
        if auto:
                begin_stroke()
        var tunnel := dig_hits_carve(p_world, p_radius)
        var removed := Dig.dig(self, p_world, p_radius, p_target_volume)
        if tunnel:
                # The bore just grew: re-check the roof over the fresh span so
                # weak cover caves in (same physics as the carve tool).
                var reach := p_radius * 2.0 + 4.0
                Stability.check_roofs(self, Rect2(p_world.x - reach, p_world.z - reach,
                                reach * 2.0, reach * 2.0))
        else:
                var reach := p_radius * 3.0 + 14.0
                Stability.check_roofs(self, Rect2(p_world.x - reach, p_world.z - reach,
                                reach * 2.0, reach * 2.0))
                var r2 := p_radius * 2.5 + 3.0
                # Freeze only the deep bowl; the rim sloughs to repose so sand pits
                # cannot hold impossible walls (spec P3: digging triggers settling).
                # Donors are limited to cells this dig disturbed: compacted baked
                # hillsides stand steeper than repose and must not avalanche.
                var r_e := effective_dig_radius(p_radius, dig_material_id(p_world))
                Stability.relax(self, Rect2(p_world.x - r2, p_world.z - r2, r2 * 2.0, r2 * 2.0),
                                Stability.MAX_ITERATIONS, Vector2(p_world.x, p_world.z),
                                r_e * 0.67 + 0.3, _stroke_cells)
        if auto:
                end_stroke("dig")
        return removed

## Public stability pass over a rect (world metres): slump + roof check.
func stabilize_rect(p_rect: Rect2) -> void:
        var auto := not _stroke_active
        if auto:
                begin_stroke()
        Stability.check_roofs(self, p_rect.grow(16.0))
        Stability.relax(self, p_rect)
        if auto:
                end_stroke("stability")

## Material a dig at p_world actually cuts: the surface cover on open ground,
## or the wall rock at/inside a carved void (same rules as material_at_3d —
## granite below 6 m or in rocky ground). The dig mask, spoil swell and
## hard-ground radius therefore follow the rock under the brush, not the cover
## sitting on the hill above the bore. The -0.6 margin catches brush centres
## that land exactly ON the carve boundary (ray hits), not just inside it.
func dig_material_id(p_world: Vector3) -> int:
        if forced_dig_material >= 0:
                return clampi(forced_dig_material, 0, material_catalog.count() - 1)
        if carve_set.sdf(p_world) > -0.6:
                var xz := Vector2(p_world.x, p_world.z)
                var depth: float = maxf(height_at(xz) - p_world.y, 0.0)
                return material_id_at_depth(xz, depth)
        return material_id_at(Vector2(p_world.x, p_world.z))

## Compatibility helper for level design/scripts. It preserves the legacy 4 m
## footprint while writing the higher-resolution physical-material field.
## The editor paint brush itself paints individual 1 m samples. -1 restores bake.
func set_material_override(p_xz: Vector2, p_mat_id: int) -> void:
        if data == null or not p_xz.is_finite() or p_mat_id < -1 \
                        or (p_mat_id >= 0 and not material_catalog.is_valid_id(p_mat_id)):
                return
        var mi := clampi(floori((p_xz.x + data.HALF) / data.MAT_CELL), 0, data.MAT_N - 1)
        var mj := clampi(floori((p_xz.y + data.HALF) / data.MAT_CELL), 0, data.MAT_N - 1)
        var i0: int = mi * int(data.MAT_CELL)
        var j0: int = mj * int(data.MAT_CELL)
        var i_end: int = data.N if mi == data.MAT_N - 1 else i0 + int(data.MAT_CELL)
        var j_end: int = data.N if mj == data.MAT_N - 1 else j0 + int(data.MAT_CELL)
        var auto := not _stroke_active
        var changed := false
        for j in range(j0, j_end):
                for i in range(i0, i_end):
                        var vertex_index: int = i + j * data.N
                        if _mat_override[vertex_index] != p_mat_id:
                                changed = true
                                _set_material_cell(vertex_index, p_mat_id, false)
        if not changed:
                return
        if auto:
                _redo_stack.clear()
                _flush_dirty()
                edited_region.emit(Rect2(mi * data.MAT_CELL - data.HALF,
                        mj * data.MAT_CELL - data.HALF, data.MAT_CELL, data.MAT_CELL))
                edited.emit()

## Reassigns all 1 m physical material samples on this terrain from one material
## to another. Cover strata remain unchanged. The operation is one undo step and
## is sparse in its history payload: only matching samples are captured.
func replace_base_material_usage(p_from_id: int, p_to_id: int) -> int:
        if data == null or _stroke_active or p_from_id == p_to_id \
                        or not material_catalog.is_valid_id(p_from_id) \
                        or not material_catalog.is_valid_id(p_to_id):
                return 0
        var matching_cells := PackedInt32Array()
        for material_index in _mat_override.size():
                var raw_id: int = _mat_override[material_index]
                var effective_id: int = _baked_material_id_at_index(material_index)
                if raw_id >= 0:
                        effective_id = raw_id
                elif raw_id <= -2:
                        effective_id = -raw_id - 2
                if effective_id == p_from_id:
                        matching_cells.append(material_index)
        if matching_cells.is_empty():
                return 0
        begin_stroke()
        for material_index in matching_cells:
                var raw_id: int = _mat_override[material_index]
                var is_spoil_skin := raw_id <= -2
                _set_material_cell(material_index, p_to_id, is_spoil_skin)
        end_stroke("replace base material")
        return matching_cells.size()

# ------------------------------------------------------------------ editing: paint

## Material paint brush: stamps p_mat_id over every 1 m material sample whose
## location lies inside the radius (plus the sample under the brush point, so tiny
## radii still paint). This is a DESIGN paint: roof-bearing for the stability
## model, diggable with its own material rules, persisted with the edits, and
## the ground mesh recolours on the next flush. A whole drag is one undo op.
## Materials are discrete ids, so there is no falloff blending.
func paint_material(p_wx: float, p_wz: float, p_radius: float, p_mat_id: int,
                p_variant_id: StringName = &"") -> void:
        if data == null or data.heights.is_empty():
                return
        if not Vector2(p_wx, p_wz).is_finite() or not is_finite(p_radius) or p_radius < 0.0:
                return
        if not material_catalog.is_valid_id(p_mat_id):
                return
        if not p_variant_id.is_empty() and not _material_has_variant(p_mat_id, p_variant_id):
                return
        var mat_id := p_mat_id
        var auto := not _stroke_active
        if auto:
                begin_stroke()
        var ci := clampi(roundi(p_wx + data.HALF), 0, data.N - 1)
        var cj := clampi(roundi(p_wz + data.HALF), 0, data.N - 1)
        var mi0 := clampi(floori(p_wx - p_radius + data.HALF), 0, data.N - 1)
        var mi1 := clampi(ceili(p_wx + p_radius + data.HALF), 0, data.N - 1)
        var mj0 := clampi(floori(p_wz - p_radius + data.HALF), 0, data.N - 1)
        var mj1 := clampi(ceili(p_wz + p_radius + data.HALF), 0, data.N - 1)
        for mj in range(mj0, mj1 + 1):
                for mi in range(mi0, mi1 + 1):
                        var cx: float = float(mi) - data.HALF
                        var cz: float = float(mj) - data.HALF
                        if (mi == ci and mj == cj) \
                                        or Vector2(cx - p_wx, cz - p_wz).length() <= p_radius:
                                var midx: int = mi + mj * data.N
                                _set_material_cell(midx, mat_id, false)
                                _set_appearance_cell(_appearance_cell_for_vertex(midx), p_variant_id)
        if auto:
                end_stroke("paint")

## Appearance-only brush: keeps the physical material untouched and changes
## the texture set only where the selected physical material is already
## present. Empty p_variant_id restores deterministic weighted variation.
func paint_appearance(p_wx: float, p_wz: float, p_radius: float, p_mat_id: int,
                p_variant_id: StringName = &"") -> void:
        if data == null or data.heights.is_empty() \
                        or not Vector2(p_wx, p_wz).is_finite() \
                        or not is_finite(p_radius) or p_radius < 0.0 \
                        or not material_catalog.is_valid_id(p_mat_id):
                return
        if not p_variant_id.is_empty() and not _material_has_variant(p_mat_id, p_variant_id):
                return
        var auto := not _stroke_active
        if auto:
                begin_stroke()
        var ci := clampi(floori((p_wx + data.HALF) / data.MAT_CELL), 0, data.MAT_N - 1)
        var cj := clampi(floori((p_wz + data.HALF) / data.MAT_CELL), 0, data.MAT_N - 1)
        var mi0 := clampi(floori((p_wx - p_radius + data.HALF) / data.MAT_CELL), 0, data.MAT_N - 1)
        var mi1 := clampi(floori((p_wx + p_radius + data.HALF) / data.MAT_CELL), 0, data.MAT_N - 1)
        var mj0 := clampi(floori((p_wz - p_radius + data.HALF) / data.MAT_CELL), 0, data.MAT_N - 1)
        var mj1 := clampi(floori((p_wz + p_radius + data.HALF) / data.MAT_CELL), 0, data.MAT_N - 1)
        for mj in range(mj0, mj1 + 1):
                for mi in range(mi0, mi1 + 1):
                        var cx: float = (float(mi) + 0.5) * data.MAT_CELL - data.HALF
                        var cz: float = (float(mj) + 0.5) * data.MAT_CELL - data.HALF
                        if (mi == ci and mj == cj) \
                                        or Vector2(cx - p_wx, cz - p_wz).length() <= p_radius:
                                var midx: int = mi + mj * data.MAT_N
                                if material_id_at(Vector2(cx, cz)) == p_mat_id:
                                        _set_appearance_cell(midx, p_variant_id)
        if auto:
                end_stroke("appearance")

## Adds a shaped surface deposit. The returned volume is the sampled geometric
## volume in cubic metres. Repeated deposits stack up to COVER_LAYERS; when the
## stack is full, callers must explicitly request reclassification.
func deposit_material(p_wx: float, p_wz: float, p_radius: float, p_peak_m: float,
                p_material_id: int, p_reclassify_existing := false,
                p_variant_id: StringName = &"") -> float:
        if data == null or not Vector2(p_wx, p_wz).is_finite() \
                        or not is_finite(p_radius) or p_radius <= 0.0 \
                        or not is_finite(p_peak_m) or p_peak_m <= 0.0 \
                        or not material_catalog.is_valid_id(p_material_id):
                return 0.0
        if not p_variant_id.is_empty() and not _material_has_variant(p_material_id, p_variant_id):
                return 0.0
        var i0 := clampi(floori(p_wx - p_radius + data.HALF), 0, data.N - 1)
        var i1 := clampi(ceili(p_wx + p_radius + data.HALF), 0, data.N - 1)
        var j0 := clampi(floori(p_wz - p_radius + data.HALF), 0, data.N - 1)
        var j1 := clampi(ceili(p_wz + p_radius + data.HALF), 0, data.N - 1)
        var samples: Array[Vector2] = [] # (height vertex index, added metres)
        var added_volume := 0.0
        for j in range(j0, j1 + 1):
                for i in range(i0, i1 + 1):
                        var q := Vector2(float(i) - data.HALF - p_wx,
                                float(j) - data.HALF - p_wz).length()
                        if q > p_radius:
                                continue
                        var ratio := maxf(1.0 - q / p_radius, 0.0)
                        var amount := p_peak_m * ratio * ratio
                        if amount <= 0.0001:
                                continue
                        var vertex_index: int = i + j * data.N
                        var stack := _cover_stack_at_vertex(vertex_index)
                        if not p_reclassify_existing and stack.materials[0] != p_material_id:
                                var has_empty_slot := false
                                for layer in COVER_LAYERS:
                                        if stack.materials[layer] < 0:
                                                has_empty_slot = true
                                                break
                                if not has_empty_slot:
                                        return 0.0 # atomic refusal; no partial deposit
                        samples.append(Vector2(vertex_index, amount))
                        added_volume += amount # 1 m^2 per height sample
        if samples.is_empty():
                return 0.0
        var auto := not _stroke_active
        if auto:
                begin_stroke()
        for sample in samples:
                var vertex_index := int(sample.x)
                var amount := sample.y
                _stroke_set_height(vertex_index, data.heights[vertex_index] + amount)
                _deposit_cover_at_vertex(vertex_index, p_material_id, amount, p_reclassify_existing)
                var i: int = vertex_index % data.N
                var j: int = vertex_index / data.N
                var mi := clampi(i / int(data.MAT_CELL), 0, data.MAT_N - 1)
                var mj := clampi(j / int(data.MAT_CELL), 0, data.MAT_N - 1)
                _set_appearance_cell(mi + mj * data.MAT_N, p_variant_id)
        if auto:
                end_stroke("deposit")
        return added_volume

func _cover_stack_at_vertex(p_vertex_index: int) -> Dictionary:
        var materials := PackedInt32Array()
        var depths := PackedFloat32Array()
        materials.resize(COVER_LAYERS)
        depths.resize(COVER_LAYERS)
        var offset := p_vertex_index * COVER_LAYERS
        for layer in COVER_LAYERS:
                materials[layer] = _cover_material_stack[offset + layer]
                depths[layer] = _cover_depth_stack[offset + layer]
        return {"materials": materials, "depths": depths}

func _set_cover_stack(p_vertex_index: int, p_materials: PackedInt32Array,
                p_depths: PackedFloat32Array, p_record := true) -> bool:
        if p_vertex_index < 0 or p_vertex_index >= data.N * data.N \
                        or p_materials.size() != COVER_LAYERS or p_depths.size() != COVER_LAYERS:
                return false
        var saw_empty := false
        for layer in COVER_LAYERS:
                var material_id: int = p_materials[layer]
                var depth: float = p_depths[layer]
                if material_id < 0:
                        if material_id != -1 or not is_finite(depth) or absf(depth) > 0.0001:
                                return false
                        saw_empty = true
                elif saw_empty or not material_catalog.is_valid_id(material_id) \
                                or not is_finite(depth) or depth <= 0.0:
                        return false
        var old_stack := _cover_stack_at_vertex(p_vertex_index)
        var changed := false
        for layer in COVER_LAYERS:
                if old_stack.materials[layer] != p_materials[layer] \
                                or not is_equal_approx(old_stack.depths[layer], p_depths[layer]):
                        changed = true
                        break
        if not changed:
                return false
        if p_record and _stroke_active and not _stroke_cover_old.has(p_vertex_index):
                _stroke_cover_old[p_vertex_index] = {
                        "materials": old_stack.materials.duplicate(),
                        "depths": old_stack.depths.duplicate(),
                }
        var offset := p_vertex_index * COVER_LAYERS
        for layer in COVER_LAYERS:
                _cover_material_stack[offset + layer] = p_materials[layer]
                _cover_depth_stack[offset + layer] = p_depths[layer]
        _invalidate_material_usage_cache()
        if p_record and _stroke_active:
                _stroke_cover_new[p_vertex_index] = {
                        "materials": p_materials.duplicate(),
                        "depths": p_depths.duplicate(),
                }
        _edited_cover_cells[p_vertex_index] = true
        _mark_cell_dirty(p_vertex_index)
        return true

func _deposit_cover_at_vertex(p_vertex_index: int, p_material_id: int,
                p_added_depth: float, p_reclassify_existing := false) -> bool:
        if not material_catalog.is_valid_id(p_material_id) or not is_finite(p_added_depth) \
                        or p_added_depth <= 0.0:
                return false
        var stack := _cover_stack_at_vertex(p_vertex_index)
        var materials: PackedInt32Array = stack.materials
        var depths: PackedFloat32Array = stack.depths
        if p_reclassify_existing:
                var total_depth := p_added_depth
                for layer in COVER_LAYERS:
                        total_depth += depths[layer]
                        materials[layer] = -1
                        depths[layer] = 0.0
                materials[0] = p_material_id
                depths[0] = total_depth
        elif materials[0] == p_material_id:
                depths[0] += p_added_depth
        else:
                var empty_layer := -1
                for layer in COVER_LAYERS:
                        if materials[layer] < 0:
                                empty_layer = layer
                                break
                if empty_layer < 0:
                        return false
                for layer in range(empty_layer, 0, -1):
                        materials[layer] = materials[layer - 1]
                        depths[layer] = depths[layer - 1]
                materials[0] = p_material_id
                depths[0] = p_added_depth
        return _set_cover_stack(p_vertex_index, materials, depths)

## Excavation consumes the surface stack top-first and leaves the base material
## available to the next material query when the cover is exhausted.
func _consume_cover(p_vertex_index: int, p_removed_depth: float) -> float:
        if not is_finite(p_removed_depth) or p_removed_depth <= 0.0:
                return 0.0
        var stack := _cover_stack_at_vertex(p_vertex_index)
        var materials: PackedInt32Array = stack.materials
        var depths: PackedFloat32Array = stack.depths
        var remaining := p_removed_depth
        var consumed := 0.0
        while remaining > 0.0001 and materials[0] >= 0:
                var take := minf(depths[0], remaining)
                depths[0] -= take
                remaining -= take
                consumed += take
                if depths[0] <= 0.0001:
                        for layer in COVER_LAYERS - 1:
                                materials[layer] = materials[layer + 1]
                                depths[layer] = depths[layer + 1]
                        materials[COVER_LAYERS - 1] = -1
                        depths[COVER_LAYERS - 1] = 0.0
        _set_cover_stack(p_vertex_index, materials, depths)
        return consumed

# ------------------------------------------------------------------ stroke buffer

## Begin capturing an edit (spec name). All writes until end_stroke() form one undo op.
func ensure_edit_buffer() -> void:
        begin_stroke()

func begin_stroke() -> void:
        if _stroke_active:
                return
        _stroke_active = true
        _stroke_ledger_before = {
                "dug_total": dug_total,
                "spoil_loose_total": spoil_loose_total,
                "collapse_count": collapse_count,
                "seepage_total": seepage_total,
        }
        _stroke_cells.resize(0)
        _stroke_old.resize(0)
        _stroke_new.resize(0)
        _stroke_index.clear()
        _stroke_mat_cells.resize(0)
        _stroke_mat_old.resize(0)
        _stroke_mat_new.resize(0)
        _stroke_mat_index.clear()
        _stroke_appearance_cells.resize(0)
        _stroke_appearance_old.resize(0)
        _stroke_appearance_new.resize(0)
        _stroke_appearance_index.clear()
        _stroke_cover_old.clear()
        _stroke_cover_new.clear()
        _stroke_water_cells.resize(0)
        _stroke_water_old.resize(0)
        _stroke_water_new.resize(0)
        _stroke_water_index.clear()
        _stroke_collapsed = false
        _stroke_collapse_rect = Rect2()
        _stroke_sph_added.clear()
        _stroke_sph_removed.clear()
        _stroke_cap_added.clear()
        _stroke_cap_removed.clear()
        _stroke_prim_rect = Rect2()
        _flatten_anchor = NAN

## Deltas of the stroke currently being captured (spec name).
func get_edit_deltas() -> Dictionary:
        if not _stroke_active:
                return {}
        return {
                "cells": _stroke_cells.duplicate(),
                "old": _stroke_old.duplicate(),
                "new": _stroke_new.duplicate(),
        }

func end_stroke(p_label := "edit") -> void:
        if not _stroke_active:
                return
        var prim_changed := _stroke_sph_added.size() + _stroke_sph_removed.size() \
                        + _stroke_cap_added.size() + _stroke_cap_removed.size() > 0
        # Stability passes that belong to this same op (their writes fold into it).
        if p_label == "carve" and prim_changed:
                Stability.check_roofs(self, _stroke_bounds().grow(16.0))
        elif p_label == "sculpt" and auto_stabilize:
                Stability.relax(self, _stroke_bounds(), Stability.MAX_ITERATIONS,
                                Vector2(1e9, 1e9), 0.0, _stroke_cells)
        # Quasi-static drainage folds into this same op while the buffer is open.
        var seep := Water.seepage_from_stroke(self, _stroke_cells, _stroke_old, _stroke_new)
        if not seep.is_empty():
                seepage_total += seep.size()
                Water.drawdown(self, _stroke_cells, _stroke_old, _stroke_new)
                seepage_cells.emit(seep)
        _stroke_active = false

        var any_change := _stroke_cells.size() > 0 or prim_changed or _stroke_mat_cells.size() > 0 \
                        or _stroke_appearance_cells.size() > 0 \
                        or _stroke_cover_new.size() > 0 or _stroke_water_cells.size() > 0
        if not any_change:
                _stroke_ledger_before.clear()
                return
        var rect := _stroke_bounds()
        var op := {
                "label": p_label,
                "rect": rect,
                "cells": _stroke_cells.duplicate(),
                "old": _stroke_old.duplicate(),
                "new": _stroke_new.duplicate(),
                "mat_cells": _stroke_mat_cells.duplicate(),
                "mat_old": _stroke_mat_old.duplicate(),
                "mat_new": _stroke_mat_new.duplicate(),
                "appearance_cells": _stroke_appearance_cells.duplicate(),
                "appearance_old": _stroke_appearance_old.duplicate(),
                "appearance_new": _stroke_appearance_new.duplicate(),
                "cover_old": _stroke_cover_old.duplicate(true),
                "cover_new": _stroke_cover_new.duplicate(true),
                "water_cells": _stroke_water_cells.duplicate(),
                "water_old": _stroke_water_old.duplicate(),
                "water_new": _stroke_water_new.duplicate(),
                "sph_added": _stroke_sph_added.duplicate(),
                "sph_removed": _stroke_sph_removed.duplicate(),
                "cap_added": _stroke_cap_added.duplicate(),
                "cap_removed": _stroke_cap_removed.duplicate(),
        }
        _undo_stack.append(op)
        if _undo_stack.size() > 256:
                _undo_stack.pop_front()
        _redo_stack.clear()
        _flush_dirty()
        _rebuild_water_overlay_if_visible()
        edited_region.emit(rect)
        edited.emit()
        if _stroke_collapsed:
                collapsed.emit(_stroke_collapse_rect)
        _stroke_ledger_before.clear()

func _grow_rect(p_a: Rect2, p_b: Rect2) -> Rect2:
        if p_b.size.x <= 0.0 or p_b.size.y <= 0.0:
                return p_a
        if p_a.size.x <= 0.0 or p_a.size.y <= 0.0:
                return p_b
        return p_a.merge(p_b)

func _cancel_stroke() -> void:
        if not _stroke_active:
                return
        var changed := _stroke_cells.size() > 0 or _stroke_mat_cells.size() > 0 \
                        or _stroke_appearance_cells.size() > 0 \
                        or _stroke_cover_new.size() > 0 \
                        or _stroke_water_cells.size() > 0 or _stroke_sph_added.size() > 0 \
                        or _stroke_sph_removed.size() > 0 or _stroke_cap_added.size() > 0 \
                        or _stroke_cap_removed.size() > 0
        var op := {
                "cells": _stroke_cells,
                "old": _stroke_old,
                "new": _stroke_new,
                "mat_cells": _stroke_mat_cells,
                "mat_old": _stroke_mat_old,
                "mat_new": _stroke_mat_new,
                "appearance_cells": _stroke_appearance_cells,
                "appearance_old": _stroke_appearance_old,
                "appearance_new": _stroke_appearance_new,
                "cover_old": _stroke_cover_old,
                "cover_new": _stroke_cover_new,
                "water_cells": _stroke_water_cells,
                "water_old": _stroke_water_old,
                "water_new": _stroke_water_new,
                "sph_added": _stroke_sph_added,
                "sph_removed": _stroke_sph_removed,
                "cap_added": _stroke_cap_added,
                "cap_removed": _stroke_cap_removed,
        }
        _stroke_active = false
        if changed:
                _apply_op(op, true)
        if not _stroke_ledger_before.is_empty():
                dug_total = _stroke_ledger_before.dug_total
                spoil_loose_total = _stroke_ledger_before.spoil_loose_total
                collapse_count = _stroke_ledger_before.collapse_count
                seepage_total = _stroke_ledger_before.seepage_total
        _stroke_ledger_before.clear()

## Cancel the active editor gesture and restore its captured terrain state.
func cancel_stroke() -> void:
        _cancel_stroke()

func _stroke_bounds() -> Rect2:
        var rect := Rect2()
        if not _stroke_cells.is_empty():
                var min_i := 1 << 30
                var max_i := -(1 << 30)
                var min_j := 1 << 30
                var max_j := -(1 << 30)
                for k in _stroke_cells.size():
                        var idx := _stroke_cells[k]
                        var i: int = idx % data.N
                        var j: int = idx / data.N
                        min_i = mini(min_i, i)
                        max_i = maxi(max_i, i)
                        min_j = mini(min_j, j)
                        max_j = maxi(max_j, j)
                rect = Rect2(float(min_i) - data.HALF - 0.5, float(min_j) - data.HALF - 0.5,
                                float(max_i - min_i) + 1.0, float(max_j - min_j) + 1.0)
        if not _stroke_mat_cells.is_empty():
                # Paint strokes can be material-only: take the bounds from the
                # 1 m samples so edited_region covers the recoloured area.
                var min_x := 1e9
                var max_x := -1e9
                var min_z := 1e9
                var max_z := -1e9
                for k in _stroke_mat_cells.size():
                        var midx: int = _stroke_mat_cells[k]
                        var mx: float = float(midx % data.N) - data.HALF - 0.5
                        var mz: float = float(midx / data.N) - data.HALF - 0.5
                        min_x = minf(min_x, mx)
                        max_x = maxf(max_x, mx + 1.0)
                        min_z = minf(min_z, mz)
                        max_z = maxf(max_z, mz + 1.0)
                rect = _grow_rect(rect, Rect2(min_x, min_z, max_x - min_x, max_z - min_z))
        if not _stroke_appearance_cells.is_empty():
                for midx in _stroke_appearance_cells:
                        var mx: float = float(midx % data.MAT_N) * data.MAT_CELL - data.HALF
                        var mz: float = float(midx / data.MAT_N) * data.MAT_CELL - data.HALF
                        rect = _grow_rect(rect, Rect2(mx, mz, data.MAT_CELL, data.MAT_CELL))
        for vertex_index in _stroke_cover_new.keys():
                var i: int = int(vertex_index) % data.N
                var j: int = int(vertex_index) / data.N
                rect = _grow_rect(rect, Rect2(float(i) - data.HALF - 0.5,
                        float(j) - data.HALF - 0.5, 1.0, 1.0))
        # Only THIS stroke's primitives (a pure carve stroke used to report the
        # whole carve set, making edited_region cover the entire map).
        rect = _grow_rect(rect, _stroke_prim_rect)
        return rect

## Every height/material/prim mutation funnels through these writers.
func _stroke_set_height(p_idx: int, p_v: float) -> void:
        if _stroke_active and not _stroke_index.has(p_idx):
                _stroke_index[p_idx] = _stroke_cells.size()
                _stroke_cells.append(p_idx)
                _stroke_old.append(data.heights[p_idx])
                _stroke_new.append(p_v)
        elif _stroke_active:
                _stroke_new[_stroke_index[p_idx]] = p_v
        data.heights[p_idx] = p_v
        _edited_cells[p_idx] = true
        _mark_cell_dirty(p_idx)

## Dig-product material paint (spoil rings, pit floors exposing bedrock):
## written as a SPOIL SKIN (see _set_material_cell).
func _stroke_set_material(p_height_idx: int, p_mat_id: int) -> void:
        _set_material_cell(p_height_idx, p_mat_id, true)

## Every material mutation funnels through here.
## p_skin: spoil/dig muck, encoded -(mat + 2). Skins show up in queries
## (material_id_at decodes them) but never in roof_material_id_at, so dumped
## rubble cannot strengthen a roof. Design paints (the paint brush,
## set_material_override) store the plain id and are fully roof-bearing.
## Both kinds sync the biome grid and dirty the ground chunks, so the mesh
## recolours on the next flush.
func _set_material_cell(p_midx: int, p_mat_id: int, p_skin: bool) -> void:
        var v := -(p_mat_id + 2) if p_skin else p_mat_id
        if _mat_override[p_midx] == v:
                return
        if _stroke_active and not _stroke_mat_index.has(p_midx):
                _stroke_mat_index[p_midx] = _stroke_mat_cells.size()
                _stroke_mat_cells.append(p_midx)
                _stroke_mat_old.append(_mat_override[p_midx])
                _stroke_mat_new.append(v)
        elif _stroke_active:
                _stroke_mat_new[_stroke_mat_index[p_midx]] = v
        _mat_override[p_midx] = v
        _invalidate_material_usage_cache()
        _edited_mat_cells[p_midx] = true
        _sync_biome(p_midx)
        _set_appearance_cell(_appearance_cell_for_vertex(p_midx), &"")

func _material_has_variant(p_material_id: int, p_variant_id: StringName) -> bool:
        var material = material_definition(p_material_id)
        if material == null:
                return false
        for appearance in material.variants:
                if appearance != null and appearance.stable_id == p_variant_id:
                        return true
        return false

func _catalog_has_variant(p_variant_id: StringName) -> bool:
        for material in material_catalog.materials:
                for appearance in material.variants:
                        if appearance != null and appearance.stable_id == p_variant_id:
                                return true
        return false

func _set_appearance_cell(p_midx: int, p_variant_id: StringName) -> void:
        var value := String(p_variant_id)
        if _appearance_override[p_midx] == value:
                return
        if _stroke_active and not _stroke_appearance_index.has(p_midx):
                _stroke_appearance_index[p_midx] = _stroke_appearance_cells.size()
                _stroke_appearance_cells.append(p_midx)
                _stroke_appearance_old.append(_appearance_override[p_midx])
                _stroke_appearance_new.append(value)
        elif _stroke_active:
                _stroke_appearance_new[_stroke_appearance_index[p_midx]] = value
        _appearance_override[p_midx] = value
        _edited_appearance_cells[p_midx] = true
        _mark_appearance_cell_dirty(p_midx)

func _mark_appearance_cell_dirty(p_midx: int) -> void:
        var mi: int = p_midx % data.MAT_N
        var mj: int = p_midx / data.MAT_N
        var i: int = mi * int(data.MAT_CELL) + int(data.MAT_CELL / 2)
        var j: int = mj * int(data.MAT_CELL) + int(data.MAT_CELL / 2)
        _mark_cell_dirty(i + j * data.N)

## Push one 1 m sample's effective material into the biome grid (the source
## vertex_color tints the ground with) and dirty its owning mesh chunk.
func _sync_biome(p_midx: int) -> void:
        var v := _mat_override[p_midx]
        var eff: int = _baked_material_id_at_index(p_midx)
        if v >= 0:
                eff = v
        elif v <= -2:
                eff = -v - 2
        if data.biome[p_midx] != eff:
                data.biome[p_midx] = eff
                _mark_cell_dirty(p_midx)

## Water-head writes go through the stroke buffer too, so drainage undoes exactly.
func _stroke_set_water(p_midx: int, p_v: float) -> void:
        if _stroke_active and not _stroke_water_index.has(p_midx):
                _stroke_water_index[p_midx] = _stroke_water_cells.size()
                _stroke_water_cells.append(p_midx)
                _stroke_water_old.append(data.water_head[p_midx])
                _stroke_water_new.append(p_v)
        elif _stroke_active:
                _stroke_water_new[_stroke_water_index[p_midx]] = p_v
        data.water_head[p_midx] = p_v

## Remove a serialized row from a stroke list (exact float match). Returns true
## when the row was found and erased.
func _erase_row(p_list: Array, p_row: PackedFloat32Array, p_stride: int) -> bool:
        for k in p_list.size():
                var r: PackedFloat32Array = p_list[k]
                if r.size() != p_stride:
                        continue
                var eq := true
                for q in p_stride:
                        if r[q] != p_row[q]:
                                eq = false
                                break
                if eq:
                        p_list.remove_at(k)
                        return true
        return false

func _stroke_prim_removed_sphere(p_row: PackedFloat32Array) -> void:
        # A primitive carved AND collapsed within the same stroke never existed in
        # the pre-stroke state: cancel its addition instead of recording a removal,
        # otherwise undo would resurrect the collapsed cavity.
        if not _erase_row(_stroke_sph_added, p_row, 4):
                _stroke_sph_removed.append(p_row)
        carve_set.remove_sphere_row(p_row)
        _stroke_collapsed = true
        var c := Vector3(p_row[0], p_row[1], p_row[2])
        _stroke_collapse_rect = _grow_rect(_stroke_collapse_rect, Rect2(
                        p_row[0] - p_row[3] - 1.0, p_row[2] - p_row[3] - 1.0,
                        p_row[3] * 2.0 + 2.0, p_row[3] * 2.0 + 2.0))
        collapse_count += 1
        _carves_changed(c - Vector3.ONE * (p_row[3] + 1.0), c + Vector3.ONE * (p_row[3] + 1.0))
        _cave_cache.clear()          # removals can un-eat neighbours: rebuild everything
        _cave_dirty = true

func _stroke_prim_removed_capsule(p_row: PackedFloat32Array) -> void:
        if not _erase_row(_stroke_cap_added, p_row, 7):
                _stroke_cap_removed.append(p_row)
        carve_set.remove_capsule_row(p_row)
        _stroke_collapsed = true
        var a := Vector3(p_row[0], p_row[1], p_row[2])
        var b := Vector3(p_row[4], p_row[5], p_row[6])
        var r: float = p_row[3]
        var bmin := a.min(b) - Vector3.ONE * (r + 1.0)
        var bmax := a.max(b) + Vector3.ONE * (r + 1.0)
        _stroke_collapse_rect = _grow_rect(_stroke_collapse_rect, Rect2(
                        bmin.x, bmin.z, bmax.x - bmin.x, bmax.z - bmin.z))
        collapse_count += 1
        _carves_changed(bmin, bmax)
        _cave_cache.clear()
        _cave_dirty = true

# ------------------------------------------------------------------ undo / redo

func can_undo() -> bool:
        return not _undo_stack.is_empty()

func can_redo() -> bool:
        return not _redo_stack.is_empty()

func undo() -> bool:
        if _undo_stack.is_empty():
                return false
        _cancel_stroke()
        var op: Dictionary = _undo_stack.pop_back()
        _apply_op(op, true)
        _redo_stack.append(op)
        edited_region.emit(op.rect)
        edited.emit()
        return true

func redo() -> bool:
        if _redo_stack.is_empty():
                return false
        _cancel_stroke()
        var op: Dictionary = _redo_stack.pop_back()
        _apply_op(op, false)
        _undo_stack.append(op)
        edited_region.emit(op.rect)
        edited.emit()
        return true

func _apply_op(p_op: Dictionary, p_to_old: bool) -> void:
        _invalidate_material_usage_cache()
        var cells: PackedInt32Array = p_op.cells
        for k in cells.size():
                var v: float = p_op.old[k] if p_to_old else p_op.new[k]
                data.heights[cells[k]] = v
                _mark_cell_dirty(cells[k])
        var mcells: PackedInt32Array = p_op.mat_cells
        for k in mcells.size():
                var mv: int = p_op.mat_old[k] if p_to_old else p_op.mat_new[k]
                _mat_override[mcells[k]] = mv
                _edited_mat_cells[mcells[k]] = true
                _sync_biome(mcells[k])
        var acells: PackedInt32Array = p_op.get("appearance_cells", PackedInt32Array())
        var appearance_values := PackedStringArray()
        if p_op.has("appearance_old") and p_op.has("appearance_new"):
                appearance_values = p_op.appearance_old if p_to_old else p_op.appearance_new
        for k in acells.size():
                _appearance_override[acells[k]] = appearance_values[k]
                _edited_appearance_cells[acells[k]] = true
                _mark_appearance_cell_dirty(acells[k])
        var cover_values: Dictionary = p_op.get("cover_old", {}) if p_to_old \
                else p_op.get("cover_new", {})
        for vertex_index in cover_values.keys():
                var stack: Dictionary = cover_values[vertex_index]
                _set_cover_stack(int(vertex_index), stack.materials, stack.depths, false)
        var wcells: PackedInt32Array = p_op.water_cells
        for k in wcells.size():
                var wv: float = p_op.water_old[k] if p_to_old else p_op.water_new[k]
                data.water_head[wcells[k]] = wv
        if p_to_old:
                for row in p_op.sph_added:
                        carve_set.remove_sphere_row(row)
                        _prim_changed_rect(row, 4)
                for row in p_op.cap_added:
                        carve_set.remove_capsule_row(row)
                        _prim_changed_rect(row, 7)
                for row in p_op.sph_removed:
                        carve_set.add_sphere_row(row)
                        _prim_changed_rect(row, 4)
                for row in p_op.cap_removed:
                        carve_set.add_capsule_row(row)
                        _prim_changed_rect(row, 7)
        else:
                for row in p_op.sph_removed:
                        carve_set.remove_sphere_row(row)
                        _prim_changed_rect(row, 4)
                for row in p_op.cap_removed:
                        carve_set.remove_capsule_row(row)
                        _prim_changed_rect(row, 7)
                for row in p_op.sph_added:
                        carve_set.add_sphere_row(row)
                        _prim_changed_rect(row, 4)
                for row in p_op.cap_added:
                        carve_set.add_capsule_row(row)
                        _prim_changed_rect(row, 7)
        _cave_cache.clear()
        _cave_dirty = true
        _flush_dirty()

        _rebuild_water_overlay_if_visible()

## Ground + cave invalidation for one serialized primitive row of an undo/redo
## op (the sheet opens or closes where the primitive was).
func _prim_changed_rect(p_row: PackedFloat32Array, p_stride: int) -> void:
        if p_stride == 4:
                var c := Vector3(p_row[0], p_row[1], p_row[2])
                _carves_changed(c - Vector3.ONE * (p_row[3] + 1.0), c + Vector3.ONE * (p_row[3] + 1.0))
        else:
                var a := Vector3(p_row[0], p_row[1], p_row[2])
                var b := Vector3(p_row[4], p_row[5], p_row[6])
                _carves_changed(a.min(b) - Vector3.ONE * (p_row[3] + 1.0),
                                a.max(b) + Vector3.ONE * (p_row[3] + 1.0))

## Apply a snapshot by layer (spec name): &"height", &"material" or &"carve".
## deltas = {"cells", "old", "new"}; volume_chunks = serialized carve primitives.
func apply_edit_snapshot(p_layer: StringName, p_deltas: Dictionary,
                p_volume_chunks := PackedFloat32Array(), p_restore_old := false) -> int:
        if data == null:
                return ERR_UNCONFIGURED
        _invalidate_material_usage_cache()
        var values_key := "old" if p_restore_old else "new"
        if p_layer == &"height" or p_layer == &"material":
                var count: int = data.N * data.N
                if not EditStore.valid_sparse(p_deltas.get("cells"), p_deltas.get(values_key),
                                count, p_layer == &"material"):
                        return ERR_INVALID_DATA
                if p_layer == &"material":
                        for value in p_deltas[values_key]:
                                var material_id: int = value if value >= 0 else -value - 2
                                if value != -1 and not material_catalog.is_valid_id(material_id):
                                        return ERR_INVALID_DATA
        elif p_layer == &"carve" or p_layer == &"volume":
                if not CarveSet.valid_payload(p_volume_chunks):
                        return ERR_INVALID_DATA
        else:
                return ERR_INVALID_PARAMETER
        if p_layer == &"height" and p_deltas.has("cells"):
                var cells: PackedInt32Array = p_deltas.cells
                for k in cells.size():
                        var v: float = p_deltas.old[k] if p_restore_old else p_deltas.new[k]
                        data.heights[cells[k]] = v
                        _edited_cells[cells[k]] = true
                        _mark_cell_dirty(cells[k])
        elif p_layer == &"material" and p_deltas.has("cells"):
                var mcells: PackedInt32Array = p_deltas.cells
                for k in mcells.size():
                        var mv: int = p_deltas.old[k] if p_restore_old else p_deltas.new[k]
                        _mat_override[mcells[k]] = mv
                        _edited_mat_cells[mcells[k]] = true
                        _sync_biome(mcells[k])
        elif p_layer == &"carve" or p_layer == &"volume":
                _apply_serialized_prims(p_volume_chunks, p_restore_old)
        _flush_dirty()
        _rebuild_water_overlay_if_visible()
        edited_region.emit(Rect2(-data.HALF, -data.HALF, data.MAP, data.MAP))
        edited.emit()
        return OK

func _apply_serialized_prims(p_data_arr: PackedFloat32Array, p_remove: bool) -> void:
        if p_data_arr.size() < 2:
                return
        var sc := int(p_data_arr[0])
        for i in sc:
                var row := PackedFloat32Array()
                for k in 4:
                        row.append(p_data_arr[1 + i * 4 + k])
                if p_remove:
                        carve_set.remove_sphere_row(row)
                else:
                        carve_set.add_sphere_row(row)
                _prim_changed_rect(row, 4)
        var base := 1 + sc * 4
        var cc := int(p_data_arr[base])
        for i in cc:
                var row := PackedFloat32Array()
                for k in 7:
                        row.append(p_data_arr[base + 1 + i * 7 + k])
                if p_remove:
                        carve_set.remove_capsule_row(row)
                else:
                        carve_set.add_capsule_row(row)
                _prim_changed_rect(row, 7)
        _cave_dirty = true

## Serialized carve primitives (spec name kept from the volume-chunks API).
func get_volume_chunks() -> PackedFloat32Array:
        return carve_set.serialize()

func set_volume_chunks(p_data_arr: PackedFloat32Array) -> int:
        if data == null:
                return ERR_UNCONFIGURED
        var old_bounds := carve_set.bounds()
        if not carve_set.deserialize(p_data_arr):
                return ERR_INVALID_DATA
        _cave_cache.clear()
        _cave_dirty = true
        var b := _grow_rect(old_bounds, carve_set.bounds())
        if b.has_area():
                _carves_changed(Vector3(b.position.x, -1000.0, b.position.y),
                                Vector3(b.end.x, 1000.0, b.end.y))
        _flush_dirty()
        if b.has_area():
                edited_region.emit(b)
                edited.emit()
        return OK

# ------------------------------------------------------------------ persistence (Phase 6)

func save_edits(p_path: String) -> int:
        if data == null:
                return ERR_UNCONFIGURED
        _ensure_material_catalog()
        if not material_catalog.validate():
                return ERR_INVALID_DATA
        var store := EditStore.new()
        store.seed_value = seed_value
        store.sampling_version = data.sampling_version
        for material in material_catalog.materials:
                store.material_ids.append(String(material.stable_id))
        for idx in _edited_cells.keys():
                store.height_cells.append(idx)
                store.height_values.append(data.heights[idx])
        for midx in _edited_mat_cells.keys():
                store.material_cells.append(midx)
                store.material_values.append(_mat_override[midx])
        for midx in _edited_appearance_cells.keys():
                store.appearance_cells.append(midx)
                store.appearance_values.append(_appearance_override[midx])
                var mi: int = midx % data.MAT_N
                var mj: int = midx / data.MAT_N
                var xz := Vector2((float(mi) + 0.5) * data.MAT_CELL - data.HALF,
                        (float(mj) + 0.5) * data.MAT_CELL - data.HALF)
                var material = material_definition(material_id_at(xz))
                store.appearance_material_ids.append(String(material.stable_id) if material != null else "")
        for material in material_catalog.materials:
                for appearance in material.variants:
                        store.appearance_variant_ids.append(String(appearance.stable_id))
        for vertex_index in _edited_cover_cells.keys():
                store.cover_cells.append(int(vertex_index))
                var cover_offset: int = int(vertex_index) * COVER_LAYERS
                for layer in COVER_LAYERS:
                        store.cover_material_values.append(_cover_material_stack[cover_offset + layer])
                        store.cover_depth_values.append(_cover_depth_stack[cover_offset + layer])
        store.water_head = data.water_head.duplicate()
        store.dug_total = dug_total
        store.spoil_loose_total = spoil_loose_total
        store.collapse_count = collapse_count
        store.seepage_total = seepage_total
        store.carve_spheres = carve_set.spheres.duplicate()
        store.carve_capsules = carve_set.capsules.duplicate()
        var temporary := p_path.get_basename() + ".tmp." + p_path.get_extension()
        var err := ResourceSaver.save(store, temporary)
        if err == OK:
                err = DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary),
                        ProjectSettings.globalize_path(p_path))
        if err != OK and FileAccess.file_exists(temporary):
                DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary))
        if err == OK:
                edits_resource = ResourceLoader.load(p_path, "", ResourceLoader.CACHE_MODE_IGNORE)
                if edits_resource == null:
                        return ERR_CANT_OPEN
        return err

func load_edits(p_path: String) -> int:
        var store: Resource = ResourceLoader.load(p_path, "", ResourceLoader.CACHE_MODE_IGNORE)
        if store == null:
                return ERR_CANT_OPEN
        var result := _load_edits_store(store)
        if result == OK:
                edits_resource = store
        return result

func _load_edits_store(p_resource: Resource) -> int:
        var store := p_resource
        if not store is EditStore or not store.is_valid():
                return ERR_INVALID_DATA
        _ensure_material_catalog()
        if not material_catalog.validate():
                return ERR_INVALID_DATA
        var translated_material_values: PackedInt32Array = store.material_values.duplicate()
        for k in translated_material_values.size():
                var value: int = translated_material_values[k]
                if value == -1:
                        continue
                var old_slot: int = value if value >= 0 else -value - 2
                var new_slot := old_slot
                if store.version >= 4:
                        if old_slot < 0 or old_slot >= store.material_ids.size():
                                return ERR_INVALID_DATA
                        new_slot = material_catalog.id_for_stable_id(StringName(store.material_ids[old_slot]))
                        if new_slot < 0:
                                return ERR_DOES_NOT_EXIST
                elif not material_catalog.is_valid_id(old_slot):
                        return ERR_DOES_NOT_EXIST
                translated_material_values[k] = new_slot if value >= 0 else -(new_slot + 2)
        var translated_cover_values: PackedInt32Array = store.cover_material_values.duplicate()
        if store.version >= 6:
                for k in translated_cover_values.size():
                        var cover_slot: int = translated_cover_values[k]
                        if cover_slot < 0:
                                continue
                        if cover_slot >= store.material_ids.size():
                                return ERR_INVALID_DATA
                        var translated_slot: int = material_catalog.id_for_stable_id(
                                StringName(store.material_ids[cover_slot]))
                        if translated_slot < 0:
                                return ERR_DOES_NOT_EXIST
                        translated_cover_values[k] = translated_slot
        if store.version >= 5:
                for k in store.appearance_cells.size():
                        var material_slot: int = material_catalog.id_for_stable_id(
                                StringName(store.appearance_material_ids[k]))
                        if material_slot < 0:
                                return ERR_DOES_NOT_EXIST
                        if not store.appearance_values[k].is_empty() \
                                        and not _material_has_variant(material_slot,
                                                StringName(store.appearance_values[k])):
                                return ERR_DOES_NOT_EXIST
        if store.seed_value != seed_value:
                seed_value = store.seed_value
        sampling_version = store.sampling_version
        bake(false)
        for k in store.height_cells.size():
                var idx: int = store.height_cells[k]
                if idx >= 0 and idx < data.heights.size():
                        data.heights[idx] = store.height_values[k]
                        _edited_cells[idx] = true
                        _mark_cell_dirty(idx)
        for k in store.material_cells.size():
                var stored_index: int = store.material_cells[k]
                if store.version >= 7:
                        if stored_index >= 0 and stored_index < _mat_override.size():
                                _mat_override[stored_index] = translated_material_values[k]
                                _edited_mat_cells[stored_index] = true
                                _sync_biome(stored_index)
                else:
                        # Versions 0–6 stored a single assignment per 4 m cell.
                        # Expand that value to the exact 1 m sample footprint used by
                        # the former coarse biome sync, including the far map edge.
                        var coarse_i: int = stored_index % data.MAT_N
                        var coarse_j: int = stored_index / data.MAT_N
                        var i0: int = coarse_i * int(data.MAT_CELL)
                        var j0: int = coarse_j * int(data.MAT_CELL)
                        var i_end: int = data.N if coarse_i == data.MAT_N - 1 else i0 + int(data.MAT_CELL)
                        var j_end: int = data.N if coarse_j == data.MAT_N - 1 else j0 + int(data.MAT_CELL)
                        for j in range(j0, j_end):
                                for i in range(i0, i_end):
                                        var vertex_index: int = i + j * data.N
                                        _mat_override[vertex_index] = translated_material_values[k]
                                        _edited_mat_cells[vertex_index] = true
                                        _sync_biome(vertex_index)
        if store.version >= 5:
                for k in store.appearance_cells.size():
                        var midx: int = store.appearance_cells[k]
                        _appearance_override[midx] = store.appearance_values[k]
                        _edited_appearance_cells[midx] = true
                        _mark_appearance_cell_dirty(midx)
        if store.version >= 6:
                for sparse_index in store.cover_cells.size():
                        var vertex_index: int = store.cover_cells[sparse_index]
                        var cover_materials := PackedInt32Array()
                        var cover_depths := PackedFloat32Array()
                        cover_materials.resize(COVER_LAYERS)
                        cover_depths.resize(COVER_LAYERS)
                        for layer in COVER_LAYERS:
                                var value_index: int = sparse_index * COVER_LAYERS + layer
                                cover_materials[layer] = translated_cover_values[value_index]
                                cover_depths[layer] = store.cover_depth_values[value_index]
                        _set_cover_stack(vertex_index, cover_materials, cover_depths, false)
        if store.water_head.size() == data.MAT_N * data.MAT_N:
                data.water_head = store.water_head.duplicate()
        dug_total = store.dug_total
        spoil_loose_total = store.spoil_loose_total
        collapse_count = store.collapse_count
        seepage_total = store.seepage_total
        carve_set.spheres = store.carve_spheres.duplicate()
        carve_set.capsules = store.carve_capsules.duplicate()
        carve_set.rebuild_hash()
        _cave_cache.clear()
        _cave_dirty = true
        if carve_set.has_carve():
                var cb := carve_set.bounds()
                _carves_changed(Vector3(cb.position.x, -1000.0, cb.position.y),
                                Vector3(cb.end.x, 1000.0, cb.end.y))
        _flush_dirty()
        _rebuild_water_overlay_if_visible()
        baked.emit()
        edited_region.emit(Rect2(-data.HALF, -data.HALF, data.MAP, data.MAP))
        edited.emit()
        return OK

## Cumulative ledger (see the vars above). Undo does not rewind it.
func get_stats() -> Dictionary:
        return {
                "dug_m3": dug_total,
                "spoil_loose_m3": spoil_loose_total,
                "collapses": collapse_count,
                "seepage_cells": seepage_total,
        }

# ------------------------------------------------------------------ meshes + collision

func _mark_cell_dirty(p_idx: int) -> void:
        var i: int = p_idx % data.N
        var j: int = p_idx / data.N
        # Shared edge vertices and their one-sample normal stencil belong to
        # neighboring chunks as well. Include both owners of boundary samples.
        var ci0 := clampi(floori(float(i - 2) / MeshUtil.CHUNK_M), 0, MeshUtil.CHUNKS - 1)
        var ci1 := clampi(floori(float(i + 1) / MeshUtil.CHUNK_M), 0, MeshUtil.CHUNKS - 1)
        var cj0 := clampi(floori(float(j - 2) / MeshUtil.CHUNK_M), 0, MeshUtil.CHUNKS - 1)
        var cj1 := clampi(floori(float(j + 1) / MeshUtil.CHUNK_M), 0, MeshUtil.CHUNKS - 1)
        for cj in range(cj0, cj1 + 1):
                for ci in range(ci0, ci1 + 1):
                        _dirty_chunks[ci + cj * MeshUtil.CHUNKS] = true

func _ground_material(p_material_id: int, p_variant_index: int) -> StandardMaterial3D:
        var material_key := Vector2i(p_material_id, p_variant_index)
        if _ground_surface_material_cache.has(material_key):
                return _ground_surface_material_cache[material_key]
        var m := StandardMaterial3D.new()
        m.vertex_color_use_as_albedo = true
        m.roughness = 1.0
        m.cull_mode = BaseMaterial3D.CULL_DISABLED  # visible from inside caves
        var material = material_definition(p_material_id)
        if material != null and p_variant_index >= 0 and p_variant_index < material.variants.size():
                var appearance = material.variants[p_variant_index]
                if appearance != null:
                        m.albedo_color = appearance.tint
                        m.roughness = appearance.roughness
                        m.uv1_scale = Vector3.ONE / appearance.world_scale_m
                        if appearance.albedo != null:
                                m.albedo_texture = appearance.albedo
                        if appearance.normal_map != null:
                                m.normal_enabled = true
                                m.normal_texture = appearance.normal_map
                                m.normal_scale = appearance.normal_strength
                        if appearance.roughness_map != null:
                                m.roughness_texture = appearance.roughness_map
                        if appearance.ambient_occlusion_map != null:
                                m.ao_enabled = true
                                m.ao_texture = appearance.ambient_occlusion_map
                        if appearance.height_map != null:
                                m.heightmap_enabled = true
                                m.heightmap_texture = appearance.height_map
                                m.heightmap_scale = 0.025
        _ground_surface_material_cache[material_key] = m
        return m

func _cave_material() -> StandardMaterial3D:
        var m := StandardMaterial3D.new()
        m.vertex_color_use_as_albedo = true
        m.roughness = 0.95
        m.cull_mode = BaseMaterial3D.CULL_DISABLED
        return m

func _ensure_ground_nodes() -> void:
        if _ground_nodes.size() == MeshUtil.CHUNKS * MeshUtil.CHUNKS:
                return
        _ground_nodes.resize(MeshUtil.CHUNKS * MeshUtil.CHUNKS)
        _ground_shapes.resize(MeshUtil.CHUNKS * MeshUtil.CHUNKS)
        for cj in MeshUtil.CHUNKS:
                for ci in MeshUtil.CHUNKS:
                        var node := MeshInstance3D.new()
                        node.name = "Ground_%d_%d" % [ci, cj]
                        node.material_override = null
                        node.mesh = ArrayMesh.new()
                        add_child(node)
                        # Runtime meshes are never saved into the user's scene (no owner).
                        _ground_nodes[ci + cj * MeshUtil.CHUNKS] = node

func _rebuild_chunk(p_key: int) -> void:
        _ensure_ground_nodes()
        _ensure_collision_body()
        var ci := p_key % MeshUtil.CHUNKS
        var cj := p_key / MeshUtil.CHUNKS
        var arrays := MeshUtil.ground_chunk_arrays(self, ci, cj)
        var mesh := ArrayMesh.new()
        var has_faces: bool = not arrays[3].is_empty()
        if has_faces:
                var surface_groups: Dictionary = arrays[4]
                var surface_keys: Array = surface_groups.keys()
                surface_keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
                        return a.x < b.x or (a.x == b.x and a.y < b.y))
                for surface_key: Vector2i in surface_keys:
                        var surface_arrays := _to_mesh_arrays(arrays)
                        surface_arrays[Mesh.ARRAY_INDEX] = surface_groups[surface_key]
                        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surface_arrays)
                        mesh.surface_set_material(mesh.get_surface_count() - 1,
                                        _ground_material(surface_key.x, surface_key.y))
        _ground_nodes[p_key].mesh = mesh
        _ground_nodes[p_key].visible = has_faces
        if enable_collision and _collision_body != null:
                _rebuild_chunk_shape(p_key, arrays)

func _to_mesh_arrays(p_arrays: Array) -> Array:
        var out := []
        out.resize(Mesh.ARRAY_MAX)
        out[Mesh.ARRAY_VERTEX] = p_arrays[0]
        out[Mesh.ARRAY_NORMAL] = p_arrays[1]
        out[Mesh.ARRAY_COLOR] = p_arrays[2]
        out[Mesh.ARRAY_INDEX] = p_arrays[3]
        if p_arrays.size() > 5:
                out[Mesh.ARRAY_TEX_UV] = p_arrays[5]
        return out

func _rebuild_chunk_shape(p_key: int, p_arrays: Array) -> void:
        if _ground_shapes[p_key] == null:
                var shape := CollisionShape3D.new()
                _collision_body.add_child(shape)
                _ground_shapes[p_key] = shape
        var verts: PackedVector3Array = p_arrays[0]
        var indices: PackedInt32Array = p_arrays[3]
        if indices.is_empty():
                _ground_shapes[p_key].shape = null
                return
        var faces := PackedVector3Array()
        faces.resize(indices.size())
        for k in indices.size():
                faces[k] = verts[indices[k]]
        var poly := ConcavePolygonShape3D.new()
        # Both ray and character queries must hit the terrain surface from air.
        # The generated triangle order is upward-facing, but the configured
        # Godot physics backend reports these concave faces as back faces.
        poly.backface_collision = true
        poly.set_faces(faces)
        _ground_shapes[p_key].shape = poly

func _rebuild_cave_mesh() -> void:
        _ensure_collision_body()
        if _cave_node == null:
                _cave_node = MeshInstance3D.new()
                _cave_node.name = "CaveSurface"
                _cave_node.material_override = _cave_material()
                add_child(_cave_node)
        if not carve_set.has_carve():
                _cave_node.visible = false
                if _cave_node.mesh == null or _cave_node.mesh.get_surface_count() > 0:
                        _cave_node.mesh = ArrayMesh.new()
                if _cave_shape != null:
                        _cave_shape.shape = null
                return
        _cave_node.visible = true
        var dirty := _cave_dirty_rect
        _cave_dirty_rect = Rect2()   # consumed either way
        if _cave_dirty and carve_set.has_carve() and not dirty.has_area():
                dirty = dirty.merge(carve_set.bounds())
        var arrays := MeshUtil.cave_mesh_arrays(self, _cave_cache, dirty)
        if (arrays[3] as PackedInt32Array).is_empty():
                _cave_node.visible = false
                if _cave_node.mesh == null or _cave_node.mesh.get_surface_count() > 0:
                        _cave_node.mesh = ArrayMesh.new()
                if _cave_shape != null:
                        _cave_shape.shape = null
                return
        var mesh := ArrayMesh.new()
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _to_mesh_arrays(arrays))
        _cave_node.mesh = mesh
        if enable_collision and _collision_body != null:
                if _cave_shape == null:
                        _cave_shape = CollisionShape3D.new()
                        _collision_body.add_child(_cave_shape)
                var verts: PackedVector3Array = arrays[0]
                var indices: PackedInt32Array = arrays[3]
                var faces := PackedVector3Array()
                faces.resize(indices.size())
                for k in indices.size():
                        faces[k] = verts[indices[k]]
                var poly := ConcavePolygonShape3D.new()
                # Cave surfaces are seen from BOTH sides (you stand inside the
                # bore): without backface collision the floor would not catch a
                # walker if a triangle happens to be wound the other way.
                poly.backface_collision = true
                poly.set_faces(faces)
                _cave_shape.shape = poly

func flush_dirty() -> void:
        _flush_dirty()

func _flush_dirty() -> void:
        if data == null:
                return
        if _dirty_chunks.is_empty() and not _cave_dirty:
                return
        _ensure_ground_nodes()
        var chunk_rect := Rect2()
        for key in _dirty_chunks.keys():
                _rebuild_chunk(key)
                var ci: int = key % MeshUtil.CHUNKS
                var cj: int = key / MeshUtil.CHUNKS
                chunk_rect = _grow_rect(chunk_rect, Rect2(
                                float(ci * MeshUtil.CHUNK_M) - data.HALF,
                                float(cj * MeshUtil.CHUNK_M) - data.HALF,
                                float(MeshUtil.CHUNK_M), float(MeshUtil.CHUNK_M)))
        _dirty_chunks.clear()
        # Heightfield changes also invalidate cached cave-surface boxes.
        _cave_dirty_rect = _grow_rect(_cave_dirty_rect, chunk_rect)
        if _cave_dirty or (_cave_dirty_rect.size.x > 0.0 and carve_set.has_carve()):
                _rebuild_cave_mesh()
                _cave_dirty = false

func _ensure_collision_body() -> void:
        # No is_inside_tree() guard: scene deserialization and headless tests
        # both flush before the node enters the tree; add_child is safe anyway.
        if enable_collision and _collision_body == null:
                _collision_body = StaticBody3D.new()
                _collision_body.name = "TerrainCollision"
                add_child(_collision_body)
                _ground_shapes.fill(null)
                _cave_shape = null

## Carve primitives changed over this XZ box. The ground sheet may open (pit,
## tunnel mouth) or close (undo, collapse), so the affected ground chunks and
## cave tiles must rebuild; the stroke's primitive rect grows too.
func _carves_changed(p_bmin: Vector3, p_bmax: Vector3) -> void:
        var r := Rect2(p_bmin.x - 1.0, p_bmin.z - 1.0,
                        p_bmax.x - p_bmin.x + 2.0, p_bmax.z - p_bmin.z + 2.0)
        _cave_dirty_rect = _grow_rect(_cave_dirty_rect, r)
        _stroke_prim_rect = _grow_rect(_stroke_prim_rect, r)
        if data == null:
                return
        var c0 := clampi(int(floor((r.position.x + data.HALF) / MeshUtil.CHUNK_M)), 0, MeshUtil.CHUNKS - 1)
        var c1 := clampi(int(floor((r.end.x + data.HALF - 0.01) / MeshUtil.CHUNK_M)), 0, MeshUtil.CHUNKS - 1)
        var d0 := clampi(int(floor((r.position.y + data.HALF) / MeshUtil.CHUNK_M)), 0, MeshUtil.CHUNKS - 1)
        var d1 := clampi(int(floor((r.end.y + data.HALF - 0.01) / MeshUtil.CHUNK_M)), 0, MeshUtil.CHUNKS - 1)
        for cj in range(d0, d1 + 1):
                for ci in range(c0, c1 + 1):
                        _dirty_chunks[ci + cj * MeshUtil.CHUNKS] = true

func _set_collision(p_enabled: bool) -> void:
        enable_collision = p_enabled
        if p_enabled:
                # Shapes build on the next flush; works from a saved scene too,
                # not just live toggling (the body is created lazily).
                _dirty_chunks.clear()
                for ci in MeshUtil.CHUNKS * MeshUtil.CHUNKS:
                        _dirty_chunks[ci] = true
                _cave_dirty = true
                _flush_dirty()
        elif _collision_body != null:
                # Toggling off actually removes the shapes (they used to linger).
                for s in _ground_shapes:
                        if s != null and is_instance_valid(s):
                                _collision_body.remove_child(s)
                                s.queue_free()
                _ground_shapes.fill(null)
                if _cave_shape != null and is_instance_valid(_cave_shape):
                        _collision_body.remove_child(_cave_shape)
                        _cave_shape.queue_free()
                _cave_shape = null

func refresh_collision() -> void:
        if not enable_collision:
                return
        if _collision_body == null:
                _set_collision(true)
                return
        _dirty_chunks.clear()
        for ci in MeshUtil.CHUNKS * MeshUtil.CHUNKS:
                _dirty_chunks[ci] = true
        _cave_dirty = true
        _flush_dirty()

# ------------------------------------------------------------------ water overlay

func _set_water_debug(p_on: bool) -> void:
        debug_water_table = p_on
        if is_instance_valid(_water_node):
                _water_node.visible = p_on
        if p_on:
                _rebuild_water_overlay_if_visible()

func _rebuild_water_overlay_if_visible() -> void:
        if not debug_water_table or data == null or data.heights.is_empty():
                return
        if _water_node == null:
                _water_node = MeshInstance3D.new()
                _water_node.name = "WaterTableOverlay"
                var m := StandardMaterial3D.new()
                m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
                m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
                m.vertex_color_use_as_albedo = true
                m.cull_mode = BaseMaterial3D.CULL_DISABLED
                _water_node.material_override = m
                add_child(_water_node)
        var res := 48
        var verts := PackedVector3Array()
        var colors := PackedColorArray()
        var indices := PackedInt32Array()
        for j in res + 1:
                var wz: float = (float(j) / float(res)) * data.MAP - data.HALF
                for i in res + 1:
                        var wx: float = (float(i) / float(res)) * data.MAP - data.HALF
                        var head := water_table_at(Vector2(wx, wz))
                        var h := height_at(Vector2(wx, wz))
                        var pore := pore_factor_at(Vector2(wx, wz))
                        verts.append(Vector3(wx, maxf(head, h - 0.1) + 0.06, wz))
                        colors.append(Color(0.15, 0.4, 0.85, clampf(pore * 0.8, 0.03, 0.75)))
        for j in res:
                for i in res:
                        var a := j * (res + 1) + i
                        indices.append(a)
                        indices.append(a + res + 1)
                        indices.append(a + 1)
                        indices.append(a + 1)
                        indices.append(a + res + 1)
                        indices.append(a + res + 2)
        var arrays := []
        arrays.resize(Mesh.ARRAY_MAX)
        arrays[Mesh.ARRAY_VERTEX] = verts
        arrays[Mesh.ARRAY_COLOR] = colors
        arrays[Mesh.ARRAY_INDEX] = indices
        var mesh := ArrayMesh.new()
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        _water_node.mesh = mesh

# ------------------------------------------------------------------ brush cursor

func show_brush_cursor() -> void:
        _ensure_cursor()
        if _cursor_ring != null:
                _cursor_ring.visible = true

func hide_brush_cursor() -> void:
        if _cursor_ring != null:
                _cursor_ring.visible = false
        if _cursor_sphere != null:
                _cursor_sphere.visible = false

func set_brush_cursor(p_pos: Vector3, p_radius: float, p_three_d_radius := -1.0) -> void:
        _ensure_cursor()
        if _cursor_ring != null:
                _cursor_ring.visible = true
                _cursor_ring.position = p_pos + Vector3(0, 0.06, 0)
                _cursor_ring.scale = Vector3(p_radius, p_radius, p_radius)
        if _cursor_sphere != null:
                if p_three_d_radius > 0.0:
                        _cursor_sphere.visible = true
                        _cursor_sphere.position = p_pos
                        _cursor_sphere.scale = Vector3.ONE * p_three_d_radius
                else:
                        _cursor_sphere.visible = false

func _ensure_cursor() -> void:
        if _cursor_ring != null and is_instance_valid(_cursor_ring):
                return
        var ring_mat := StandardMaterial3D.new()
        ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        ring_mat.albedo_color = Color(1.0, 0.55, 0.1, 0.9)
        var torus := TorusMesh.new()
        torus.inner_radius = 0.04
        torus.outer_radius = 1.0
        _cursor_ring = MeshInstance3D.new()
        _cursor_ring.name = "BrushCursor"
        _cursor_ring.mesh = torus
        _cursor_ring.material_override = ring_mat
        add_child(_cursor_ring)
        var sph_mat := StandardMaterial3D.new()
        sph_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        sph_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        sph_mat.albedo_color = Color(1.0, 0.55, 0.1, 0.25)
        _cursor_sphere = MeshInstance3D.new()
        _cursor_sphere.name = "BrushCursorVolume"
        _cursor_sphere.mesh = SphereMesh.new()
        _cursor_sphere.material_override = sph_mat
        add_child(_cursor_sphere)
        _cursor_sphere.visible = false
