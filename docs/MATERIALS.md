# Terrain material authoring

Each terrain material is a shared resource in the terrain’s material catalog. Paint assignments refer to stable resource IDs, so renaming the display name or reordering the shelf does not change the saved material identity. Local pore state and painted appearance overrides are stored with terrain edits, not written back into the shared material.

## Supported physical values

| Property | Unit / meaning | Current consumer |
| --- | --- | --- |
| Hardness | Unitless gameplay resistance | Reduces effective dig-brush radius using the current empirical dig rule. |
| Cohesion | kPa | Roof support and collapse checks. |
| Internal friction | Degrees | Roof-support shear term. This is distinct from contact friction and angle of repose. |
| Repose angle | Degrees, dry | Slump target and spoil placement. |
| Permeability | m/s | Current water drawdown rate. The water model remains a simplified game simulation. |
| Surface friction | Unitless query value | Returned by `surface_physics_at`; not yet installed as a generic rigid-body contact override. |
| Spoil expansion | Loose volume / compact excavated volume | Dig and spoil placement volume estimate. |
| Bulk density | kg/m³ | `material_mass_kg` query. |
| Porosity | 0–1 | Returned by the surface-physics query; no separate saturation/retention model consumes it yet. |
| Wet repose reduction | 0–1 maximum reduction fraction | Scales the reduction in repose angle. An optional unit `Curve` shapes response by pore saturation; null preserves the legacy linear response. |
| Wet cohesion reduction | 0–1 maximum reduction fraction | Scales the reduction in cohesion. An optional unit `Curve` shapes response by pore saturation; null preserves the legacy linear response. |

These are implemented gameplay parameters, not a complete soil constitutive model. The optional moisture curves map normalized pore saturation (X) to a normalized wet-reduction multiplier (Y); both axes must stay within 0–1. Compaction, erosion, material-specific mixture mass accounting and per-body contact response remain planned work. Generated geology is still classified at 4 m resolution, while painted physical-material assignments and cover strata use the 1 m heightfield samples.

## Base material and surface cover

The terrain maps 4 m generated geology into 1 m physical-material assignments and supports up to four cover layers at each 1 m heightfield vertex. `material_id_at()` returns the top cover when present; `material_id_at_depth()` walks cover thickness from the surface, then returns the physical material or configured deep substrate. These are discrete nearest-vertex queries, so material and thin-cover edges can step at the 1 m sample scale. Repose and cohesion curves are editable in each material's Water Response group; catalog duplication creates independent curve resources.

The **Deposit** tool adds a radial mound, records the same per-sample thickness as cover, and supports one undo step per drag. Different materials form separate strata. A full four-layer stack rejects a deposit atomically. Enable **Reclassify existing cover** when replacing the old stack is intended; this preserves total thickness and adds the new mound while assigning the covered volume to the chosen material. Dig consumes cover top-first and exposes the lower layer, base override or configured substrate. The current generated spoil ring reclassifies its local cover to the single material selected for that dig operation.

Regular **Paint** changes the base material and appearance; it leaves existing cover in place. It does not add geometry or change cover thickness. The saved terrain-edit schema is version 7 and maps 1 m physical samples and cover-layer material slots through stable catalog IDs; version 0–6 files remain accepted.

## Texture sets

A texture set keeps albedo, normal, roughness, height and ambient-occlusion maps together. `world_scale_m` controls metre-scale tiling; tint, roughness and normal strength are shared by the set. Weighted random selection is deterministic for a terrain seed, stable material ID and spatial patch. Set `appearance_patch_size_m` on the material to change the patch size. A chosen set is persisted as its stable variant ID; an empty appearance override means weighted variation.

Use the Paint dock’s **Material + texture** mode to update physical identity and appearance together. **Texture only** changes appearance on cells already using the selected material. It skips cells whose physical material differs and is undoable.

## Creating and saving

Use **Create**, **Duplicate**, **Add Texture Set**, **Edit Properties**, **Export Material** and **Import Material** in the dock. Create, duplicate, import, archive/restore and Add Texture Set actions use Godot's editor undo history. Export writes the selected material as a `.tres` resource. Import validates a material preset, creates fresh material and texture-set IDs, and keeps texture files shared by reference. **Export Library** saves the full catalog as a `.tres` resource; **Merge Library** adds materials whose stable IDs are not already present, preserves their IDs and archived shelf state, and skips collisions without replacing existing definitions. This makes repeated merges idempotent. The merge is one undoable catalog action. Use single-material import when you want a new independent identity instead of merging an existing library identity. **Replace base uses of** remaps matching 1 m material samples on the selected terrain to the selected paint material as one undoable edit; cover layers are preserved. **Archive selected** hides a material from the default shelf without deleting its catalog slot or changing terrain/save references; **Show archived** lets you restore it. The usage summary aggregates the selected stable material ID across matching terrain nodes in the open scene, including nodes with separate catalogs; it does not scan unopened scene files. Duplicate also creates independent editable resources. Save the scene after creating or editing catalog resources so the project keeps the catalog and its assets. Save the terrain edit resource and then save the scene to establish its startup link.
