# Visual assets

`perch-icon-master.png` is the 1254×1254 source used to generate the native
macOS app-icon slots. It was generated with OpenAI's built-in image generation
tool from this prompt:

> Create a refined native Mac utility icon for Perch, a temporary file shelf
> that grows out of the MacBook camera notch. Use a dark graphite rounded-square
> tile whose top-center camera-notch shape flows into a subtle glass tray holding
> three overlapping document cards. Premium Apple-platform icon, dimensional
> but restrained, clean geometric forms, quiet fog-gray palette with one muted
> mauve/lavender accent, readable at 16 px. No text, watermark, device mockup,
> desktop background, or tiny decorative detail.

The files in `Perch/Assets.xcassets/AppIcon.appiconset` are mechanically scaled
from the master. Keep the master rather than upscaling an icon slot.
