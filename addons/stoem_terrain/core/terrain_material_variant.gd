@tool
class_name StoemTerrainMaterialVariant
extends Resource
## One coordinated visual treatment for a terrain material.

@export var stable_id: StringName = &""
@export var display_name: String = "Default"
@export var albedo: Texture2D
@export var normal_map: Texture2D
@export var roughness_map: Texture2D
@export var height_map: Texture2D
@export var ambient_occlusion_map: Texture2D
@export var weight: float = 1.0
@export var world_scale_m: float = 4.0
@export var tint: Color = Color.WHITE
@export_range(0.0, 2.0, 0.01) var normal_strength: float = 1.0
@export_range(0.0, 1.0, 0.01) var roughness: float = 1.0
