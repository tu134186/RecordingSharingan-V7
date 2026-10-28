// Derived from Yves000/Crescendo (GPL-3.0), upstream 33c60a69d76454c268709b381ad987832403e534.
// Modified 2026-10-28: isolated namespace/domain and opt-in integration in RecordingSharingan.
// iOS 16/17 lock screen: the now-playing platter is a remote MediaRemoteUI
// scene (MRUNowPlayingViewController context==2 / MRUCoverSheetViewController
// root) composited by SpringBoard's CoverSheet into a PLPlatterView. Apple
// ships the volume row dormant in this class family in the lock-screen context
// (Control Center's expanded card still uses it). Force the flag in the
// lock-screen host and push the grown size across the process boundary.
//
// Must stay ≤ iOS 17: on 18+ the lock-screen content is MRULockscreenView
// (RSIVHooksLockScreen18.x) and this class family only backs surfaces that
// manage their own volume UI.
#import "RSIVShared.h"

// Last pushed show-state and measured width per VC. Skips the forced relayout
// when the platter already reflects reality: the synchronous re-layout in
// rsiv_syncHeight makes the media UI re-query mediaserverd, and doing that on
// every settle tick risks a mediaserverd watchdog kill.
static void * const kRSIVPushedShowKey  = (void *)&kRSIVPushedShowKey;
static void * const kRSIVPushedWidthKey = (void *)&kRSIVPushedWidthKey;
// Stamped on the volume view once Apple's wiring pass has run for it, so the
// pass fires only on an actual show-flip or a freshly created view — see
// rsiv_stampHostAndForce.
static void * const kRSIVWiredKey       = (void *)&kRSIVWiredKey;

%group RSIVLockScreen1617

%hook MRUNowPlayingView

// The single forcing point. Apple's own gating funnels every state change
// through this setter, so any re-gating pass re-applies our value.
// Non-lock-screen hosts pass through untouched — CC keeps managing its own
// volume row.
- (void)setShowVolumeControlsView:(BOOL)show {
    if (RSIVShouldForceVolume(self)) show = YES;
    %orig(show);
}

// -updateVisibility can hide the row through a direct ivar write that bypasses
// the setter; re-assert after Apple's pass. The self-assignment routes through
// the forcing setter, and the equality guard prevents recursion.
- (void)updateVisibility {
    %orig;
    if (RSIVShouldForceVolume(self) && !self.showVolumeControlsView)
        self.showVolumeControlsView = YES;
}

%end

%hook MRUNowPlayingViewController

- (void)viewDidLoad {
    %orig;
    [self rsiv_stampHostAndForce];
    RSIVObservePrefsChanged(self, @selector(rsiv_prefsChanged));
}

// The LS scene disappears on unlock; a lingering visible-bit would suppress
// the volume ribbon on the home screen. (CC ≤17 shares this class in
// SpringBoard, but only the MediaRemoteUI LS host ever publishes.)
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    if (RSIVViewHostKind(self.viewIfLoaded) == RSIVHostLockScreen)
        RSIVVisibleSetBit(kRSIVVisibleLS, NO);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [self rsiv_stampHostAndForce];
    if (!RSIVEnabled()) return;
    __weak MRUNowPlayingViewController *weakSelf = self;   // see RSIVSettleTicks
    RSIVSettleTicks(^{
        [weakSelf rsiv_stampHostAndForce];
        [weakSelf rsiv_syncHeight];
    });
}

// Stamp the host kind on the view (the view-level force predicate reads it)
// and apply the flag in the lock-screen host. Idempotent — host detection can
// miss at -viewDidLoad (window not attached yet) and succeed on a later
// appearance/tick.
%new
- (void)rsiv_stampHostAndForce {
    if (![self isViewLoaded]) return;
    RSIVHostKind host = RSIVHostKindForVC(self);
    if (host == RSIVHostNone) return;
    MRUNowPlayingView *npv = (MRUNowPlayingView *)self.view;
    objc_setAssociatedObject(npv, kRSIVHostViewKey, @(host), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (host != RSIVHostLockScreen) return;

    BOOL want = RSIVShouldForceVolume(npv);
    BOOL flipped = (npv.showVolumeControlsView != want);
    if (flipped)
        npv.showVolumeControlsView = want;   // routes through the forcing setter
    if (!want) { [self rsiv_syncHeight]; return; }

    // Wiring is gated on an actual flip (or a volume view that has never been
    // wired — it is created lazily, so ticks retry until it exists): this
    // method runs on every appearance and settle tick, and re-running Apple's
    // pass when nothing changed visibly blinks the row on iOS 16. Skipping the
    // re-seed is safe: the view is its own volume-controller delegate once
    // wired (17+ would drop updates while offScreen, but the isOnScreen hook
    // in RSIVHooksVolumeView.x reports YES for forced players).
    MRUNowPlayingVolumeControlsView *vol = npv.volumeControlsView;
    if (flipped || !objc_getAssociatedObject(vol, kRSIVWiredKey)) {
        if (vol) objc_setAssociatedObject(vol, kRSIVWiredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Apple's wiring pass (volume controller connect, 17+: delegate +
        // hardware volume assertion). Its route data source stays in place —
        // see MPVolumeController in RSIVPrivate.h.
        if ([self respondsToSelector:@selector(updateVolumeControls)])
            [self updateVolumeControls];
        // Seed the volume view so it starts tracking immediately: volume
        // updates are dropped while onScreen is NO (17+; 16 has no such
        // property).
        if ([vol respondsToSelector:@selector(setOnScreen:)]) vol.onScreen = YES;
        [vol updateVisibility];
        [vol updateVolumeAnimated:NO];
        [npv setNeedsLayout];
    }
    [self rsiv_syncHeight];
}

%new
- (void)rsiv_prefsChanged {
    [self rsiv_stampHostAndForce];
    [self rsiv_syncHeight];
}

// Re-derive the platter height and push it across the process boundary.
// -[MRUNowPlayingView sizeThatFits:] accounts for the volume region when the
// flag is on, so the grown size flows from preferredContentSize into
// -[MRUCoverSheetViewController updatePreferredContentSize] → scene settings →
// SpringBoard resizes the PLPlatterView (grow and shrink). Never call
// -updateContentAnimated: instead — it recurses into a content update
// (MediaRemoteUI crash loop) and toggles the artwork mode.
%new
- (void)rsiv_syncHeight {
    if (![self isViewLoaded]) return;
    MRUNowPlayingView *npv = (MRUNowPlayingView *)self.view;
    if (RSIVViewHostKind(npv) != RSIVHostLockScreen) return;
    BOOL show = RSIVShouldForceVolume(npv) && npv.showVolumeControlsView;
    // Publish "LS slider on screen" for SpringBoard's ribbon suppression.
    RSIVVisibleSetBit(kRSIVVisibleLS, show && npv.window != nil);

    NSNumber *pushedShow = objc_getAssociatedObject(self, kRSIVPushedShowKey);
    CGFloat curW = npv.bounds.size.width;
    CGFloat pushedW = [objc_getAssociatedObject(self, kRSIVPushedWidthKey) doubleValue];
    BOOL needSync = (pushedShow == nil) ? show
                                        : (pushedShow.boolValue != show || fabs(pushedW - curW) > 0.5);
    if (!needSync) return;
    objc_setAssociatedObject(self, kRSIVPushedShowKey, @(show), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, kRSIVPushedWidthKey, @(curW), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [npv invalidateIntrinsicContentSize];
    for (UIView *v = npv; v; v = v.superview) [v setNeedsLayout];
    [npv layoutIfNeeded];

    CGFloat w = npv.bounds.size.width;
    if (w <= 0) return;
    CGSize fit = [npv sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)];
    if (fit.height <= 0) return;
    if (!CGSizeEqualToSize(self.preferredContentSize, fit))
        self.preferredContentSize = fit;
    UIViewController *csheet = RSIVCoverSheetAncestor(self);
    if (csheet && [csheet respondsToSelector:@selector(updatePreferredContentSize)]) {
        [csheet performSelector:@selector(updatePreferredContentSize)];
        [csheet.viewIfLoaded setNeedsLayout];
    }
}

%end

%end // RSIVLockScreen1617

%ctor {
    @autoreleasepool {
        if (RSIVIOSMajor() < 16 || RSIVIOSMajor() > 17) return;
        if (!objc_getClass("MRUNowPlayingView")) return;
        // Stale visible-bits from a dead publisher would suppress the volume
        // ribbon indefinitely — clear on publisher relaunch (the iOS 18 file's
        // ctor clear doesn't run on these versions).
        if (!RSIVIsSpringBoard()) RSIVVisibleClearAll();
        %init(RSIVLockScreen1617);
    }
}
