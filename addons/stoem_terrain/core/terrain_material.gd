@tool
class_name StoemTerrainMaterial
extends Resource
## Reusable terrain material definition. Physical properties are shared by all
## locations using this resource; local wetness and cover depth live in terrain data.

@export_group("Identity")
@export var stable_id: StringName = &""
@export var key: StringName = &"loam"
@export var display_name: String = "Loam"
@export_multiline var description: String = ""
@export var tags: PackedStringArray = PackedStringArray()
@export_group("Appearance")
@export var preview_color: Color = Color(0.5, 0.5, 0.5)
@export_range(1.0, 256.0, 1.0, "suffix:m") var appearance_patch_size_m: float = 16.0

# Appearance variants are complete texture sets. A renderer chooses a variant
# deterministically and samples every map from that same entry.
@export var variants: Array[Resource] = []

@export_group("Digging and stability")
# Dimensionless gameplay resistance; currently reduces effective dig-brush radius.
@export var hardness: float = 0.25
# Apparent cohesion in kPa, consumed by the roof-support model.
@export var cohesion_kpa: float = 25.0
# Internal friction angle in degrees, consumed by roof-support shear.
@export var friction_deg: float = 34.0
# Dry repose angle in degrees, consumed by slump and spoil placement.
@export var repose_deg: float = 33.0
# Saturated hydraulic conductivity in m/s, used by the current drawdown model.
@export_group("Water response")
@export var permeability: float = 1.0e-5
# Maximum reduction fraction at full response, used by stability.
@export_range(0.0, 1.0, 0.01) var wet_repose_reduction: float = 0.45
@export_range(0.0, 1.0, 0.01) var wet_cohesion_reduction: float = 0.70
# Optional unit curves: X = normalized pore saturation, Y = multiplier for the
# maximum wet reduction above. Null preserves the legacy linear response.
@export_tooltip("X: normalized pore saturation (0–1). Y: multiplier for the maximum wet repose reduction (0–1). Null uses a linear response.")
@export var wet_repose_response: Curve
@export_tooltip("X: normalized pore saturation (0–1). Y: multiplier for the maximum wet cohesion reduction (0–1). Null uses a linear response.")
@export var wet_cohesion_response: Curve
@export_range(0.0, 1.0, 0.01) var porosity: float = 0.42

@export_group("Mass and contact queries")
# Returned by the surface query; not yet applied to generic rigid-body contacts.
@export var surface_friction: float = 0.85
# Loose spoil volume divided by compact excavated volume.
@export var digging_spoil_ratio: float = 1.20
# Dry bulk density in kg/m^3, consumed by material_mass_kg().
@export var bulk_density_kg_m3: float = 1400.0

func _init() -> void:
	# Start new and legacy-loaded materials with editable curves that reproduce
	# the prior linear response exactly.
	wet_repose_response = _new_linear_response_curve()
	wet_cohesion_response = _new_linear_response_curve()

static func _new_linear_response_curve() -> Curve:
	var response := Curve.new()
	response.add_point(Vector2(0.0, 0.0), 0.0, 0.0,
			Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	response.add_point(Vector2(1.0, 1.0), 0.0, 0.0,
			Curve.TANGENT_LINEAR, Curve.TANGENT_LINEAR)
	return response
