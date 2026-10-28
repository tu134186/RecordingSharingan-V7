// Derived from Yves000/Crescendo (GPL-3.0), upstream 33c60a69d76454c268709b381ad987832403e534.
// Modified 2026-10-28: isolated namespace/domain and opt-in integration in RecordingSharingan.
// SpringBoard gesture blocker: the Dynamic Island's resize/dismiss gesture
// (SBSystemApertureResizeGestureRecognizer + the long-press, on a window-level
// UISystemGestureView) preempts a drag on the DI volume slider — the island
// reads it as a dismiss/move. The aperture content is scaled/transformed, so
// geometry hit-testing is unreliable; instead the slider raises the
// cross-process touch flag while touched (RSIVFlagTouch in RSIVHooksVolumeView.x)
// and the island's gesture is failed whenever the flag is up. NextUp 3 ships
// the same mechanism with an independent flag.
#import "RSIVShared.h"

@interface SBSystemApertureResizeGestureRecognizer : UIGestureRecognizer @end
@interface SBSystemApertureLongPressGestureRecognizer : UIGestureRecognizer @end
@interface SBVolumeControl : NSObject @end
@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstanceIfExists;
@property (readonly) BOOL isLockScreenVisible;
@end

// The LS visible-bit is published by the MediaRemoteUI scene, which on iOS 16
// outlives the lock screen (no disappear/window-loss on unlock), leaving the
// bit raised on the home screen. SpringBoard knows the truth, so the bit only
// counts while the lock screen UI is actually visible. Fails toward "visible"
// when the manager is unavailable — then the bit alone decides.
static BOOL RSIVLSSurfaceUp(void) {
    static Class LSM; if (!LSM) LSM = objc_getClass("SBLockScreenManager");
    if (![LSM respondsToSelector:@selector(sharedInstanceIfExists)]) return YES;
    SBLockScreenManager *m = [LSM sharedInstanceIfExists];
    if (!m || ![m respondsToSelector:@selector(isLockScreenVisible)]) return YES;
    @try { return m.isLockScreenVisible; } @catch (__unused NSException *e) { return YES; }
}

%group RSIVSpringBoard

// Suppress the system volume ribbon while a Crescendo slider is being dragged
// or is on screen: a visible slider is the volume UI, so hardware-button
// presses must not stack the ribbon on top — the same behaviour Apple's CC
// gets from its per-process MPVolumeHUDController registration, which cannot
// see our views in MediaRemoteUI (see kRSIVVisibleNotify in RSIVShared.h). Same
// method on iOS 16-26.
%hook SBVolumeControl
- (void)_presentVolumeHUDWithVolume:(float)volume {
    uint64_t vis = RSIVVisibleGet();
    BOOL sliderOnScreen = ((vis & kRSIVVisibleLS) && RSIVLSSurfaceUp()) || (vis & kRSIVVisibleDI);
    if (RSIVTouchFlagDown() || sliderOnScreen) return;
    %orig;
}
%end

%hook SBSystemApertureResizeGestureRecognizer
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (RSIVTouchFlagDown()) { self.state = UIGestureRecognizerStateFailed; return; }
    %orig;
}
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (RSIVTouchFlagDown()) { self.state = UIGestureRecognizerStateFailed; return; }
    %orig;
}
%end

// The long-press that opens the island can keep tracking into a drag; fail it
// too while the slider is being touched.
%hook SBSystemApertureLongPressGestureRecognizer
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if (RSIVTouchFlagDown()) { self.state = UIGestureRecognizerStateFailed; return; }
    %orig;
}
%end

%end // RSIVSpringBoard

%ctor {
    @autoreleasepool {
        // iOS 16 too: the HUD suppression applies to the lock-screen slider on
        // every version; the aperture recognizers are nil classes on devices
        // without a Dynamic Island.
        if (!RSIVIsSpringBoard() || RSIVIOSMajor() < 16) return;
        %init(RSIVSpringBoard);
        // Re-seed the live state token from persisted prefs on every
        // SpringBoard launch: notifyd drops a notify_state word once no
        // process holds the name registered, which happens across a respring —
        // without this a disabled toggle would read back as its fail-open
        // default. The token is global, so this one seed restores the state
        // for every reader process.
        RSIVPrefsPublishState();
        // No slider can be on screen this early, and MediaRemoteUI's own ctor
        // clear runs only when that process relaunches, which is on demand.
        RSIVVisibleClearAll();
    }
}
