// Derived from Yves000/Crescendo (GPL-3.0), upstream 33c60a69d76454c268709b381ad987832403e534.
// Modified 2026-10-28: isolated namespace/domain and opt-in integration in RecordingSharingan.
// Dynamic Island expanded now-playing player. Two class generations, one
// mechanism: iOS 16 MRUSessionNowPlaying*, iOS 17-26 MRUActivityNowPlaying*,
// both rendered by MediaRemoteUI into a SystemAperture scene. Neither family
// has a dormant volume row, so Crescendo builds Apple's
// MRUNowPlayingVolumeControlsView itself and wires MRUVolumeController +
// MPVolumeControllerSystemDataSource. That pairing is safe only here: no Apple
// code touches this controller, so nothing calls route-DS-only API on it (that
// combination crashes on the lock screen, where Apple's own VC owns the
// controller).
//
// Height + placement: grow -preferredHeightForBottomSafeArea, clamp -bounds
// during Apple's layout pass, then place the strip explicitly. The strip sits
// above a visible NextUp 3 row, keeping the lock-screen order — transport,
// volume, up-next.
#import "RSIVShared.h"
#import <mach-o/dyld.h>

// Above a NextUp row the strip only needs the slider plus small gaps; alone it
// also carries the island's bottom padding, so the reservation is larger.
static const CGFloat kRSIVDIStripHeight = 28.0;  // 24 pt slider + gaps
static const CGFloat kRSIVDIStripAlone  = 40.0;  // slider + bottom padding share
static const CGFloat kRSIVDIBottomPad   = 24.0;  // island content bottom padding
static const long long kRSIVDIExpandedMode = 4;  // activeLayoutMode when fully expanded
static const CGFloat kRSIVDIExpandedMinHeight = 120.0; // view is reused for the compact pill

static void * const kRSIVDIReserveKey = (void *)&kRSIVDIReserveKey;

// The player view whose layout pass currently runs with the height clamp
// applied, and the amount to clamp by. Main-thread only; a pointer compare
// keeps the -bounds override off the associated-object lock (-bounds is called
// at animation frame rate).
static __unsafe_unretained UIView *gRSIVDIClamped;
static CGFloat gRSIVDIClampAmount = kRSIVDIStripHeight;

// Both VC families get this property via %property; declaring it on
// UIViewController lets the shared helpers below stay family-agnostic.
@interface UIViewController (RSIVDIVolume)
@property (nonatomic, strong) MRUNowPlayingVolumeControlsView *rsiv_diVolume;
- (void)rsiv_diEnsure;
- (void)rsiv_diPrefsChanged;
@end

#pragma mark - Shared mechanics (both class generations)

// Family-specific on purpose: the verified expansion signal on 17+ is
// activeLayoutMode; only the iOS 16 family goes through -isExpanded (with the
// layout mode as its fallback).
static BOOL RSIVDIActivityExpanded(UIViewController *vc) {
    return [(MRUActivityNowPlayingViewController *)vc activeLayoutMode] >= kRSIVDIExpandedMode;
}
static BOOL RSIVDISessionExpanded(UIViewController *vc) {
    @try { if ([vc respondsToSelector:@selector(isExpanded)])
        return [(MRUSessionNowPlayingViewController *)vc isExpanded]; }
    @catch (__unused NSException *e) {}
    return [(MRUSessionNowPlayingViewController *)vc activeLayoutMode] >= kRSIVDIExpandedMode;
}

// Which of the two applies to this VC, decided by which %init ran.
static BOOL (*gRSIVDIExpanded)(UIViewController *) = RSIVDIActivityExpanded;
static BOOL RSIVDIExpanded(UIViewController *vc) { return gRSIVDIExpanded(vc); }

// Create + wire our volume row inside `host`, stamp the host, return it.
static MRUNowPlayingVolumeControlsView *RSIVDICreateVolume(UIView *host) {
    static Class VolCls, CtlCls, DSCls;
    if (!VolCls) VolCls = objc_getClass("MRUNowPlayingVolumeControlsView");
    if (!CtlCls) CtlCls = objc_getClass("MRUVolumeController");
    if (!DSCls)  DSCls  = objc_getClass("MPVolumeControllerSystemDataSource");
    if (!VolCls || !CtlCls || !DSCls || !host) return nil;

    MRUNowPlayingVolumeControlsView *vol = [[VolCls alloc] initWithFrame:CGRectZero];
    MRUVolumeController *ctl = [[CtlCls alloc] init];
    ctl.dataSource = [[DSCls alloc] init];
    vol.volumeController = ctl;                     // wires ctl.delegate = vol
    if ([vol respondsToSelector:@selector(setOnScreen:)]) vol.onScreen = YES;  // 17+
    // The host's styling provider gives the platter's monochrome look; the
    // default tint renders blue.
    if ([host respondsToSelector:@selector(stylingProvider)]
        && [(MRUActivityNowPlayingView *)host stylingProvider]
        && [vol respondsToSelector:@selector(setStylingProvider:)]) {
        vol.stylingProvider = [(MRUActivityNowPlayingView *)host stylingProvider];
        if ([vol respondsToSelector:@selector(updateVisualStyling)]) [vol updateVisualStyling];
    }
    vol.hidden = YES;   // touch flag: 17+ via -didMoveToWindow recognizer, 16 via tracking hooks
    [host addSubview:vol];
    objc_setAssociatedObject(host, kRSIVHostViewKey, @(RSIVHostDynamicIsland), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [ctl updateVolumeValue];
    [vol updateVolumeAnimated:NO];
    return vol;
}

// Create the row once the view exists; re-attach it if the view was rebuilt.
static void RSIVDIEnsure(UIViewController *vc) {
    if (![vc isViewLoaded]) return;
    MRUNowPlayingVolumeControlsView *vol = vc.rsiv_diVolume;
    if (vol) {
        if (!vol.superview) [vc.view addSubview:vol];
        return;
    }
    vc.rsiv_diVolume = RSIVDICreateVolume(vc.view);
}

// Height of a visible NextUp row inside `host`, 0 if there is none.
static CGFloat RSIVDINURowHeight(UIView *host) {
    static Class NURow; if (!NURow) NURow = objc_getClass("NUNextUpRowView");
    CGFloat nuH = 0;
    if (NURow) {
        for (UIView *sub in host.subviews)
            if ([sub isKindOfClass:NURow] && !sub.isHidden)
                nuH = MAX(nuH, sub.frame.size.height);
    }
    return nuH;
}

static CGFloat RSIVDIStripFor(UIView *host) {
    return RSIVDINURowHeight(host) > 0 ? kRSIVDIStripHeight : kRSIVDIStripAlone;
}

// The aperture reserves this height at the bottom of the expanded player; grow
// it by the strip so the island opens tall enough for the slider (stacks with
// NextUp 3's identical hook, which adds its own strip).
static double RSIVDIGrowBottomSafeArea(UIViewController *vc, double h) {
    if (RSIVEnabled() && RSIVInterfaceEnabled(RSIVHostDynamicIsland)
        && [vc isViewLoaded] && RSIVDIExpanded(vc) && RSIVAvailable(vc.view)) {
        CGFloat strip = RSIVDIStripFor(vc.view);
        objc_setAssociatedObject(vc, kRSIVDIReserveKey, @(strip), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        h += strip;
    }
    return h;
}

// Live Settings toggle: hide/show is handled by layout; the aperture re-reads
// our grown height only through Apple's own layout-mode update, so drive it on
// the flip.
static void RSIVDIPrefsChanged(UIViewController *vc) {
    if (![vc isViewLoaded]) return;
    [vc.view setNeedsLayout];
    if (!RSIVDIExpanded(vc)) return;
    if ([vc respondsToSelector:@selector(updateLayoutModesPreferringImmediateTransition:deferInCustomLayout:reason:)]) {
        @try { [(MRUActivityNowPlayingViewController *)vc
                    updateLayoutModesPreferringImmediateTransition:NO
                                               deferInCustomLayout:NO
                                                            reason:@"Crescendo volume row"]; }
        @catch (__unused NSException *e) {}
    }
}

// Whether this layout pass should clamp and place the strip.
static BOOL RSIVDIViewShows(UIView *host) {
    return host.bounds.size.height >= kRSIVDIExpandedMinHeight
        && RSIVViewHostKind(host) == RSIVHostDynamicIsland
        && RSIVShouldForceVolume(host);
}

// Place the strip in the host's bottom band, above a visible NextUp 3 row.
static void RSIVDILayoutVolume(UIView *host, MRUNowPlayingVolumeControlsView *vol, BOOL show) {
    show = show && vol != nil;
    // Publish "DI slider on screen" for SpringBoard's ribbon suppression. Runs
    // before any early return: a pass without a row must still clear the bit,
    // or a stale bit would suppress the ribbon until MediaRemoteUI relaunches.
    RSIVVisibleSetBit(kRSIVVisibleDI, show && host.window != nil);
    if (!vol) return;
    vol.hidden = !show;
    if (!show) return;

    // Real height via -frame (the layer), NOT -bounds: when this pass nests
    // inside NextUp 3's layoutSubviews, their bounds clamp is still active and
    // -bounds already reports height minus their row. -frame bypasses every
    // bounds hook.
    CGFloat realH = host.frame.size.height;
    CGFloat width = host.bounds.size.width;   // width is never clamped
    // The NextUp row is measured by its height, never its position — this pass
    // can nest inside NextUp's, where the row's origin is still last pass's
    // value but its height is a per-surface constant.
    CGFloat nuH = RSIVDINURowHeight(host);
    [host bringSubviewToFront:vol];
    CGFloat bottom = realH - nuH;
    // 24 pt side margins match Apple's rows.
    CGFloat sliderH = 24.0;
    CGFloat bandTop = bottom - (nuH > 0 ? kRSIVDIStripHeight : kRSIVDIStripAlone);
    static Class Transport; if (!Transport) Transport = objc_getClass("MRUNowPlayingTransportControlsView");
    if (Transport) {
        for (UIView *sub in host.subviews)
            if ([sub isKindOfClass:Transport] && !sub.isHidden) {
                CGFloat maxY = CGRectGetMaxY(sub.frame);
                if (maxY > 0 && maxY < bottom) bandTop = maxY;
                break;
            }
    }
    CGFloat y;
    if (nuH > 0) {
        // Above a NextUp row: center in the free band between the transport
        // and the row's separator.
        y = bandTop + ((bottom - bandTop) - sliderH) / 2.0;
    } else {
        // Alone at the bottom edge: centering would split Apple's own bottom
        // safe area unevenly around the slider. Anchor it with the island's
        // 24 pt content padding instead, floored at the band top so it can
        // never ride into the transport controls.
        y = MAX(bandTop, bottom - kRSIVDIBottomPad - sliderH);
    }
    vol.frame = CGRectMake(24.0, y, width - 48.0, sliderH);
}

// layoutSubviews tail: find the owning VC (the only responder with the
// property) and place the row.
static void RSIVDILayoutPass(UIView *host, BOOL show) {
    UIResponder *r = host.nextResponder;
    while (r && ![r respondsToSelector:@selector(rsiv_diVolume)]) r = r.nextResponder;
    UIViewController *vc = (UIViewController *)r;
    RSIVDILayoutVolume(host, vc.rsiv_diVolume, show);

    // The reservation was made for the row state seen at query time; if the
    // NextUp row appeared or vanished since, ask the aperture to re-measure.
    if (!show || !vc) return;
    NSNumber *reserved = objc_getAssociatedObject(vc, kRSIVDIReserveKey);
    if (reserved && reserved.doubleValue != RSIVDIStripFor(host)) {
        static BOOL pending;
        if (!pending) {
            pending = YES;
            __weak UIViewController *weakVC = vc;
            dispatch_async(dispatch_get_main_queue(), ^{
                pending = NO;
                if (weakVC) RSIVDIPrefsChanged(weakVC);
            });
        }
    }
}

#pragma mark - iOS 17-26: MRUActivityNowPlaying*

%group RSIVDI

%hook MRUActivityNowPlayingViewController

%property (nonatomic, strong) MRUNowPlayingVolumeControlsView *rsiv_diVolume;

- (void)viewDidLoad {
    %orig;
    [self rsiv_diEnsure];
    RSIVObservePrefsChanged(self, @selector(rsiv_diPrefsChanged));
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [self rsiv_diEnsure];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    RSIVVisibleSetBit(kRSIVVisibleDI, NO);
}

- (double)preferredHeightForBottomSafeArea {
    return RSIVDIGrowBottomSafeArea(self, %orig);
}

%new
- (void)rsiv_diEnsure { RSIVDIEnsure(self); }

%new
- (void)rsiv_diPrefsChanged { RSIVDIPrefsChanged(self); }

%end

%hook MRUActivityNowPlayingView

// Report the compact height during our own layout pass so %orig lays the media
// controls out top-anchored and leaves the bottom strip free. Stacks with
// NextUp 3's identical clamp — during Apple's pass both are active, so the
// content sits above both strips regardless of hook nesting order.
- (CGRect)bounds {
    CGRect b = %orig;
    if (self == gRSIVDIClamped) b.size.height -= gRSIVDIClampAmount;
    return b;
}

- (void)layoutSubviews {
    BOOL show = RSIVDIViewShows(self);
    if (show) {
        gRSIVDIClampAmount = RSIVDIStripFor(self);
        gRSIVDIClamped = self;
        // @finally: if Apple's layout throws, the clamp must still be lifted —
        // otherwise this view permanently reports a clamped -bounds.
        @try { %orig; }
        @finally { gRSIVDIClamped = nil; }
    } else {
        %orig;
    }
    RSIVDILayoutPass(self, show);
}

%end

%end // RSIVDI

#pragma mark - iOS 16: MRUSessionNowPlaying* (pre-Activity family)

%group RSIVDI16

%hook MRUSessionNowPlayingViewController

%property (nonatomic, strong) MRUNowPlayingVolumeControlsView *rsiv_diVolume;

- (void)viewDidLoad {
    %orig;
    [self rsiv_diEnsure];
    RSIVObservePrefsChanged(self, @selector(rsiv_diPrefsChanged));
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [self rsiv_diEnsure];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    RSIVVisibleSetBit(kRSIVVisibleDI, NO);
}

- (double)preferredHeightForBottomSafeArea {
    return RSIVDIGrowBottomSafeArea(self, %orig);
}

%new
- (void)rsiv_diEnsure { RSIVDIEnsure(self); }

%new
- (void)rsiv_diPrefsChanged { RSIVDIPrefsChanged(self); }

%end

%hook MRUSessionNowPlayingView

- (CGRect)bounds {
    CGRect b = %orig;
    if (self == gRSIVDIClamped) b.size.height -= gRSIVDIClampAmount;
    return b;
}

- (void)layoutSubviews {
    BOOL show = RSIVDIViewShows(self);
    if (show) {
        gRSIVDIClampAmount = RSIVDIStripFor(self);
        gRSIVDIClamped = self;
        @try { %orig; }
        @finally { gRSIVDIClamped = nil; }
    } else {
        %orig;
    }
    RSIVDILayoutPass(self, show);
}

%end

%end // RSIVDI16

// MediaControls.framework is loaded on demand in SpringBoard, so at
// constructor time these classes may not exist and %init would silently hook
// nothing. Install when the image shows up; _dyld_register_func_for_add_image
// replays already-loaded images, so MediaRemoteUI (which links it) installs
// immediately.
static void RSIVDIInitIfLoaded(void) {
    static BOOL done = NO;
    if (done) return;
    if (objc_getClass("MRUActivityNowPlayingViewController")) {
        done = YES;
        %init(RSIVDI);
    } else if (objc_getClass("MRUSessionNowPlayingViewController")) {
        done = YES;
        gRSIVDIExpanded = RSIVDISessionExpanded;
        %init(RSIVDI16);
    }
}

static void RSIVDIImageAdded(const struct mach_header *mh, intptr_t slide) {
    RSIVDIInitIfLoaded();
}

%ctor {
    @autoreleasepool {
        if (RSIVIOSMajor() < 16) return;
        // The touch flag outlives its setter in notifyd: if this process died
        // mid-touch it is still raised on relaunch, and SpringBoard would keep
        // failing the island's gestures until the staleness backstop expires.
        if (!RSIVIsSpringBoard()) RSIVTouchFlagSet(NO);
        _dyld_register_func_for_add_image(RSIVDIImageAdded);
    }
}
