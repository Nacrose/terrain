# Implementation status

Updated: 15 November 2026. Source: the local Terrain repair copy, compared against the unmodified extracted addon. The supplied ZIP remains unchanged.

## Completed and verified in this build

### Terrain correctness and editor interaction (M1)

- Chunk-edge geometry and normal invalidation, slope refresh, carve replacement/undo invalidation, full-chunk empty meshes, collision refresh/disable ownership, transformed sampling/rays/normals, out-of-bounds rays, material snapshot synchronization, outer material edges, water-overlay refresh, repeat-build river reset and public argument validation were repaired in the implementation copy.
- Mouse strokes now capture the active tool and paint settings; cancellation rolls back the active edit; selection is inactive by default; Alt navigation passes through; first dig clicks are not swallowed by a stale throttle; editor callbacks check live terrain references.
- Coarse sample centers are corrected for newly generated terrain. Sampling schema v1 retains the legacy convention for older edit resources.
- Edit files validate before mutation, use schema v7 stable material/appearance/cover identities, and write through a temporary file. Schema v0–v6 resources remain accepted; legacy 4 m material assignments expand to the matching 1 m samples on load. Save/load failures are reported by the panel.
- Saved edit resources can be linked to a terrain node and are restored before its final `baked` signal. The editor records the resource link in scene undo history; the scene must be saved after the link is created.

### Material catalog baseline (M2, partial)

- Seven legacy built-in slots retain their identities. New materials receive stable IDs and can be duplicated without sharing mutable material/variant controls. Texture resources are shared on duplicate by design.
- Material resources expose the physical values consumed by the current terrain model: hardness, cohesion, internal friction, repose, hydraulic permeability, contact-friction query value, spoil expansion, bulk density, porosity and wet reductions. Density feeds mass queries; optional moisture response curves shape the wet repose/cohesion reductions used by stability; dig/material queries use the catalog.
- Complete texture-set resources support albedo, normal, roughness, height and ambient-occlusion maps, metre-based tiling, tint, roughness and normal strength.
- Create, duplicate, edit and texture-set controls are available in the terrain dock. Material and appearance assignments persist by stable ID.
- The dock aggregates cached 1 m material-sample and cover-layer usage for the selected stable material ID across terrain nodes in the currently open scene, including separate catalogs that contain that ID. It does not scan other scene files.
- Material presets export as `.tres` resources and import as independent catalog copies with regenerated stable material and texture-set IDs. Full catalog libraries can also be exported and merged: new materials preserve their stable IDs and archived state, matching IDs are skipped, invalid libraries leave the destination unchanged, and repeated merges do not duplicate entries. Both single-material import and catalog merge validation are covered by focused checks.
- Materials can be archived from the default paint shelf and restored later. Archiving preserves the slot, stable ID, existing terrain assignments and saved edit references; it does not delete or reassign material data.
- **Replace base uses** reassigns matching 1 m material samples on the selected terrain to the currently selected paint material. It is one undoable terrain edit; cover layers and other terrain nodes are untouched.
- Create, duplicate, import, archive/restore, catalog-library merge and Add Texture Set now register actions with Godot's scene-aware editor undo history. Direct Inspector property edits have not been manually checked in a native editor session.

### Surface cover, deposits and depth queries (M3, partial)

- The procedural geology is generated at 4 m resolution, then material paint/override assignments are stored on a 1 m sample grid. Up to four ordered cover strata are stored at each 1 m heightfield vertex. Surface and depth queries resolve the cover stack before the physical material field and configured deep substrate.
- The separate Deposit tool adds a radial mound and records matching per-sample cover thickness. Different materials stack as separate layers; a full stack refuses the deposit atomically unless the user explicitly enables reclassification.
- Digging consumes cover from the top down, so the exposed surface changes to the lower material as its overburden is removed. The generated spoil ring records its material as one reclassified surface layer.
- Material and cover edits participate in stroke undo/redo. Edit schema v7 stores 1 m physical-material assignments plus four stable-ID cover slots and four depths per changed sample. Schema v0–v6 material assignments migrate from their 4 m cells.
- Surface and physical-material queries use nearest 1 m heightfield samples. Mass-conserving mixtures, deeper geology and contact-level friction are not implemented.

### Appearance painting and basic dock UX (M4/M5, partial)

- Selected texture-set painting, deterministic weighted selection, configurable coherent patches and appearance-only painting are implemented. Appearance-only edits preserve physical identity and participate in undo/redo.
- Rendered terrain chunks are partitioned by physical material/appearance variant and receive texture materials. A numeric metre-valued radius control accompanies the slider.
- The editor UX regression harness covers tool forwarding, selection/navigation behavior and stroke handling. Texture assignment is asserted on generated mesh surfaces.

## Verification evidence

Ran with Godot 4.7.2 on the supplied project’s Compatibility renderer setting:

- Earlier `tests/run.gd` and `tests/regressions.gd` runs passed 229 acceptance assertions and 73 focused checks. They predate the latest schema-v7/material-library changes and were not rerun in this continuation.
- `tests/ux_probe.gd`: current editor-input probes pass, including open-scene usage aggregation, catalog create/texture-set undo/redo and material-library merge undo/redo. These are scripted probes, not a manual mouse/keyboard session in a running native editor.
- `tests/material_catalog.gd`: focused catalog, texture, appearance-only, usage count, deposit, stacked-depth query, excavation, full-stack, undo/redo, stable-ID persistence, preset import/export, catalog library merge, base replacement, archive/restore and scene-linked startup checks pass with 0 failures.
- `--headless --editor --path . --quit`: editor scan completes without script parse errors. This scan also caught and led to removal of unsupported `@export_tooltip` annotations in the material resource.

Native editor dispatch and visual viewport review remain unverified.

In this sandbox, Godot prints `user://` application-data and macOS certificate-store errors because those host locations are outside the writable project. The headless editor UX harness also prints RID/ObjectDB shutdown leak diagnostics after its assertions pass; treat those as an unresolved harness/editor shutdown warning until checked in a native session. Automated probes complete with exit code 0. This environment has not provided a visual viewport review or a manual native editor dispatch test.

## Remaining roadmap

| Milestone | State | Main remaining work |
| --- | --- | --- |
| M0 source/build baseline | Verified | Local baseline is Godot 4.7.2; no broader platform claim. |
| M1 terrain repair | Verified by supplied and focused suites; native editor dispatch unverified | Manual editor navigation, multiple scenes/terrains, scene reopen in an actual user project. |
| M2 material catalog | Partial | Preset and full-library export/import/merge, open-scene usage counts, reversible shelf archiving, selected-terrain 1 m sample replacement and editor undo for catalog actions are implemented. All-project usage counts, cover-layer/cross-terrain remapping and native Inspector undo review remain. |
| M3 depth/physical behavior | Partial | 1 m physical-material assignments plus up to four 1 m cover layers, depth queries, deposits, top-first excavation, editable moisture-response curves, undo/redo and schema-v7 persistence are implemented. Material-specific mass balance, deeper physical strata and rigid-body material contacts remain. |
| M4 material appearance | Partial | Slope-aware blending, cave-wall variants, import validation, bounded resident texture library, real viewport visual QA and appearance edits without unnecessary collision work. |
| M5 complete editor UX | Partial | Contextual CAD-style tool rail/settings, persistent preferences, preview/cancel for all operations, high-DPI/narrow-dock/theme checks and onboarding scene. |
| M6 configurable authoring | Not implemented | Terrain dimensions, heightmap import/export, generation preview/recovery, protected authoring layers, filters/masks and explicit cave fill policy. |
| M7 large-world performance | Not implemented | Measured baselines, job queues, LOD, collision distance, streaming and bounded resource soak. |
| M8 integration contracts | Not implemented | Versioned environment/wind/fire/navigation contracts and optional-provider tests. |
| M9 companion plugins | Not implemented | Separate Nepal forest, grass/wind and wildlife addons; the twenty-tree and local-shrub content requirements remain open. |
| M10 advanced authoring/simulation | Not implemented | Roads/trails, edit layers, contours/cross-sections, regional regeneration, erosion and richer hydrology. |
| M11 full release | Partial | This clean terrain addon package exists. Companion packages, demo, manual editor/render QA, performance report and license/provenance review remain. |

The generated geology and climate inputs remain at 4 m resolution; painted physical material assignments and surface cover use the existing 1 m heightfield sample grid. `surface_friction` is a query value; it is not yet applied as a distinct rigid-body contact response. No geotechnical accuracy claim is made.
