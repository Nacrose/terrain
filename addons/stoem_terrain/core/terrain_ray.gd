@tool
class_name StoemTerrainRay
extends RefCounted
## Ray picking against the terrain-local implicit field, including carved air.

## Returns an empty dictionary on miss, or a local position and normal on hit.
static func pick(p_terrain, p_from: Vector3, p_dir: Vector3, p_max_dist: float = 800.0,
                p_heightfield_only: bool = false) -> Dictionary:
        if not p_from.is_finite() or not p_dir.is_finite() or p_dir.is_zero_approx() \
                        or not is_finite(p_max_dist) or p_max_dist <= 0.0:
                return {}
        var dir := p_dir.normalized()
        if p_terrain.contains_local_xz(Vector2(p_from.x, p_from.z)) \
                        and _field(p_terrain, p_from, p_heightfield_only) < 0.0:
                return {}
        var step := 0.8
        var distance := 0.0
        while distance < p_max_dist:
                var previous := distance
                distance = minf(distance + step, p_max_dist)
                var position := p_from + dir * distance
                if not p_terrain.contains_local_xz(Vector2(position.x, position.z)):
                        continue
                if _field(p_terrain, position, p_heightfield_only) < 0.0:
                        var low := previous
                        var high := distance
                        for iteration in range(14):
                                var middle := (low + high) * 0.5
                                var sample := p_from + dir * middle
                                if p_terrain.contains_local_xz(Vector2(sample.x, sample.z)) \
                                                and _field(p_terrain, sample, p_heightfield_only) < 0.0:
                                        high = middle
                                else:
                                        low = middle
                        var hit := p_from + dir * ((low + high) * 0.5)
                        var normal: Vector3 = p_terrain.implicit_normal(hit)
                        if p_heightfield_only:
                                normal = p_terrain.normal_at(Vector2(hit.x, hit.z))
                        return {"position": hit, "normal": normal}
        return {}

static func _field(p_terrain, p: Vector3, p_heightfield_only: bool) -> float:
        if p_heightfield_only:
                return p.y - p_terrain.height_at(Vector2(p.x, p.z))
        return p_terrain.implicit_F(p)
