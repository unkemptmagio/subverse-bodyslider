# BodySlider for Subverse

Live body sliders for Subverse (breasts, butt, thighs, hips, waist, nipples, areolas), saved per character, with 3 shared presets. Changes show instantly in the Pandora menu, scenes and the gallery.

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
| Drag sliders | Breasts/butt: volume (2.0 = twice as big). Thighs, hips, waist, nipples, areolas: width or length |
| `<` / `>` | Switch character when several are on screen |
| RESET | Back to default for that character |
| PRESET 1-3 | Click a number to load it; SAVE then a number stores the current shape (shared by all characters) |
| F10 | Hide the panel for screenshots |
| Numpad 8/2, 6/4, 7/9, 5 | Breasts, butt, switch character, reset |

Slider ranges are set in `BodySlider.ini` (`[limits]`: `<slider>_min` / `<slider>_max`, 0.1–50; the DLL clamps each axis to 0.2–6).

## How it works
- `lua/main.lua` (UE4SS): finds heroine skeletal meshes, keeps per-character values, draws the panel (reusing the game's own UI widgets), and writes the wanted bone scales to `cmd.txt`.
- `src/lib.rs` (Rust DLL, no dependencies): loaded by the Lua side. It finds each mesh's `RefBasesInvMatrix` in memory and rescales the breast/butt bones about their bind-pose pivots. The renderer reads those matrices every frame, so the change is live. It only ever touches meshes that are loaded right now.

## Build
```
cargo build --release
```
Copy `target/release/bodyslider.dll` next to `Scripts/` in the mod folder.

## Notes
- Don't use UE4SS hot reload (Ctrl+R).
- Uninstall: delete the `BodySlider` folder. No game files are changed.

## License
MIT. Use, modify and share freely, with credit to the original author (unkemptmagio).
