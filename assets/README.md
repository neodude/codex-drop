# Codex Drop artwork

The current artwork is an original screenshot-transfer symbol: two overlapping
card frames and a curved downward arrow. The rear card uses lavender/lilac
(`#B5A2FF`); the front card and arrow use aquamarine (`#56F5D0`) over graphite.
It contains no OpenAI knot, Codex cloud, or terminal mark.

## Provenance

Created for this project on 2026-10-24 using the built-in image generation tool.
The selected screenshot-stack concept was edited to add the lavender rear card
and extend the graphite background to all four square canvas corners. A second
built-in edit extracted a transparent version for in-app use and the Android
adaptive launcher foreground. The prompts are preserved in
[generation-prompts.txt](generation-prompts.txt).

`CodexDrop-icon-master.png` is the unmodified opaque generation output;
`DropMark.png` is the unmodified transparent derivative. Both retain the image
tool's embedded content credentials. Platform-sized PNGs are deterministic `sips`
resizes of the opaque master. `artwork-manifest.json` records every exported PNG.

## Platform exports

- `CodexDrop-icon.png`: 1024 × 1024 opaque icon used by the macOS icon build pipeline.
- iPhone `AppIcon.appiconset`: the same 1024 × 1024 opaque icon.
- iPhone App and Share `DropMark.imageset`: identical transparent `DropMark.png` copies.
- Android `drawable-nodpi/drop_mark.png`: the same transparent mark.
- Android `mipmap-anydpi/ic_launcher.xml`: adaptive icon with graphite background
  and the transparent mark inset by 22% to preserve launcher mask safety margins.
  The minimum Android API is 28, so every supported device uses adaptive icons;
  pre-26 raster launcher fallbacks and a version-qualified resource folder are unnecessary.

The opaque assets have square canvas corners. Each platform applies its own app
icon mask. No rounded app icon mask is baked into the image.

## License

The original project artwork is included under the repository's MIT license.
That license does not grant rights to third-party names or trademarks. This
provenance records creation and exports; it does not claim trademark clearance.
