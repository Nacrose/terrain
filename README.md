# Terrain — local repair build

This package contains the repaired terrain addon with material and appearance painting, a material catalog, and a first surface-cover/deposit workflow. It is a local development build based on the supplied source archive; the original ZIP was left unchanged.

The folder is also a small Godot verification project. It includes only the focused tests used for this repair, not the original full authoring/demo project.

## Install

Copy `addons/stoem_terrain/` into your Godot project’s `addons/` folder, open **Project → Project Settings → Plugins**, and enable **Terrain**. The build was checked with Godot 4.7.2 using the supplied project’s Compatibility renderer. Other Godot versions, renderers and operating systems are not yet verified.

## Material workflow

- Select **Paint** in the Terrain dock.
- Choose a physical terrain material and either **Weighted random** or a named texture set.
- Choose **Material + texture** to change the physical material, or **Texture only** to change appearance on cells already using the selected physical material.
- Use **Create**, **Duplicate**, **Add Texture Set**, and **Edit Properties** to author materials. Material resources expose their supported physical parameters and texture maps in the Inspector.
- Use **Export Material** to save a `.tres` preset and **Import Material** to add it as a fresh copy with new material/texture-set IDs. Imported texture assets remain shared references.
- Use **Export Library** to save the current catalog and **Merge Library** to add its missing stable material IDs into another catalog. Existing definitions stay unchanged, collisions are skipped, and repeating the merge does not duplicate entries.
- **Archive selected** hides a material from the default shelf while preserving its terrain/save references; turn on **Show archived** to restore it later.
- **Replace base uses of** lets you choose a source material, then replaces its 1 m material samples on the selected terrain with the selected paint material. It is undoable; cover layers remain unchanged.
- The material dock shows 1 m material-sample and cover-layer usage across matching terrain nodes in the currently open scene.
- Use the separate **Deposit** tool to raise a material mound and record its surface-cover depth. Deposits stack up to four strata on the 1 m height grid; the explicit reclassification toggle replaces an existing stack when that is intended. Painted physical material assignments also use the 1 m sample grid, while generated geology/climate fields remain 4 m.
- Weighted appearance is stable by seed and grouped into configurable patches. Painting, undo/redo and edit saves preserve stable material and texture-set IDs.
- **Save** and **Load** in the edit panel operate on `.res` edit resources. The resource is linked to the terrain node. Save the scene after linking it so it will restore automatically on scene startup.

## Known scope

This is not the complete ecosystem plan. The implementation status document identifies what is verified and what remains. In particular, material-specific mass balance, deeper geology beyond the four cover layers, contact-level rigid-body friction, catalog-wide replacement across terrains, visual viewport QA, configurable terrain dimensions, large-world streaming/LOD and the separate forest, grass/wind and wildlife plugins are not included in this package.

The source archive supplied no license file. This package is prepared for the user’s local project workflow; external redistribution rights have not been established.

## Continue the project on another machine

Clone the public repository and start with [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) for current progress, verification and next steps. The full roadmap is in [IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md). Supporting source context is in the [terrain bug audit](docs/TERRAIN_BUG_AUDIT.md), [Nepal Forest plan](docs/NEPAL_FOREST_PLAN.md), and [material authoring guide](docs/MATERIALS.md). The addon’s technical directory and class identifiers remain `addons/stoem_terrain/` and `StoemTerrain*` for compatibility; the user-facing plugin name is **Terrain**.

## Run the included checks

From this directory, with Godot 4.7.2 available as `godot`:

```sh
godot --headless --path . --script res://tests/run.gd
godot --headless --path . --script res://tests/regressions.gd
godot --headless --editor --path . --script res://tests/ux_probe.gd
godot --headless --path . --script res://tests/material_catalog.gd
```
