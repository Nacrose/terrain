@tool
class_name StoemTerrainMesh
extends RefCounted
## Mesh generation. Meshes are derived artefacts: the authoritative data is always
## the heightfield + analytic carve set.
##
## Ground = chunked grid mesh. Wherever carved air breaks the surface (pit at
## the click point, tunnel mouth), the ground sheet is CUT: those quads are
## skipped, so the opening is visible and the collision shape matches what you
## see (the sheet used to seal every opening - "carving does nothing", "can't
## walk into the tunnel").
##
## Caves = surface nets over F = max(y - height, carve_sdf), partitioned into
## 12 m XZ tiles (one per carve-hash cell) so no surface point is emitted
## twice (the per-primitive boxes used to duplicate every wall where
## primitives overlapped -> z-fighting). Quads that lie flat on the un-carved
## sheet (the "apron" around openings) are clipped: the ground mesh already
## renders that surface.

const Carve = preload("res://addons/stoem_terrain/core/terrain_carve.gd")

const CHUNKS := 16      # 16 x 16 chunks over the map
const CHUNK_M := 48     # metres per chunk
const STEP := 1         # metres per ground quad (digs under 2 m must be visible)
const TILE := 12        # metres per cave tile; equals Carve.CELL so hash cells align 1:1

static func _biome_color(p_terrain, p_id: int) -> Color:
        if p_terrain != null:
                var material = p_terrain.material_definition(p_id)
                if material != null:
                        return material.preview_color
        match p_id:
                0: return Color(0.416, 0.512, 0.290)   # loam
                1: return Color(0.851, 0.757, 0.478)   # sand
                2: return Color(0.600, 0.557, 0.467)   # gravel
                3: return Color(0.706, 0.541, 0.353)   # clay
                4: return Color(0.549, 0.549, 0.569)   # granite
                5: return Color(0.710, 0.694, 0.655)   # scree
                6: return Color(0.937, 0.953, 0.965)   # snow
                _: return Color(0.5, 0.5, 0.5)

static func vertex_color(p_data: Resource, p_i: int, p_j: int, p_terrain = null) -> Color:
        var idx: int = p_i + p_j * p_data.N
        var material_id: int = p_data.biome[idx]
        if p_terrain != null:
                var surface_id: int = p_terrain.surface_material_id_at_vertex(p_i, p_j)
                if surface_id >= 0:
                        material_id = surface_id
        var col := _biome_color(p_terrain, material_id)
        var rk: float = p_data.sample_coarse(p_data.rock_frac, float(p_i), float(p_j))
        var sl: float = p_data.slope[idx]
        var so: float = p_data.sample_coarse(p_data.soil_mix, float(p_i), float(p_j))
        var rock_w: float = clampf(rk * 0.6 + (0.35 if sl > 0.75 else 0.0), 0.0, 0.85)
        col = col.lerp(Color(0.52, 0.50, 0.48), rock_w)
        col = col.lerp(Color(0.30, 0.42, 0.18), clampf(so - 0.55, 0.0, 0.35))
        var h: float = p_data.heights[idx]
        if h < 1.8:
                col = col.lerp(Color(0.76, 0.68, 0.44), smoothstep(1.8, 0.4, h) * 0.8)
        return col

## Grid mesh arrays for one 48 m ground chunk: [verts, normals, colors, indices].
## Quads whose centre the carve set opens (same test as surface_is_open_world)
## are dropped: the sheet has a hole exactly where tunnels and pits break the
## surface, and the collision shape (built from the same arrays) opens too.
static func ground_chunk_arrays(p_terrain, p_ci: int, p_cj: int) -> Array:
        var p_data = p_terrain.data
        var u_count := CHUNK_M / STEP + 1
        var verts := PackedVector3Array()
        var normals := PackedVector3Array()
        var colors := PackedColorArray()
        var indices := PackedInt32Array()
        var uvs := PackedVector2Array()
        var material_indices := {}
        var i0 := p_ci * CHUNK_M
        var j0 := p_cj * CHUNK_M
        var carve = p_terrain.carve_set
        var maybe_open: bool = carve.has_carve() and carve.intersects_rect(Rect2(
                        float(i0) - p_data.HALF - 1.0, float(j0) - p_data.HALF - 1.0,
                        float(CHUNK_M) + 2.0, float(CHUNK_M) + 2.0))
        for v in u_count:
                var j := j0 + v * STEP
                for u in u_count:
                        var i := i0 + u * STEP
                        var idx: int = i + j * p_data.N
                        verts.append(Vector3(float(i) - p_data.HALF, p_data.heights[idx], float(j) - p_data.HALF))
                        var ia := clampi(i - 1, 0, p_data.N - 1)
                        var ib := clampi(i + 1, 0, p_data.N - 1)
                        var ja := clampi(j - 1, 0, p_data.N - 1)
                        var jb := clampi(j + 1, 0, p_data.N - 1)
                        var nrm := Vector3(
                                p_data.heights[ia + j * p_data.N] - p_data.heights[ib + j * p_data.N],
                                2.0,
                                p_data.heights[i + ja * p_data.N] - p_data.heights[i + jb * p_data.N])
                        normals.append(nrm.normalized())
                        p_data.slope[idx] = maxf(absf(nrm.x), absf(nrm.z)) * 0.5
                        colors.append(vertex_color(p_data, i, j, p_terrain))
                        uvs.append(Vector2(float(i) - p_data.HALF, float(j) - p_data.HALF))
        for v in u_count - 1:
                for u in u_count - 1:
                        var cx: float = float(i0 + u * STEP) + 0.5 - p_data.HALF
                        var cz: float = float(j0 + v * STEP) + 0.5 - p_data.HALF
                        if maybe_open:
                                if p_terrain.surface_is_open_world(cx, cz):
                                        continue    # hole in the sheet: carved air pierces it here
                        var a := v * u_count + u
                        var b := a + 1
                        var c := a + u_count
                        var d := c + 1
                        indices.append(a)
                        indices.append(c)
                        indices.append(b)
                        indices.append(b)
                        indices.append(c)
                        indices.append(d)
                        var material_id: int = p_terrain.material_id_at(Vector2(cx, cz))
                        var mi := clampi(floori((cx + p_data.HALF) / p_data.MAT_CELL), 0, p_data.MAT_N - 1)
                        var mj := clampi(floori((cz + p_data.HALF) / p_data.MAT_CELL), 0, p_data.MAT_N - 1)
                        var cell_index: int = mi + mj * p_data.MAT_N
                        var variant_index: int = p_terrain.appearance_variant_index_for_cell(cell_index, material_id)
                        var appearance_key := Vector2i(material_id, variant_index)
                        var group: PackedInt32Array = material_indices.get(appearance_key, PackedInt32Array())
                        group.append(a)
                        group.append(c)
                        group.append(b)
                        group.append(b)
                        group.append(c)
                        group.append(d)
                        material_indices[appearance_key] = group
        return [verts, normals, colors, indices, material_indices, uvs]

static func _fv(p_f: PackedFloat32Array, p_nx: int, p_ny: int,
                p_ix: int, p_iy: int, p_iz: int) -> float:
        return p_f[p_ix + p_nx * (p_iy + p_ny * p_iz)]

## Cave surface: surface nets over F = max(y - height, carve sdf), one cached
## 12 m XZ tile per carve-hash cell. p_dirty (world metres) rebuilds the tiles
## it intersects; tiles missing from p_cache are built; an empty cache builds
## everything. Returns [verts, normals, colors, indices].
static func cave_mesh_arrays(p_terrain, p_cache: Dictionary, p_dirty: Rect2 = Rect2()) -> Array:
        var verts := PackedVector3Array()
        var normals := PackedVector3Array()
        var colors := PackedColorArray()
        var indices := PackedInt32Array()
        var carve = p_terrain.carve_set
        if not carve.has_carve():
                return [verts, normals, colors, indices]
        var b: Rect2 = carve.bounds()
        var tx0 := floori(b.position.x / TILE)
        var tx1 := floori(b.end.x / TILE)
        var tz0 := floori(b.position.y / TILE)
        var tz1 := floori(b.end.y / TILE)
        for tz in range(tz0, tz1 + 1):
                for tx in range(tx0, tx1 + 1):
                        var key := Vector2i(tx, tz)
                        var rows: Dictionary = carve.rows_near_cell(key)
                        var sph_rows: PackedInt32Array = rows["sph"]
                        var cap_rows: PackedInt32Array = rows["cap"]
                        if sph_rows.is_empty() and cap_rows.is_empty():
                                p_cache.erase(key)   # tile no longer touched by any primitive
                                continue
                        var stale := not p_cache.has(key)
                        if not stale and p_dirty.size.x > 0.0:
                                stale = p_dirty.intersects(Rect2(float(tx * TILE), float(tz * TILE),
                                                float(TILE), float(TILE)))
                        if stale:
                                p_cache[key] = _build_cave_tile(p_terrain, tx, tz, sph_rows, cap_rows)
                        _append_cached(p_cache[key], verts, normals, colors, indices)
        return [verts, normals, colors, indices]

## One 12 m tile of the cave surface. Lattice points span one extra column on
## each side, and quads are emitted only for edges the tile owns, so tiles
## meet without gaps and without duplicated faces.
static func _build_cave_tile(p_terrain, p_tx: int, p_tz: int,
                p_sph: PackedInt32Array, p_cap: PackedInt32Array) -> Dictionary:
        var data = p_terrain.data
        var carve = p_terrain.carve_set
        var x0 := p_tx * TILE
        var z0 := p_tz * TILE
        var ylo := 1e9
        var yhi := -1e9
        for q in p_sph.size():
                var o: int = p_sph[q] * 4
                ylo = minf(ylo, carve.spheres[o + 1] - carve.spheres[o + 3])
                yhi = maxf(yhi, carve.spheres[o + 1] + carve.spheres[o + 3])
        for q in p_cap.size():
                var o: int = p_cap[q] * 7
                ylo = minf(ylo, minf(carve.capsules[o + 1], carve.capsules[o + 5]) - carve.capsules[o + 3])
                yhi = maxf(yhi, maxf(carve.capsules[o + 1], carve.capsules[o + 5]) + carve.capsules[o + 3])
        ylo = float(floori(ylo - 1.5))
        yhi = float(ceili(yhi + 1.5))
        if yhi - ylo > 240.0:
                yhi = ylo + 240.0
        var nx := TILE + 2        # lattice points x0-1 .. x0+TILE
        var nz := TILE + 2        # lattice points z0-1 .. z0+TILE
        var ny := int(yhi - ylo) + 3
        var f := PackedFloat32Array()
        f.resize(nx * ny * nz)
        var k := 0
        for iz in nz:
                var wz: float = float(z0 - 1 + iz)
                for iy in ny:
                        var wy: float = ylo - 1.0 + float(iy)
                        for ix in nx:
                                var wx: float = float(x0 - 1 + ix)
                                var hs: float = wy - data.sample_height(wx + data.HALF, wz + data.HALF)
                                f[k] = maxf(hs, carve.sdf_rows(Vector3(wx, wy, wz), p_sph, p_cap))
                                k += 1

        var lv := PackedVector3Array()
        var ln := PackedVector3Array()
        var lc := PackedColorArray()
        var li := PackedInt32Array()
        # Cell vertex for every cell of the extended lattice (cells 0..nx-2 etc.
        # include the border columns the neighbouring tile's quads share).
        var cell_vert := {}
        for iz in nz - 1:
                for iy in ny - 1:
                        for ix in nx - 1:
                                var solid_count := 0
                                for cz in 2:
                                        for cy in 2:
                                                for cx in 2:
                                                        if _fv(f, nx, ny, ix + cx, iy + cy, iz + cz) < 0.0:
                                                                solid_count += 1
                                if solid_count == 0 or solid_count == 8:
                                        continue
                                var base := Vector3(float(x0 - 1 + ix), ylo - 1.0 + float(iy), float(z0 - 1 + iz))
                                var sum := Vector3.ZERO
                                var cnt := 0
                                for e in _EDGES:
                                        var va: float = _fv(f, nx, ny, ix + e[0].x, iy + e[0].y, iz + e[0].z)
                                        var vb: float = _fv(f, nx, ny, ix + e[1].x, iy + e[1].y, iz + e[1].z)
                                        if (va < 0.0) != (vb < 0.0):
                                                var t := va / (va - vb)
                                                sum += base + Vector3(e[0]).lerp(Vector3(e[1]), t)
                                                cnt += 1
                                if cnt == 0:
                                        continue
                                var v := sum / float(cnt)
                                # Where the isosurface runs flush with the ground
                                # sheet (the "apron" band around openings), sink
                                # it 4 cm under the sheet: the sheet renders that
                                # surface outside the hole, the apron bridges the
                                # hole edge down to the tunnel wall, and the two
                                # never z-fight.
                                var sheet_d: float = v.y - p_terrain.height_at(Vector2(v.x, v.z))
                                if sheet_d > -0.5:
                                        v.y -= 0.04 * clampf(1.0 + sheet_d / 0.5, 0.0, 1.0)
                                var vi := lv.size()
                                cell_vert[ix + nx * (iy + ny * iz)] = vi
                                lv.append(v)
                                ln.append(p_terrain.implicit_normal(v))
                                var depth: float = p_terrain.height_at(Vector2(v.x, v.z)) - v.y
                                var shade: float = clampf(1.0 - depth / 30.0, 0.25, 1.0)
                                lc.append(Color(0.50 * shade, 0.485 * shade, 0.465 * shade))

        # One quad per OWNED lattice edge with a sign change (base point inside
        # the tile's 12 m span), joining its 4 adjacent cells.
        for iz in range(1, nz - 1):
                for iy in range(1, ny - 1):
                        for ix in range(1, nx - 1):
                                var f0 := _fv(f, nx, ny, ix, iy, iz)
                                # x-edge
                                if (f0 < 0.0) != (_fv(f, nx, ny, ix + 1, iy, iz) < 0.0):
                                        _emit_quad(cell_vert, nx, ny, li, [Vector3i(ix, iy - 1, iz - 1),
                                                        Vector3i(ix, iy, iz - 1), Vector3i(ix, iy, iz),
                                                        Vector3i(ix, iy - 1, iz)], f0 < 0.0)
                                # y-edge (cell order chosen so the quad winds
                                # counter-clockwise around +y, like the x/z edges)
                                if (f0 < 0.0) != (_fv(f, nx, ny, ix, iy + 1, iz) < 0.0):
                                        _emit_quad(cell_vert, nx, ny, li, [Vector3i(ix - 1, iy, iz - 1),
                                                        Vector3i(ix - 1, iy, iz), Vector3i(ix, iy, iz),
                                                        Vector3i(ix, iy, iz - 1)], f0 < 0.0)
                                # z-edge
                                if (f0 < 0.0) != (_fv(f, nx, ny, ix, iy, iz + 1) < 0.0):
                                        _emit_quad(cell_vert, nx, ny, li, [Vector3i(ix - 1, iy - 1, iz),
                                                        Vector3i(ix, iy - 1, iz), Vector3i(ix, iy, iz),
                                                        Vector3i(ix - 1, iy, iz)], f0 < 0.0)
        return {"verts": lv, "normals": ln, "colors": lc, "indices": li}

static func _append_cached(p_entry: Dictionary, r_verts: PackedVector3Array,
                r_normals: PackedVector3Array, r_colors: PackedColorArray,
                r_indices: PackedInt32Array) -> void:
        var off := r_verts.size()
        var li: PackedInt32Array = p_entry["indices"]
        for k in li.size():
                r_indices.append(li[k] + off)
        r_verts.append_array(p_entry["verts"])
        r_normals.append_array(p_entry["normals"])
        r_colors.append_array(p_entry["colors"])

## Edge corner offsets for the 12 cell edges (axis-aligned, values 0/1).
const _EDGES := [
        [Vector3i(0, 0, 0), Vector3i(1, 0, 0)],
        [Vector3i(0, 1, 0), Vector3i(1, 1, 0)],
        [Vector3i(0, 0, 1), Vector3i(1, 0, 1)],
        [Vector3i(0, 1, 1), Vector3i(1, 1, 1)],
        [Vector3i(0, 0, 0), Vector3i(0, 1, 0)],
        [Vector3i(1, 0, 0), Vector3i(1, 1, 0)],
        [Vector3i(0, 0, 1), Vector3i(0, 1, 1)],
        [Vector3i(1, 0, 1), Vector3i(1, 1, 1)],
        [Vector3i(0, 0, 0), Vector3i(0, 0, 1)],
        [Vector3i(1, 0, 0), Vector3i(1, 0, 1)],
        [Vector3i(0, 1, 0), Vector3i(0, 1, 1)],
        [Vector3i(1, 1, 0), Vector3i(1, 1, 1)],
]

## Emit one quad as two triangles. Winding flips with the sign at the edge
## start so faces always point from solid towards air.
static func _emit_quad(p_cell_vert: Dictionary, p_nx: int, p_ny: int,
                r_indices: PackedInt32Array, p_cells: Array, p_solid_at_start: bool) -> void:
        var ids := PackedInt32Array()
        for cell in p_cells:
                var c: Vector3i = cell
                var key := c.x + p_nx * (c.y + p_ny * c.z)
                if not p_cell_vert.has(key):
                        return
                ids.append(p_cell_vert[key])
        if ids.size() != 4:
                return
        if p_solid_at_start:
                r_indices.append(ids[0])
                r_indices.append(ids[1])
                r_indices.append(ids[2])
                r_indices.append(ids[0])
                r_indices.append(ids[2])
                r_indices.append(ids[3])
        else:
                r_indices.append(ids[2])
                r_indices.append(ids[1])
                r_indices.append(ids[0])
                r_indices.append(ids[3])
                r_indices.append(ids[2])
                r_indices.append(ids[0])
