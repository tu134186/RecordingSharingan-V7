# VC / Dynamic Island layout research — evidence checkpoint (2026-10-24)

## Baseline and safety
- Tested stable package: 7.11.9.4.3.2.6.5.
- This branch is **research-only**. Do not alter Tweak.xm, injection, or existing build workflow without validated evidence.
- The 94326 source is preserved.

## Newly verified from V6.5 source archive
- `Tweak.xm` contains **no** literal `SBSystemApertureViewController` and **no** literal `hostView`. Therefore no confirmed direct VC hook exists in this source.
- `SBSystemApertureContainerView` occurs in two places: the existing layout refresh helper (around line 2424), and an existing `%hook SBSystemApertureContainerView -layoutSubviews` (around line 3011).
- The existing container hook explicitly documents that native container +5pt width extension is **disabled** in baseline 7.11.9.4.3.2.6. Re-enabling it without new evidence would repeat a failed experiment.
- `_UIPortalView` occurs in existing view-discovery diagnostics, including sourceView investigation. It does **not** prove the portal is the clipping parent.
- Sharingan view sets `clipsToBounds = NO` and `layer.masksToBounds = NO` at its own level; ancestor clipping and physical cutout remain unverified.
- `SAUIElementView -layoutSubviews` is already hooked. New hooks must be audited against this before adding overlapping layout work.

## Next falsifiable experiment (not implemented)
Collect **read-only** frame/bounds/window/clipsToBounds/masksToBounds/ancestor chain at two points:
1. Recording-only after indicator is visible, before manual island swipe.
2. Immediately after the manual swipe that visibly changes the cropping.

Compare identity and geometry for `SBSystemApertureContainerView`, `SAUIElementView`, portal/sourceView and any observed VC-owned root view. Do not claim VC involvement until the actual controller ownership or call path is observed.

## Pass/fail criteria
- A parent clip rect changing across states would support clipping hypothesis.
- Only child frame changes would support positioning/layout hypothesis.
- No meaningful geometry change would require checking occlusion and animation presentation state instead.

## Axs skill relevance
The shared Axs skill archive is general Theos/Logos engineering guidance, not an implementation of `SBSystemApertureViewController` layout.
