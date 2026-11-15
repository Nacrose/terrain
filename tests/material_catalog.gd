extends SceneTree
## Focused checks for custom material authoring and stable-ID edit persistence.
const Terrain = preload("res://addons/stoem_terrain/nodes/terrain_3d.gd")
const Catalog = preload("res://addons/stoem_terrain/core/terrain_material_catalog.gd")
const Variant = preload("res://addons/stoem_terrain/core/terrain_material_variant.gd")
const EditStore = preload("res://addons/stoem_terrain/core/terrain_edits.gd")

var failures := 0

func _initialize() -> void:
	var terrain = Terrain.new()
	terrain.name = "MaterialCatalogTest"
	root.add_child(terrain)
	terrain.bake()
	var catalog = terrain.material_catalog
	_check(catalog is Catalog and catalog.validate(), "default catalog is valid")
	_check(catalog.count() == 7, "legacy built-in material IDs remain available")
	var created_id: int = catalog.create_material("Basalt")
	_check(created_id == 7 and catalog.count() == 8, "create appends a stable custom material")
	_check(terrain.dig_mask.size() == 8, "new materials receive a default-enabled dig mask")
	var created = catalog.get_material(created_id)
	created.preview_color = Color(0.12, 0.18, 0.24)
	created.bulk_density_kg_m3 = 2900.0
	created.wet_repose_reduction = 0.3
	_check(terrain.material_mass_kg(created_id, 2.0) == 5800.0, "density feeds the mass query")
	_check(is_equal_approx(terrain.wet_repose_deg(created_id, 1.0), created.repose_deg * 0.7),
			"wet repose reduction is material-adjustable")
	var variant = catalog.create_variant(created_id, "Chunked basalt")
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.2, 0.3, 0.4))
	var texture := ImageTexture.create_from_image(image)
	variant.albedo = texture
	variant.world_scale_m = 2.0
	variant.emit_changed()
	_check(not variant.stable_id.is_empty(), "texture set receives a persistent identity")
	var copy_id: int = catalog.duplicate_material(created_id)
	var copied = catalog.get_material(copy_id)
	_check(copy_id == 8 and catalog.validate(), "duplicate material remains catalog-valid")
	_check(copied.stable_id != created.stable_id, "duplicate material receives a fresh persistent ID")
	_check(copied.variants[0] != variant and copied.variants[0].stable_id != variant.stable_id,
			"duplicate appearance controls get independent identities")
	copied.variants[0].roughness = 0.2
	_check(not is_equal_approx(variant.roughness, copied.variants[0].roughness),
			"editing a duplicated appearance does not modify the source")
	var point := Vector2(-30.0, 18.0)
	terrain.paint_material(point.x, point.y, 0.0, created_id, variant.stable_id)
	_check(terrain.material_id_at(point) == created_id, "custom material can be assigned to terrain")
	_check(terrain.appearance_variant_id_at(point) == variant.stable_id,
			"selected texture set is painted independently from the material identity")
	var second_variant = catalog.create_variant(created_id, "Weathered basalt")
	second_variant.albedo = texture
	second_variant.world_scale_m = 2.0
	second_variant.emit_changed()
	var patch_pick_a: int = terrain.appearance_variant_index_for_cell(0, created_id)
	var patch_pick_b: int = terrain.appearance_variant_index_for_cell(1, created_id)
	_check(patch_pick_a >= 0 and patch_pick_a == patch_pick_b,
			"weighted texture variation is coherent across neighboring cells in one patch")
	catalog.reorder_display(copy_id, 0)
	_check(terrain.appearance_variant_index_for_cell(0, created_id) == patch_pick_a,
			"weighted appearance remains stable when shelf order changes")
	var other_point := point + Vector2(8.0, 0.0)
	terrain.set_material_override(other_point, 0)
	terrain.paint_appearance(point.x, point.y, 0.0, created_id, second_variant.stable_id)
	_check(terrain.material_id_at(point) == created_id \
			and terrain.appearance_variant_id_at(point) == second_variant.stable_id,
			"appearance-only paint changes texture without replacing physical material")
	_check(terrain.material_id_at(other_point) == 0,
			"appearance-only paint skips cells with a different physical material")
	_check(terrain.undo() and terrain.appearance_variant_id_at(point) == variant.stable_id,
			"appearance-only paint participates in undo")
	_check(terrain.redo() and terrain.appearance_variant_id_at(point) == second_variant.stable_id,
			"appearance-only paint participates in redo")
	var cover_point := Vector2(60.0, -48.0)
	terrain.set_material_override(cover_point, 4) # granite base, also the configured substrate
	var first_deposit: float = terrain.deposit_material(cover_point.x, cover_point.y,
			1.25, 0.4, created_id)
	_check(first_deposit > 0.4 and terrain.material_id_at(cover_point) == created_id \
			and is_equal_approx(terrain.cover_depth_at(cover_point), 0.4),
			"first deposit adds geometry and a metre-resolved cover layer")
	var second_deposit: float = terrain.deposit_material(cover_point.x, cover_point.y,
			1.25, 0.2, 6)
	_check(second_deposit > 0.2 and terrain.material_id_at(cover_point) == 6 \
			and terrain.material_id_at_depth(cover_point, 0.3) == created_id \
			and terrain.material_id_at_depth(cover_point, 0.7) == 4,
			"second deposit stacks above the first and exposes the base at depth")
	var painted_usage: Dictionary = terrain.material_usage_for(created_id)
	var cover_usage: Dictionary = terrain.material_usage_for(6)
	_check(painted_usage.material_cells == 1 and painted_usage.cover_layers > 0,
			"material usage counts painted 1 m samples and deposited strata")
	_check(cover_usage.cover_layers > 0,
			"material usage cache refreshes when another material is deposited")
	_check(terrain.undo() and terrain.material_id_at(cover_point) == created_id,
			"deposit layer participates in undo")
	_check(terrain.redo() and terrain.material_id_at(cover_point) == 6,
			"deposit layer participates in redo")
	var covered_dig_depth: float = terrain.cover_depth_at(cover_point)
	var covered_dig_y: float = terrain.height_at(cover_point)
	var covered_removed: float = terrain.dig(Vector3(cover_point.x, covered_dig_y + 0.05,
			cover_point.y), 0.5, 0.01)
	_check(covered_removed > 0.0 and terrain.cover_depth_at(cover_point) < covered_dig_depth,
			"terrain dig consumes cover thickness along with the cut")
	_check(terrain.undo() and is_equal_approx(terrain.cover_depth_at(cover_point), covered_dig_depth),
			"covered dig restores layer depth on undo")
	_check(terrain.redo() and terrain.cover_depth_at(cover_point) < covered_dig_depth,
			"covered dig reapplies layer depth on redo")
	var cover_vertex: int = terrain._height_vertex_index(cover_point)
	terrain.begin_stroke()
	var removed_cover: float = terrain._consume_cover(cover_vertex, 0.3)
	terrain.end_stroke("excavate")
	_check(is_equal_approx(removed_cover, 0.3) and terrain.material_id_at(cover_point) == created_id,
			"excavation consumes the top layer and exposes the layer below")
	_check(terrain.undo() and terrain.material_id_at(cover_point) == 6,
			"cover excavation is undoable")
	_check(terrain.redo() and terrain.material_id_at(cover_point) == created_id,
			"cover excavation redoes in layer order")
	var full_stack_point := Vector2(90.0, -90.0)
	terrain.set_material_override(full_stack_point, 4)
	for layer_material in [7, 6, 5, 4]:
		terrain.deposit_material(full_stack_point.x, full_stack_point.y, 0.6, 0.05, layer_material)
	var full_stack_height: float = terrain.height_at(full_stack_point)
	var rejected_fifth: float = terrain.deposit_material(full_stack_point.x,
			full_stack_point.y, 0.6, 0.05, 3)
	_check(is_equal_approx(rejected_fifth, 0.0) \
			and is_equal_approx(terrain.height_at(full_stack_point), full_stack_height),
			"full cover stack refuses an implicit fifth layer without partial changes")
	terrain.deposit_material(full_stack_point.x, full_stack_point.y, 0.6, 0.05, 3, true)
	_check(terrain.material_id_at(full_stack_point) == 3 \
			and is_equal_approx(terrain.cover_depth_at(full_stack_point), 0.25),
			"explicit reclassification handles a full bounded layer stack")
	_check(terrain.undo() and terrain.material_id_at(full_stack_point) == 4,
			"full-stack reclassification is undoable")
	_check(terrain.redo() and terrain.material_id_at(full_stack_point) == 3,
			"full-stack reclassification redoes")
	var ground: MeshInstance3D = terrain.get_node("Ground_7_8")
	var rendered_texture := false
	for surface in ground.mesh.get_surface_count():
		var surface_material: StandardMaterial3D = ground.mesh.surface_get_material(surface)
		if surface_material.albedo_texture == texture \
					and is_equal_approx(surface_material.uv1_scale.x, 0.5):
			rendered_texture = true
	_check(rendered_texture, "material texture set reaches the terrain surface with metre-based tiling")
	var contact: Dictionary = terrain.surface_physics_at(point)
	_check(contact.get("stable_id", &"") == created.stable_id, "surface physics query returns the stable material identity")
	var path := "res://review_state/material_catalog_edits.res"
	_check(terrain.save_edits(path) == OK, "custom material edits save")
	_check(terrain.edits_resource is EditStore and terrain.edits_resource.is_valid(),
			"saving edits links the saved resource for scene startup")
	var stored: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	_check(stored is EditStore and stored.version == 7 and stored.is_valid(), "custom edit file validates as schema 7")
	_check(stored.material_ids.size() == 9 and stored.material_ids[created_id] == String(created.stable_id),
			"edit file maps material slots to stable IDs")
	var point_material_sample: int = int(round(point.x + terrain.data.HALF)) \
			+ int(round(point.y + terrain.data.HALF)) * terrain.data.N
	var point_sample_index: int = stored.material_cells.find(point_material_sample)
	_check(point_sample_index >= 0 and stored.material_values[point_sample_index] == created_id,
			"edit file stores 1 m physical material assignments")
	var point_material_cell: int = int(floor((point.x + terrain.data.HALF) / terrain.data.MAT_CELL)) \
			+ int(floor((point.y + terrain.data.HALF) / terrain.data.MAT_CELL)) * terrain.data.MAT_N
	var point_appearance_index: int = stored.appearance_cells.find(point_material_cell)
	_check(point_appearance_index >= 0 \
			and stored.appearance_values[point_appearance_index] == String(second_variant.stable_id),
			"edit file stores the selected texture set by stable ID")
	_check(not stored.cover_cells.is_empty() \
			and stored.cover_material_values.size() == stored.cover_cells.size() * terrain.COVER_LAYERS,
			"edit file stores full cover stacks")
	terrain.set_material_override(point, 0)
	_check(terrain.load_edits(path) == OK and terrain.material_id_at(point) == created_id,
			"custom material identity survives terrain edit reload")
	_check(terrain.appearance_variant_id_at(point) == second_variant.stable_id,
			"selected texture set survives terrain edit reload")
	_check(terrain.material_id_at(cover_point) == created_id \
			and terrain.cover_depth_at(cover_point) > 0.25 \
			and terrain.cover_depth_at(cover_point) < 0.35
			and terrain.material_id_at_depth(cover_point, 0.4) == 4,
			"cover stack and substrate survive save/load by stable material identity")
	var scene_target = Terrain.new()
	scene_target.seed_value = terrain.seed_value
	var load_error: int = scene_target.load_edits(path)
	_check(load_error == ERR_DOES_NOT_EXIST, "missing custom material IDs reject load before mutation")
	_check(scene_target.data == null and scene_target.seed_value == terrain.seed_value,
			"failed custom load leaves the target terrain unchanged")
	var startup_state := {"bakes": 0, "material": -1}
	scene_target.baked.connect(func() -> void:
		startup_state.bakes += 1
		startup_state.material = scene_target.material_id_at(point))
	scene_target.material_catalog = catalog
	scene_target.edits_resource = stored
	root.add_child(scene_target)
	await process_frame
	_check(startup_state.bakes == 1 and startup_state.material == created_id,
			"scene-linked edits restore before the terrain publishes its ready signal")
	_check(scene_target.appearance_variant_id_at(point) == second_variant.stable_id,
			"scene-linked appearance assignments restore automatically")
	_check(scene_target.material_id_at(cover_point) == created_id \
			and scene_target.cover_depth_at(cover_point) > 0.25 \
			and scene_target.cover_depth_at(cover_point) < 0.35,
			"scene-linked cover strata restore automatically")
	var preset_path := "res://review_state/basalt_preset.tres"
	_check(ResourceSaver.save(created, preset_path) == OK,
			"material preset exports as a reusable resource")
	var preset: Resource = ResourceLoader.load(preset_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	var imported_id: int = catalog.import_material(preset)
	var imported = catalog.get_material(imported_id)
	_check(imported_id >= 0 and imported != null and imported.stable_id != created.stable_id,
			"material preset imports as a fresh material identity")
	_check(imported != null and imported.variants.size() == 2 \
			and imported.variants[0].stable_id != preset.variants[0].stable_id \
			and imported.variants[0] != preset.variants[0] \
			and imported.variants[0].albedo == preset.variants[0].albedo,
			"imported texture controls are independent while texture assets stay shared")
	var invalid_preset = created.duplicate(false)
	invalid_preset.hardness = NAN
	var catalog_size_before_invalid_import: int = catalog.count()
	_check(catalog.import_material(invalid_preset) < 0 \
			and catalog.count() == catalog_size_before_invalid_import,
			"invalid material preset is rejected without changing the catalog")
	var replace_point := Vector2(250.0, 250.0)
	terrain.set_material_override(replace_point, imported_id)
	var replaced_cells: int = terrain.replace_base_material_usage(imported_id, created_id)
	_check(replaced_cells == 16 and terrain.material_id_at(replace_point) == created_id,
			"base material replacement changes only matching 1 m samples on this terrain")
	_check(terrain.undo() and terrain.material_id_at(replace_point) == imported_id,
			"base material replacement is one undoable operation")
	_check(terrain.redo() and terrain.material_id_at(replace_point) == created_id,
			"base material replacement redoes correctly")
	var imported_stable_id: StringName = imported.stable_id if imported != null else &""
	_check(imported_id >= 0 and catalog.archive_material(imported_id) and catalog.is_archived(imported_id) \
			and catalog.id_for_stable_id(imported_stable_id) == imported_id \
			and catalog.validate(),
			"archive hides a material without changing its stable catalog slot")
	_check(catalog.restore_material(imported_id) and not catalog.is_archived(imported_id) \
			and catalog.id_for_stable_id(imported_stable_id) == imported_id,
			"archived material can be restored with all saved references intact")
	var library_source := Catalog.new()
	var library_material_id: int = library_source.create_material("Library loam")
	var library_material = library_source.get_material(library_material_id)
	library_material.key = &"alluvial_soil"
	var library_variant = library_source.create_variant(library_material_id, "Mossy")
	library_variant.albedo = texture
	library_source.archive_material(library_material_id)
	var library_path := "res://review_state/terrain_material_library.tres"
	_check(ResourceSaver.save(library_source, library_path) == OK,
			"whole material catalog exports as a reusable library")
	var loaded_library: Resource = ResourceLoader.load(library_path, "",
			ResourceLoader.CACHE_MODE_IGNORE)
	var merge_destination := Catalog.new()
	var merge_result: Dictionary = merge_destination.merge_catalog(loaded_library)
	var merged_material_id: int = merge_destination.id_for_stable_id(library_material.stable_id)
	var merged_material = merge_destination.get_material(merged_material_id)
	var loaded_library_material = loaded_library.get_material(library_material_id)
	_check(bool(merge_result.get("ok", false)) and int(merge_result.get("added", 0)) == 1 \
			and int(merge_result.get("skipped", 0)) == 7 and merged_material_id >= 7,
			"catalog merge adds new stable IDs and skips shared built-in identities")
	_check(merged_material != library_material and merged_material.stable_id == library_material.stable_id \
			and merged_material.key == library_material.key \
			and merged_material.variants[0] != library_variant \
			and merged_material.variants[0].stable_id == library_variant.stable_id \
			and merged_material.variants[0].albedo == loaded_library_material.variants[0].albedo,
			"merged material controls are independent while identities and texture references are preserved")
	_check(merge_destination.is_archived(merged_material_id),
			"catalog merge preserves archived shelf state for added materials")
	var repeated_merge: Dictionary = merge_destination.merge_catalog(loaded_library)
	_check(int(repeated_merge.get("added", -1)) == 0 \
			and int(repeated_merge.get("skipped", 0)) == 8 \
			and merge_destination.count() == 8,
			"repeating a library merge is idempotent by stable material identity")
	var invalid_library = loaded_library.duplicate(false)
	invalid_library.materials = loaded_library.materials.duplicate()
	invalid_library.materials[7] = loaded_library.materials[7].duplicate(false)
	invalid_library.materials[7].hardness = NAN
	var count_before_invalid_merge: int = merge_destination.count()
	var invalid_merge: Dictionary = merge_destination.merge_catalog(invalid_library)
	_check(not bool(invalid_merge.get("ok", true)) \
			and merge_destination.count() == count_before_invalid_merge,
			"invalid catalog merge is rejected without partial changes")
	print("MATERIAL CATALOG RESULT: %d failure(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS ", message)
	else:
		failures += 1
		print("FAIL ", message)
