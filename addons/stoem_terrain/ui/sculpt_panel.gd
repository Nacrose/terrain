@tool
extends VBoxContainer
## Stoem Terrain dock panel. Built in code so the plugin stays scene-file free.
## Tools keep their own radius (carve has its own, dig its own), matching the
## original plugin's per-tool behaviour.

const Mat = preload("res://addons/stoem_terrain/core/terrain_material_table.gd")
const Catalog = preload("res://addons/stoem_terrain/core/terrain_material_catalog.gd")

signal edit_material_requested(material: Resource)
signal edits_resource_linked(terrain: Node, old_resource: Resource, new_resource: Resource)
signal catalog_mutation_recorded(catalog: Resource, label: String, before_state: Dictionary, after_state: Dictionary)
signal material_property_mutation_recorded(catalog: Resource, material: Resource, label: String,
                property_name: String, before_value: Variant, after_value: Variant)

const TOOL_RAISE := 0
const TOOL_LOWER := 1
const TOOL_SMOOTH := 2
const TOOL_FLATTEN := 3
const CARVE_TOOL := 4
const DIG_TOOL := 5
const PAINT_TOOL := 6
const DEPOSIT_TOOL := 7
const SELECT_TOOL := -1
const TOOL_IDS := [SELECT_TOOL, TOOL_RAISE, TOOL_LOWER, TOOL_SMOOTH, TOOL_FLATTEN,
                CARVE_TOOL, DIG_TOOL, PAINT_TOOL, DEPOSIT_TOOL]
const TOOL_NAMES := ["Select", "Raise", "Lower", "Smooth", "Flatten", "Carve", "Dig", "Paint", "Deposit"]

var terrain = null
var scene_root: Node = null
var _observed_catalog: Resource = null
var tool := SELECT_TOOL
var radii := [10.0, 10.0, 14.0, 12.0, 4.0, 2.0, 8.0, 1.5]
var strength := 1.0
var falloff := 0.65
var paint_id := 0
var show_archived_materials := false
var paint_variant_id: StringName = &""
var paint_scope := 0 # 0: paint physical material + appearance, 1: appearance only
var deposit_height_m := 0.25
var deposit_reclassify := false

var _tool_buttons: Array = []
var _radius_slider: HSlider = null
var _radius_spin: SpinBox = null
var _radius_label: Label = null
var _strength_slider: HSlider = null
var _falloff_slider: HSlider = null
var _info: Label = null
var _seed_box: SpinBox = null
var _stability_check: CheckButton = null
var _water_check: CheckButton = null
var _dig_mat_option: OptionButton = null
var _paint_grid: GridContainer = null
var _material_usage_label: Label = null
var _show_archived_check: CheckButton = null
var _archive_material_button: Button = null
var _replace_source_option: OptionButton = null
var _replace_base_button: Button = null
var _variant_option: OptionButton = null
var _paint_scope_option: OptionButton = null
var _deposit_height_spin: SpinBox = null
var _deposit_reclassify_check: CheckButton = null
var _mask_grid: GridContainer = null
var _new_material_name: LineEdit = null
var _edit_material_button: Button = null
var _undo_btn: Button = null
var _redo_btn: Button = null
var _file_dialog: EditorFileDialog = null
var _file_mode_save := true
var _material_file_dialog: EditorFileDialog = null
var _material_file_mode_save := true
var _mask_checks: Array = []
var _stats: Label = null

func _init() -> void:
        var root := VBoxContainer.new()
        root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        add_child(root)

        _add_heading(root, "Stoem Terrain")

        # Tools grid
        var grid := GridContainer.new()
        grid.columns = 3
        root.add_child(grid)
        var group := ButtonGroup.new()
        for i in TOOL_NAMES.size():
                var tool_id: int = TOOL_IDS[i]
                var b := Button.new()
                b.text = TOOL_NAMES[i]
                b.toggle_mode = true
                b.button_group = group
                b.custom_minimum_size = Vector2(72, 26)
                b.pressed.connect(func() -> void: _on_tool_pressed(tool_id))
                grid.add_child(b)
                _tool_buttons.append(b)
        _tool_buttons[0].button_pressed = true

        # Radius (per-tool memory)
        var rl := _label_row(root, "Radius")
        _radius_label = rl
        var radius_row := HBoxContainer.new()
        root.add_child(radius_row)
        _radius_slider = _add_slider(radius_row, 0.5, 40.0, radii[0])
        _radius_spin = SpinBox.new()
        _radius_spin.min_value = 0.5
        _radius_spin.max_value = 40.0
        _radius_spin.step = 0.25
        _radius_spin.value = radii[0]
        _radius_spin.suffix = " m"
        _radius_spin.custom_minimum_size.x = 82.0
        _radius_spin.tooltip_text = "Brush radius in metres"
        _radius_spin.value_changed.connect(func(v: float) -> void: _radius_slider.value = v)
        radius_row.add_child(_radius_spin)
        _radius_slider.value_changed.connect(func(v: float) -> void:
                if tool < 0:
                        return
                radii[tool] = v
                _radius_spin.set_value_no_signal(v)
                _radius_label.text = "Radius (%s)" % TOOL_NAMES[tool + 1])

        # Strength / falloff
        _add_slider(root, 0.1, 3.0, strength, "Strength")
        _strength_slider = _last_slider
        _strength_slider.value_changed.connect(func(v: float) -> void: strength = v)
        _add_slider(root, 0.0, 1.0, falloff, "Falloff")
        _falloff_slider = _last_slider
        _falloff_slider.value_changed.connect(func(v: float) -> void: falloff = v)
        _on_tool_pressed(SELECT_TOOL)

        # Material picker for the Paint tool (discrete materials: no blending,
        # so the falloff slider does not apply to it).
        var paint_head := Label.new()
        paint_head.text = "Paint material"
        root.add_child(paint_head)
        _paint_grid = GridContainer.new()
        _paint_grid.columns = 3
        root.add_child(_paint_grid)
        _material_usage_label = Label.new()
        _material_usage_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        _material_usage_label.text = "Usage in selected terrain appears here."
        root.add_child(_material_usage_label)
        var archive_row := HBoxContainer.new()
        root.add_child(archive_row)
        _show_archived_check = CheckButton.new()
        _show_archived_check.text = "Show archived"
        _show_archived_check.toggled.connect(func(enabled: bool) -> void:
                show_archived_materials = enabled
                _rebuild_material_controls())
        archive_row.add_child(_show_archived_check)
        _archive_material_button = Button.new()
        _archive_material_button.text = "Archive selected"
        _archive_material_button.pressed.connect(_toggle_material_archive)
        archive_row.add_child(_archive_material_button)
        var replace_row := HBoxContainer.new()
        root.add_child(replace_row)
        var replace_label := Label.new()
        replace_label.text = "Replace base uses of"
        replace_row.add_child(replace_label)
        _replace_source_option = OptionButton.new()
        _replace_source_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        replace_row.add_child(_replace_source_option)
        _replace_base_button = Button.new()
        _replace_base_button.text = "Replace"
        _replace_base_button.tooltip_text = "Replace this source material across 1 m samples on the selected terrain. Cover strata stay unchanged."
        _replace_base_button.pressed.connect(_replace_base_material)
        replace_row.add_child(_replace_base_button)

        var variant_row := HBoxContainer.new()
        root.add_child(variant_row)
        var variant_label := Label.new()
        variant_label.text = "Texture set"
        variant_row.add_child(variant_label)
        _variant_option = OptionButton.new()
        _variant_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        _variant_option.item_selected.connect(_on_variant_selected)
        variant_row.add_child(_variant_option)

        var scope_row := HBoxContainer.new()
        root.add_child(scope_row)
        var scope_label := Label.new()
        scope_label.text = "Paint mode"
        scope_row.add_child(scope_label)
        _paint_scope_option = OptionButton.new()
        _paint_scope_option.add_item("Material + texture")
        _paint_scope_option.add_item("Texture only")
        _paint_scope_option.tooltip_text = "Texture only updates appearance on cells already using the selected material."
        _paint_scope_option.item_selected.connect(func(index: int) -> void: paint_scope = index)
        _paint_scope_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        scope_row.add_child(_paint_scope_option)

        var deposit_row := HBoxContainer.new()
        root.add_child(deposit_row)
        var deposit_label := Label.new()
        deposit_label.text = "Deposit peak"
        deposit_row.add_child(deposit_label)
        _deposit_height_spin = SpinBox.new()
        _deposit_height_spin.min_value = 0.05
        _deposit_height_spin.max_value = 10.0
        _deposit_height_spin.step = 0.05
        _deposit_height_spin.value = deposit_height_m
        _deposit_height_spin.suffix = " m"
        _deposit_height_spin.value_changed.connect(func(value: float) -> void: deposit_height_m = value)
        deposit_row.add_child(_deposit_height_spin)
        _deposit_reclassify_check = CheckButton.new()
        _deposit_reclassify_check.text = "Reclassify existing cover"
        _deposit_reclassify_check.tooltip_text = "Explicitly replace the existing cover stack with the deposited material."
        _deposit_reclassify_check.toggled.connect(func(enabled: bool) -> void:
                deposit_reclassify = enabled)
        root.add_child(_deposit_reclassify_check)

        var material_actions := HBoxContainer.new()
        root.add_child(material_actions)
        _new_material_name = LineEdit.new()
        _new_material_name.placeholder_text = "New material name"
        _new_material_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        material_actions.add_child(_new_material_name)
        var create_material_button := Button.new()
        create_material_button.text = "Create"
        create_material_button.pressed.connect(_create_material)
        material_actions.add_child(create_material_button)
        var duplicate_material_button := Button.new()
        duplicate_material_button.text = "Duplicate"
        duplicate_material_button.pressed.connect(_duplicate_material)
        material_actions.add_child(duplicate_material_button)
        var add_variant_button := Button.new()
        add_variant_button.text = "Add Texture Set"
        add_variant_button.pressed.connect(_add_texture_variant)
        material_actions.add_child(add_variant_button)
        _edit_material_button = Button.new()
        _edit_material_button.text = "Edit Properties"
        _edit_material_button.pressed.connect(_edit_material)
        material_actions.add_child(_edit_material_button)
        var preset_actions := HBoxContainer.new()
        root.add_child(preset_actions)
        var export_material_button := Button.new()
        export_material_button.text = "Export Material"
        export_material_button.pressed.connect(func() -> void: _open_material_file_dialog(true))
        preset_actions.add_child(export_material_button)
        var import_material_button := Button.new()
        import_material_button.text = "Import Material"
        import_material_button.pressed.connect(func() -> void: _open_material_file_dialog(false))
        preset_actions.add_child(import_material_button)

        # Options
        _stability_check = CheckButton.new()
        _stability_check.text = "Stabilize sculpt strokes"
        _stability_check.toggled.connect(func(on: bool) -> void:
                if terrain != null:
                        terrain.auto_stabilize = on)
        root.add_child(_stability_check)

        _water_check = CheckButton.new()
        _water_check.text = "Show water table"
        _water_check.toggled.connect(func(on: bool) -> void:
                if terrain != null:
                        terrain.debug_water_table = on)
        root.add_child(_water_check)

        var mat_row := HBoxContainer.new()
        root.add_child(mat_row)
        var ml := Label.new()
        ml.text = "Dig material"
        mat_row.add_child(ml)
        _dig_mat_option = OptionButton.new()
        _dig_mat_option.add_item("Auto (surface)")
        _dig_mat_option.item_selected.connect(_on_dig_material_selected)
        mat_row.add_child(_dig_mat_option)

        # Per-material dig permission (e.g. protect granite from the dig tool).
        var mask_head := Label.new()
        mask_head.text = "Dig allowed (per material)"
        root.add_child(mask_head)
        _mask_grid = GridContainer.new()
        _mask_grid.columns = 3
        root.add_child(_mask_grid)

        _add_heading(root, "Bake")
        var bake_row := HBoxContainer.new()
        root.add_child(bake_row)
        _seed_box = SpinBox.new()
        _seed_box.min_value = 1
        _seed_box.max_value = 999999999
        _seed_box.step = 1
        _seed_box.value = 20261113
        bake_row.add_child(_seed_box)
        var bake_btn := Button.new()
        bake_btn.text = "Bake"
        bake_btn.pressed.connect(func() -> void:
                if terrain != null:
                        terrain.seed_value = int(_seed_box.value)
                        terrain.bake())
        bake_row.add_child(bake_btn)

        _add_heading(root, "History")
        var hist := HBoxContainer.new()
        root.add_child(hist)
        _undo_btn = Button.new()
        _undo_btn.text = "Undo"
        _undo_btn.pressed.connect(func() -> void:
                if terrain != null:
                        terrain.undo())
        hist.add_child(_undo_btn)
        _redo_btn = Button.new()
        _redo_btn.text = "Redo"
        _redo_btn.pressed.connect(func() -> void:
                if terrain != null:
                        terrain.redo())
        hist.add_child(_redo_btn)

        _add_heading(root, "Edits (.res)")
        var io := HBoxContainer.new()
        root.add_child(io)
        var save_btn := Button.new()
        save_btn.text = "Save"
        save_btn.pressed.connect(func() -> void: _open_file_dialog(true))
        io.add_child(save_btn)
        var load_btn := Button.new()
        load_btn.text = "Load"
        load_btn.pressed.connect(func() -> void: _open_file_dialog(false))
        io.add_child(load_btn)

        _info = Label.new()
        _info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        _info.custom_minimum_size = Vector2(0, 84)
        root.add_child(_info)

        _stats = Label.new()
        _stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
        root.add_child(_stats)

        _file_dialog = EditorFileDialog.new()
        _file_dialog.access = EditorFileDialog.ACCESS_RESOURCES
        _file_dialog.add_filter("*.res ; Terrain edits")
        add_child(_file_dialog)
        _material_file_dialog = EditorFileDialog.new()
        _material_file_dialog.access = EditorFileDialog.ACCESS_RESOURCES
        _material_file_dialog.add_filter("*.tres,*.res ; Material presets")
        add_child(_material_file_dialog)
        _rebuild_material_controls()

func _add_heading(p_parent: Control, p_text: String) -> void:
        var l := Label.new()
        l.text = p_text
        l.add_theme_font_size_override("font_size", 13)
        p_parent.add_child(l)
        var sep := HSeparator.new()
        p_parent.add_child(sep)

func _label_row(p_parent: Control, p_text: String) -> Label:
        var l := Label.new()
        l.text = p_text
        p_parent.add_child(l)
        return l

var _last_slider: HSlider = null

func _add_slider(p_parent: Control, p_min: float, p_max: float,
                p_value: float, p_text := "") -> HSlider:
        if p_text != "":
                _label_row(p_parent, p_text)
        var s := HSlider.new()
        s.min_value = p_min
        s.max_value = p_max
        s.step = 0.05
        s.value = p_value
        s.custom_minimum_size = Vector2(0, 20)
        p_parent.add_child(s)
        _last_slider = s
        return s

func _on_tool_pressed(p_id: int) -> void:
        tool = p_id
        if tool < 0:
                _radius_label.text = "Select terrain"
                _radius_slider.editable = false
                _strength_slider.editable = false
                _falloff_slider.editable = false
                return
        _radius_slider.editable = true
        _strength_slider.editable = true
        _falloff_slider.editable = true
        _radius_slider.value = radii[p_id]
        _radius_label.text = "Radius (%s)" % TOOL_NAMES[p_id + 1]

func _current_catalog():
        if terrain != null and is_instance_valid(terrain):
                return terrain.material_catalog
        return null

func _rebuild_material_controls() -> void:
        for child in _paint_grid.get_children():
                child.queue_free()
        for child in _mask_grid.get_children():
                child.queue_free()
        _mask_checks.clear()
        _dig_mat_option.clear()
        _dig_mat_option.add_item("Auto (surface)")
        var catalog = _current_catalog()
        var count: int = catalog.count() if catalog is Catalog else Mat.COUNT
        var order: PackedInt32Array = catalog.display_order if catalog is Catalog else PackedInt32Array()
        var visible_ids: Array[int] = []
        for display_index in count:
                var id: int = order[display_index] if order.size() == count else display_index
                if catalog is Catalog and catalog.is_archived(id) and not show_archived_materials:
                        continue
                visible_ids.append(id)
        if not visible_ids.has(paint_id):
                paint_id = visible_ids[0] if not visible_ids.is_empty() else -1
        var paint_group := ButtonGroup.new()
        for display_index in visible_ids.size():
                var id: int = visible_ids[display_index]
                var material = catalog.get_material(id) if catalog is Catalog else Mat.get_material(id)
                var label: String = material.display_name if material != null else "Missing Material"
                if catalog is Catalog and catalog.is_archived(id):
                        label = "[Archived] %s" % label
                var material_id := id
                var paint_button := Button.new()
                paint_button.text = label
                paint_button.toggle_mode = true
                paint_button.button_group = paint_group
                paint_button.tooltip_text = "Paint this terrain material"
                paint_button.pressed.connect(func() -> void: _select_paint_material(material_id))
                _paint_grid.add_child(paint_button)
                if material_id == paint_id:
                        paint_button.button_pressed = true

                var option_index := _dig_mat_option.item_count
                _dig_mat_option.add_item(label)
                _dig_mat_option.set_item_metadata(option_index, material_id)
                var check := CheckButton.new()
                check.text = label
                check.button_pressed = terrain == null or terrain.dig_mask.size() != count \
                        or terrain.dig_mask[material_id] == 1
                check.toggled.connect(func(allowed: bool) -> void:
                        if terrain != null and is_instance_valid(terrain) \
                                        and terrain.dig_mask.size() == terrain.material_catalog.count():
                                terrain.dig_mask[material_id] = 1 if allowed else 0)
                _mask_grid.add_child(check)
                _mask_checks.append(check)
        _edit_material_button.disabled = not (catalog is Catalog and catalog.is_valid_id(paint_id))
        _archive_material_button.disabled = not (catalog is Catalog and catalog.is_valid_id(paint_id))
        if catalog is Catalog and catalog.is_valid_id(paint_id) and catalog.is_archived(paint_id):
                _archive_material_button.text = "Restore selected"
                _archive_material_button.tooltip_text = "Restore this stable material slot to the default paint shelf."
        else:
                _archive_material_button.text = "Archive selected"
                _archive_material_button.tooltip_text = "Hide from the default paint shelf; terrain and saved references stay intact."
        _rebuild_replacement_picker()
        _rebuild_variant_picker()
        _update_material_usage()

func _rebuild_replacement_picker() -> void:
        _replace_source_option.clear()
        var catalog = _current_catalog()
        if not catalog is Catalog:
                _replace_base_button.disabled = true
                return
        var selected_source := -1
        for id in catalog.display_order:
                if id == paint_id or not catalog.is_valid_id(id):
                        continue
                var material = catalog.get_material(id)
                var label: String = material.display_name
                if catalog.is_archived(id):
                        label = "[Archived] %s" % label
                var item_index := _replace_source_option.item_count
                _replace_source_option.add_item(label)
                _replace_source_option.set_item_metadata(item_index, id)
                if selected_source < 0:
                        selected_source = item_index
        if selected_source >= 0:
                _replace_source_option.select(selected_source)
        _replace_base_button.disabled = selected_source < 0 or terrain == null \
                        or not is_instance_valid(terrain) or not catalog.is_valid_id(paint_id)

func _replace_base_material() -> void:
        var catalog = _current_catalog()
        if not catalog is Catalog or _replace_source_option.selected < 0 \
                        or not is_instance_valid(terrain):
                return
        var source_id: int = int(_replace_source_option.get_item_metadata(
                _replace_source_option.selected))
        var replaced: int = terrain.replace_base_material_usage(source_id, paint_id)
        if replaced <= 0:
                show_feedback("No base material samples were replaced. Cover layers remain unchanged.")
                return
        show_feedback("Replaced %d 1 m material samples on this terrain. Undo restores the previous assignments; cover layers were preserved." % replaced)

func _toggle_material_archive() -> void:
        var catalog = _current_catalog()
        if not (catalog is Catalog) or not catalog.is_valid_id(paint_id):
                return
        var archived_id := paint_id
        if catalog.is_archived(archived_id):
                var before_state: Dictionary = catalog.editor_state_snapshot()
                catalog.restore_material(archived_id)
                catalog_mutation_recorded.emit(catalog, "Restore terrain material", before_state,
                        catalog.editor_state_snapshot())
                set_terrain(terrain)
                paint_id = archived_id
                _rebuild_material_controls()
                show_feedback("Material restored to the paint shelf.")
        else:
                var before_state: Dictionary = catalog.editor_state_snapshot()
                catalog.archive_material(archived_id)
                catalog_mutation_recorded.emit(catalog, "Archive terrain material", before_state,
                        catalog.editor_state_snapshot())
                if not show_archived_materials:
                        paint_id = -1
                set_terrain(terrain)
                show_feedback("Material archived from the shelf. Existing terrain and saved references are preserved.")

func _select_paint_material(p_material_id: int) -> void:
        paint_id = p_material_id
        paint_variant_id = &""
        _rebuild_variant_picker()
        _update_material_usage()

func set_scene_root(p_scene_root: Node) -> void:
        scene_root = p_scene_root
        _update_material_usage()

func _update_material_usage() -> void:
        if terrain == null or not is_instance_valid(terrain):
                _material_usage_label.text = "Usage in selected terrain appears here."
                return
        var selected_catalog = _current_catalog()
        if not selected_catalog is Catalog or not selected_catalog.is_valid_id(paint_id):
                _material_usage_label.text = "No usage data for this material."
                return
        var selected_material = selected_catalog.get_material(paint_id)
        var totals := {
                "terrain_count": 0,
                "material_cells": 0,
                "cover_layers": 0,
                "deep_terrain_count": 0,
                "forced_terrain_count": 0,
        }
        var seen_terrains := {}
        if scene_root != null and is_instance_valid(scene_root):
                _collect_scene_material_usage(scene_root, selected_material.stable_id, totals,
                        seen_terrains)
        if not seen_terrains.has(terrain.get_instance_id()):
                _accumulate_terrain_material_usage(terrain, selected_material.stable_id,
                        totals, seen_terrains)
        var assignments: PackedStringArray = []
        var material_cells: int = int(totals.material_cells)
        var cover_layers: int = int(totals.cover_layers)
        if material_cells > 0:
                assignments.append("%s 1 m material samples" % material_cells)
        if cover_layers > 0:
                assignments.append("%s cover layers" % cover_layers)
        if totals.deep_terrain_count > 0:
                assignments.append("deep substrate in %s terrain(s)" % totals.deep_terrain_count)
        if totals.forced_terrain_count > 0:
                assignments.append("forced dig in %s terrain(s)" % totals.forced_terrain_count)
        var summary := "No references found"
        if not assignments.is_empty():
                summary = ", ".join(assignments)
        _material_usage_label.text = "Open scene usage (%s terrain(s)): %s\nCounts include baked, painted and spoil material samples; other scenes are not scanned." % [totals.terrain_count, summary]

func _collect_scene_material_usage(p_node: Node, p_stable_id: StringName,
                p_totals: Dictionary, p_seen: Dictionary) -> void:
        _accumulate_terrain_material_usage(p_node, p_stable_id, p_totals, p_seen)
        for child in p_node.get_children():
                _collect_scene_material_usage(child, p_stable_id, p_totals, p_seen)

func _accumulate_terrain_material_usage(p_node: Node, p_stable_id: StringName,
                p_totals: Dictionary, p_seen: Dictionary) -> void:
        if p_node == null or not is_instance_valid(p_node) \
                        or not p_node.has_method("stoem_is_terrain") \
                        or not p_node.has_method("material_usage_for"):
                return
        var instance_id: int = p_node.get_instance_id()
        if p_seen.has(instance_id):
                return
        var catalog = p_node.get("material_catalog")
        if catalog == null or not catalog.has_method("id_for_stable_id"):
                return
        var material_id: int = catalog.id_for_stable_id(p_stable_id)
        if material_id < 0:
                return
        p_seen[instance_id] = true
        p_totals.terrain_count += 1
        var usage: Dictionary = p_node.material_usage_for(material_id)
        p_totals.material_cells += int(usage.get("material_cells", 0))
        p_totals.cover_layers += int(usage.get("cover_layers", 0))
        if bool(usage.get("deep_substrate", false)):
                p_totals.deep_terrain_count += 1
        if bool(usage.get("forced_dig", false)):
                p_totals.forced_terrain_count += 1

func _rebuild_variant_picker() -> void:
        _variant_option.clear()
        _variant_option.add_item("Weighted random")
        _variant_option.set_item_metadata(0, "")
        var catalog = _current_catalog()
        if not (catalog is Catalog) or not catalog.is_valid_id(paint_id):
                _variant_option.select(0)
                return
        var material = catalog.get_material(paint_id)
        var selected_index := 0
        for appearance in material.variants:
                var index := _variant_option.item_count
                _variant_option.add_item(appearance.display_name)
                _variant_option.set_item_metadata(index, String(appearance.stable_id))
                if appearance.stable_id == paint_variant_id:
                        selected_index = index
        if selected_index == 0:
                paint_variant_id = &""
        _variant_option.select(selected_index)

func _on_variant_selected(p_index: int) -> void:
        paint_variant_id = StringName(_variant_option.get_item_metadata(p_index))

func _add_texture_variant() -> void:
        var catalog = _current_catalog()
        if not (catalog is Catalog) or not catalog.is_valid_id(paint_id):
                return
        var material = catalog.get_material(paint_id)
        var previous_variants: Array[Resource] = _copy_resource_array(material.variants)
        var appearance = catalog.create_variant(paint_id)
        if appearance == null:
                return
        var next_variants: Array[Resource] = _copy_resource_array(material.variants)
        material_property_mutation_recorded.emit(catalog, material, "Add terrain texture set",
                "variants", previous_variants, next_variants)
        paint_variant_id = appearance.stable_id
        _rebuild_variant_picker()
        edit_material_requested.emit(appearance)

func _copy_resource_array(p_resources: Array) -> Array[Resource]:
        var copy: Array[Resource] = []
        for resource in p_resources:
                copy.append(resource)
        return copy

func _create_material() -> void:
        var catalog = _current_catalog()
        if not catalog is Catalog:
                return
        var name := _new_material_name.text.strip_edges()
        if name.is_empty():
                name = "New Material"
        var before_state: Dictionary = catalog.editor_state_snapshot()
        paint_id = catalog.create_material(name)
        catalog_mutation_recorded.emit(catalog, "Create terrain material", before_state,
                catalog.editor_state_snapshot())
        paint_variant_id = &""
        _new_material_name.clear()
        set_terrain(terrain)

func _duplicate_material() -> void:
        var catalog = _current_catalog()
        if not catalog is Catalog or not catalog.is_valid_id(paint_id):
                return
        var before_state: Dictionary = catalog.editor_state_snapshot()
        var id: int = catalog.duplicate_material(paint_id)
        if id >= 0:
                catalog_mutation_recorded.emit(catalog, "Duplicate terrain material", before_state,
                        catalog.editor_state_snapshot())
                paint_id = id
                paint_variant_id = &""
                set_terrain(terrain)

func _edit_material() -> void:
        var catalog = _current_catalog()
        if catalog is Catalog and catalog.is_valid_id(paint_id):
                edit_material_requested.emit(catalog.get_material(paint_id))

func _on_dig_material_selected(p_item_index: int) -> void:
        if terrain == null or not is_instance_valid(terrain):
                return
        terrain.forced_dig_material = -1 if p_item_index == 0 \
                else int(_dig_mat_option.get_item_metadata(p_item_index))

func radius_for_tool() -> float:
        return radii[tool] if tool >= 0 and tool < radii.size() else 0.0

func set_terrain(p_t) -> void:
        if terrain != null and is_instance_valid(terrain) \
                        and terrain.has_signal("edited") \
                        and terrain.edited.is_connected(_update_material_usage):
                terrain.edited.disconnect(_update_material_usage)
        if _observed_catalog != null and is_instance_valid(_observed_catalog) \
                        and _observed_catalog.changed.is_connected(_on_catalog_changed_ui):
                _observed_catalog.changed.disconnect(_on_catalog_changed_ui)
        _observed_catalog = null
        terrain = p_t
        if p_t == null:
                _info.text = "No StoemTerrain3D selected.\nSelect one, or just open a scene\nthat contains one and click in the 3D view."
                _edit_material_button.disabled = true
                _archive_material_button.disabled = true
                _replace_base_button.disabled = true
                _update_material_usage()
                return
        if terrain.has_signal("edited") \
                        and not terrain.edited.is_connected(_update_material_usage):
                terrain.edited.connect(_update_material_usage)
        if terrain.material_catalog != null and terrain.material_catalog.has_signal("changed"):
                _observed_catalog = terrain.material_catalog
                if not _observed_catalog.changed.is_connected(_on_catalog_changed_ui):
                        _observed_catalog.changed.connect(_on_catalog_changed_ui)
        _info.text = "Sculpting: %s" % p_t.name
        _seed_box.value = p_t.seed_value
        _stability_check.button_pressed = p_t.auto_stabilize
        _water_check.button_pressed = p_t.debug_water_table
        _rebuild_material_controls()
        var forced_index := 0
        for i in range(1, _dig_mat_option.item_count):
                if int(_dig_mat_option.get_item_metadata(i)) == p_t.forced_dig_material:
                        forced_index = i
                        break
        _dig_mat_option.select(forced_index)

func _on_catalog_changed_ui() -> void:
        if terrain != null and is_instance_valid(terrain):
                _rebuild_material_controls()

func _open_file_dialog(p_save: bool) -> void:
        if terrain == null:
                return
        _file_mode_save = p_save
        if p_save:
                _file_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
        else:
                _file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
        _file_dialog.current_file = "terrain_edits.res"
        _file_dialog.popup_centered_ratio(0.5)

func _ready() -> void:
        _file_dialog.file_selected.connect(_on_file_selected)
        _material_file_dialog.file_selected.connect(_on_material_file_selected)

func _open_material_file_dialog(p_save: bool) -> void:
        var catalog = _current_catalog()
        if not catalog is Catalog:
                show_feedback("Select a terrain with a material catalog first.")
                return
        if p_save and not catalog.is_valid_id(paint_id):
                show_feedback("Select a valid material to export.")
                return
        _material_file_mode_save = p_save
        if p_save:
                _material_file_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
                var material = catalog.get_material(paint_id)
                _material_file_dialog.current_file = "%s.tres" % material.display_name.to_snake_case()
        else:
                _material_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
                _material_file_dialog.current_file = ""
        _material_file_dialog.popup_centered_ratio(0.5)

func _on_material_file_selected(p_path: String) -> void:
        var catalog = _current_catalog()
        if not catalog is Catalog or not is_instance_valid(terrain):
                return
        if _material_file_mode_save:
                if not catalog.validate() or not catalog.is_valid_id(paint_id):
                        show_feedback("Material catalog is invalid; preset was not exported.")
                        return
                var save_error := ResourceSaver.save(catalog.get_material(paint_id), p_path)
                show_feedback("Exported material preset.\n%s" % p_path if save_error == OK \
                        else "Material preset export failed (%s)." % error_string(save_error))
                return
        var imported: Resource = ResourceLoader.load(p_path, "", ResourceLoader.CACHE_MODE_IGNORE)
        var before_state: Dictionary = catalog.editor_state_snapshot()
        var imported_id: int = catalog.import_material(imported)
        if imported_id < 0:
                show_feedback("Preset is invalid or incompatible; the catalog was unchanged.")
                return
        catalog_mutation_recorded.emit(catalog, "Import terrain material preset", before_state,
                catalog.editor_state_snapshot())
        paint_id = imported_id
        paint_variant_id = &""
        _rebuild_material_controls()
        show_feedback("Imported as an independent material copy.\n%s" % p_path)

func _on_file_selected(p_path: String) -> void:
        if not is_instance_valid(terrain):
                return
        var previous_edits: Resource = terrain.edits_resource
        var result: int
        if _file_mode_save:
                result = terrain.save_edits(p_path)
        else:
                result = terrain.load_edits(p_path)
        if result != OK:
                _info.text = "Terrain file operation failed (%s).\n%s" % [error_string(result), p_path]
        else:
                _info.text = "Saved and linked edit resource. Save the scene to keep this link.\n%s" % p_path \
                        if _file_mode_save else "Loaded and linked edits. Save the scene to keep this link.\n%s" % p_path
                if previous_edits != terrain.edits_resource:
                        edits_resource_linked.emit(terrain, previous_edits, terrain.edits_resource)

func show_feedback(p_message: String) -> void:
        _info.text = p_message
        _feedback_until_ms = Time.get_ticks_msec() + 4000

var _feedback_until_ms := 0

func _process(_delta: float) -> void:
        if terrain == null or not is_instance_valid(terrain):
                _undo_btn.disabled = true
                _redo_btn.disabled = true
                _stats.text = ""
                return
        _undo_btn.disabled = not terrain.can_undo()
        _redo_btn.disabled = not terrain.can_redo()
        if terrain.has_method("get_stats"):
                var st: Dictionary = terrain.get_stats()
                _stats.text = "ledger: dug %.1f m3 | spoil %.1f m3 loose\ncollapses %d | seepage %d cells" % [
                                st.dug_m3, st.spoil_loose_m3, st.collapses, st.seepage_cells]
        if Time.get_ticks_msec() < _feedback_until_ms:
                return
        var pick: Dictionary = terrain.last_pick
        if pick.is_empty():
                _info.text = "Hover the terrain in the 3D view.\nLMB: apply tool | Ctrl+Z / Ctrl+Shift+Z: undo / redo"
                return
        var pos: Vector3 = pick.position
        _info.text = "%s\nheight %.2f m | slope %.1f deg\nmaterial %s | pore %.2f%s" % [
                Vector2(pos.x, pos.z),
                float(pick.height),
                float(pick.slope_deg),
                String(pick.material),
                float(pick.pore),
                " | carved air" if bool(pick.carved) else "",
        ]
