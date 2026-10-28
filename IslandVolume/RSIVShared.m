// Derived from Yves000/Crescendo (GPL-3.0), upstream 33c60a69d76454c268709b381ad987832403e534.
// Modified 2026-10-28: isolated namespace/domain and opt-in integration in RecordingSharingan.
// Implementations for RSIVShared.h. Everything with process-wide state lives
// here on purpose: one associated-object key address, one notify token and one
// class cache per process (a static inline in the header would duplicate them
// per translation unit).
#import "RSIVShared.h"

void * const kRSIVHostViewKey  = (void *)&kRSIVHostViewKey;
void * const kRSIVAvailableKey = (void *)&kRSIVAvailableKey;

#pragma mark - Process / version

NSInteger RSIVIOSMajor(void) {
    static NSInteger v; static dispatch_once_t once;
    dispatch_once(&once, ^{ v = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion; });
    return v;
}

BOOL RSIVIsSpringBoard(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"];
}

#pragma mark - Prefs re-broadcast

void RSIVObservePrefsChanged(id observer, SEL selector) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc removeObserver:observer name:RSIVPrefsChangedNotification object:nil];
    [nc addObserver:observer selector:selector name:RSIVPrefsChangedNotification object:nil];
}

// One process-local re-broadcaster for the Darwin prefs signal, so every hook
// file can rely on RSIVPrefsChangedNotification without owning the registration
// (RSIVPrefsObserve accepts a single block per process).
__attribute__((constructor)) static void RSIVSharedInit(void) {
    if (RSIVIOSMajor() < 16) return;
    RSIVPrefsObserve(^{
        [NSNotificationCenter.defaultCenter postNotificationName:RSIVPrefsChangedNotification
                                                          object:nil];
    });
}

#pragma mark - Lock-screen host detection

// Class lookups are cached after the first hit and retried while nil:
// MediaControls.framework loads on demand, so a class can appear late. Classes
// are never unloaded, so a non-nil cache stays valid.
static Class RSIVClassCoverSheet(void) {
    static Class c; if (!c) c = objc_getClass("MRUCoverSheetViewController"); return c;
}
static Class RSIVClassLockscreenView(void) {
    static Class c; if (!c) c = objc_getClass("MRULockscreenView"); return c;
}

static const long long kRSIVLockScreenContext = 2; // MRUNowPlayingViewController lock-screen context

static UIViewController *RSIVAncestorOfClass(Class cls, UIViewController *vc) {
    if (!cls) return nil;
    for (UIViewController *a = vc; a; a = a.parentViewController)
        if ([a isKindOfClass:cls]) return a;
    return nil;
}

UIViewController *RSIVCoverSheetAncestor(UIViewController *vc) {
    return RSIVAncestorOfClass(RSIVClassCoverSheet(), vc);
}

// Fallback for an iOS 16 context value drift: the window class carries the
// surface. The window may be nil before the view is on screen — callers retry
// on appearance.
static BOOL RSIVVCInLockScreenWindow(UIViewController *vc) {
    UIWindow *win = vc.viewIfLoaded.window;
    if (!win) return NO;
    NSString *cls = NSStringFromClass(win.class);
    return [cls containsString:@"CoverSheet"] || [cls containsString:@"Secure"];
}

RSIVHostKind RSIVHostKindForVC(MRUNowPlayingViewController *vc) {
    static Class cc; if (!cc) cc = objc_getClass("MRUControlCenterViewController");
    if (!vc) return RSIVHostNone;
    if (vc.context == kRSIVLockScreenContext) return RSIVHostLockScreen;
    if (RSIVAncestorOfClass(cc, vc)) return RSIVHostControlCenter;
    if (RSIVCoverSheetAncestor(vc)) return RSIVHostLockScreen;
    if (RSIVVCInLockScreenWindow(vc)) return RSIVHostLockScreen;
    return RSIVHostNone;
}

RSIVHostKind RSIVViewHostKind(UIView *view) {
    NSNumber *n = objc_getAssociatedObject(view, kRSIVHostViewKey);
    return n ? (RSIVHostKind)n.integerValue : RSIVHostNone;
}

BOOL RSIVInterfaceEnabled(RSIVHostKind h) {
    switch (h) {
        case RSIVHostLockScreen:    return RSIVPrefBool(@"showLockScreen", NO);
        case RSIVHostDynamicIsland: return RSIVPrefBool(@"showDynamicIsland", YES);
        default:                  return YES;
    }
}

#pragma mark - Volume-force predicate

// "Listening suggestions" / "Not Playing" state: the player swaps the
// transport for suggestion tiles, so a forced volume row would float under
// content it doesn't belong to. Duck-typed — a missing selector reports "not
// suggesting".
static BOOL RSIVViewShowsSuggestions(UIView *playerView) {
    if (![playerView respondsToSelector:@selector(showSuggestionsView)]) return NO;
    return [(MRUNowPlayingView *)playerView showSuggestionsView];
}

BOOL RSIVAvailable(UIView *playerView) {
    NSNumber *n = objc_getAssociatedObject(playerView, kRSIVAvailableKey);
    return n ? n.boolValue : YES;
}

void RSIVSetAvailable(UIView *playerView, BOOL available) {
    objc_setAssociatedObject(playerView, kRSIVAvailableKey, @(available), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL RSIVShouldForceVolume(UIView *playerView) {
    if (!RSIVEnabled()) return NO;
    // MRULockscreenView exists only in the iOS 18+ lock-screen scene, so it is
    // lock-screen by construction; everything else carries a stamped host kind.
    Class lsv = RSIVClassLockscreenView();
    RSIVHostKind kind = (lsv && [playerView isKindOfClass:lsv]) ? RSIVHostLockScreen
                                                              : RSIVViewHostKind(playerView);
    if (kind != RSIVHostLockScreen && kind != RSIVHostDynamicIsland) return NO;
    // iOS 18.2+ drives the same flag from its own system switch (see
    // RSIVNativeVolume* in RSIVPrefs.h), so the lock screen is handed back rather
    // than contested. The island player has no volume row on any version and
    // is unaffected.
    if (kind == RSIVHostLockScreen && RSIVNativeVolumeSupported()) return NO;
    if (!RSIVInterfaceEnabled(kind)) return NO;
    return RSIVAvailable(playerView) && !RSIVViewShowsSuggestions(playerView);
}

UIView *RSIVEnclosingPlayerView(UIView *view) {
    static Class npv;   if (!npv)   npv   = objc_getClass("MRUNowPlayingView");
    static Class div;   if (!div)   div   = objc_getClass("MRUActivityNowPlayingView");
    static Class div16; if (!div16) div16 = objc_getClass("MRUSessionNowPlayingView");
    Class lsv = RSIVClassLockscreenView();
    for (UIView *a = view.superview; a; a = a.superview) {
        if ((npv && [a isKindOfClass:npv]) || (lsv && [a isKindOfClass:lsv])
            || (div && [a isKindOfClass:div]) || (div16 && [a isKindOfClass:div16])) return a;
    }
    return nil;
}

void RSIVSettleTicks(dispatch_block_t tick) {
    static const double delays[] = { 0.1, 0.3, 0.6, 1.0, 1.5 };
    for (size_t i = 0; i < sizeof(delays) / sizeof(delays[0]); i++)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), tick);
}

#pragma mark - Cross-process slider-touch flag

static int RSIVTouchToken(void) {
    static int token = -1; static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (notify_register_check(kRSIVTouchNotify, &token) != NOTIFY_STATUS_OK) token = -1;
    });
    return token;
}

void RSIVTouchFlagSet(BOOL down) {
    int t = RSIVTouchToken();
    if (t == -1) return;
    // Coalesce on the second-granular timestamp: touchesMoved refreshes at
    // event rate, one notifyd write per second is enough. The sentinel makes
    // the first call always write, so the %ctor clear reaches a stale word
    // left by a dead publisher.
    static uint64_t last = UINT64_MAX;
    uint64_t next = down ? (uint64_t)time(NULL) : 0;
    if (next == last) return;
    last = next;
    notify_set_state(t, next);
    notify_post(kRSIVTouchNotify);
}

BOOL RSIVTouchFlagDown(void) {
    int t = RSIVTouchToken();
    if (t == -1) return NO;
    uint64_t v = 0;
    notify_get_state(t, &v);
    if (v == 0) return NO;
    time_t now = time(NULL);
    return now >= (time_t)v && now - (time_t)v <= kRSIVTouchMaxAge; // stale == setter died mid-touch
}

#pragma mark - Cross-process slider-visibility token

static int RSIVVisibleToken(void) {
    static int token = -1; static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (notify_register_check(kRSIVVisibleNotify, &token) != NOTIFY_STATUS_OK) token = -1;
    });
    return token;
}

uint64_t RSIVVisibleGet(void) {
    int t = RSIVVisibleToken();
    uint64_t v = 0;
    if (t != -1) notify_get_state(t, &v);
    uint64_t bits = v & kRSIVVisibleBitsMask;
    if (!bits) return 0;
    time_t now = time(NULL), ts = (time_t)(v >> 8);
    if (now < ts || now - ts > kRSIVVisibleMaxAge) return 0; // stale == publisher died or suspended
    return bits;
}

// Re-stamps the word while any bit is set; not scheduled otherwise. Main
// queue, like every writer here.
static dispatch_source_t gRSIVVisibleBeatTimer;
static void RSIVVisibleWrite(uint64_t bits);

static void RSIVVisibleBeatUpdate(BOOL alive) {
    if (alive) {
        if (gRSIVVisibleBeatTimer) return;
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                         dispatch_get_main_queue());
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, kRSIVVisibleBeat * NSEC_PER_SEC),
                                  kRSIVVisibleBeat * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            // Re-stamp the raw bits, not the validated read: a beat delayed
            // past kRSIVVisibleMaxAge must revive the word, not drop it.
            int t = RSIVVisibleToken();
            uint64_t raw = 0;
            if (t != -1) notify_get_state(t, &raw);
            RSIVVisibleWrite(raw & kRSIVVisibleBitsMask);
        });
        dispatch_resume(timer);
        gRSIVVisibleBeatTimer = timer;
    } else if (gRSIVVisibleBeatTimer) {
        dispatch_source_cancel(gRSIVVisibleBeatTimer);
        gRSIVVisibleBeatTimer = nil;
    }
}

static void RSIVVisibleWrite(uint64_t bits) {
    int t = RSIVVisibleToken();
    if (t == -1) return;
    // Coalesce on the encoded word (bits + second): the DI layout pass calls
    // in at frame rate, one notifyd write per second is enough. The sentinel
    // makes the first call always write, so a ctor clear reaches a stale word
    // left by a dead publisher.
    static uint64_t last = UINT64_MAX;
    uint64_t word = bits ? (((uint64_t)time(NULL) << 8) | bits) : 0;
    if (word != last) {
        last = word;
        notify_set_state(t, word);
        notify_post(kRSIVVisibleNotify);
    }
    RSIVVisibleBeatUpdate(bits != 0);
}

void RSIVVisibleSetBit(uint64_t bit, BOOL on) {
    uint64_t bits = RSIVVisibleGet(); // validated; stale bits must not survive
    RSIVVisibleWrite(on ? (bits | bit) : (bits & ~bit));
}

void RSIVVisibleClearAll(void) {
    RSIVVisibleWrite(0);
}
