# BodySlider for Subverse

Live body sliders for Subverse, saved per character, with 3 shared presets: body shape (breasts, butt, thighs, hips, waist), breast detail (nipples, areolas, gap, splay, lift) and physics (jiggle, bounce, hair). Changes show instantly in the Pandora menu, scenes and the gallery.

Nexus Mods: https://www.nexusmods.com/subverse/mods/25

## Requirements
- Subverse (tested on GOG v1.2 + Celestina DLC)
- [UE4SS v3.0.1](https://github.com/UE4SS-RE/RE-UE4SS/releases) in `Subverse\Subverse\Binaries\Win64`

## Install
Download the zip from [Releases](../../releases) and copy the `BodySlider` folder into
`<Subverse>\Subverse\Binaries\Win64\ue4ss\Mods\`.

## Controls
| Input | Action |
|---|---|
| Num0 / F8 | Open / close the slider panel |
| BODY / BREASTS / PHYSICS | Section bars: click one to open it |
| BODY | Breasts/butt: volume (2.0 = twice as big). Thighs, hips, waist: width |
| BREASTS | Nipples (length), Areolas (size), Gap (cm between the breasts), Splay (nipples point out/in), Lift (perky/droop, nipples keep their direction) |
| PHYSICS | Jiggle (breast + butt springs), Bounce (cm of up/down spring travel), Hair. Try Jiggle 2x + Bounce 1 cm |
| `<` / `>` | Switch character when several are on screen |
| RESET | Back to default for that character |
| PRESET 1-3 | Click a number to load it; SAVE then a number stores the current shape (shared by all characters) |
| F10 | Hide the panel for screenshots |
| Numpad 8/2, 6/4, 7/9, 5 | Breasts, butt, switch character, reset |

Slider ranges are set in `BodySlider.ini` (`[limits]`: `<slider>_min` / `<slider>_max`; the DLL clamps scales to 0.2–6 per axis, turns to 45°, moves to 10 cm).

Physics needs the game's own physics bodies: a few gallery poses ship without butt bodies (e.g. Lily's base pose), so the butt can't move there.

## How it works
- `lua/main.lua` (UE4SS): finds heroine skeletal meshes, keeps per-character values, draws the panel (reusing the game's own UI widgets), and writes the wanted bone scales/moves to `cmd.txt`. Jiggle/Bounce/Hair edit the game's own PhysX springs on the live PhysicsAsset (UE reflection), then re-init the body's physics.
- `src/lib.rs` (Rust DLL, no dependencies): loaded by the Lua side. It finds each mesh's `RefBasesInvMatrix` in memory and reshapes bones about their bind-pose pivots: scale (uniform or per axis), rotate/move (gap, splay), or lift (each breast bone moved up by its forward distance, so the nipple moves rigidly). The renderer reads those matrices every frame, so the change is live. It only ever touches meshes that are loaded right now.

## Build
```
cargo build --release
```
Copy `target/release/bodyslider.dll` next to `Scripts/` in the mod folder. Tests: `cargo test --release` (DLL math) and `python lua/physics_mocktest.py` (physics section against mock UE objects, needs `pip install lupa`).

## Notes
- Don't use UE4SS hot reload (Ctrl+R).
- Uninstall: delete the `BodySlider` folder. No game files are changed.

## License
MIT. Use, modify and share freely, with credit to the original author (unkemptmagio).
