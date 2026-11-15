extends SceneTree
## Run in a project containing the add-on with --headless --script res://tests/regressions.gd.

const Terrain = preload("res://addons/stoem_terrain/nodes/terrain_3d.gd")
const Data = preload("res://addons/stoem_terrain/core/terrain_data.gd")
const Carves = preload("res://addons/stoem_terrain/core/terrain_carve.gd")
const Store = preload("res://addons/stoem_terrain/core/terrain_edits.gd")
const MeshUtil = preload("res://addons/stoem_terrain/core/terrain_mesh.gd")

var failures := 0
var checks := 0
var regions: Array = []
var load_heights: Array = []

func check(condition: bool, message: String) -> void:
    checks += 1
    if condition:
        print("PASS ", message)
    else:
        failures += 1
        print("FAIL ", message)

func _initialize() -> void:
    _run.call_deferred()

func _run() -> void:
    var terrain = Terrain.new()
    root.add_child(terrain)
    terrain.edited_region.connect(func(rect: Rect2): regions.append(rect))
    _boundary_and_materials(terrain)
    _carves_and_snapshots(terrain)
    _transforms_and_rays(terrain)
    _invalid_edits(terrain)
    _cancelled_stroke(terrain)
    await _collision(terrain)
    _water_overlay(terrain)
    _persistence(terrain)
    _coarse_sampling()
    terrain.free()
    print("RESULT: %d checks, %d failures" % [checks, failures])
    quit(1 if failures else 0)

func _boundary_and_materials(terrain) -> void:
    terrain.sculpt(0.0, -96.0, 0.49, 10.0, Terrain.TOOL_RAISE, 1.0)
    var height: float = terrain.height_at(Vector2(0, -96))
    for cz in [5, 6]:
        for cx in [7, 8]:
            var arrays: Array = terrain._ground_nodes[cx + cz * 16].mesh.surface_get_arrays(0)
            var index: int = (288 - cz * 48) * 49 + (384 - cx * 48)
            check(absf(arrays[Mesh.ARRAY_VERTEX][index].y - height) < 0.0001,
                    "shared corner updated in chunk %d,%d" % [cx, cz])
    var left: Array = terrain._ground_nodes[87].mesh.surface_get_arrays(0)
    var right: Array = terrain._ground_nodes[88].mesh.surface_get_arrays(0)
    check(left[Mesh.ARRAY_NORMAL][47 * 49 + 48].is_equal_approx(right[Mesh.ARRAY_NORMAL][47 * 49]),
            "shared boundary normals agree")
    var slope_index := 383 + 288 * 769
    var expected_slope: float = maxf(
            absf(terrain.data.heights[slope_index + 1] - terrain.data.heights[slope_index - 1]),
            absf(terrain.data.heights[slope_index + 769] - terrain.data.heights[slope_index - 769])) * 0.5
    check(is_equal_approx(terrain.data.slope[slope_index], expected_slope), "cached slope refreshed after sculpt")
    check(terrain.undo(), "boundary edit can undo")
    check(terrain.redo(), "boundary edit can redo")

    var old_history: int = terrain._undo_stack.size()
    regions.clear()
    terrain.set_material_override(Vector2(384, 384), 4)
    check(terrain.biome_at_world(384, 384) == &"granite", "material paint reaches final row and column")
    check(regions.size() == 1, "direct material override emits one region event")
    check(terrain._undo_stack.size() == old_history, "direct override preserves history API behavior")
    regions.clear()
    terrain.set_material_override(Vector2(384, 384), 4)
    check(regions.is_empty(), "unchanged material emits no redundant event")
    var error: int = terrain.apply_edit_snapshot(&"material", {
        "cells": PackedInt32Array([184 + 184 * 769]), "new": PackedInt32Array([1])})
    check(error == OK and terrain.biome_at_world(-200, -200) == &"sand", "material snapshot synchronizes biome")
    var fresh: Array = MeshUtil.ground_chunk_arrays(terrain, 3, 3)
    var rendered: Array = terrain._ground_nodes[51].mesh.surface_get_arrays(0)
    var color_diffs := 0
    for ci in fresh[2].size():
        # ArrayMesh stores vertex colors at lower precision than the source
        # PackedColorArray; allow that expected quantization while checking the
        # entire chunk still matches its current source data.
        var expected: Color = fresh[2][ci]
        var actual: Color = rendered[Mesh.ARRAY_COLOR][ci]
        var delta := maxf(maxf(absf(expected.r - actual.r), absf(expected.g - actual.g)),
                maxf(absf(expected.b - actual.b), absf(expected.a - actual.a)))
        if delta > 0.006:
            color_diffs += 1
    check(color_diffs == 0, "material snapshot refreshes visible colors")

func _carves_and_snapshots(terrain) -> void:
    var height: float = terrain.height_at(Vector2(25, 25))
    var payload := PackedFloat32Array([1, 25, height, 25, 3, 0])
    check(terrain.set_volume_chunks(payload) == OK, "carve replacement accepts valid data")
    var cut: ArrayMesh = terrain._ground_nodes[136].mesh
    check(_mesh_index_count(cut) < 13824, "carve replacement opens ground geometry")
    regions.clear()
    check(terrain.set_volume_chunks(PackedFloat32Array([0, 0])) == OK, "clear carve set succeeds")
    var restored: ArrayMesh = terrain._ground_nodes[136].mesh
    check(_mesh_index_count(restored) == 13824, "cleared hole restores ground triangles")
    check(regions.size() == 1 and regions[0].has_point(Vector2(25, 25)), "cleared hole reports old region")
    check(terrain.apply_edit_snapshot(&"carve", {}, payload) == OK, "carve snapshot applies")
    check(terrain.surface_is_open_world(25, 25), "carve snapshot opens surface")
    check(terrain.apply_edit_snapshot(&"carve", {}, payload, true) == OK, "carve snapshot reverses")
    restored = terrain._ground_nodes[136].mesh
    check(_mesh_index_count(restored) == 13824, "reversed carve snapshot closes mesh")
    var shapes := Carves.new()
    shapes.deserialize(payload)
    for malformed in [PackedFloat32Array(), PackedFloat32Array([999, 0]),
            PackedFloat32Array([-1, 0]), PackedFloat32Array([0.5, 0]),
            PackedFloat32Array([1, 0, 0, 0, NAN, 0])]:
        check(not shapes.deserialize(malformed) and shapes.serialize() == payload,
                "invalid carve payload rejected without partial replacement")

    # A void covering an entire chunk must produce an empty mesh and collider.
    var emptying := PackedFloat32Array([1, 24, 0, 24, 100, 0])
    terrain.set_volume_chunks(emptying)
    check(terrain._ground_nodes[136].mesh.get_surface_count() == 0,
            "fully carved ground chunk has no invalid mesh surface")
    check(not terrain._ground_nodes[136].visible, "fully carved ground chunk is hidden")
    terrain.set_volume_chunks(PackedFloat32Array([0, 0]))
    check(terrain._ground_nodes[136].visible, "restoring ground restores visibility")

func _mesh_index_count(p_mesh: ArrayMesh) -> int:
    var total := 0
    for surface in p_mesh.get_surface_count():
        var arrays: Array = p_mesh.surface_get_arrays(surface)
        total += arrays[Mesh.ARRAY_INDEX].size()
    return total

func _transforms_and_rays(terrain) -> void:
    var local := Vector3(20, terrain.height_at(Vector2(20, 10)), 10)
    terrain.transform = Transform3D(Basis(Vector3.UP, 0.4).scaled(Vector3(2, 3, 2)), Vector3(100, 70, -30))
    var world: Vector3 = terrain.global_transform * local
    check(absf(terrain.sample_height_world(world.x, world.z) - world.y) < 0.001,
            "world height respects translation, yaw and scale")
    var hit: Dictionary = terrain.raycast_world(world + Vector3.UP * 10, Vector3.DOWN, 20)
    check(not hit.is_empty() and hit.position.distance_to(world) < 0.002, "world ray respects transform")
    var expected_normal: Vector3 = (terrain.global_transform.basis.inverse().transposed()
            * terrain.normal_at(Vector2(20, 10))).normalized()
    check(terrain.normal_at_world(world.x, world.z).distance_to(expected_normal) < 0.001,
            "world normal uses inverse transpose for nonuniform scale")
    terrain.transform = Transform3D(Basis(Vector3.FORWARD, 0.1), Vector3(0, 50, 0))
    world = terrain.global_transform * local
    check(absf(terrain.sample_height_world(world.x, world.z) - world.y) < 0.002, "tilted terrain world height")
    terrain.transform = Transform3D.IDENTITY
    check(is_nan(terrain.sample_height_world(1000, 0)), "out-of-bounds world height is invalid")
    check(terrain.raycast(Vector3(1000, 100, 0), Vector3.DOWN, 200).is_empty(), "ray misses outside map")
    check(not terrain.is_solid(Vector3(1000, -100, 0)), "solid query excludes outside map")
    var height: float = terrain.height_at(Vector2.ZERO)
    check(terrain.raycast(Vector3(0, height + 1, 0), Vector3.DOWN, 0.9).is_empty(),
            "ray respects maximum distance")
    check(terrain.raycast(Vector3(0, height + 1, 0), Vector3.ZERO).is_empty(), "zero direction ray misses")

func _invalid_edits(terrain) -> void:
    var before: PackedFloat32Array = terrain.data.heights.duplicate()
    check(terrain.apply_edit_snapshot(&"height", {"cells": PackedInt32Array([0]),
            "new": PackedFloat32Array()}) == ERR_INVALID_DATA, "mismatched snapshot lengths rejected")
    check(terrain.apply_edit_snapshot(&"height", {"cells": PackedInt32Array([0, 999999]),
            "new": PackedFloat32Array([20, 30])}) == ERR_INVALID_DATA, "snapshot indices validated before writes")
    check(terrain.apply_edit_snapshot(&"height", {"cells": PackedInt32Array([0]),
            "new": PackedFloat32Array([NAN])}) == ERR_INVALID_DATA, "NaN snapshot rejected")
    terrain.sculpt(0, 0, 2, NAN, 0, 0.5)
    check(terrain.dig(Vector3.ZERO, -2) == 0.0, "negative-radius dig rejected")
    check(not terrain.carve_capsule(Vector3.ZERO, Vector3.ONE, INF), "infinite capsule rejected")
    check(terrain.data.heights == before, "invalid edits leave heights intact")

func _cancelled_stroke(terrain) -> void:
    var point := Vector2(30, 30)
    var before: float = terrain.height_at(point)
    var history_size: int = terrain._undo_stack.size()
    terrain.begin_stroke()
    terrain.sculpt(point.x, point.y, 2.0, 4.0, Terrain.TOOL_RAISE, 1.0)
    terrain.flush_dirty()
    check(not is_equal_approx(terrain.height_at(point), before), "active stroke changes visible terrain")
    terrain.cancel_stroke()
    check(is_equal_approx(terrain.height_at(point), before), "cancel restores active stroke")
    check(terrain._undo_stack.size() == history_size, "cancel does not add an undo entry")

func _collision(terrain) -> void:
    terrain.enable_collision = true
    check(terrain._collision_body.get_child_count() == 256, "collision enables 256 ground shapes")
    check(terrain._ground_shapes[0].shape.backface_collision, "terrain collision accepts rays from air")
    terrain.refresh_collision()
    check(terrain._collision_body.get_child_count() == 256, "refresh reuses collision nodes")
    terrain.enable_collision = true
    check(terrain._collision_body.get_child_count() == 256, "repeated enable is idempotent")
    await physics_frame
    await physics_frame
    var point := Vector2(-0.01, -96)
    var height: float = terrain.height_at(point)
    var query := PhysicsRayQueryParameters3D.create(Vector3(point.x, height + 10, point.y),
            Vector3(point.x, height - 10, point.y))
    var hit: Dictionary = terrain.get_world_3d().direct_space_state.intersect_ray(query)
    print("DEBUG physics ray height=", height, " hit=", hit, " shape_count=", terrain._collision_body.get_child_count())
    check(not hit.is_empty() and absf(hit.position.y - height) < 0.02,
            "physics ray agrees with edited boundary height")
    terrain.enable_collision = false
    check(terrain._collision_body.get_child_count() == 0, "disable removes all collision shapes after refresh")

func _water_overlay(terrain) -> void:
    terrain.debug_water_table = true
    check(terrain._water_node.visible, "water overlay enables")
    terrain.debug_water_table = false
    check(not terrain._water_node.visible, "water overlay disables")
    terrain.debug_water_table = true
    check(terrain._water_node.visible, "water overlay re-enables")
    terrain.debug_water_table = false

func _persistence(terrain) -> void:
    var path := "res://review_state/stoem_regression_save.res"
    check(terrain.save_edits(path) == OK, "atomic save succeeds")
    var cached: Resource = ResourceLoader.load(path)
    terrain.sculpt(10, 10, 0.49, 5, Terrain.TOOL_RAISE, 1)
    var expected: float = terrain.height_at(Vector2(10, 10))
    check(terrain.save_edits(path) == OK, "save overwrites an existing checkpoint")
    terrain.baked.connect(func(): load_heights.append(terrain.height_at(Vector2(10, 10))))
    check(terrain.load_edits(path) == OK, "load latest file with older Resource still cached")
    check(absf(terrain.height_at(Vector2(10, 10)) - expected) < 0.0001, "load bypasses stale resource cache")
    check(load_heights.size() == 1 and absf(load_heights[0] - expected) < 0.0001,
            "baked signal fires once after restored edits")
    check(terrain.data.sampling_version == 2, "new checkpoint preserves centered sampling")
    var before: PackedFloat32Array = terrain.data.heights.duplicate()
    var invalid := Store.new()
    invalid.height_cells = PackedInt32Array([0, 1])
    invalid.height_values = PackedFloat32Array([25])
    var invalid_path := "res://review_state/stoem_regression_invalid.res"
    ResourceSaver.save(invalid, invalid_path)
    check(terrain.load_edits(invalid_path) == ERR_INVALID_DATA, "invalid save rejected")
    check(terrain.data.heights == before, "invalid load preserves current terrain")
    var old := Store.new()
    old.version = 0
    old.seed_value = 777
    var old_path := "res://review_state/stoem_regression_legacy.res"
    ResourceSaver.save(old, old_path)
    check(terrain.load_edits(old_path) == OK and terrain.data.sampling_version == 1,
            "legacy version zero uses original sampling")
    check(cached != null, "stale resource held throughout overwrite test")
    for saved in [path, invalid_path, old_path]:
        DirAccess.remove_absolute(ProjectSettings.globalize_path(saved))

func _coarse_sampling() -> void:
    var data := Data.new()
    var field := PackedFloat32Array()
    field.resize(192 * 192)
    for j in 192:
        for i in 192:
            field[i + j * 192] = i + j * 10
    check(is_equal_approx(data.sample_coarse(field, 2, 2), 0), "first coarse cell sampled at its center")
    check(is_equal_approx(data.sample_coarse(field, 6, 6), 11), "second coarse cell sampled at its center")
    check(is_equal_approx(data.sample_coarse(field, 4, 4), 5.5), "coarse interpolation between centers")
    data.sampling_version = 1
    check(is_equal_approx(data.sample_coarse(field, 2, 2), 5.5), "legacy coarse interpolation retained")
    data.build()
    var points := data.river_pts.duplicate()
    data.build()
    check(data.river_pts == points, "rebuilding a data resource does not duplicate river points")
