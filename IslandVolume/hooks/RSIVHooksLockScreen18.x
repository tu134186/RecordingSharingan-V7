// Derived from Yves000/Crescendo (GPL-3.0), upstream 33c60a69d76454c268709b381ad987832403e534.
// Modified 2026-10-28: isolated namespace/domain and opt-in integration in RecordingSharingan.
// iOS 18-26 lock screen. The card is a Live Activity: the media controls are a
// remote MediaRemoteUI scene (MRULockscreenView — it still carries Apple's
// dormant showVolumeControlsView), hosted by SpringBoard inside a PLPlatterView.
// Force the flag on the view, let the scene re-negotiate its size via
// -updatePreferredContentSize, and publish the shown-state onto the Darwin
// visibility token for SpringBoard.
#import "../RSIVShared.h"

static void * const kRSIVPushed18Key = (void *)&kRSIVPushed18Key;

%group RSIVLS18Remote

%hook MRULockscreenView

// The forcing point (same shape as the 16/17 hook). MRULockscreenView only
// exists in the lock-screen scene, so no host stamping is needed.
- (void)setShowVolumeControlsView:(BOOL)show {
    if (RSIVShouldForceVolume(self)) show = YES;
    %orig(show);
    // Only "visible" while the scene is actually on a window — the LA scene
    // can outlive the lock screen, and a stale LS bit would suppress the
    // volume ribbon on the home screen.
    RSIVVisibleSetBit(kRSIVVisibleLS, show && self.window != nil);
}

- (void)updateVisibility {
    %orig;
    if (RSIVShouldForceVolume(self) && !self.showVolumeControlsView)
        self.showVolumeControlsView = YES;
}

%end

%hook MRULockscreenViewController

- (void)viewDidLoad {
    %orig;
    [self rsiv_ls18Apply];
    RSIVObservePrefsChanged(self, @selector(rsiv_ls18Apply));
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    RSIVVisibleSetBit(kRSIVVisibleLS, NO);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [self rsiv_ls18Apply];
    if (!RSIVEnabled()) return;
    __weak MRULockscreenViewController *weakSelf = self;   // see RSIVSettleTicks
    RSIVSettleTicks(^{ [weakSelf rsiv_ls18Apply]; });
}

// Apply the flag, seed the volume view, and push the (possibly changed) scene
// size. Idempotent; gated on an actual state flip before forcing a re-measure.
%new
- (void)rsiv_ls18Apply {
    if (![self isViewLoaded]) return;
    MRULockscreenView *lsv = (MRULockscreenView *)self.view;
    if (![lsv respondsToSelector:@selector(setShowVolumeControlsView:)]) return;

    BOOL want = RSIVShouldForceVolume(lsv);
    if (lsv.showVolumeControlsView != want)
        lsv.showVolumeControlsView = want;   // routes through the forcing setter

    if (want) {
        // Apple's wiring pass (volume controller connect, delegate, hardware
        // volume assertion). Its route data source stays in place — see
        // MPVolumeController in RSIVPrivate.h.
        if ([self respondsToSelector:@selector(updateVolumeControls)])
            [self updateVolumeControls];
        MRUNowPlayingVolumeControlsView *vol = lsv.volumeControlsView;
        if ([vol respondsToSelector:@selector(setOnScreen:)]) vol.onScreen = YES;
        [vol updateVisibility];
        [vol updateVolumeAnimated:NO];
    }
    RSIVVisibleSetBit(kRSIVVisibleLS, want && lsv.window != nil);

    NSNumber *pushed = objc_getAssociatedObject(self, kRSIVPushed18Key);
    if (pushed && pushed.boolValue == want) return;
    objc_setAssociatedObject(self, kRSIVPushed18Key, @(want), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [lsv setNeedsLayout];
    // Ask the scene to re-derive its size and push it to SpringBoard.
    if ([self respondsToSelector:@selector(updatePreferredContentSize)])
        [self updatePreferredContentSize];
}

%end

%end // RSIVLS18Remote

%ctor {
    @autoreleasepool {
        if (RSIVIOSMajor() < 18) return;
        // The visibility token persists in notifyd past its publisher: if
        // MediaRemoteUI died with a slider up, stale bits would keep the
        // volume ribbon suppressed. Clear when the publisher comes up — also
        // on the versions that skip the group below, where nothing else would.
        if (!RSIVIsSpringBoard()) RSIVVisibleClearAll();
        // From 18.2 the lock screen is Apple's (RSIVNativeVolume* in RSIVPrefs.h).
        // The group stays uninstalled rather than neutered hook by hook: every
        // lever in it derives from RSIVShouldForceVolume, which already hands the
        // surface back, and the LS visibility bit would otherwise be raised for
        // Apple's own slider.
        if (RSIVNativeVolumeSupported()) return;
        %init(RSIVLS18Remote);
    }
}
