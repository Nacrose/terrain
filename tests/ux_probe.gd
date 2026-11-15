@tool
extends SceneTree
## UX probes: drive the editor plugin's 3D-viewport input path exactly like the
## real editor does (press -> motion -> release, Ctrl+Z) and assert the terrain,
## meshes and undo stack actually change. Run:
##   godot --headless --editor --path . -s tests/ux_probe.gd
## (needs --editor: the plugin extends EditorPlugin, which only the editor may
## instantiate; the probe wires the plugin/panel by hand instead of via docks.)
## Prints one PASS/FAIL per assertion; exit code 0 iff everything passes.

const Terrain = preload("res://addons/stoem_terrain/nodes/terrain_3d.gd")
const PluginScript = preload("res://addons/stoem_terrain/plugin.gd")
const PanelScript = preload("res://addons/stoem_terrain/ui/sculpt_panel.gd")
const Mat = preload("res://addons/stoem_terrain/core/terrain_material_table.gd")
const Catalog = preload("res://addons/stoem_terrain/core/terrain_material_catalog.gd")

class UsageProbeTerrain extends Node:
        var material_catalog: Resource
        var usage_values: Dictionary = {}

        func stoem_is_terrain() -> bool:
                return true

        func material_usage_for(_material_id: int) -> Dictionary:
                return usage_values.duplicate()

var failures := 0
var plugin = null
var panel = null
var t = null
var _started := false

## A real Camera3D inside a real SubViewport, so the plugin's project_ray_*
## calls hit the genuine engine implementation (GDScript cannot shadow native
## Camera3D methods).
class ProbeCam extends Node3D:
        var cam: Camera3D = null
        var vp: SubViewport = null

        func setup(p_tree_root: Window, p_ground: Vector3) -> void:
                vp = SubViewport.new()
                vp.size = Vector2(800, 600)
                p_tree_root.add_child(vp)
                cam = Camera3D.new()
                cam.fov = 70.0
                vp.add_child(cam)
                cam.position = p_ground + Vector3(6.0, 60.0, 10.0)
                cam.look_at(p_ground, Vector3.UP)

func _check(p_cond: bool, p_msg: String) -> void:
        if p_cond:
                print("  PASS  %s" % p_msg)
        else:
                failures += 1
                print("  FAIL  %s" % p_msg)

func _initialize() -> void:
        pass    # nodes are created in _process: in -s script mode the tree is
                # not live during _initialize, so cameras cannot project rays yet

func _process(_delta: float) -> bool:
        if _started:
                return false
        _started = true
        _run_probes()
        return true

func _run_probes() -> void:
        print("=== Terrain UX probes (editor input path) ===")
        t = Terrain.new()
        t.seed_value = 20261113
        root.add_child(t)
        t.bake()
        plugin = PluginScript.new()
        panel = PanelScript.new()
        plugin._panel = panel
        plugin._terrain = t
        panel.catalog_mutation_recorded.connect(plugin._record_catalog_mutation)
        panel.material_property_mutation_recorded.connect(plugin._record_material_property_mutation)
        panel.set_terrain(t)
        var usage_probe := UsageProbeTerrain.new()
        usage_probe.material_catalog = t.material_catalog
        usage_probe.usage_values = {"material_cells": 3, "cover_layers": 2}
        root.add_child(usage_probe)
        panel.set_scene_root(root)
        var local_usage: Dictionary = t.material_usage_for(panel.paint_id)
        var expected_scene_cells: int = int(local_usage.get("material_cells", 0)) + 3
        _check(panel._material_usage_label.text.contains("Open scene usage (2 terrain(s))"),
                        "material dock counts matching terrain nodes in the open scene")
        _check(panel._material_usage_label.text.contains("%s 1 m material samples" % expected_scene_cells),
				"material dock aggregates physical material sample usage across the scene")

        _ux_carve_click()
        _ux_carve_drag()
        _ux_dig_click()
        _ux_raise_drag()
        _ux_paint_drag()
        _ux_deposit_click()
        _ux_key_undo()
        _ux_dig_in_pit()
        _ux_discovery()
        _ux_material_catalog_undo()
        if failures == 0:
                print("RESULT: ALL UX PROBES PASS")
        else:
                print("RESULT: %d UX FAILURES" % failures)
        quit(1 if failures > 0 else 0)

func _ux_material_catalog_undo() -> void:
        print("[UX] material catalog undo/redo")
        var undo_manager = EditorInterface.get_editor_undo_redo()
        var catalog = t.material_catalog
        var undo_history = undo_manager.get_history_undo_redo(
                undo_manager.get_object_history_id(catalog))
        var count_before: int = catalog.count()
        panel._new_material_name.text = "Undo Probe"
        panel._create_material()
        var created_id: int = count_before
        _check(catalog.count() == count_before + 1,
                        "create action adds one material to the catalog")
        undo_history.undo()
        _check(catalog.count() == count_before,
                        "editor undo removes the created material")
        undo_history.redo()
        _check(catalog.count() == count_before + 1 and catalog.is_valid_id(created_id),
                        "editor redo restores the same material slot")
        panel.paint_id = created_id
        panel._rebuild_material_controls()
        var variants_before: int = catalog.get_material(created_id).variants.size()
        panel._add_texture_variant()
        _check(catalog.get_material(created_id).variants.size() == variants_before + 1,
                        "texture set action adds one variant")
        undo_history.undo()
        _check(catalog.get_material(created_id).variants.size() == variants_before,
                        "editor undo removes the added texture set")
        undo_history.redo()
        _check(catalog.get_material(created_id).variants.size() == variants_before + 1,
                        "editor redo restores the added texture set")
        var source_catalog := Catalog.new()
        var source_slot: int = source_catalog.create_material("UX Library Material")
        var source_material = source_catalog.get_material(source_slot)
        source_catalog.materials = [source_material]
        source_catalog.display_order = PackedInt32Array([0])
        source_catalog.archived_material_ids = PackedInt32Array()
        var library_path := "res://review_state/ux_material_library.tres"
        _check(ResourceSaver.save(source_catalog, library_path) == OK,
                        "material library fixture saves")
        var merged_id: StringName = source_material.stable_id
        var count_before_merge: int = catalog.count()
        panel._material_file_mode_catalog = true
        panel._material_file_mode_save = false
        panel._on_catalog_file_selected(catalog, library_path)
        _check(catalog.count() == count_before_merge + 1 \
                        and catalog.id_for_stable_id(merged_id) >= 0,
                        "dock library merge appends a new material")
        undo_history.undo()
        _check(catalog.count() == count_before_merge \
                        and catalog.id_for_stable_id(merged_id) < 0,
                        "editor undo removes the merged library material")
        undo_history.redo()
        _check(catalog.count() == count_before_merge + 1 \
                        and catalog.id_for_stable_id(merged_id) >= 0,
                        "editor redo restores the same merged material identity")

## Camera rig 60 m above p_ground, tilted so the centre pixel lands near p_ground.
func _cam_over(p_ground: Vector3) -> ProbeCam:
        var rig := ProbeCam.new()
        root.add_child(rig)
        rig.setup(root, p_ground)
        return rig

func _hit_through(p_cam: ProbeCam, p_screen: Vector2) -> Dictionary:
        return t.raycast(p_cam.cam.project_ray_origin(p_screen),
                        p_cam.cam.project_ray_normal(p_screen), 500.0)

func _press(p_cam: ProbeCam, p_screen: Vector2) -> void:
        var e := InputEventMouseButton.new()
        e.button_index = MOUSE_BUTTON_LEFT
        e.pressed = true
        e.position = p_screen
        plugin._forward_3d_gui_input(p_cam.cam, e)

func _motion(p_cam: ProbeCam, p_screen: Vector2) -> void:
        var e := InputEventMouseMotion.new()
        e.position = p_screen
        plugin._forward_3d_gui_input(p_cam.cam, e)

func _release(p_cam: ProbeCam) -> void:
        var e := InputEventMouseButton.new()
        e.button_index = MOUSE_BUTTON_LEFT
        e.pressed = false
        e.position = Vector2(400, 300)
        plugin._forward_3d_gui_input(p_cam.cam, e)

## Simulate a human dig cadence: the plugin throttles to one scoop per 120 ms,
## but probe sections run milliseconds apart, so arm the gate as if a second
## has passed since the last scoop.
func _arm_dig() -> void:
        plugin._last_dig_ms = Time.get_ticks_msec() - 1000

var _used_spots: Array = []

func _find_gentle() -> Vector2:
        for wz in range(-300, 301, 10):
                for wx in range(-300, 301, 10):
                        var p := Vector2(float(wx), float(wz))
                        var near := false
                        for e in _used_spots:
                                if p.distance_to(e) < 50.0:
                                        near = true
                                        break
                        if near:
                                continue
                        var ok := true
                        for off in [Vector2(0, 0), Vector2(8, 0), Vector2(-8, 0),
                                        Vector2(0, 8), Vector2(0, -8), Vector2(16, 0)]:
                                if t.slope_deg_at(p + off) > 8.0:
                                        ok = false
                                        break
                        if ok:
                                _used_spots.append(p)
                                return p
        return Vector2(0, 0)

func _ground_mesh_min_y(p_x: float, p_z: float) -> float:
        var best := 1e9
        for n in t.get_children():
                if n is MeshInstance3D and String(n.name).begins_with("Ground_"):
                        if (n as MeshInstance3D).get_aabb().has_point(Vector3(p_x, t.height_at(Vector2(p_x, p_z)), p_z)):
                                var vc: PackedVector3Array = (n as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
                                for v in vc:
                                        if absf(v.x - p_x) < 2.0 and absf(v.z - p_z) < 2.0:
                                                best = minf(best, v.y)
        return best

func _ux_carve_click() -> void:
        print("[UX] carve: single click")
        var spot := _find_gentle()
        var gh: float = t.height_at(spot)
        var cam := _cam_over(Vector3(spot.x, gh, spot.y))
        var hit := _hit_through(cam, Vector2(400, 300))
        _check(not hit.is_empty(), "carve click: ray hits the ground")
        if hit.is_empty():
                return
        panel.tool = panel.CARVE_TOOL
        panel.radii[panel.CARVE_TOOL] = 4.0
        _press(cam, Vector2(400, 300))
        _check(t.carve_set.sphere_count() == 1, "carve click: one void carved (%d)" % t.carve_set.sphere_count())
        _check(t._cave_node != null and t._cave_node.mesh != null
                        and t._cave_node.mesh.get_surface_count() > 0,
                        "carve click: cave mesh visible immediately (before release)")
        _check(t.is_solid(Vector3(spot.x, gh - 3.0, spot.y)) == false,
                        "carve click: pit opened at the click point")
        _release(cam)
        _check(t.can_undo(), "carve click: undo op pushed on release")
        _check(t.undo(), "carve click: undo works")
        _check(t.carve_set.sphere_count() == 0, "carve click: undo removed the void")

func _ux_carve_drag() -> void:
        print("[UX] carve: click + drag")
        var spot := _find_gentle() + Vector2(40.0, 0.0)
        var gh: float = t.height_at(spot)
        var cam := _cam_over(Vector3(spot.x, gh, spot.y))
        panel.tool = panel.CARVE_TOOL
        panel.radii[panel.CARVE_TOOL] = 3.0
        var prims0: int = t.carve_set.sphere_count() + t.carve_set.capsule_count()
        _press(cam, Vector2(400, 300))
        _motion(cam, Vector2(430, 300))
        _motion(cam, Vector2(470, 300))
        _motion(cam, Vector2(520, 300))
        _release(cam)
        var added: int = t.carve_set.sphere_count() + t.carve_set.capsule_count() - prims0
        _check(added >= 3, "carve drag: stroke carved %d primitives (sphere + chained capsules)" % added)
        _check(t.carve_set.capsule_count() >= 2, "carve drag: drag chains capsules into one bore")
        _check(t.can_undo() and t.undo(), "carve drag: one undo removes the whole stroke")
        _check(t.carve_set.sphere_count() + t.carve_set.capsule_count() == prims0,
                        "carve drag: undo restored the primitive count")

func _ux_dig_click() -> void:
        print("[UX] dig: click + drag")
        _arm_dig()
        var spot := _find_gentle() + Vector2(-60.0, 40.0)
        var gh: float = t.height_at(spot)
        var cam := _cam_over(Vector3(spot.x, gh, spot.y))
        panel.tool = panel.DIG_TOOL
        panel.radii[panel.DIG_TOOL] = 2.0
        var gh0: float = t.height_at(spot)
        var stats0: Dictionary = t.get_stats()
        _press(cam, Vector2(400, 300))
        _check(t.get_stats().dug_m3 > stats0.dug_m3, "dig click: mass booked (%.2f m3)" % (t.get_stats().dug_m3 - stats0.dug_m3))
        var mesh_y := _ground_mesh_min_y(spot.x, spot.y)
        _check(mesh_y < gh0 - 0.4, "dig click: pit visible in the mesh before release (%.2f < %.2f)" % [mesh_y, gh0])
        _motion(cam, Vector2(460, 300))
        _motion(cam, Vector2(520, 300))
        _release(cam)
        _check(t.can_undo(), "dig drag: undo op pushed")
        var dig_undo: bool = t.undo()
        _check(dig_undo, "dig drag: undo works")
        var restored := absf(t.height_at(spot) - gh0) < 1e-4
        _check(restored, "dig drag: undo restored the surface height")

func _ux_raise_drag() -> void:
        print("[UX] sculpt: raise tool drag")
        var spot := _find_gentle() + Vector2(70.0, -60.0)
        var gh0: float = t.height_at(spot)
        var cam := _cam_over(Vector3(spot.x, gh0, spot.y))
        panel.tool = 0
        panel.radii[0] = 8.0
        panel.strength = 1.5
        _press(cam, Vector2(400, 300))
        _motion(cam, Vector2(440, 300))
        _motion(cam, Vector2(480, 300))
        _release(cam)
        _check(t.height_at(spot) > gh0 + 0.15, "raise drag: ground rose (%.2f -> %.2f)" % [gh0, t.height_at(spot)])
        _check(t.can_undo(), "raise drag: undo op pushed")
        _last_raise_spot = spot
        _last_raise_base = gh0
        _last_raise_cam = cam

func _ux_paint_drag() -> void:
        print("[UX] paint: drag with the material brush")
        var spot := _find_gentle()
        var before: StringName = t.material_at(spot)
        var want := Mat.ID_SNOW
        if before == &"snow":
                want = Mat.ID_CLAY
        var cam := _cam_over(Vector3(spot.x, t.height_at(spot), spot.y))
        panel.tool = panel.PAINT_TOOL
        panel.radii[panel.PAINT_TOOL] = 6.0
        panel.paint_id = want
        _press(cam, Vector2(400, 300))
        _motion(cam, Vector2(410, 300))
        _motion(cam, Vector2(420, 305))
        _release(cam)
        _check(t.material_at(spot) == Mat.key_for_id(want),
                        "paint drag recoloured the ground (%s)" % String(t.material_at(spot)))
        _check(t.can_undo(), "paint drag pushed an undo op")
        _check(t.undo(), "undo the paint drag")
        _check(t.material_at(spot) == before, "undo restored the original material")

func _ux_deposit_click() -> void:
        print("[UX] deposit: click with the cover-layer tool")
        var spot := _find_gentle()
        var height_before: float = t.height_at(spot)
        var material_id: int = t.material_id_at(spot)
        var cam := _cam_over(Vector3(spot.x, height_before, spot.y))
        panel.tool = panel.DEPOSIT_TOOL
        panel.radii[panel.DEPOSIT_TOOL] = 1.5
        panel.paint_id = material_id
        panel.deposit_height_m = 0.25
        _press(cam, Vector2(400, 300))
        _release(cam)
        _check(t.cover_depth_at(spot) > 0.0 and t.height_at(spot) > height_before,
                "deposit click raised geometry and recorded cover depth")
        _check(t.material_id_at(spot) == material_id,
                "deposit material identity matches the selected shelf material")
        _check(t.undo() and is_equal_approx(t.cover_depth_at(spot), 0.0),
                "deposit click is one undoable edit")

func _ux_key_undo() -> void:
        print("[UX] keyboard undo (Ctrl+Z)")
        var h0: float = t.height_at(_last_raise_spot)
        var ke := InputEventKey.new()
        ke.pressed = true
        ke.keycode = KEY_Z
        ke.ctrl_pressed = true
        plugin._forward_3d_gui_input(_last_raise_cam.cam, ke)
        _check(absf(t.height_at(_last_raise_spot) - _last_raise_base) < 1e-4,
                        "Ctrl+Z: raise undone (%.2f -> %.2f)" % [h0, t.height_at(_last_raise_spot)])
        _check(t.can_redo(), "Ctrl+Z: redo available after undo")

var _last_raise_spot := Vector2.ZERO
var _last_raise_base := 0.0
var _last_raise_cam: ProbeCam = null

func _ux_dig_in_pit() -> void:
        print("[UX] dig inside a carved pit (tunnel-shaft UX)")
        var spot := _find_gentle() + Vector2(0.0, 90.0)
        var gh: float = t.height_at(spot)
        var cam := _cam_over(Vector3(spot.x, gh, spot.y))
        # Carve a pit first, exactly like a user would with the Carve tool.
        panel.tool = panel.CARVE_TOOL
        panel.radii[panel.CARVE_TOOL] = 3.0
        _press(cam, Vector2(400, 300))
        _release(cam)
        _check(t.carve_set.sphere_count() >= 1, "pit carved")
        # Aim at the pit floor and dig: must extend the void, not crater above.
        var hit := _hit_through(cam, Vector2(400, 300))
        _check(not hit.is_empty(), "pit floor is pickable")
        if hit.is_empty():
                return
        var sph0: int = t.carve_set.sphere_count()
        var h_above0: float = t.height_at(Vector2(hit.position.x, hit.position.z))
        panel.tool = panel.DIG_TOOL
        panel.radii[panel.DIG_TOOL] = 1.5
        _arm_dig()
        _press(cam, Vector2(400, 300))
        _release(cam)
        _check(t.carve_set.sphere_count() > sph0, "dig in pit extended the carve set")
        _check(t.height_at(Vector2(hit.position.x, hit.position.z)) >= h_above0 - 0.02,
                        "dig in pit did not cut the surface above")

func _ux_discovery() -> void:
        print("[UX] terrain discovery (no-selection fallback)")
        _check(plugin._find_terrain_in(null) == null, "discovery: null root handled")
        var holder := Node3D.new()
        var mid := Node3D.new()
        holder.add_child(mid)
        root.remove_child(t)
        mid.add_child(t)
        _check(plugin._find_terrain_in(holder) == t, "discovery: finds a nested terrain")
        mid.remove_child(t)
        root.add_child(t)
        holder.queue_free()
        # Input with no terrain wired: must pass through cleanly (the editor
        # has no edited scene headless, so autodiscovery finds nothing).
        plugin._terrain = null
        var ret: int = plugin._forward_3d_gui_input(null, InputEventMouseButton.new())
        _check(ret == EditorPlugin.AFTER_GUI_INPUT_PASS,
                        "discovery: input passes through when no terrain exists")
        plugin._terrain = t
