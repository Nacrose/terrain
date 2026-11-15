@tool
extends EditorPlugin
## Terrain editor integration: dock panel, viewport brush input, undo/redo
## shortcuts. Tools act on the SELECTED StoemTerrain3D node, or (fallback) on
## the first one found in the currently edited scene, so clicks keep working
## after an editor restart without re-selecting the node.

const PanelScript = preload("res://addons/stoem_terrain/ui/sculpt_panel.gd")

var _panel = null
var _terrain = null
var _painting := false
var _stroke_tool := -1
var _stroke_radius := 0.0
var _stroke_strength := 0.0
var _stroke_falloff := 0.0
var _stroke_paint_id := 0
var _stroke_paint_variant_id: StringName = &""
var _stroke_paint_scope := 0
var _stroke_deposit_height := 0.25
var _stroke_deposit_reclassify := false
var _last_carve_pos := Vector3(1e9, 0.0, 0.0)
var _last_dig_pos := Vector3(1e9, 0.0, 0.0)
var _last_dig_ms := -1000000      # never eat the first click after engine start
var _discover_next_ms := 0

func _enter_tree() -> void:
        set_input_event_forwarding_always_enabled()
        _panel = PanelScript.new()
        _panel.edit_material_requested.connect(_edit_material_resource)
        _panel.edits_resource_linked.connect(_record_edits_resource_link)
        _panel.catalog_mutation_recorded.connect(_record_catalog_mutation)
        _panel.material_property_mutation_recorded.connect(_record_material_property_mutation)
        add_control_to_dock(DOCK_SLOT_LEFT_BR, _panel)
        var sel := EditorInterface.get_selection()
        if not sel.selection_changed.is_connected(_on_selection_changed):
                sel.selection_changed.connect(_on_selection_changed)
        _on_selection_changed()
        scene_changed.connect(_on_scene_changed)

func _edit_material_resource(p_material: Resource) -> void:
        if p_material != null:
                EditorInterface.edit_resource(p_material)

func _record_edits_resource_link(p_terrain: Node, p_old: Resource, p_new: Resource) -> void:
        if not is_instance_valid(p_terrain):
                return
        var history := EditorInterface.get_editor_undo_redo()
        history.create_action("Link Terrain edit resource")
        history.add_do_property(p_terrain, "edits_resource", p_new)
        history.add_undo_property(p_terrain, "edits_resource", p_old)
        history.commit_action()

func _record_catalog_mutation(p_catalog: Resource, p_label: String,
                p_before: Dictionary, p_after: Dictionary) -> void:
        if not is_instance_valid(p_catalog):
                return
        var history := EditorInterface.get_editor_undo_redo()
        history.create_action(p_label)
        history.add_do_method(p_catalog, "restore_editor_state", p_after)
        history.add_undo_method(p_catalog, "restore_editor_state", p_before)
        # The catalog action has already been applied by the dock. Record it without
        # replaying the do method and rebuilding every terrain chunk a second time.
        history.commit_action(false)

func _record_material_property_mutation(p_catalog: Resource, p_material: Resource,
                p_label: String, p_property: String, p_before: Variant, p_after: Variant) -> void:
        if not is_instance_valid(p_catalog) or not is_instance_valid(p_material):
                return
        var history := EditorInterface.get_editor_undo_redo()
        history.create_action(p_label)
        history.add_do_property(p_material, p_property, p_after)
        history.add_do_method(p_catalog, "notify_editor_mutation")
        history.add_undo_property(p_material, p_property, p_before)
        history.add_undo_method(p_catalog, "notify_editor_mutation")
        history.commit_action(false)

func _handles(p_object: Object) -> bool:
        return p_object is Node3D and p_object.has_method("stoem_is_terrain")

func _on_scene_changed(_scene: Node) -> void:
        _set_terrain(null)
        _discover_next_ms = 0

func _exit_tree() -> void:
        _set_terrain(null)
        var sel := EditorInterface.get_selection()
        if sel.selection_changed.is_connected(_on_selection_changed):
                sel.selection_changed.disconnect(_on_selection_changed)
        if scene_changed.is_connected(_on_scene_changed):
                scene_changed.disconnect(_on_scene_changed)
        if _panel != null:
                remove_control_from_docks(_panel)
                _panel.queue_free()
                _panel = null

func _set_terrain(p_t) -> void:
        if _terrain != null and is_instance_valid(_terrain):
                if _painting:
                        _finish_stroke()
                _terrain.hide_brush_cursor()
        _painting = false
        _terrain = p_t
        if _panel != null:
                _panel.set_terrain(p_t)
                _panel.set_scene_root(EditorInterface.get_edited_scene_root())
        if _terrain != null:
                _terrain.show_brush_cursor()

func _on_selection_changed() -> void:
        var found = null
        for n in EditorInterface.get_selection().get_selected_nodes():
                if n.has_method("stoem_is_terrain"):
                        found = n
                        break
        _set_terrain(found)

## Depth-first search for a terrain under p_node. Public so the UX probes can
## exercise it; used as the no-selection fallback.
func _find_terrain_in(p_node: Node) -> Node:
        if p_node == null:
                return null
        if p_node.has_method("stoem_is_terrain"):
                return p_node
        for c in p_node.get_children():
                var found := _find_terrain_in(c)
                if found != null:
                        return found
        return null

## When nothing (or nothing valid) is selected, fall back to the terrain in
## the open scene so the tools never go silently dead. Rate-limited: scenes
## can be big and this runs from the input path.
func _autodiscover_terrain() -> void:
        if not EditorInterface.get_selection().get_selected_nodes().is_empty():
                return
        var now := Time.get_ticks_msec()
        if now < _discover_next_ms:
                return
        _discover_next_ms = now + 500
        var found: Node = _find_terrain_in(EditorInterface.get_edited_scene_root())
        if found != null:
                _set_terrain(found)

func _pick(p_camera: Camera3D, p_screen_pos: Vector2) -> Dictionary:
        if _terrain == null or not is_instance_valid(_terrain):
                return {}
        var origin := p_camera.project_ray_origin(p_screen_pos)
        var dir := p_camera.project_ray_normal(p_screen_pos)
        var inverse: Transform3D = _terrain.global_transform.affine_inverse()
        var local_dir := inverse.basis * dir
        return _terrain.raycast(inverse * origin, local_dir, 900.0 * local_dir.length())

func _input(event: InputEvent) -> void:
        if _painting and event is InputEventKey and event.pressed \
                        and event.keycode == KEY_ESCAPE:
                if _terrain != null and is_instance_valid(_terrain):
                        _terrain.cancel_stroke()
                _painting = false
                _stroke_tool = -1
                return
        # Releases outside the 3D viewport still finish the captured stroke.
        if _painting and event is InputEventMouseButton \
                        and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
                _painting = false
                _finish_stroke()

func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
        if _panel == null:
                return EditorPlugin.AFTER_GUI_INPUT_PASS
        if _terrain == null or not is_instance_valid(_terrain):
                _autodiscover_terrain()
        if _terrain == null or not is_instance_valid(_terrain):
                return EditorPlugin.AFTER_GUI_INPUT_PASS
        if not _painting and _panel.tool < 0:
                _terrain.hide_brush_cursor()
                return EditorPlugin.AFTER_GUI_INPUT_PASS
        if event is InputEventMouse and event.alt_pressed:
                return EditorPlugin.AFTER_GUI_INPUT_PASS
        if event is InputEventMouseMotion:
                var hit := _pick(viewport_camera, event.position)
                _update_cursor(hit)
                if _painting:
                        _apply_tool(hit)
                        return EditorPlugin.AFTER_GUI_INPUT_STOP
                return EditorPlugin.AFTER_GUI_INPUT_PASS
        if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
                if event.pressed:
                        var hit := _pick(viewport_camera, event.position)
                        if hit.is_empty():
                                return EditorPlugin.AFTER_GUI_INPUT_PASS
                        _painting = true
                        _stroke_tool = _panel.tool
                        _stroke_radius = _panel.radius_for_tool()
                        _stroke_strength = _panel.strength
                        _stroke_falloff = _panel.falloff
                        _stroke_paint_id = _panel.paint_id
                        _stroke_paint_variant_id = _panel.paint_variant_id
                        _stroke_paint_scope = _panel.paint_scope
                        _stroke_deposit_height = _panel.deposit_height_m
                        _stroke_deposit_reclassify = _panel.deposit_reclassify
                        _terrain.begin_stroke()
                        _last_carve_pos = Vector3(1e9, 0.0, 0.0)
                        _last_dig_pos = Vector3(1e9, 0.0, 0.0)
                        _last_dig_ms = -1000000
                        _apply_tool(hit)
                        return EditorPlugin.AFTER_GUI_INPUT_STOP
                elif _painting:
                        _painting = false
                        _finish_stroke()
                        return EditorPlugin.AFTER_GUI_INPUT_STOP
        if event is InputEventKey and event.pressed and not event.echo:
                if event.ctrl_pressed or event.meta_pressed:
                        if event.keycode == KEY_Z:
                                if event.shift_pressed:
                                        if not _terrain.can_redo():
                                                return EditorPlugin.AFTER_GUI_INPUT_PASS
                                        _terrain.redo()
                                else:
                                        if not _terrain.can_undo():
                                                return EditorPlugin.AFTER_GUI_INPUT_PASS
                                        _terrain.undo()
                                return EditorPlugin.AFTER_GUI_INPUT_STOP
                        if event.keycode == KEY_Y:
                                if not _terrain.can_redo():
                                        return EditorPlugin.AFTER_GUI_INPUT_PASS
                                _terrain.redo()
                                return EditorPlugin.AFTER_GUI_INPUT_STOP
        return EditorPlugin.AFTER_GUI_INPUT_PASS

func _update_cursor(p_hit: Dictionary) -> void:
        var active_tool: int = _stroke_tool if _painting else _panel.tool
        if active_tool < 0:
                _terrain.hide_brush_cursor()
                return
        if p_hit.is_empty():
                _terrain.hide_brush_cursor()
                _terrain.last_pick = {}
                return
        var pos: Vector3 = p_hit.position
        var r: float = _stroke_radius if _painting else _panel.radius_for_tool()
        if active_tool == _panel.CARVE_TOOL:
                _terrain.set_brush_cursor(pos, r, r)
        elif active_tool == _panel.DIG_TOOL:
                _terrain.set_brush_cursor(pos, r, r * 0.6)
        else:
                _terrain.set_brush_cursor(pos, r)
        _terrain.last_pick = {
                "position": pos,
                "height": _terrain.height_at(Vector2(pos.x, pos.z)),
                "material": _terrain.material_at(Vector2(pos.x, pos.z)),
                "slope_deg": _terrain.slope_deg_at(Vector2(pos.x, pos.z)),
                "pore": _terrain.pore_factor_at(Vector2(pos.x, pos.z)),
                "carved": _terrain.carve_set.sdf(pos) > 0.0,
        }

func _apply_tool(p_hit: Dictionary) -> void:
        if p_hit.is_empty():
                return
        var pos: Vector3 = p_hit.position
        var t: int = _stroke_tool if _painting else _panel.tool
        if t < 0:
                return
        var r: float = _stroke_radius if _painting else _panel.radius_for_tool()
        var strength: float = _stroke_strength if _painting else _panel.strength
        var falloff: float = _stroke_falloff if _painting else _panel.falloff
        if t <= 3:
                _terrain.sculpt(pos.x, pos.z, r, strength, t, falloff)
                _terrain.flush_dirty()
        elif t == _panel.CARVE_TOOL:
                var min_move: float = maxf(0.35 * r, 0.5)
                if _last_carve_pos.distance_to(pos) > min_move:
                        # Chain capsules from the previous stamp: a drag becomes
                        # one smooth bore instead of a pile of overlapping
                        # spheres (fewer primitives, cheaper queries, no
                        # z-fighting between duplicated walls).
                        var jumped := _last_carve_pos.x > 1e8 \
                                        or _last_carve_pos.distance_to(pos) > r * 8.0
                        if jumped:
                                _terrain.carve_void(pos, r)
                        else:
                                _terrain.carve_capsule(_last_carve_pos, pos, r)
                        _terrain.flush_dirty()
                        _last_carve_pos = pos
        elif t == _panel.DIG_TOOL:
                # Throttle: one scoop every 120 ms while dragging (a full drag
                # feels continuous without melting the stability solver).
                if _last_dig_pos.distance_to(pos) > maxf(0.5 * r, 0.5) \
                                and Time.get_ticks_msec() - _last_dig_ms > 120:
                        _terrain.dig(pos, r)
                        # Dig commits its writes through the open stroke buffer, so
                        # the mesh refresh has to be requested here (like sculpt) or
                        # the pit would stay invisible until the button is released.
                        _terrain.flush_dirty()
                        _last_dig_ms = Time.get_ticks_msec()
                        _last_dig_pos = pos
        elif t == _panel.PAINT_TOOL:
                # Paint brush: cheap stamps, one undo op for the whole drag.
                if _last_dig_pos.distance_to(pos) > maxf(0.35 * r, 0.5):
                        var paint_id: int = _stroke_paint_id if _painting else _panel.paint_id
                        var variant_id: StringName = _stroke_paint_variant_id if _painting \
                                else _panel.paint_variant_id
                        var paint_scope: int = _stroke_paint_scope if _painting else _panel.paint_scope
                        if paint_scope == 1:
                                _terrain.paint_appearance(pos.x, pos.z, r, paint_id, variant_id)
                        else:
                                _terrain.paint_material(pos.x, pos.z, r, paint_id, variant_id)
                        _terrain.flush_dirty()
                        _last_dig_pos = pos
        elif t == _panel.DEPOSIT_TOOL:
                if _last_dig_pos.distance_to(pos) > maxf(0.35 * r, 0.5):
                        var paint_id: int = _stroke_paint_id if _painting else _panel.paint_id
                        var variant_id: StringName = _stroke_paint_variant_id if _painting \
                                else _panel.paint_variant_id
                        var peak_m: float = _stroke_deposit_height if _painting else _panel.deposit_height_m
                        var reclassify: bool = _stroke_deposit_reclassify if _painting \
                                else _panel.deposit_reclassify
                        var added_volume: float = _terrain.deposit_material(pos.x, pos.z, r, peak_m,
                                paint_id, reclassify, variant_id)
                        if added_volume <= 0.0 and _panel.has_method("show_feedback"):
                                _panel.show_feedback("Deposit skipped: check the brush settings and cover-layer limit.")
                        _terrain.flush_dirty()
                        _last_dig_pos = pos

func _finish_stroke() -> void:
        if _terrain == null or not is_instance_valid(_terrain):
                return
        var label := "sculpt"
        if _stroke_tool == _panel.CARVE_TOOL:
                label = "carve"
        elif _stroke_tool == _panel.DIG_TOOL:
                label = "dig"
        elif _stroke_tool == _panel.PAINT_TOOL:
                label = "paint"
        elif _stroke_tool == _panel.DEPOSIT_TOOL:
                label = "deposit"
        _terrain.end_stroke(label)
        _stroke_tool = -1
