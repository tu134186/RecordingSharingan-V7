# Whole-island halo evidence and scope

Reference: user-supplied ios16dao(4).dylib, arm64 slice, inspected 2026-10-26.

- 0x12BD4 loads SBSystemApertureContainerView; 0x12BE8 loads layoutSubviews; 0x12BEC installs the 0x12D14 callback.
- 0x12D4C passes that same container to the halo renderer at 0xF504.
- 0xF5B8 reads presentationLayer; 0xF5DC and 0xF5F0 read presentation/model bounds; 0xF618 and 0xF794 read cornerRadius.
- 0xF7A8 uses half-height if the layer has no explicit corner radius. 0xF840 creates the rounded rectangle outline.
- 0x125A0 displayLinkFired compares presentation/model sizes and invalidates the link when geometry settles.

These observations establish a whole-container outline, not an outline around the replacement image. Our independent implementation adds a private CAShapeLayer to the already-hooked container, inside its bounds. It never changes native geometry, corners, masks, hierarchy, opacity or hit testing. Its display link only runs while presentation geometry differs and has a two-second cap. An event-driven launch/settings scan discovers existing instances. Color, thickness and shadow are configurable. Expanded-shape precision and clipping of the glow remain pending device verification. The underscore-prefixed alternate container is not hooked in this initial iOS 16.5 build.

6.17 image assets, side selection, placement and rotation code remain unchanged. Default halo: enabled, blue, 1.5 pt, shadow enabled. Disable in Settings for the original appearance.
