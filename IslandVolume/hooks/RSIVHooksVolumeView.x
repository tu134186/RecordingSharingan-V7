// Derived from Yves000/Crescendo (GPL-3.0), upstream 33c60a69d76454c268709b381ad987832403e534.
// Modified 2026-10-28: isolated namespace/domain and opt-in integration in RecordingSharingan.
// Hooks on Apple's volume row itself (MRUNowPlayingVolumeControlsView), shared
// by every version 16-26, in whichever player view hosts it.
//
// Two jobs:
//  1  Visibility ↔ height coupling: when the route stops supporting volume
//     control, drop the force (and the platter growth) with it.
//  2  iOS 17+: volume updates are dropped while isOnScreen is NO, and Apple
//     only sets it where it believes volume is showing. Report YES while our
//     force owns the enclosing player view.
#import "RSIVShared.h"

// A pure observer recognizer: raises the cross-process touch flag at touch-DOWN
// so SpringBoard can fail the island's gestures and suppress the volume ribbon
// before either fights the drag. Never recognizes, never cancels touches in the
// view, so the slider's own fluid gestures are untouched.
@interface RSIVFlagTouch : UIGestureRecognizer
@end
@implementation RSIVFlagTouch
// Must stay a true observer: if the slider's fluid pan can force this
// recognizer out, UIKit skips its touchesEnded/-Cancelled and the flag stays
// raised until the staleness backstop.
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other { return NO; }

// The clear lingers 0.7 s behind the touch-up: the fluid slider's final commit
// travels through mediaserverd and reaches SpringBoard after the touch ends,
// so an immediate clear lets exactly that last change present the ribbon. The
// generation counter keeps a delayed clear from wiping a newer touch's flag.
static uint64_t gRSIVTouchGen;

static void RSIVFlagRelease(void) {
    uint64_t gen = ++gRSIVTouchGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gRSIVTouchGen == gen) RSIVTouchFlagSet(NO);
    });
}

// touchesMoved refreshes the flag's timestamp so the staleness backstop can be
// tight without unsuppressing mid-drag.
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { gRSIVTouchGen++; RSIVTouchFlagSet(YES); [super touchesBegan:t withEvent:e]; }
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { RSIVTouchFlagSet(YES); [super touchesMoved:t withEvent:e]; }
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { RSIVFlagRelease(); [super touchesEnded:t withEvent:e]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e { RSIVFlagRelease(); [super touchesCancelled:t withEvent:e]; }
@end

void RSIVAttachTouchFlag(UIView *volumeView) {
    // iOS 16 must NOT get the recognizer: the pre-fluid MRUSlider is a
    // hand-rolled UIControl on classic touch delivery, and a never-resolving
    // observer recognizer withholds its touchesEnded — the control wedges at
    // tracking=YES until respring. There the flag comes from the tracking
    // hooks below (RSIVVolumeTrack16) instead; 17+ fluid sliders run on their
    // own recognizers and coexist with the observer.
    if (RSIVIOSMajor() < 17) return;
    for (UIGestureRecognizer *gr in volumeView.gestureRecognizers)
        if ([gr isKindOfClass:[RSIVFlagTouch class]]) return;
    [volumeView addGestureRecognizer:[[RSIVFlagTouch alloc] init]];
}

%group RSIVVolumeView

%hook MRUNowPlayingVolumeControlsView

// Every forced volume view gets the touch flag as it enters a window (LS
// 16/17, LS 18+, DI — the host stamp is set before the view is added). Apple's
// own hosts (CC) are never forced, so they are skipped.
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    UIView *player = RSIVEnclosingPlayerView(self);
    if (player && RSIVShouldForceVolume(player)) RSIVAttachTouchFlag(self);
}

- (void)volumeController:(id)controller volumeControlAvailableDidChange:(BOOL)available {
    %orig;
    UIView *player = RSIVEnclosingPlayerView(self);
    if (!player) return;
    // Only react inside a player we force; Apple's own hosts (CC cards)
    // manage themselves.
    BOOL forcedHost = RSIVShouldForceVolume(player) || !RSIVAvailable(player);
    if (!forcedHost) return;
    RSIVSetAvailable(player, available);

    BOOL want = RSIVShouldForceVolume(player);   // re-derived with the new availability
    if ([player respondsToSelector:@selector(setShowVolumeControlsView:)]) {
        MRUNowPlayingView *npv = (MRUNowPlayingView *)player;
        if (npv.showVolumeControlsView != want) npv.showVolumeControlsView = want;
    }
    [player setNeedsLayout];
    // Re-sync the platter height on the owning VC, deferred out of the callback.
    UIResponder *r = player.nextResponder;
    while (r && ![r isKindOfClass:UIViewController.class]) r = r.nextResponder;
    UIViewController *vc = (UIViewController *)r;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([vc respondsToSelector:@selector(rsiv_syncHeight)])
            [vc performSelector:@selector(rsiv_syncHeight)];
        else if ([vc respondsToSelector:@selector(rsiv_ls18Apply)])
            [vc performSelector:@selector(rsiv_ls18Apply)];
    });
}

// iOS 17+ only (the selector doesn't exist on 16; Logos no-ops a missing
// method's hook at init time).
- (BOOL)isOnScreen {
    BOOL r = %orig;
    if (r) return r;
    UIView *player = RSIVEnclosingPlayerView(self);
    return player && RSIVShouldForceVolume(player);
}

%end

// The enable pin. Apple's visibility pass hard-disables the slider in the
// lock-screen context regardless of availability, and that predicate sits
// below every public property — so pin the setter instead: inside a player we
// force, a disable becomes an enable. Everything else (CC cards, unavailable
// routes) passes through. MRUSlider doesn't override -setEnabled: itself, so
// this adds a class-local override above UIControl's — other UIControls are
// untouched.
%hook MRUSlider

- (void)setEnabled:(BOOL)enabled {
    if (!enabled) {
        UIView *player = RSIVEnclosingPlayerView(self);
        if (player && RSIVShouldForceVolume(player)) enabled = YES;
    }
    %orig(enabled);
}

%end

%end // RSIVVolumeView

// iOS 16 flag source: the slider's own UIControl tracking edges — zero
// interference with touch delivery (see RSIVAttachTouchFlag). Scoped to forced
// players so the CC card's stock slider (same class, SpringBoard) never flags.
%group RSIVVolumeTrack16

// Set at begin-tracking when the drag raised the flag. The release edges key
// off it rather than a fresh RSIVShouldForceVolume: that predicate can flip
// mid-drag (route loss, Settings toggle), which would skip the release and
// strand the flag until it expires.
static void * const kRSIVTracking16Key = (void *)&kRSIVTracking16Key;

%hook MRUSlider

- (BOOL)beginTrackingWithTouch:(id)touch withEvent:(id)event {
    BOOL r = %orig;
    UIView *player = RSIVEnclosingPlayerView(self);
    if (r && player && RSIVShouldForceVolume(player)) {
        gRSIVTouchGen++; RSIVTouchFlagSet(YES);
        objc_setAssociatedObject(self, kRSIVTracking16Key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return r;
}

// Refreshes the timestamp during a long-held drag (the 17+ path refreshes
// from the recognizer's touchesMoved instead).
- (BOOL)continueTrackingWithTouch:(id)touch withEvent:(id)event {
    BOOL r = %orig;
    if (r && objc_getAssociatedObject(self, kRSIVTracking16Key)) RSIVTouchFlagSet(YES);
    return r;
}

- (void)endTrackingWithTouch:(id)touch withEvent:(id)event {
    %orig;
    if (objc_getAssociatedObject(self, kRSIVTracking16Key)) {
        objc_setAssociatedObject(self, kRSIVTracking16Key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RSIVFlagRelease();
    }
}

- (void)cancelTrackingWithEvent:(id)event {
    %orig;
    if (objc_getAssociatedObject(self, kRSIVTracking16Key)) {
        objc_setAssociatedObject(self, kRSIVTracking16Key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RSIVFlagRelease();
    }
}

%end
%end // RSIVVolumeTrack16

%ctor {
    @autoreleasepool {
        if (RSIVIOSMajor() < 16) return;
        if (!objc_getClass("MRUNowPlayingVolumeControlsView")) return;
        %init(RSIVVolumeView);
        if (RSIVIOSMajor() == 16) %init(RSIVVolumeTrack16);
    }
}
