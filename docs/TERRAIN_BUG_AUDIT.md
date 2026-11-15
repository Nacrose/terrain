# Terrain plugin bug audit: original-source baseline

Status: historical baseline audit. Implementation was approved and is in progress; use the repository-root `IMPLEMENTATION_STATUS.md` for current fixed/open states. Reviewed original archive: `stoem-terrain.zip`, version 2.3.2. Engine used for the baseline probes: Godot 4.7.2, macOS, headless. This report describes the supplied source before repairs.

The original ZIP remains unchanged outside this repository. A separate repair copy was used during development; the tracked addon in this repository is the current implementation. B01–B27 findings below are baseline issue statements and do not by themselves indicate whether a finding remains open. Check `IMPLEMENTATION_STATUS.md` and the latest test evidence before acting on an item.

## Evidence and limits

The supplied acceptance suite passed 204 assertions; the supplied UX suite passed 31. Additional probes against the original addon nevertheless reproduced the failures below. Passing the existing suites therefore does not establish that the addon is ready for production.

The tests were run in a scratch project. The acceptance runner redirected test save paths from `user://` into the scratch project because the sandbox could not create the application's normal data directory. Environment logs also include macOS certificate-access errors. The UX harness leaves objects/resources alive at shutdown; those leak messages have not been isolated to normal plugin use.

Native editor event dispatch, visual rendering, actual physics contacts, exported games, GPU performance, and other Godot versions remain unverified. The UX tests call the input handler directly. An audit cannot prove the absence of every possible bug; this is the current actionable inventory, with uncertainty called out.

Source locations below are relative to `addons/stoem_terrain/` in the original archive. P1 means state corruption, lost work, collision or terrain correctness; P2 means incorrect behavior or significant usability; P3 means lower-impact cleanup. “Reproduced” means a runtime probe observed the failure. “Source” means the code path supports the finding, with a dedicated regression still needed.

## Reproduced findings

| ID | Priority | Finding and evidence | Proposed repair |
| --- | --- | --- | --- |
| B01 | P1 | **Chunk seams after editing.** A shared-edge vertex rose from 46.547 to 49.747 m in one chunk; its neighbor stayed at 46.547 m, producing a 3.2 m crack. `_mark_cell_dirty()` marks only one chunk. `nodes/terrain_3d.gd:1052`. | Invalidate every chunk sharing the changed vertex and every chunk whose normal calculation uses it. Cover edges, corners, and the one-cell normal stencil. |
| B02 | P1 | **Collision refresh duplicates shapes; disabling leaves collision behind.** Shape count went 256 → 512 after refresh and remained 256 after disable. References are cleared before old shapes are removed. `nodes/terrain_3d.gd:1226,1250`. | Reuse or explicitly remove owned shapes. Make enable, refresh, disable and rebake idempotent. Verify physics behavior as well as node counts. |
| B03 | P1 | **Clearing caves leaves holes in the ground mesh.** Queries reported a closed surface, but the chunk stayed at 13,632 indices instead of the intact 13,824. No region event was emitted. `nodes/terrain_3d.gd:970`. | Invalidate the union of old and new carve bounds, restore ground and collision, then emit change notifications. Include moving/replacing all caves. |
| B04 | P2 | **Material snapshots disagree with the displayed terrain data.** Material query became sand while biome remained loam. `nodes/terrain_3d.gd:921`. | Apply snapshots through shared synchronization logic for overrides, biome/color data, dirty meshes and notifications. |
| B05 | P2 | **Direct material override emits no change notification.** Probe observed zero `edited_region` signals. `nodes/terrain_3d.gd:528`. | Define and implement a consistent external mutation contract, including mesh refresh and a bounded event. Preserve the existing non-undo setter behavior unless intentionally changed. |
| B06 | P1 | **World-named queries ignore terrain transforms.** With terrain translated upward 100 m, reported height remained 4.131 m while the surface was at 104.131 m. `nodes/terrain_3d.gd:226`; editor picking also passes world rays into the local query path at `plugin.gd:77`. | Keep internal math local; add explicit world conversion for queries, picking and returned normals. Define supported rotations/scales rather than silently giving wrong results. |
| B07 | P2 | **Raycasts hit nonexistent terrain outside the map.** A ray at x = 1,000 hit despite the map ending at x = 384. Clamped height samples act like an infinite extension. `core/terrain_ray.gd:9`. | Clip ray queries to terrain bounds and define out-of-bounds behavior consistently. Retain clamped sampling only where explicitly intended. |
| B08 | P1 | **Load publishes unfinished state.** `baked` observers saw height 46.547 m, then `edited_region` observers saw the restored 49.747 m. `load_edits()` calls the signal-emitting bake before restoring edits. `nodes/terrain_3d.gd:1001`. | Restore and synchronize a complete state before publishing completion. Document event order for vegetation and other consumers. |
| B09 | P1 workflow gap | **Normal scene saving does not preserve terrain edits.** Packing succeeded, but the instantiated terrain had null data; `_ready()` regenerates it. The separate Save Edits workflow exists, but there is no persistent startup edit-resource reference. `nodes/terrain_3d.gd:96,982`. | Establish a scene-linked edits resource with an explicit, reliable save/reload lifecycle and dirty-state feedback. Keep the external edit-file workflow compatible. Test scene reopen and exported runtime. |

## Additional source findings

| ID | Priority | Finding | Proposed repair / verification |
| --- | --- | --- | --- |
| B10 | P1 | **Load and snapshot validation is incomplete.** Array lengths, encoded materials, finite values, primitive counts/strides and versions are insufficiently checked. `load_edits()` rebakes before completing validation; malformed input can leave partial state. `nodes/terrain_3d.gd:921,942,1001`; `core/terrain_carve.gd:309`. | Validate the whole payload before mutation. Reject invalid data with a useful error and preserve current terrain, undo history and saved files. Preserve valid legacy schemas, including version 0 covered by the supplied tests. |
| B11 | P1/P2 | **Persistence reliability needs repair.** Writer sets version 1 although the resource defaults to 2; loads use the default resource cache; writes go directly to the destination. UI discards save/load return codes. `nodes/terrain_3d.gd:982`; `ui/sculpt_panel.gd:270`. | Specify schema/migrations; test repeated save/load of one path; load fresh contents when required; use temporary-file replacement with checked errors; show failures without reporting success. Filesystem failure cases need reproduction. |
| B12 | P2 | **Carve snapshots do not invalidate ground openings.** `_apply_serialized_prims()` sets cave-dirty only. `nodes/terrain_3d.gd:942`. | Route primitive additions/removals through affected-bounds invalidation; verify ground, cave mesh, physics, undo and events agree. |
| B13 | P2 | **Slope data becomes stale after height changes.** Build computes `data.slope`; height writes update heights and dirty chunks only, while terrain color consumes cached slope. `core/terrain_data.gd:112`; `nodes/terrain_3d.gd:706`; `core/terrain_mesh.gd:38`. | Recompute affected derivative data with the required neighbor halo for sculpt, dig, collapse, snapshots, undo/redo and load. |
| B14 | P2 | **The last map row/column is missed by material synchronization.** Coarse 4 m cells update four vertices each; the terminal vertex at index 768 is excluded. `nodes/terrain_3d.gd:751`. | Include terminal border vertices and all sharing chunks. Test each outer edge and corner. |
| B15 | P2 | **Coarse-field sampling is offset.** Values are generated at cell centers but sampled as if located at grid origins, shifting interpolation by half a cell (2 m). `core/terrain_data.gd:80,204`. | Correct the coordinate convention with boundary tests. Preserve old terrain appearance through versioned generation/sampling or a documented opt-in migration; do not silently reinterpret old saves. |
| B16 | P2 | **Water debug overlay does not hide when disabled and can be stale after undo.** Setter only rebuilds when enabled; undo applies water state without refreshing the overlay. `nodes/terrain_3d.gd:861,1265`. | Synchronize visibility and geometry on all relevant state changes. |
| B17 | P2 | **Empty ground chunks lack an explicit empty-mesh path.** Ground generation can remove every triangle, yet rebuild unconditionally submits a surface and concave shape. `nodes/terrain_3d.gd:1089,1110`. | Treat zero triangles as an empty visual/collision chunk. Reproduce full removal and restoration; do not assume the engine's handling of unindexed vertex arrays is correct here. |
| B18 | P2 | **Cave invalidation defeats local caching.** A dirty cave rebuild expands its dirty rectangle to all carve bounds. `nodes/terrain_3d.gd:1125`. | Retain local invalidation plus the necessary meshing halo; measure tile rebuild counts. The final combined mesh may still need assembly. |
| B19 | P2 | **Ray query boundary cases.** Fixed 0.8 m steps can overshoot maximum distance and miss thin solid intervals; the upward cutoff at y > 160 assumes a height ceiling edits do not enforce. `core/terrain_ray.gd:9`. | Enforce maximum distance, remove unjustified height cutoff, validate arguments and test thin walls. Choose and document a supported picking tolerance; the composite field must not be assumed to be an exact distance field. |
| B20 | P2 | **Public argument validation is uneven.** Invalid material IDs, non-finite values and unreasonable/negative geometric inputs can reach array indexing or geometry calculations. | Audit public entry points, define finite/range constraints and reject invalid calls before changes. Avoid arbitrary new limits that break valid existing content. |
| B21 | P3 | **Repeated build on one data resource accumulates river points.** `build()` appends to `river_pts` without clearing it. `core/terrain_data.gd:112`. | Clear derived collections before rebuilding and verify repeat builds produce identical data sizes/results. |

## Editor issues and tests still needed

These source concerns require native editor verification; directly invoking the handler is insufficient.

- **B22, P1/P2: Input registration.** The plugin defines `_forward_3d_gui_input()` without `_handles()` or explicit always-forward registration. Verify actual delivery when the terrain is selected and after reopening a scene, then implement the appropriate editor registration.
- **B23, P2: Navigation and undo interception.** The handler has no Alt-navigation guard and consumes Ctrl/Cmd+Z even if terrain undo does nothing. Establish an explicit terrain-tool activation state and leave normal editor actions available when that tool is inactive.
- **B24, P2: Stroke lifecycle.** Mouse release is handled only in the forwarded viewport path; selection changes end a stroke with the hard-coded sculpt label without resetting `_painting`; scene-tab changes have no explicit handler. Finish or cancel a stroke reliably on release outside the viewport, focus loss, selection changes, scene changes, deletion and plugin disable. Capture the tool at stroke start.
- **B25, P2: Fallback selection can target unintended terrain.** Autodiscovery chooses the first terrain when a different object is selected. Define a safe active-target policy, especially with multiple terrains.
- **B26, P2: Rapid dig clicks can be dropped.** `_last_dig_ms` persists across strokes, so a new click within the drag throttle interval may perform no dig. Reset the per-stroke throttle while retaining drag throttling.
- **B27, P2: Freed-node references in UI callbacks.** Several callbacks check only `terrain != null`, unlike the process callback's validity guard. Test terrain deletion while dialogs and controls are active; clear references and guard all callbacks.

## Shortcomings and unresolved simulation questions

These are distinct from a demonstrated crash or correctness defect.

1. **Large-forest performance is unproven.** The terrain is fixed at 768 × 768 m with 256 ground chunks, approximately 614,656 resident ground vertices and 1,179,648 ground triangles before caves. There is no explicit terrain LOD, distance streaming or background generation. One local headless bake took 2.531 seconds; enabling collision took 2.714 seconds. These are single-run CPU timings, not frame-rate benchmarks.
2. **Editing performs synchronous mesh/collision work.** Large brushes, many caves and repeated collision rebuilds can stall the editor. Measure after correctness repairs, then introduce a bounded update queue if needed. Actual threaded generation and LOD are a separate architectural phase.
3. **Caves are assembled into one visual mesh and collider.** Local cached generation helps, but a combined mesh limits spatial culling and incremental uploads. Per-tile render/collision ownership is a possible later improvement.
4. **Digging and collapse are approximations.** Tunnel removal uses a 4³ sample estimate. Capsule collapse fills a sequence of overlapping spheres; this raises a potential double-counting/subsidence concern. Overlapping cavity collapses and boundary spoil placement need independent volume-accounting tests before claiming mass conservation. These concerns are not yet reproduced failures.
5. **Water and soil are simplified.** Water-table/pore/drainage behavior should not be described as a full hydrology or geotechnical simulation. Performance, numerical stability and repeatability under long edit sequences need stress tests.
6. **Nepal vegetation inputs are insufficient.** “Biome” is effectively a material label. Local terrain height is not altitude above sea level, and the generated temperature range is not a Nepal elevation model. Forest integration needs a separate ecological layer, altitude offset, climate/season parameters and stable region-change events.
7. **Visual terrain material is basic.** Vertex-color surfaces lack the authored texture/normal/detail blending needed to match naturalistic trees. This is an art/rendering feature, not a core correctness fix.
8. **Distribution is incomplete.** The supplied ZIP has addon scripts and tests but no complete demo project, installation guide, API/coordinate contract, supported-engine matrix or license file. The author's licensing terms must be established before redistributing beyond your own working copy; a license should not be invented.

## Proposed implementation order

### Phase 1 — Terrain state and collision correctness

Address B01–B05, B12–B14, B16–B18 and B21. Centralize invalidation enough that height, material, cave and water changes consistently update derived state, meshes, physics and events. Preserve existing public API behavior where possible.

Acceptance: shared chunk borders and normals agree; clearing/replacing caves restores surfaces; repeated collision refresh/toggle cycles do not grow nodes or retain active collision; every mutation path agrees with queries and visuals; empty chunks restore cleanly.

### Phase 2 — Persistence and compatibility

Address B08–B11 and the save implications of B15. Define schema/version migration before changing interpolation. Validate before mutation, make save replacement failure-safe, handle resource caching, show errors and connect scene persistence to a saved edits resource. Preserve the supplied version-0 compatibility test and characterize existing version-1/version-2 files.

Acceptance: save/reload, scene reopen and runtime startup reproduce edited terrain; old supported saves load; unsupported/corrupt inputs produce a useful error without modifying existing terrain or overwriting a good file; observers see complete restored state.

### Phase 3 — Coordinates, picking and editor lifecycle

Address B06–B07, B19–B20 and B22–B27. Explicitly separate local operations from world-facing APIs. Support translation and well-defined transforms; for transforms incompatible with a single-valued world height query, use ray-based surface sampling or clearly reject the unsupported operation. Fix native input registration, active-target selection, stroke termination, navigation and undo behavior.

Acceptance: picking matches the visible surface under supported transforms, rays respect bounds/range, invalid calls are non-destructive, and native editor workflows pass with multiple terrains, scene switching and node deletion.

### Phase 4 — Simulation audit and measured optimization

Create focused volume-accounting and long-sequence checks for digging/collapse, including overlapping primitives and map boundaries. Repair discrepancies that are reproduced and document intended approximation tolerances. Benchmark bake, brush latency, cave edits, collision refresh, node counts and memory after repeated operations. Optimize redundant rebuilds first. Report remaining costs before proposing LOD, streaming or a thread-based rewrite.

Acceptance: no unexplained volume-accounting drift outside declared tolerances; deterministic replay where promised; bounded resource counts; measured before/after timings with workload and machine recorded. A desktop FPS target needs a real rendered scene and representative forest content.

### Phase 5 — Release validation and handoff

Run the existing 204 acceptance and 31 UX assertions, plus targeted regressions for each repaired finding. Add native editor smoke tests, physics contact tests and a fresh-project import/export check. Investigate shutdown leaks independently from harness cleanup. Supply a corrected addon ZIP, changelog, installation and persistence instructions, compatibility notes, test results and a list of unresolved limitations.

Tree generation, 20 species, shrubs, wind, fire, growth, chopping and propagation remain in the earlier vegetation plan. They should begin after terrain correctness and the integration contract are dependable.

## Current implementation status

The user approved implementation of the terrain roadmap. This file preserves baseline evidence only. Current progress, tests, limitations and the next milestone are tracked in [`IMPLEMENTATION_STATUS.md`](../IMPLEMENTATION_STATUS.md) and [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md).
