@tool
class_name StoemTerrainData
extends Resource
## Seed-deterministic procedural terrain data.
## Heightfield + derived climate/biome fields + surface material ids + water table.
## Grid conventions:
##   - Full resolution: N = 769 samples per side (indices 0..768, 1 m spacing).
##     Index (i, j) sits at terrain coordinates (i, j); centred world = (i - 384, j - 384).
##   - Coarse grids: MAT_N = 192 cells per side of 4 m (materials, water head, climate).
## Every value is a pure function of seed_value: identical seed -> identical bake.

const N := 769
const MAP := 768.0
const HALF := 384.0
const MAT_N := 192
const MAT_CELL := 4.0

var seed_value: int = 20261113
var sampling_version: int = 2

# Full-resolution fields (N * N).
var heights := PackedFloat32Array()
var slope := PackedFloat32Array()
var biome := PackedInt32Array()
var river := PackedFloat32Array()
var flow := PackedFloat32Array()
var river_pts := PackedVector2Array()

# Coarse 4 m fields (MAT_N * MAT_N).
var moisture := PackedFloat32Array()
var temp_c := PackedFloat32Array()
var rock_frac := PackedFloat32Array()
var soil := PackedFloat32Array()
var soil_mix := PackedFloat32Array()
var gravel_mask := PackedFloat32Array()
var pond_cap := PackedFloat32Array()
var materials := PackedInt32Array()
var water_head := PackedFloat32Array()

func _init(p_seed: int = 20261113, p_sampling_version: int = 2) -> void:
        seed_value = p_seed
        sampling_version = p_sampling_version

static func _noise(p_seed: int, p_freq: float, p_octaves: int,
                p_gain: float = 0.5, p_type: int = FastNoiseLite.TYPE_SIMPLEX) -> FastNoiseLite:
        var fn := FastNoiseLite.new()
        fn.seed = p_seed
        fn.noise_type = p_type
        fn.frequency = p_freq
        fn.fractal_octaves = p_octaves
        fn.fractal_gain = p_gain
        return fn

func build() -> void:
        river_pts.clear()
        var nc := N * N
        heights.resize(nc)
        slope.resize(nc)
        biome.resize(nc)
        river.resize(nc)
        flow.resize(nc)
        var mc := MAT_N * MAT_N
        moisture.resize(mc)
        temp_c.resize(mc)
        rock_frac.resize(mc)
        soil.resize(mc)
        soil_mix.resize(mc)
        gravel_mask.resize(mc)
        pond_cap.resize(mc)
        materials.resize(mc)
        water_head.resize(mc)

        var cont := _noise(seed_value + 101, 1.0 / 830.0, 5)
        var ridge := _noise(seed_value + 211, 1.0 / 215.0, 4, 0.55)
        var riv := _noise(seed_value + 313, 1.0 / 505.0, 3, 0.5, FastNoiseLite.TYPE_SIMPLEX_SMOOTH)
        var moist := _noise(seed_value + 417, 1.0 / 640.0, 3)
        var temp := _noise(seed_value + 519, 1.0 / 900.0, 2)
        var rock := _noise(seed_value + 623, 1.0 / 130.0, 3)
        var soi := _noise(seed_value + 729, 1.0 / 310.0, 2)
        var pond := _noise(seed_value + 831, 1.0 / 460.0, 2)
        var head := _noise(seed_value + 937, 1.0 / 520.0, 2)

        # --- coarse climate fields ---
        for j in MAT_N:
                var wz := (float(j) + 0.5) * MAT_CELL - HALF
                for i in MAT_N:
                        var wx := (float(i) + 0.5) * MAT_CELL - HALF
                        var k := i + j * MAT_N
                        moisture[k] = clampf(0.5 + moist.get_noise_2d(wx, wz) * 0.75, 0.0, 1.0)
                        temp_c[k] = 17.0 + temp.get_noise_2d(wx, wz) * 9.0
                        rock_frac[k] = clampf(rock.get_noise_2d(wx, wz) * 0.9 + 0.55, 0.0, 1.0)
                        soil[k] = clampf(0.5 + soi.get_noise_2d(wx, wz) * 0.4, 0.0, 1.0)

        # --- heights + river mask at 1 m ---
        for j in N:
                var wz := float(j) - HALF
                for i in N:
                        var wx := float(i) - HALF
                        var c := cont.get_noise_2d(wx, wz)
                        var base := 7.0 + c * 27.0
                        var rv := 1.0 - absf(ridge.get_noise_2d(wx, wz))
                        var mmask := smoothstep(0.35, 0.75, base / 34.0)
                        var h := base + rv * rv * 52.0 * mmask
                        var d := sqrt(wx * wx + wz * wz) / HALF
                        var fall := 1.0 - smoothstep(0.74, 1.02, d)
                        h = -15.0 + (h + 15.0) * fall
                        var rnv := absf(riv.get_noise_2d(wx, wz))
                        var rmask := 1.0 - smoothstep(0.0, 0.05, rnv)
                        h -= 3.4 * rmask * smoothstep(-2.0, 10.0, h)
                        var idx := i + j * N
                        heights[idx] = h
                        river[idx] = rmask
                        flow[idx] = rmask * (1.0 - smoothstep(0.0, 0.18, rnv))

        # --- slope + river sample points ---
        for j in N:
                for i in N:
                        var idx := i + j * N
                        var i0 := maxi(i - 1, 0)
                        var i1 := mini(i + 1, N - 1)
                        var j0 := maxi(j - 1, 0)
                        var j1 := mini(j + 1, N - 1)
                        var dx := absf(heights[i1 + j * N] - heights[i0 + j * N]) * 0.5
                        var dz := absf(heights[i + j1 * N] - heights[i + j0 * N]) * 0.5
                        slope[idx] = maxf(dx, dz)
                        if river[idx] > 0.55 and i % 12 == 0 and j % 12 == 0:
                                river_pts.append(Vector2(float(i), float(j)))

        # --- coarse derived fields, materials, water table ---
        for j in MAT_N:
                var wz := (float(j) + 0.5) * MAT_CELL - HALF
                for i in MAT_N:
                        var wx := (float(i) + 0.5) * MAT_CELL - HALF
                        var k := i + j * MAT_N
                        var h := sample_height(wx + HALF, wz + HALF)
                        var sl := sample_grid(slope, wx + HALF, wz + HALF)
                        var rk := rock_frac[k] * (0.35 + 0.65 * smoothstep(0.15, 0.9, sl))
                        rock_frac[k] = rk
                        var rmask := sample_grid(river, wx + HALF, wz + HALF)
                        var gm := clampf(rmask * 1.5 - 0.25, 0.0, 1.0)
                        if rk > 0.6 and sl < 0.9:
                                gm = maxf(gm, 0.35)
                        gravel_mask[k] = gm
                        var cap := -999.0
                        if h < 2.0:
                                cap = 1.7 + pond.get_noise_2d(wx, wz) * 0.6
                        pond_cap[k] = cap
                        var so := clampf(soil[k] * 0.5 + moisture[k] * 0.55 - rk * 0.35, 0.0, 1.0)
                        soil[k] = so
                        soil_mix[k] = clampf(so * 1.25 - rk * 0.5, 0.0, 1.0)

                        # Sand from one smooth aridity measure (temperature excess + dryness),
                        # so deserts form coherent regions instead of fragmented intersections.
                        var arid := (temp_c[k] - 20.0) / 9.0 + (0.38 - moisture[k]) * 1.5
                        var mat := 0  # loam
                        if h > 46.0 or (temp_c[k] < -3.0 and h > 30.0):
                                mat = 6  # snow
                        elif sl > 0.95 or rk > 0.72:
                                mat = 5  # scree
                        elif h > 27.0 and rk > 0.42:
                                mat = 4  # granite
                        elif gm > 0.5:
                                mat = 2  # gravel
                        elif arid > 0.05 and sl < 0.28 and h < 24.0:
                                mat = 1  # sand
                        elif moisture[k] > 0.74 and h < 7.0:
                                mat = 3  # clay
                        materials[k] = mat

                        # Hydraulic head: regional gradient + ponds + rivers, clamped under ground
                        # away from open water (unconfined water table follows valleys).
                        var hd := 9.0 - wx * 0.012 + head.get_noise_2d(wx, wz) * 2.6
                        if cap > -900.0:
                                hd = maxf(hd, cap)
                        if rmask > 0.45:
                                hd = maxf(hd, h + 0.06)
                        if cap <= -900.0 and rmask <= 0.45:
                                hd = minf(hd, h - 0.12)
                        water_head[k] = hd

        # --- biome per 1 m cell (nearest coarse material cell) ---
        for j in N:
                var mj := clampi(int(float(j) / MAT_CELL), 0, MAT_N - 1)
                for i in N:
                        var mi := clampi(int(float(i) / MAT_CELL), 0, MAT_N - 1)
                        biome[i + j * N] = materials[mi + mj * MAT_N]

## Bilinear height sample in terrain coordinates (0..768 on both axes).
func sample_height(p_tx: float, p_tz: float) -> float:
        return sample_grid(heights, p_tx, p_tz)

## Bilinear sample of any full-resolution field in terrain coordinates.
func sample_grid(p_field: PackedFloat32Array, p_tx: float, p_tz: float) -> float:
        var x := clampf(p_tx, 0.0, MAP)
        var z := clampf(p_tz, 0.0, MAP)
        var i0 := clampi(floori(x), 0, N - 2)
        var j0 := clampi(floori(z), 0, N - 2)
        var fx := x - float(i0)
        var fz := z - float(j0)
        var h00 := p_field[i0 + j0 * N]
        var h10 := p_field[i0 + 1 + j0 * N]
        var h01 := p_field[i0 + (j0 + 1) * N]
        var h11 := p_field[i0 + 1 + (j0 + 1) * N]
        return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)

## Bilinear sample of a coarse (4 m) field in terrain coordinates.
func sample_coarse(p_field: PackedFloat32Array, p_tx: float, p_tz: float) -> float:
        # Coarse samples are generated at cell centres (2, 6, 10, ...).
        # Version 1 retains the old offset for existing saved terrain.
        var offset := 0.5 if sampling_version >= 2 else 0.0
        var x := clampf(p_tx / MAT_CELL - offset, 0.0, MAT_N - 1.0)
        var z := clampf(p_tz / MAT_CELL - offset, 0.0, MAT_N - 1.0)
        var i0 := clampi(floori(x), 0, MAT_N - 2)
        var j0 := clampi(floori(z), 0, MAT_N - 2)
        var fx := x - float(i0)
        var fz := z - float(j0)
        var h00 := p_field[i0 + j0 * MAT_N]
        var h10 := p_field[i0 + 1 + j0 * MAT_N]
        var h01 := p_field[i0 + (j0 + 1) * MAT_N]
        var h11 := p_field[i0 + 1 + (j0 + 1) * MAT_N]
        return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)
