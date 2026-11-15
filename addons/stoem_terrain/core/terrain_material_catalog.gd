@tool
class_name StoemTerrainMaterialCatalog
extends Resource
## Stable material slots with a separate reorderable shelf view. Removing a
## used slot must preserve its position until terrain data has been remapped.

const Definition = preload("res://addons/stoem_terrain/core/terrain_material.gd")
const Variant = preload("res://addons/stoem_terrain/core/terrain_material_variant.gd")
const Defaults = preload("res://addons/stoem_terrain/core/terrain_material_table.gd")

@export var materials: Array[Resource] = []
@export var display_order: PackedInt32Array = PackedInt32Array()
@export var archived_material_ids: PackedInt32Array = PackedInt32Array()

func _init() -> void:
	if materials.is_empty():
		for source in Defaults.table():
			materials.append(source.duplicate(true))
	if display_order.is_empty():
		for i in materials.size():
			display_order.append(i)

func count() -> int:
	return materials.size()

func is_valid_id(p_id: int) -> bool:
	return p_id >= 0 and p_id < materials.size() and materials[p_id] != null

func get_material(p_id: int) -> Resource:
	return materials[p_id] if is_valid_id(p_id) else null

func key_for_id(p_id: int) -> StringName:
	var material := get_material(p_id)
	return material.key if material != null else &""

func display_name_for_id(p_id: int) -> String:
	var material := get_material(p_id)
	if material == null:
		return "Missing Material"
	return material.display_name if not material.display_name.is_empty() else String(material.key).capitalize()

func id_for_stable_id(p_stable_id: StringName) -> int:
	for i in materials.size():
		if materials[i] != null and materials[i].stable_id == p_stable_id:
			return i
	return -1

func create_material(p_name: String = "New Material") -> int:
	var material = Definition.new()
	material.display_name = p_name
	material.key = StringName(p_name.to_snake_case())
	material.stable_id = _new_stable_id()
	material.hardness = 0.25
	material.cohesion_kpa = 10.0
	material.friction_deg = 30.0
	material.repose_deg = 32.0
	material.permeability = 1.0e-5
	material.surface_friction = 0.7
	material.digging_spoil_ratio = 1.2
	material.bulk_density_kg_m3 = 1400.0
	material.porosity = 0.4
	material.preview_color = Color(0.42, 0.48, 0.38)
	materials.append(material)
	display_order.append(materials.size() - 1)
	_emit_change()
	return materials.size() - 1

func duplicate_material(p_id: int, p_name: String = "") -> int:
	var source = get_material(p_id)
	if source == null or not validate():
		return -1
	var copy_name: String = p_name if not p_name.is_empty() else source.display_name + " Copy"
	return _append_independent_copy(source, copy_name)

## Imports a preset as a new catalog entry. The imported material and texture
## set controls receive fresh identities; texture map resources remain shared.
func import_material(p_source: Resource) -> int:
	if not p_source is Definition or not validate():
		return -1
	for appearance in p_source.variants:
		if appearance == null or not appearance is Variant:
			return -1
	return _append_independent_copy(p_source, p_source.display_name)

func _append_independent_copy(p_source: Resource, p_name: String) -> int:
	var copy = p_source.duplicate(false)
	copy.stable_id = _new_stable_id()
	copy.display_name = p_name.strip_edges() if not p_name.strip_edges().is_empty() else "Imported Material"
	copy.key = StringName(copy.display_name.to_snake_case())
	copy.tags = p_source.tags.duplicate()
	copy.wet_repose_response = p_source.wet_repose_response.duplicate(true) \
			if p_source.wet_repose_response != null else null
	copy.wet_cohesion_response = p_source.wet_cohesion_response.duplicate(true) \
			if p_source.wet_cohesion_response != null else null
	var independent_variants: Array[Resource] = []
	for source_variant in p_source.variants:
		if source_variant == null:
			independent_variants.append(null)
			continue
		# Duplicate editable controls while sharing texture maps by reference.
		var variant_copy = source_variant.duplicate(false)
		variant_copy.stable_id = _new_stable_id()
		independent_variants.append(variant_copy)
	copy.variants = independent_variants
	materials.append(copy)
	display_order.append(materials.size() - 1)
	if not validate():
		materials.pop_back()
		display_order.remove_at(display_order.size() - 1)
		return -1
	_emit_change()
	return materials.size() - 1

func create_variant(p_material_id: int, p_name: String = "Texture Set") -> Resource:
	var material = get_material(p_material_id)
	if material == null:
		return null
	var appearance = Variant.new()
	appearance.stable_id = _new_stable_id()
	appearance.display_name = p_name
	material.variants.append(appearance)
	_emit_change()
	return appearance

func reorder_display(p_id: int, p_target_index: int) -> bool:
	var old_index := display_order.find(p_id)
	if old_index < 0 or p_target_index < 0 or p_target_index >= display_order.size():
		return false
	display_order.remove_at(old_index)
	display_order.insert(p_target_index, p_id)
	_emit_change()
	return true

## Hides a material from the default paint shelf without removing its stable
## slot or changing terrain/save references. This is an archive action, not a
## destructive delete; archived entries can be restored at any time.
func archive_material(p_id: int) -> bool:
	if not is_valid_id(p_id) or archived_material_ids.has(p_id):
		return false
	archived_material_ids.append(p_id)
	_emit_change()
	return true

func restore_material(p_id: int) -> bool:
	var archived_index: int = archived_material_ids.find(p_id)
	if archived_index < 0:
		return false
	archived_material_ids.remove_at(archived_index)
	_emit_change()
	return true

func is_archived(p_id: int) -> bool:
	return archived_material_ids.has(p_id)

## State payload used by the editor undo manager for catalog-level actions.
## Material resources are intentionally shared; structural actions only change
## the catalog arrays and archive list.
func editor_state_snapshot() -> Dictionary:
	var material_snapshot: Array[Resource] = []
	for material in materials:
		material_snapshot.append(material)
	return {
		"materials": material_snapshot,
		"display_order": display_order.duplicate(),
		"archived_material_ids": archived_material_ids.duplicate(),
	}

func restore_editor_state(p_state: Dictionary) -> bool:
	var raw_materials: Variant = p_state.get("materials")
	var raw_order: Variant = p_state.get("display_order")
	var raw_archived: Variant = p_state.get("archived_material_ids")
	if not raw_materials is Array or not raw_order is PackedInt32Array \
			or not raw_archived is PackedInt32Array:
		return false
	var restored_materials: Array[Resource] = []
	for material in raw_materials:
		if material == null or not material is Definition:
			return false
		restored_materials.append(material)
	var old_materials := materials
	var old_order := display_order
	var old_archived := archived_material_ids
	materials = restored_materials
	display_order = raw_order.duplicate()
	archived_material_ids = raw_archived.duplicate()
	if not validate():
		materials = old_materials
		display_order = old_order
		archived_material_ids = old_archived
		return false
	_emit_change()
	return true

## Refreshes terrain consumers after an undo/redo catalog/material mutation.
func notify_editor_mutation() -> void:
	_emit_change()

func validate() -> bool:
	if display_order.size() != materials.size():
		return false
	var seen := {}
	for slot in display_order:
		if slot < 0 or slot >= materials.size() or seen.has(slot):
			return false
		seen[slot] = true
	var archived_seen := {}
	for slot in archived_material_ids:
		if not is_valid_id(slot) or archived_seen.has(slot):
			return false
		archived_seen[slot] = true
	var ids := {}
	var variant_ids := {}
	for material in materials:
		if material == null or not material is Definition:
			return false
		if material.stable_id.is_empty() or ids.has(material.stable_id):
			return false
		ids[material.stable_id] = true
		if not is_finite(material.appearance_patch_size_m) or material.appearance_patch_size_m < 1.0 \
				or not is_finite(material.hardness) or material.hardness < 0.0 \
				or not is_finite(material.cohesion_kpa) or material.cohesion_kpa < 0.0 \
				or not is_finite(material.friction_deg) or material.friction_deg < 0.0 or material.friction_deg > 89.0 \
				or not is_finite(material.repose_deg) or material.repose_deg < 0.0 or material.repose_deg > 89.0 \
				or not is_finite(material.permeability) or material.permeability < 0.0 \
				or not is_finite(material.surface_friction) or material.surface_friction < 0.0 \
				or not is_finite(material.digging_spoil_ratio) or material.digging_spoil_ratio < 1.0 \
				or not is_finite(material.bulk_density_kg_m3) or material.bulk_density_kg_m3 <= 0.0 \
				or not is_finite(material.porosity) or material.porosity < 0.0 or material.porosity > 1.0 \
				or not is_finite(material.wet_repose_reduction) or material.wet_repose_reduction < 0.0 or material.wet_repose_reduction > 1.0 \
				or not is_finite(material.wet_cohesion_reduction) or material.wet_cohesion_reduction < 0.0 or material.wet_cohesion_reduction > 1.0 \
				or not _is_valid_response_curve(material.wet_repose_response) \
				or not _is_valid_response_curve(material.wet_cohesion_response):
			return false
		for appearance in material.variants:
			if appearance == null or not appearance is Variant:
				return false
			if appearance.stable_id.is_empty() or variant_ids.has(appearance.stable_id) \
					or not is_finite(appearance.weight) or appearance.weight < 0.0 \
					or not is_finite(appearance.world_scale_m) or appearance.world_scale_m <= 0.0:
				return false
			variant_ids[appearance.stable_id] = true
			if not material.variants.is_empty():
				var total_weight := 0.0
				for candidate in material.variants:
					total_weight += candidate.weight
				if total_weight <= 0.0:
					return false
	return true

## Moisture response resources must use normalized 0–1 pore saturation and
## return a normalized 0–1 reduction multiplier. Null curves use the old linear
## response, so existing material resources remain valid without migration.
func _is_valid_response_curve(p_curve: Curve) -> bool:
	if p_curve == null:
		return true
	if p_curve.get_point_count() < 2 \
			or not is_finite(p_curve.min_domain) or not is_finite(p_curve.max_domain) \
			or not is_equal_approx(p_curve.min_domain, 0.0) \
			or not is_equal_approx(p_curve.max_domain, 1.0):
		return false
	var previous_x := -INF
	for point_index in p_curve.get_point_count():
		var point: Vector2 = p_curve.get_point_position(point_index)
		if not point.is_finite() or point.x < 0.0 or point.x > 1.0 \
				or point.y < 0.0 or point.y > 1.0 or point.x <= previous_x:
			return false
		previous_x = point.x
	if not is_equal_approx(p_curve.get_point_position(0).x, 0.0) \
			or not is_equal_approx(p_curve.get_point_position(p_curve.get_point_count() - 1).x, 1.0):
		return false
	for sample_index in 33:
		var sample_x := float(sample_index) / 32.0
		var sample_value: float = p_curve.sample(sample_x)
		if not is_finite(sample_value) or sample_value < 0.0 or sample_value > 1.0:
			return false
	return true

func _new_stable_id() -> StringName:
	return StringName("stoem:%s" % str(ResourceUID.create_id()))

func _emit_change() -> void:
	if Engine.is_editor_hint():
		notify_property_list_changed()
	emit_changed()
