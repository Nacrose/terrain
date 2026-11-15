**Nepal Forest — Terrain integration plan**

Prepared 14 November 2026. This is a future companion-addon plan; forest-plugin implementation has not started. The user requested a separate procedural tree/shrub plugin, 20 tree species, locally available shrubs, naturalistic desktop visuals, wind response, fire, cutting, growth and spreading. This plan proposes an initial library of 10 Nepal shrubs as a starting point; that count and the final species roster remain proposals. Target assumptions are Godot 4.7.2 and Forward+ pending compatibility and performance review.

**1. Terrain review and evidence**

The supplied original archive is version 2.3.2 and contains 14 add-on files and three test scripts. Its technical main-node class is `StoemTerrain3D`, retained in the current repository for compatibility. Archive SHA-256 is `3f02fedba3985df76a9fa51c79c7792414770b7cc9049604e7bdae0dcf85c86a`.

The review used an extracted copy and a temporary Godot project. Godot 4.7.2 ran 204 supplied acceptance assertions and 31 supplied scripted UX assertions successfully, with both runners returning exit code zero. The acceptance runner's save destinations were redirected from user storage to the review workspace. A supplemental diagnostic script was prepared and remains unexecuted.

The headless runs emitted sandbox-related application-data, editor-settings, and certificate-access errors. The UX run also emitted object/resource leak messages at shutdown. Their impact on normal interactive operation needs separate verification. The UX script calls the editor input handler directly, so its passing result establishes handler behavior. Real viewport dispatch, visual appearance, GPU performance, and the additional source-review findings below remain unverified interactively.

Source locations below refer to files inside the supplied archive. The node file abbreviation in the tables means `addons/stoem_terrain/nodes/terrain_3d.gd`.

| Existing capability | Evidence | Integration use |
|---|---|---|
| Seeded heightfield | `core/terrain_data.gd`, lines 12–16 and 52 | Reproducible terrain and vegetation placement |
| Fixed 768 × 768 metre map | `core/terrain_data.gd`, lines 12–16 | Explicit placement bounds and forest chunk indexing |
| 256 ground chunks, each 48 metres across | `core/terrain_mesh.gd`, lines 22–24 | Align vegetation management with terrain edits |
| Height, normals, slope, material queries | Node file, lines 134–190 | Placement, ground alignment, and substrate suitability |
| Moisture, temperature, soil, rock, and river fields | `core/terrain_data.gd`, lines 21–37 | Inputs to vegetation habitat selection |
| Water table, pore factor, saturation | Node file, lines 192–199 | Root moisture and wet-ground rules |
| Cave-aware solidity and ray queries | Node file, lines 201–265 | Reject openings and check supporting ground |
| Editing, collapse, and seepage signals | Node file, lines 15–19 | Reevaluate affected vegetation |
| Sculpting, digging, material painting, undo/redo | Node file, lines 330–978 | Interactive landscape changes |
| Explicit terrain edit save/load | Node file, lines 982–1039 | Coordinated terrain and vegetation checkpoints |

The ground has 1 metre mesh spacing. Before carving, its 256 chunks contain a calculated 1,179,648 triangles and 614,656 vertices, including duplicated chunk-edge vertices. These counts follow from the mesh-generation loops and describe resident geometry. Frame workload requires GPU profiling. Bake creates all chunks synchronously. The add-on currently has no implemented terrain LOD, distance streaming, or background generation queue.

Its material appearance uses vertex-colored StandardMaterial3D resources. The supplied archive contains no foliage renderer, vegetation art, tree lifecycle, fire, or wind system. Water behavior consists of a generated water table, pore-pressure helpers, edit-triggered drawdown, and a debug overlay.

**2. Source-review findings to resolve during integration**

These findings are based on code inspection. The bundled tests pass, and the targeted reproductions listed here belong to the first implementation milestone.

| Priority | Finding and consequence | Evidence and proposed verification |
|---|---|---|
| High | Editor input registration is incomplete. The plugin defines the viewport handler but lacks `_handles()` and an always-forward input registration. This can prevent normal viewport dispatch even though direct handler tests pass. | `plugin.gd`, lines 18–24 and 84–124. Verify actual mouse input in an enabled editor plugin and switching between terrain and vegetation tools. |
| High | Height invalidation marks only the chunk containing the changed sample. Shared edge vertices and adjacent normal samples can remain stale in neighboring meshes and colliders. Trees sampling the new height can then disagree with the visible ground. | Node file, lines 1052–1057, and `core/terrain_mesh.gd`, lines 69–83. Reproduce a small raise/lower edit on each chunk boundary and corner. |
| High | `refresh_collision()` clears references to existing ground shapes and creates replacement shapes without freeing the originals. Repeated enabling has a related path. Old collision may survive later edits or disabling. | Node file, lines 1110–1123, 1226–1261. Count shapes across refresh, repeated enable, edit, disable, and re-enable cycles. |
| Medium | Public methods described as world-space queries use terrain-local coordinates directly. Meshes inherit the node transform, while queries and editor rays omit conversion. Sampling also clamps outside the map, allowing apparently valid results beyond the rendered terrain. | Node file, lines 134–145 and 265–266, `plugin.gd`, lines 77–82, and `core/terrain_data.gd`, lines 190–215. Verify translated terrain, rotations, supported scales, and out-of-bounds samples. |
| Medium | Some mutation paths bypass complete invalidation or notification. Direct material overrides omit edit signals. Material snapshots omit biome synchronization. Replacing carve data invalidates the new bounds only, so clearing or moving a hole can leave old ground geometry stale. | Node file, lines 528–531 and 921–978. Compare material queries, displayed geometry, hole closure, collision, and signal coverage for every public edit path. |
| Integration requirement | Saving the scene does not capture the runtime terrain data and edit dictionaries. The add-on provides a separate edit-save workflow. Loading calls `bake()`, which emits `baked` before saved edits are restored. | Node file, lines 40, 102–130 and 982–1039. Coordinate explicit saves and delay vegetation restoration until terrain edits finish loading. |

Godot documents `_handles()` as part of the conditions for forwarding 3D viewport input. The first finding therefore needs a real editor dispatch test in addition to the included direct-call UX tests. [Godot 4.7 EditorPlugin documentation](https://docs.godotengine.org/en/4.7/classes/class_editorplugin.html#class-editorplugin-private-method-forward-3d-gui-input)

Terrain climate also needs interpretation. `biome_at_world()` returns one of seven ground-material names. Temperature and moisture originate from noise fields, and the default snow rule can trigger above a local height of 46 metres. Cached `data.slope` is built during terrain generation. Vegetation should use live `slope_deg_at()` after edits and a separate ecological elevation and habitat profile. Relevant code is in `core/terrain_data.gd`, lines 80–183, and the node file, lines 145–149 and 232–236.

**3. Integration architecture**

Build Nepal Forest as a companion add-on under `addons/nepal_forest/`. A Stoem adapter provides a single boundary between the forest and the terrain implementation. It will expose valid surface position, normal, current slope, substrate, environmental inputs, ground support, and affected regions.

The first integration fixture uses an origin-aligned, unit-scale terrain, matching the current implementation's coordinate assumptions. Coordinate conversion and bounds handling become explicit adapter behavior, with transformed-terrain cases covered before those configurations are exposed as supported. Initial forest tiles align with Stoem's 48 metre chunks. Rendering can subdivide these into 24 metre areas when profiling shows a culling benefit.

The main components will be an editor dock and brushes, species resources, a structural tree generator, a shared mesh/material cache, a forest renderer, a lifecycle simulator, wind and fire controllers, interaction objects, and versioned persistence. A terrain reference is assigned explicitly so scenes containing several terrain nodes have predictable ownership.

Each tree has a stable identity and a connected trunk-and-branch structure. Its persistent state is separate from whichever mesh or physics object currently represents it. Nearby interactive trees can leave an instance batch, become individual objects, and return to batching without changing identity or duplicating harvest rewards.

An adapter listens to `edited_region`, `collapsed`, `seepage_cells`, and `baked`. Multiple notifications are coalesced into affected vegetation tiles. Normal edits update those tiles. Full rebakes and completed loads trigger coordinated restoration. A readiness notification after terrain loading will prevent placement against the intermediate pristine bake.

For ordinary surface planting, combine height and current slope with opening tests and several root-footprint support samples. Cave-aware rays resolve ambiguous boundaries. A bounded placement query rejects positions outside the actual terrain. The surface height alone is insufficient around carved openings.

**4. Species and art scope**

The 20 proposed trees are listed below. Each receives a referenced species resource, distinct branching rules, bark and foliage assets, growth proportions, seasonal settings, and configurable environmental preferences.

| Tree | Scientific name |
|---|---|
| Sal | Shorea robusta |
| Sissoo | Dalbergia sissoo |
| Khair | Senegalia catechu |
| Simal | Bombax ceiba |
| Jamun | Syzygium cumini |
| Karma / Haldu | Haldina cordifolia |
| Chilaune | Schima wallichii |
| Dhale katus | Castanopsis indica |
| Utis | Alnus nepalensis |
| Khote salla / Chir pine | Pinus roxburghii |
| Gobre salla / Blue pine | Pinus wallichiana |
| Laligurans | Rhododendron arboreum |
| Kafal | Myrica esculenta |
| Lapsi | Choerospondias axillaris |
| Kharsu oak | Quercus semecarpifolia |
| Thulo phalant | Quercus lamellosa |
| Bhojpatra | Betula utilis |
| Himalayan fir | Abies spectabilis |
| Bar / Banyan | Ficus benghalensis |
| Peepal | Ficus religiosa |

The selection draws on Nepal's forest inventory, timber directory, Lapsi reference, and documentation of culturally important plants. Scientific names and synonyms will identify assets consistently where common names vary. [Forest Resource Assessment](https://www.frtc.gov.np/uploads/files/Final_FRA_data_analysis_manual_2021.pdf), [Timber directory](https://redd.gov.np/assets/2/REDD_Directory_2024_FINAL_DRAFT.pdf/file), [Lapsi reference](https://frtc.gov.np/downloadfiles/book2-1702615738.pdf), [FAO Nepal study](https://www.fao.org/4/XII/0087-A1.htm)

Ten shrubs are proposed as the starting understory library.

| Shrub | Scientific name | Planned structural treatment |
|---|---|---|
| Chutro | Berberis asiatica | Branching woody shrub |
| Timur | Zanthoxylum armatum | Shrub and small-tree forms |
| Jamane mandro | Mahonia napaulensis | Upright stems and compound foliage |
| Aiselu | Rubus ellipticus | Arching bramble canes and patches |
| Ghangaru | Pyracantha crenulata | Dense branching and fruit clusters |
| Dhayaro | Woodfordia fruticosa | Fine branching and flowering forms |
| Simali | Vitex negundo | Multi-stem shrub forms |
| Asuro | Justicia adhatoda | Broadleaf shrub clusters |
| Lokta | Daphne bholua | Upright woody shrub |
| Sunpati | Rhododendron anthopogon | Compact high-elevation shrub forms |

The palette is supported by Nepalese botanical and field records. Exact habitat envelopes, phenology, and visual proportions will be recorded with sources during species authoring. [National Botanic Garden](https://www.nbg.gov.np/wp-content/uploads/2022/12/GARDEN-PROFILE-THE-NATIONAL-BOTANIC-GARDEN-OF-NEPAL.pdf), [Plant Resources journal](https://dpr.gov.np/wp-content/uploads/2021/08/Journal-of-Plant-Resource-FINAL-2021_Main.pdf), [Madhesh survey](https://frtc.madhesh.gov.np/assets/uploads/671dfaa0ddf01.pdf), [Asuro record](https://lml-database.icimod.org/detail/justicia-adhatoda), [Lokta assessment](https://elibrary.tucl.edu.np/items/310d1381-8f8f-494f-8bd0-36abbe5d4324), [Sunpati reference](https://dpr.gov.np/wp-content/uploads/2019/04/Plant-Resource-2016.pdf)

Naturalistic appearance requires a dedicated art pass. Produce species-specific leaf, needle, flower, fruit, and bark assets with appropriate color, opacity, normal, and roughness information. Geometry must have convincing taper, forks, branch attachment, root flare, crown asymmetry, and age proportions. Banyan adds aerial roots. Variant seeds control structure, while instance parameters add size, color, foliage-density, and wind-phase variation.

Species previews will be compared in consistent lighting at close, middle, and far distances. Check silhouette, foliage density, branch continuity, texture scale, shadow quality, and detail transitions. The first visual set is Sal, Chir pine, Laligurans, Chutro, and Aiselu.

**5. Habitat generation and understory**

Provide editable presets for lowland Sal forest, riverine woodland, subtropical hill forest, temperate broadleaf/conifer forest, subalpine vegetation, and village edges. Each preset chooses a suitable subset of the library. A base ecological elevation and optional elevation scaling connect Stoem's local relief to habitat selection. East–west regional variation can be represented by species weights and environmental ranges.

Placement combines material, current slope, moisture, river proximity, ecological elevation, canopy cover, and spacing. Seeded cluster placement produces groves, gaps, forest margins, and patches of understory. Exclusion masks protect roads, buildings, paths, water, and designed clearings. Shrub density responds to shade and disturbance, using species-specific tolerances.

Initial generation, planted individuals, and later recruitment share placement checks. A configurable population and recruitment budget bounds long-running spread. Seeds, occupied space, and reproductive eligibility use stable simulation state, so unloading and reloading a region does not duplicate recruitment.

**6. Tree and shrub behavior**

| System | Planned implementation and visible result |
|---|---|
| Wind | GPU trunk bending, branch movement, leaf flutter, moving gusts, and local wind zones. Stiffness and bend weights follow plant structure. Root bases remain anchored and branch attachments move coherently. |
| Growth | Seed, seedling, sapling, mature, and old stages with consistent branch identity. Height, trunk radius, crown, and foliage evolve together. Cached stage meshes and gradual transitions limit rebuild cost. |
| Chopping | Tool hits accumulate section damage. Cuts gain visible depth, chips, and exposed wood. Felling leaves a stump and uses hit direction, lean, and constrained physics for the fall. |
| Log processing | Generated trunk sections receive capped ends and simplified collision. Species, volume, and condition determine wood yield. Stable IDs prevent duplicate collection. |
| Pruning | Remove branch subtrees, update dependent foliage and collision, retain scars, and apply species-specific regrowth rules. |
| Fire | Heat, ignition, burning, foliage loss, charring, weakening, smoldering, and burnout. Trees, shrubs, stumps, and logs carry fuel and moisture state. |
| Spread | A spatial neighbor index and bounded simulation ticks propagate heat and embers using distance, wind, fuel, and moisture. Shrubs can connect ground fuel to trees. Fire continues across simulation-region boundaries. |
| Water and weather | Terrain wetness contributes to root conditions. Weather controls rainfall, surface wetness, drying, and extinguishing. Shared wind affects both foliage and fire. |
| Regeneration | Surviving plants recover, eligible stumps resprout, seeds germinate in suitable gaps, and deadwood decays. Rates and eligibility are species-configurable gameplay parameters. |
| Seasons and harvesting | Flowering, fruiting, appropriate leaf changes, wetness, and optional snow appearance. Harvest signals support berries, fruit, seeds, and other configured resources. |

Age, health, damage, moisture, and fire are independent state fields. A burning tree can be felled, its detached logs can continue burning, and its stump can survive or die according to its remaining state.

Root support checks respond to digging, spoil deposition, and collapse. Small editor changes can re-ground a planted instance. Substantial runtime support loss can expose roots, topple a tree, or uproot a shrub. Terrain-edit undo restores the vegetation consequences belonging to the same editing transaction. Chopping and harvesting have their own persistent records.

Ash, char, leaf litter, and vegetation damage use forest-owned visual state. Stoem's material painting changes physical substrate and roof strength, so fire visuals use a dedicated overlay with their own parameters. Coupling roots into soil stability would require an additional documented terrain-model extension and is a later optional feature.

**7. Performance design and measurable targets**

Maintain compact plant records for the forest and create richer scene objects around interactions. Batch shared meshes by spatial tile, species, variant, and detail level. Lazy creation of occupied batches, a bounded variant cache, and habitat subsets keep the number of render batches manageable. Prominent trees can use individual geometry.

Near plants use detailed meshes and necessary collision. Middle-distance plants use simplified shared geometry. Far vegetation uses low-detail geometry or baked impostors. Transitions preserve crown scale, wind phase, and stable identity. Foliage uses suitable cutout rendering, controlled coverage, reduced distant shadows, and simpler far animation. Rendering and simulation distances have separate controls.

Prepare geometry arrays in background work, then apply scene changes and GPU uploads through a budgeted main-thread queue. Generation jobs carry revision IDs so an obsolete job cannot overwrite a newer edit. Cache keys include species settings, seed, age representation, generator version, and quality settings. Dirty-region notifications coalesce before expensive work.

Use staggered ticks for growth, moisture, and recruitment. Active fire keeps a bounded spatial simulation independent of camera visibility. Distant growth advances from elapsed simulation time. Physics logs and particle effects use pools and explicit caps. Terrain collider refreshes update the necessary shapes after the lifecycle bug is resolved.

Godot MultiMesh batches are culled as a group, so spatial subdivision is part of the renderer design. The implementation must profile both batch count and hidden geometry cost. [Godot MultiMesh documentation](https://docs.godotengine.org/en/stable/tutorials/performance/using_multimesh.html)

| Benchmark | Provisional scene and acceptance goal |
|---|---|
| Terrain baseline | Record terrain-only CPU/GPU frame times, memory, bake time, and edit latency on the chosen reference computer. |
| Normal forest | 10,000 placed trees and 20,000 shrubs, with up to 128 detailed interactive plants near the player. Aim for 60 FPS at 1080p on the agreed reference desktop. |
| Interaction stress | Exercise up to 32 visible burning plants and 32 active log bodies together, then tune documented quality presets against measured frame times. |
| Streaming and edits | Measure median, 95th, and 99th percentile frame time, worst spikes, batch count, triangle count, memory, collision count, and pending jobs while crossing tiles and editing terrain. |
| Long simulation | Accelerate growth, recruitment, fire, and decay to verify population limits, stable memory, and consistent save/load. |

These are test targets. Hardware, final asset complexity, visible species mixtures, and Stoem's baseline cost determine the achieved limits. The supplied terrain currently rebuilds synchronously, so local invalidation and incremental rebuild work are assessed early. Terrain LOD or wider-world streaming becomes a separate measured extension if the reference scene needs it.

**8. Persistence and editor workflow**

Save terrain and forest under a coordinated checkpoint containing terrain seed/revision, generation settings/version, stable plant IDs, procedural seeds, ages, damage, cuts, fire state, recruitment, stumps, logs, and harvested records. Use versioned files and a manifest committed after both components save successfully. A failed save must leave a loadable previous checkpoint.

Load terrain generation and edits first, then restore vegetation, and finally rebuild visual and physics representations. Active fire and detached wood restore consistently. Rebaking the terrain is an explicit world operation with a clearly selected vegetation regeneration policy. Editor undo/redo covers planting, painting, removal, and terrain-related vegetation changes.

Provide a species preview dock, seed and shape controls, age/season/wind preview, biome resources, tree and shrub brushes, density/exclusion painting, scattering, generation progress/cancel, bake controls, and performance statistics. Terrain and vegetation brushes have explicit active modes so input and undo shortcuts reach the intended tool.

Game integration exposes operations for planting, damage, cutting, ignition, extinguishing, pruning, and collecting, plus signals for growth stages, falling, burning, harvest, death, and regrowth. The demonstration scene includes basic interactions and exercises save/load through the normal game entry point.

**9. Implementation sequence and completion checks**

| Milestone | Work | Completion evidence |
|---|---|---|
| A — Terrain compatibility | Reproduce source findings, make scoped fixes, establish coordinates/bounds, complete edit notifications, and define load completion. Build the adapter and shared editor tool modes. | Original 235 assertions pass. New regression checks cover real editor dispatch, boundary meshes/colliders, repeated collision lifecycle, transform/bounds behavior, all edit paths, and load ordering. |
| B — Visual and rendering foundation | Generate Sal, Chir pine, Laligurans, Chutro, and Aiselu with materials, seeded variants, wind, forest tiles, and detail levels. | Recognizable species, coherent branches, anchored wind animation, useful variation, acceptable detail transitions, and a measured combined terrain/vegetation baseline. |
| C — Full plant library and habitats | Complete all 20 trees and 10 proposed shrubs. Add referenced habitat resources, cluster generation, shade response, exclusions, and preview galleries. | Every species has its own validated preset and assets. Seeded regeneration is repeatable. Placement rejects unsuitable surfaces and responds to terrain edits. |
| D — Cutting and wood | Add damage, pruning, felling, stumps, sectioned logs, collection, and root-support responses. Integrate persistence from this milestone onward. | Trees and logs collide correctly with edited ground and caves. Burning-state fields and IDs survive detachment. Harvest cannot repeat after save/load. |
| E — Fire and weather | Add ignition, fuel/moisture, spread, effects, charring, extinguishing, and shared wind/weather inputs. | Fire crosses tile boundaries, follows budget limits, affects shrubs/logs/stumps, persists through saves, and supports cutting a burning tree. |
| F — Living forest | Add growth transitions, reproduction, recruitment, competition, regrowth, decay, and seasons. | Accelerated lifecycle scenes remain bounded. Reloads preserve recruitment and damage. Species growth retains a consistent individual form. |
| G — Integration and release validation | Profile and tune presets, exercise editor and exported game workflows, finish documentation, and package the add-on and demos. | Installation works in a clean target-version project with the Terrain addon. Normal and stress benchmarks report measured results and limitations. All specified interactions and save/load cases pass. |

Each milestone produces a reviewable working result. Regression tests are added for specific failure cases and state transitions. Visual and real-editor checks complement headless assertions. The first milestone includes targeted source-level terrain fixes because those paths directly affect grounding, collision, and editor coexistence.

**10. Deliverables and decisions still open**

The completed implementation will provide the installable Nepal Forest add-on, 20 tree presets, a locally sourced shrub library, generated/shared art assets, a Terrain adapter, scoped terrain compatibility changes, species and interaction demos, a benchmark scene, installation/API documentation, and measured quality presets. Terrain changes will be reviewable as a patch with regression evidence.

The working assumptions are Godot 4.7.2, Forward+, naturalistic desktop graphics, metre-scale geometry, and a Nepal-wide library with habitat-specific selection. The user specified 20 trees and local shrubs. The exact tree roster and the initial count of 10 shrubs are proposed selections. The reference CPU/GPU, desired regional emphasis, and preferred depth of log processing remain configurable decisions. They do not prevent reviewing the architecture and milestone sequence.

This document records the terrain review and the complete proposed implementation scope. Source-inspection findings require targeted reproduction, and rendering performance requires measurement on the agreed reference hardware.
