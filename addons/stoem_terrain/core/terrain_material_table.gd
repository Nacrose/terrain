@tool
class_name StoemTerrainMaterialTable
extends RefCounted
## Default material set and lookups. Ids are stable and match the biome ids
## produced by StoemTerrainData: 0 loam, 1 sand, 2 gravel, 3 clay, 4 granite,
## 5 scree, 6 snow.
##
## Field meanings (see StoemTerrainMaterial):
##   hardness            resistance to digging (shrinks effective brush radius)
##   cohesion_kpa        apparent cohesion (roof span limits)
##   friction_deg        internal friction angle
##   repose_deg          dry angle of repose (slump target)
##   permeability        saturated conductivity in m/s, used by drawdown
##   surface_friction    contact query value (not yet applied to rigid bodies)
##   digging_spoil_ratio swell factor: loose spoil volume / compact cut volume

const MatClass = preload("res://addons/stoem_terrain/core/terrain_material.gd")

const ID_LOAM := 0
const ID_SAND := 1
const ID_GRAVEL := 2
const ID_CLAY := 3
const ID_GRANITE := 4
const ID_SCREE := 5
const ID_SNOW := 6
const COUNT := 7

static var _table: Array = []

static func _make(p_key: StringName, p_hard: float, p_coh: float, p_fric: float,
		p_repose: float, p_perm: float, p_surf: float, p_swell: float) -> Resource:
	var m := MatClass.new()
	m.key = p_key
	m.display_name = String(p_key).capitalize()
	m.stable_id = StringName("stoem:" + String(p_key))
	m.hardness = p_hard
	m.cohesion_kpa = p_coh
	m.friction_deg = p_fric
	m.repose_deg = p_repose
	m.permeability = p_perm
	m.surface_friction = p_surf
	m.digging_spoil_ratio = p_swell
	match p_key:
		&"loam": m.preview_color = Color(0.416, 0.512, 0.290)
		&"sand": m.preview_color = Color(0.851, 0.757, 0.478)
		&"gravel": m.preview_color = Color(0.600, 0.557, 0.467)
		&"clay": m.preview_color = Color(0.706, 0.541, 0.353)
		&"granite": m.preview_color = Color(0.549, 0.549, 0.569)
		&"scree": m.preview_color = Color(0.710, 0.694, 0.655)
		&"snow": m.preview_color = Color(0.937, 0.953, 0.965)
	match p_key:
		&"sand":
			m.bulk_density_kg_m3 = 1600.0
			m.porosity = 0.36
		&"gravel":
			m.bulk_density_kg_m3 = 1750.0
			m.porosity = 0.28
		&"clay":
			m.bulk_density_kg_m3 = 1450.0
			m.porosity = 0.48
		&"granite":
			m.bulk_density_kg_m3 = 2700.0
			m.porosity = 0.02
		&"scree":
			m.bulk_density_kg_m3 = 1900.0
			m.porosity = 0.24
		&"snow":
			m.bulk_density_kg_m3 = 350.0
			m.porosity = 0.7
	return m

## Ordered by id (0..6).
static func table() -> Array:
	if _table.is_empty():
		_table = [
			_make(&"loam", 0.25, 25.0, 34.0, 33.0, 1.0e-5, 0.85, 1.20),
			_make(&"sand", 0.18, 0.0, 32.0, 34.0, 5.0e-3, 0.60, 1.12),
			_make(&"gravel", 0.45, 0.0, 36.0, 38.0, 5.0e-2, 0.75, 1.25),
			_make(&"clay", 0.50, 60.0, 26.0, 30.0, 1.0e-7, 0.70, 1.30),
			_make(&"granite", 1.00, 2000.0, 48.0, 60.0, 1.0e-9, 0.95, 1.45),
			_make(&"scree", 0.35, 0.0, 34.0, 36.0, 1.0e-2, 0.65, 1.18),
			_make(&"snow", 0.12, 8.0, 25.0, 28.0, 1.0e-4, 0.40, 1.05),
		]
	return _table

static func get_material(p_id: int) -> Resource:
	var t := table()
	return t[clampi(p_id, 0, t.size() - 1)]

static func key_for_id(p_id: int) -> StringName:
	var t := table()
	if p_id < 0 or p_id >= t.size():
		return &"loam"
	return t[p_id].key

static func id_for_key(p_key: StringName) -> int:
	var t := table()
	for i in t.size():
		if t[i].key == p_key:
			return i
	return 0

## Effective dig radius shrinks with hardness (granite barely yields).
static func effective_radius(p_radius: float, p_id: int) -> float:
	var m := get_material(p_id)
	return maxf(p_radius / (1.0 + 0.6 * m.hardness), 0.3)

## Saturation weakens the repose angle (pore pressure factor 0..1).
static func wet_repose_deg(p_id: int, p_pore: float) -> float:
	var m := get_material(p_id)
	return m.repose_deg * (1.0 - 0.45 * clampf(p_pore, 0.0, 1.0))

## Saturation weakens cohesion (wet roofs fail sooner).
static func wet_cohesion_kpa(p_id: int, p_pore: float) -> float:
	var m := get_material(p_id)
	return m.cohesion_kpa * (1.0 - 0.7 * clampf(p_pore, 0.0, 1.0))
