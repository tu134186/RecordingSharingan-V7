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


## External iOS 16 SpringBoard evidence (2026-10-24)
- Independent technical research on iPhone 14 Pro Dynamic Island identifies **two distinct window scenes**: `SBSystemApertureWindowScene` and `SBSystemApertureCurtainWindowScene`. Source: https://pookjw.github.io/Develop/Aperture_with_Clear_Color/article.html
- This is a **new competing hypothesis**: the apparent missing segment may involve the curtain/window-scene compositing or masking rather than the container's `frame`. The cited article discusses changing island appearance on iOS 16.0; it does **not** establish that the same mechanism causes RecordingSharingan clipping on iOS 16.5.
- Therefore read-only diagnostics should also record each candidate view's `window` identity, `windowScene` class, and `layer.mask` presence, in addition to `frame`, `bounds`, and `clipsToBounds`.
- `DynamicCowTS` manipulates device traits to enable Dynamic Island on other devices, but does not supply verified hooks for this native 14 Pro Max cropping issue. Source: https://github.com/matteozappia/DynamicCowTS

## Revised decision tree
1. If the visible crop follows an ancestor `clipsToBounds`/mask boundary, instrument that ancestor only.
2. If it follows a different window-scene curtain/mask, investigate scene composition without changing VC width.
3. If it follows the physical camera cutout regardless of scene/frame, software can only relocate/scale content, not render through hardware.
4. No production layout mutation until at least one hypothesis has before/after runtime evidence.
