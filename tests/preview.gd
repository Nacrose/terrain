extends SceneTree
## Renders preview images of the terrain (with a showcase tunnel + digs) to
## res://tests_out/. Run: godot --headless --path . --script res://tests/preview.gd

const Terrain = preload("res://addons/stoem_terrain/nodes/terrain_3d.gd")
const MeshUtil = preload("res://addons/stoem_terrain/core/terrain_mesh.gd")

func _initialize() -> void:
        var t := Terrain.new()
        t.seed_value = 20261113
        root.add_child(t)
        t.bake()

        # Showcase edits: a sand pit with spoil, a pond dig, and (last, so no
        # later dig can re-check and collapse its roof) a tunnel through a hill.
        var hill: Variant = _find_hill(t)
        var tunnel := {}
        var sand: Variant = _find_mat(t, 1)
        if sand != null:
                t.dig(Vector3(sand.x, t.height_at(sand), sand.y), 2.2, 12.0)
        var pond: Variant = _find_wet(t)
        if pond != null:
                t.dig(Vector3(pond.x, t.height_at(pond), pond.y), 2.0, 6.0)
        if hill != null:
                var y_bore: float = t.height_at(hill) - 8.0
                # Showcase determinism: make the hill granitic so the bore's
                # roof provably holds regardless of where the earlier showcase
                # digs landed (baked biome colours are unaffected).
                for wz in range(int(hill.y) - 12, int(hill.y) + 13, 2):
                        for wx in range(int(hill.x) - 8, int(hill.x) + 41, 2):
                                t.set_material_override(Vector2(float(wx), float(wz)), 4)
                t.carve_capsule(Vector3(hill.x, y_bore, hill.y),
                                Vector3(hill.x + 32.0, y_bore, hill.y), 1.5)
                if t.carve_set.capsule_count() > 0:
                        tunnel = {"x0": hill.x, "z": hill.y, "y": y_bore}
                else:
                        print("NOTE: showcase bore collapsed (weak cover); rendering digs only")

        var dir := "res://tests_out"
        DirAccess.make_dir_recursive_absolute(dir)
        _render_heightmap(t, dir + "/heightmap.png")
        _render_materials(t, dir + "/materials.png")
        _render_water(t, dir + "/water_table.png")
        _render_section(t, tunnel, dir + "/cross_section.png")
        _render_mesh_holes(t, tunnel, dir + "/mesh_holes.png")
        print("previews written to ", ProjectSettings.globalize_path(dir))
        quit(0)

## Top-down raster of the ACTUAL ground-sheet mesh around the tunnel mouth:
## green = ground sheet triangles, brown = cave-surface triangles (visible
## through the cut), dark = neither (the hole). Proof that carving opens the
## sheet and the cave walls connect: the mouth shows brown walls through a
## green-rimmed hole instead of a sealed green sheet.
func _render_mesh_holes(t, p_tunnel: Dictionary, p_path: String) -> void:
        if not p_tunnel.has("x0"):
                return
        # Centre the window on the actual mouth (first open column along the bore).
        var mouth_x: float = p_tunnel.x0 + 30.0
        for x in range(int(p_tunnel.x0) + 1, int(p_tunnel.x0) + 37):
                if t.surface_is_open_world(float(x), p_tunnel.z):
                        mouth_x = float(x)
                        break
        var x0: float = mouth_x
        var z0: float = p_tunnel.z
        var win := 48.0
        var ppm := 10.0
        var size := int(win * ppm)
        var img := Image.create(size, size, false, Image.FORMAT_RGB8)
        img.fill(Color(0.07, 0.06, 0.05))
        var ci0 := clampi(int(floor((x0 - win * 0.5 + 384.0) / 48.0)), 0, 15)
        var ci1 := clampi(int(floor((x0 + win * 0.5 + 384.0) / 48.0)), 0, 15)
        var cj0 := clampi(int(floor((z0 - win * 0.5 + 384.0) / 48.0)), 0, 15)
        var cj1 := clampi(int(floor((z0 + win * 0.5 + 384.0) / 48.0)), 0, 15)
        # cave surface first (ground sheet draws over it where present)
        var cave: Array = MeshUtil.cave_mesh_arrays(t, {}, Rect2(x0 - win, z0 - win, win * 2.0, win * 2.0))
        _paint_tris(img, cave[0], cave[3], x0, z0, win, ppm, Color(0.42, 0.33, 0.24))
        for cj in range(cj0, cj1 + 1):
                for ci in range(ci0, ci1 + 1):
                        var arrays: Array = MeshUtil.ground_chunk_arrays(t, ci, cj)
                        _paint_tris(img, arrays[0], arrays[3], x0, z0, win, ppm, Color(0.30, 0.44, 0.20))
        img.save_png(p_path)

func _paint_tris(img: Image, p_verts: PackedVector3Array, p_idx: PackedInt32Array,
                p_cx: float, p_cz: float, p_win: float, p_ppm: float, p_col: Color) -> void:
        var half := p_win * 0.5
        var size := img.get_width()
        var k := 0
        while k + 2 < p_idx.size():
                var a: Vector3 = p_verts[p_idx[k]]
                var b: Vector3 = p_verts[p_idx[k + 1]]
                var c: Vector3 = p_verts[p_idx[k + 2]]
                k += 3
                if maxf(a.x, maxf(b.x, c.x)) < p_cx - half or minf(a.x, minf(b.x, c.x)) > p_cx + half:
                        continue
                if maxf(a.z, maxf(b.z, c.z)) < p_cz - half or minf(a.z, minf(b.z, c.z)) > p_cz + half:
                        continue
                var steps := 22
                for u in steps + 1:
                        for v in steps + 1 - u:
                                var w := 1.0 - float(u) / float(steps) - float(v) / float(steps)
                                var px := a.x * w + b.x * (float(u) / float(steps)) + c.x * (float(v) / float(steps))
                                var pz := a.z * w + b.z * (float(u) / float(steps)) + c.z * (float(v) / float(steps))
                                var ix := int((px - (p_cx - half)) * p_ppm)
                                var iy := int((pz - (p_cz - half)) * p_ppm)
                                if ix >= 0 and ix < size and iy >= 0 and iy < size:
                                        img.set_pixel(ix, iy, p_col)
        return

func _find_hill(t) -> Variant:
        for wz in range(-320, 321, 12):
                for wx in range(-300, 261, 8):
                        var p := Vector2(float(wx), float(wz))
                        var h0: float = t.height_at(p)
                        if h0 < 16.0 or t.slope_deg_at(p) > 30.0:
                                continue
                        var y_bore := h0 - 8.0
                        var covered := true
                        for k in [0.0, 8.0, 16.0, 24.0, 28.0]:
                                if t.height_at(p + Vector2(k, 0.0)) < y_bore + 1.7:
                                        covered = false
                                        break
                        if not covered:
                                continue
                        if t.height_at(p + Vector2(36.0, 0.0)) > y_bore - 2.0:
                                continue
                        return p
        return null

func _find_mat(t, p_id: int) -> Variant:
        for wz in range(-340, 341, 6):
                for wx in range(-340, 341, 6):
                        if t.material_id_at(Vector2(float(wx), float(wz))) == p_id:
                                return Vector2(float(wx), float(wz))
        return null

func _find_wet(t) -> Variant:
        for wz in range(-340, 341, 6):
                for wx in range(-340, 341, 6):
                        var p := Vector2(float(wx), float(wz))
                        if t.water_table_at(p) - t.height_at(p) > 0.4 and t.slope_deg_at(p) < 9.0:
                                return p
        return null

func _render_heightmap(t, p_path: String) -> void:
        var img := Image.create(768, 768, false, Image.FORMAT_RGB8)
        var light := Vector3(-0.55, 0.7, -0.45).normalized()
        for j in 768:
                for i in 768:
                        var h: float = t.data.heights[i + j * t.data.N]
                        var shade: float = clampf(0.35 + h / 55.0, 0.0, 1.0)
                        var n: Vector3 = t.normal_at(Vector2(float(i) - 384.0, float(j) - 384.0))
                        var lambert: float = clampf(n.dot(light), 0.0, 1.0)
                        var v := shade * (0.45 + 0.55 * lambert)
                        img.set_pixel(i, j, Color(v, v, v * 1.02))
        img.save_png(p_path)

func _render_materials(t, p_path: String) -> void:
        var img := Image.create(768, 768, false, Image.FORMAT_RGB8)
        for j in 768:
                for i in 768:
                        var col: Color = MeshUtil._biome_color(t.data.biome[i + j * t.data.N])
                        img.set_pixel(i, j, col)
        img.save_png(p_path)

func _render_water(t, p_path: String) -> void:
        var img := Image.create(768, 768, false, Image.FORMAT_RGB8)
        for j in 768:
                for i in 768:
                        var h: float = t.data.heights[i + j * t.data.N]
                        var g: float = clampf(0.3 + h / 60.0, 0.0, 1.0)
                        var col := Color(g * 0.85, g * 0.9, g * 0.8)
                        var p := Vector2(float(i) - 384.0, float(j) - 384.0)
                        var pore: float = t.pore_factor_at(p)
                        if pore > 0.05:
                                col = col.lerp(Color(0.1, 0.35, 0.85), pore * 0.85)
                        if t.surface_is_open_world(p.x, p.y):
                                col = Color(0.95, 0.4, 0.1)
                        img.set_pixel(i, j, col)
        img.save_png(p_path)

func _render_section(t, p_tunnel: Dictionary, p_path: String) -> void:
        # Vertical slice along x at the tunnel's z (or the map centre).
        var z: float = p_tunnel.get("z", 0.0)
        var img := Image.create(768, 170, false, Image.FORMAT_RGB8)
        var y_top := 52.0
        var y_bot := -32.0
        for px in 768:
                var x := float(px) - 384.0
                var h: float = t.height_at(Vector2(x, z))
                var head: float = t.water_table_at(Vector2(x, z))
                for py in 170:
                        var y := y_top - (y_top - y_bot) * float(py) / 169.0
                        var col := Color(0.66, 0.78, 0.9)  # sky
                        if y < h:
                                if t.is_solid(Vector3(x, y, z)):
                                        var depth: float = h - y
                                        var shade: float = clampf(1.0 - depth / 45.0, 0.3, 1.0)
                                        var mat_col: Color = MeshUtil._biome_color(t.material_id_at(Vector2(x, z)))
                                        col = mat_col.lerp(Color(0.42, 0.36, 0.3), 0.55).darkened(1.0 - shade)
                                else:
                                        col = Color(0.12, 0.09, 0.07)  # carved air (cave/tunnel)
                        if absf(y - head) < 0.28 and y < h + 0.3 and y > h - 26.0:
                                col = Color(0.15, 0.45, 0.95)  # water table line
                        img.set_pixel(px, py, col)
        # tunnel mouth marker
        if p_tunnel.has("x0"):
                var x0: float = p_tunnel.x0
                var py := int((y_top - p_tunnel.y) / (y_top - y_bot) * 169.0)
                var px := int(x0 + 384.0)
                for k in range(-3, 30 * 2):
                        var q := clampi(px + k, 0, 767)
                        img.set_pixel(q, clampi(py, 0, 169), Color(0.95, 0.4, 0.1))
        img.save_png(p_path)
