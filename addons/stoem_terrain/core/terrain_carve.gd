@tool
class_name StoemTerrainCarve
extends RefCounted
## Analytic carve set: subtractive spheres and capsules ("bores") in centred world
## metres. This is pure maths, not voxels: a tunnel is one capsule (7 floats), a
## cave chamber is one sphere (4 floats). The spatial hash is only an index over
## the primitives, never sample data.
##
## sdf(p) convention: POSITIVE inside carved air, negative outside. The terrain's
## implicit solid function is F(p) = max(p.y - height(x, z), sdf(p)) < 0.

const CELL := 12.0

var spheres := PackedFloat32Array()    # stride 4: cx, cy, cz, r
var capsules := PackedFloat32Array()   # stride 7: ax, ay, az, r, bx, by, bz

var _sph_hash := {}                    # Vector2i -> PackedInt32Array (sphere rows)
var _cap_hash := {}                    # Vector2i -> PackedInt32Array (capsule rows)
var _bounds_min := Vector3(1e9, 1e9, 1e9)
var _bounds_max := Vector3(-1e9, -1e9, -1e9)
var _bounds_valid := false

func clear() -> void:
        spheres.resize(0)
        capsules.resize(0)
        _sph_hash.clear()
        _cap_hash.clear()
        _bounds_valid = false

func has_carve() -> bool:
        return spheres.size() > 0 or capsules.size() > 0

func sphere_count() -> int:
        return spheres.size() / 4

func capsule_count() -> int:
        return capsules.size() / 7

# ---------------------------------------------------------------- primitives

func add_sphere(p_center: Vector3, p_radius: float) -> void:
        if not p_center.is_finite() or not is_finite(p_radius) or p_radius <= 0.05:
                return
        spheres.append(p_center.x)
        spheres.append(p_center.y)
        spheres.append(p_center.z)
        spheres.append(p_radius)
        # Hash rows are primitive INDICES (sphere_sdf multiplies by the stride).
        var row := sphere_count() - 1
        _register_box(_sph_hash, row, p_center - Vector3.ONE * p_radius, p_center + Vector3.ONE * p_radius)
        _grow_bounds(p_center - Vector3.ONE * p_radius, p_center + Vector3.ONE * p_radius)

func add_capsule(p_a: Vector3, p_b: Vector3, p_radius: float) -> void:
        if not p_a.is_finite() or not p_b.is_finite() or not is_finite(p_radius) or p_radius <= 0.05:
                return
        capsules.append(p_a.x)
        capsules.append(p_a.y)
        capsules.append(p_a.z)
        capsules.append(p_radius)
        capsules.append(p_b.x)
        capsules.append(p_b.y)
        capsules.append(p_b.z)
        var bmin := p_a.min(p_b) - Vector3.ONE * p_radius
        var bmax := p_a.max(p_b) + Vector3.ONE * p_radius
        # Hash rows are primitive INDICES (capsule_sdf multiplies by the stride).
        _register_box(_cap_hash, capsule_count() - 1, bmin, bmax)
        _grow_bounds(bmin, bmax)

## Re-add a raw sphere row (undo support). Row = PackedFloat32Array [cx, cy, cz, r].
func add_sphere_row(p_row: PackedFloat32Array) -> void:
        if p_row.size() != 4:
                return
        add_sphere(Vector3(p_row[0], p_row[1], p_row[2]), p_row[3])

func add_capsule_row(p_row: PackedFloat32Array) -> void:
        if p_row.size() != 7:
                return
        add_capsule(Vector3(p_row[0], p_row[1], p_row[2]), Vector3(p_row[4], p_row[5], p_row[6]), p_row[3])

func _sphere_row(p_i: int) -> PackedFloat32Array:
        var row := PackedFloat32Array()
        var o := p_i * 4
        for k in 4:
                row.append(spheres[o + k])
        return row

func _capsule_row(p_i: int) -> PackedFloat32Array:
        var row := PackedFloat32Array()
        var o := p_i * 7
        for k in 7:
                row.append(capsules[o + k])
        return row

## Remove one sphere by index (swap-remove + hash rebuild). Returns the removed row.
func remove_sphere(p_i: int) -> PackedFloat32Array:
        if p_i < 0 or p_i >= sphere_count():
                return PackedFloat32Array()
        var row := _sphere_row(p_i)
        var last := sphere_count() - 1
        if p_i != last:
                for k in 4:
                        spheres[p_i * 4 + k] = spheres[last * 4 + k]
        spheres.resize(spheres.size() - 4)
        rebuild_hash()
        return row

func remove_capsule(p_i: int) -> PackedFloat32Array:
        if p_i < 0 or p_i >= capsule_count():
                return PackedFloat32Array()
        var row := _capsule_row(p_i)
        var last := capsule_count() - 1
        if p_i != last:
                for k in 7:
                        capsules[p_i * 7 + k] = capsules[last * 7 + k]
        capsules.resize(capsules.size() - 7)
        rebuild_hash()
        return row

## Remove the sphere matching a serialized row exactly (undo support).
func remove_sphere_row(p_row: PackedFloat32Array) -> bool:
        if p_row.size() != 4:
                return false
        for i in sphere_count():
                var o := i * 4
                var is_match := true
                for k in 4:
                        if spheres[o + k] != p_row[k]:
                                is_match = false
                                break
                if is_match:
                        remove_sphere(i)
                        return true
        return false

func remove_capsule_row(p_row: PackedFloat32Array) -> bool:
        if p_row.size() != 7:
                return false
        for i in capsule_count():
                var o := i * 7
                var is_match := true
                for k in 7:
                        if capsules[o + k] != p_row[k]:
                                is_match = false
                                break
                if is_match:
                        remove_capsule(i)
                        return true
        return false

# ---------------------------------------------------------------- spatial hash

func _register_box(p_hash: Dictionary, p_row: int, p_bmin: Vector3, p_bmax: Vector3) -> void:
        var c0 := _cell_of(p_bmin)
        var c1 := _cell_of(p_bmax)
        for cz in range(c0.y, c1.y + 1):
                for cx in range(c0.x, c1.x + 1):
                        var key := Vector2i(cx, cz)
                        if not p_hash.has(key):
                                p_hash[key] = PackedInt32Array([p_row])
                        else:
                                p_hash[key].append(p_row)

func _cell_of(p: Vector3) -> Vector2i:
        return Vector2i(floori(p.x / CELL), floori(p.z / CELL))

func rebuild_hash() -> void:
        _sph_hash.clear()
        _cap_hash.clear()
        _bounds_valid = false
        for i in sphere_count():
                var o := i * 4
                var c := Vector3(spheres[o], spheres[o + 1], spheres[o + 2])
                var r := spheres[o + 3]
                _register_box(_sph_hash, i, c - Vector3.ONE * r, c + Vector3.ONE * r)
                _grow_bounds(c - Vector3.ONE * r, c + Vector3.ONE * r)
        for i in capsule_count():
                var o := i * 7
                var a := Vector3(capsules[o], capsules[o + 1], capsules[o + 2])
                var r := capsules[o + 3]
                var b := Vector3(capsules[o + 4], capsules[o + 5], capsules[o + 6])
                _register_box(_cap_hash, i, a.min(b) - Vector3.ONE * r, a.max(b) + Vector3.ONE * r)
                _grow_bounds(a.min(b) - Vector3.ONE * r, a.max(b) + Vector3.ONE * r)

func _grow_bounds(p_bmin: Vector3, p_bmax: Vector3) -> void:
        if not _bounds_valid:
                _bounds_min = p_bmin
                _bounds_max = p_bmax
                _bounds_valid = true
        else:
                _bounds_min = _bounds_min.min(p_bmin)
                _bounds_max = _bounds_max.max(p_bmax)

func bounds() -> Rect2:
        if not _bounds_valid:
                return Rect2()
        return Rect2(Vector2(_bounds_min.x - 1.0, _bounds_min.z - 1.0),
                        Vector2(_bounds_max.x - _bounds_min.x + 2.0, _bounds_max.z - _bounds_min.z + 2.0))

# ---------------------------------------------------------------- queries

func sphere_sdf(p_i: int, p: Vector3) -> float:
        var o := p_i * 4
        var dx := p.x - spheres[o]
        var dy := p.y - spheres[o + 1]
        var dz := p.z - spheres[o + 2]
        return spheres[o + 3] - sqrt(dx * dx + dy * dy + dz * dz)

func capsule_sdf(p_i: int, p: Vector3) -> float:
        var o := p_i * 7
        var a := Vector3(capsules[o], capsules[o + 1], capsules[o + 2])
        var b := Vector3(capsules[o + 4], capsules[o + 5], capsules[o + 6])
        var ab := b - a
        var l2 := maxf(ab.length_squared(), 1.0e-9)
        var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
        var proj := a + ab * t
        return capsules[o + 3] - (p - proj).length()

## Signed value of the carve set: positive inside carved air, negative outside.
## Scans the 3x3 hash neighbourhood, which is exact for the inside test and a good
## local approximation of wall distance for solid points.
func sdf(p: Vector3) -> float:
        if not _bounds_valid:
                return -1000.0
        if p.x < _bounds_min.x - 1.5 or p.x > _bounds_max.x + 1.5 \
                        or p.y < _bounds_min.y - 1.5 or p.y > _bounds_max.y + 1.5 \
                        or p.z < _bounds_min.z - 1.5 or p.z > _bounds_max.z + 1.5:
                return -1000.0
        var best := -1000.0
        var cx := floori(p.x / CELL)
        var cz := floori(p.z / CELL)
        for dz in range(-1, 2):
                for dx in range(-1, 2):
                        var key := Vector2i(cx + dx, cz + dz)
                        if _sph_hash.has(key):
                                var rows: PackedInt32Array = _sph_hash[key]
                                for i in rows.size():
                                        best = maxf(best, sphere_sdf(rows[i], p))
                        if _cap_hash.has(key):
                                var crows: PackedInt32Array = _cap_hash[key]
                                for i in crows.size():
                                        best = maxf(best, capsule_sdf(crows[i], p))
        return best

## Carve a spherical void if the spot is not already carved. Returns true if added.
func carve_sphere(p_center: Vector3, p_radius: float) -> bool:
        if not p_center.is_finite() or not is_finite(p_radius) or p_radius <= 0.05:
                return false
        if sdf(p_center) > p_radius - 0.05:
                return false
        add_sphere(p_center, p_radius)
        return true

## Any primitive's horizontal footprint intersecting this world rect?
func intersects_rect(p_rect: Rect2) -> bool:
        for i in sphere_count():
                var o := i * 4
                var cx := spheres[o]
                var cz := spheres[o + 2]
                var r := spheres[o + 3]
                if p_rect.intersects(Rect2(cx - r, cz - r, r * 2.0, r * 2.0)):
                        return true
        for i in capsule_count():
                var o := i * 7
                var ax := capsules[o]
                var az := capsules[o + 2]
                var bx := capsules[o + 4]
                var bz := capsules[o + 6]
                var r := capsules[o + 3]
                var minx := minf(ax, bx) - r
                var maxx := maxf(ax, bx) + r
                var minz := minf(az, bz) - r
                var maxz := maxf(az, bz) + r
                if p_rect.intersects(Rect2(minx, minz, maxx - minx, maxz - minz)):
                        return true
        return false

## Primitive rows (indices) registered in one 12 m hash cell: exactly the
## primitives whose footprint overlaps that cell. Tiled cave meshing and
## carve-aware digging sample only these rows (no hash scans per sample).
func rows_near_cell(p_key: Vector2i) -> Dictionary:
        var out := {"sph": PackedInt32Array(), "cap": PackedInt32Array()}
        if _sph_hash.has(p_key):
                out["sph"] = _sph_hash[p_key]
        if _cap_hash.has(p_key):
                out["cap"] = _cap_hash[p_key]
        return out

## Union sdf of the given rows only. Rows not overlapping a query region can
## never make it positive there, so tile-local sampling is sign-exact inside
## the tile; it only smooths distance values near tile borders (vertex
## placement stays within one lattice cell of the true surface).
func sdf_rows(p: Vector3, p_sph: PackedInt32Array, p_cap: PackedInt32Array) -> float:
        var best := -1000.0
        for q in p_sph.size():
                best = maxf(best, sphere_sdf(p_sph[q], p))
        for q in p_cap.size():
                best = maxf(best, capsule_sdf(p_cap[q], p))
        return best

## Serialized form: [sph_count, spheres..., cap_count, capsules...].
func serialize() -> PackedFloat32Array:
        var out := PackedFloat32Array()
        out.append(float(sphere_count()))
        out.append_array(spheres)
        out.append(float(capsule_count()))
        out.append_array(capsules)
        return out

static func valid_rows(p_rows: PackedFloat32Array, p_stride: int) -> bool:
        if p_rows.size() % p_stride != 0:
                return false
        for i in p_rows.size():
                if not is_finite(p_rows[i]):
                        return false
                if i % p_stride == 3 and p_rows[i] <= 0.05:
                        return false
        return true

static func valid_payload(p_data: PackedFloat32Array) -> bool:
        if p_data.size() < 2:
                return false
        if not is_finite(p_data[0]) or p_data[0] < 0 or p_data[0] != floorf(p_data[0]):
                return false
        if p_data[0] > (p_data.size() - 2) / 4:
                return false
        var sc := int(p_data[0])
        var count_offset := 1 + sc * 4
        var count := p_data[count_offset]
        if not is_finite(count) or count < 0 or count != floorf(count):
                return false
        if count != float(p_data.size() - count_offset - 1) / 7.0:
                return false
        return valid_rows(p_data.slice(1, count_offset), 4) \
                and valid_rows(p_data.slice(count_offset + 1), 7)

func deserialize(p_data: PackedFloat32Array) -> bool:
        if not valid_payload(p_data):
                return false
        var sc := int(p_data[0])
        var cc := int(p_data[1 + sc * 4])
        spheres = p_data.slice(1, 1 + sc * 4)
        capsules = p_data.slice(2 + sc * 4, 2 + sc * 4 + cc * 7)
        rebuild_hash()
        return true
