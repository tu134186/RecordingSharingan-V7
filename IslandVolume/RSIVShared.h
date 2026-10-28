// Derived from Yves000/Crescendo (GPL-3.0), upstream 33c60a69d76454c268709b381ad987832403e534.
// Modified 2026-10-28: isolated namespace/domain and opt-in integration in RecordingSharingan.
// Shared API for the hook translation units: process/version gates, lock-screen
// host detection, the volume-force predicate and the cross-process Darwin
// tokens. Implemented in RSIVShared.m so each process holds exactly one copy of
// every notify token and class cache.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>
#import "RSIVPrivate.h"
#import "RSIVPrefs.h"

#pragma mark - Process / version

NSInteger RSIVIOSMajor(void);
BOOL RSIVIsSpringBoard(void);

#pragma mark - Shared state

// Associated-object keys, defined once in RSIVShared.m: they are set in one hook
// file and read in another on the same object, so every file must see the same
// address.
extern void * const kRSIVHostViewKey;   // host kind stamped on the now-playing view
extern void * const kRSIVAvailableKey;  // route supports volume control (absent == YES)

// Posted process-locally whenever the Settings toggles change (re-broadcast of
// the Darwin prefs signal).
#define RSIVPrefsChangedNotification @"com.tu.recordingsharingan.volume.prefsChanged"

// Subscribe `observer` to RSIVPrefsChangedNotification (replaces any previous
// registration).
void RSIVObservePrefsChanged(id observer, SEL selector);

#pragma mark - Lock-screen host detection

// Where a now-playing VC is hosted. Control Center reuses the same class family
// on iOS ≤17, so lock-screen must be detected positively — the volume force
// never applies to CC or anything unrecognised.
typedef NS_ENUM(NSInteger, RSIVHostKind) {
    RSIVHostNone = 0,
    RSIVHostLockScreen,
    RSIVHostControlCenter,
    RSIVHostDynamicIsland,   // stamped by RSIVHooksDynamicIsland.x
};

RSIVHostKind RSIVHostKindForVC(MRUNowPlayingViewController *vc);
RSIVHostKind RSIVViewHostKind(UIView *view);

// Scene-root VC of the iOS 16/17 lock-screen scene — a detection signal and,
// via -updatePreferredContentSize, the cross-process re-measure lever.
UIViewController *RSIVCoverSheetAncestor(UIViewController *vc);

// Per-surface Settings gate, independent of the master switch.
BOOL RSIVInterfaceEnabled(RSIVHostKind h);

#pragma mark - Volume-force predicate

// Route supports volume control. Absent stamp == YES.
BOOL RSIVAvailable(UIView *playerView);
void RSIVSetAvailable(UIView *playerView, BOOL available);

// The single show predicate. Every lever derives from this, so slider
// visibility and platter height can never disagree.
BOOL RSIVShouldForceVolume(UIView *playerView);

// Walk up from the volume row to the player view that hosts it.
UIView *RSIVEnclosingPlayerView(UIView *view);

// Run `tick` a few times over ~1.5 s while a scene settles. Callers must
// weak-capture their VC in the block: Logos self is __unsafe_unretained, and a
// raw capture dangles if the VC is torn down inside the tick window.
void RSIVSettleTicks(dispatch_block_t tick);

#pragma mark - Cross-process slider-touch flag

// Raised while a finger is on a forced slider (published by MediaRemoteUI).
// SpringBoard reads it to fail the island's resize/dismiss gestures and to
// suppress the system volume ribbon for the duration of the drag.
//
// The "on" state carries the touch-down wall-clock second, not a bare 1:
// notify state outlives the setter process, and if the scene dies mid-touch a
// bare 1 would fail the island's gestures until reboot. Readers ignore a flag
// older than kRSIVTouchMaxAge; the display-side %ctor additionally clears it on
// relaunch. (The name keeps its historical "ditouch" suffix so a mid-upgrade
// SpringBoard still finds it.)
#define kRSIVTouchNotify "com.tu.recordingsharingan.volume.ditouch"
#define kRSIVTouchMaxAge 5 // s; the setter refreshes the timestamp while dragging

void RSIVTouchFlagSet(BOOL down);
BOOL RSIVTouchFlagDown(void);

// Attach the touch-flag recognizer to a volume view, once (defined in
// RSIVHooksVolumeView.x).
void RSIVAttachTouchFlag(UIView *volumeView);

#pragma mark - Cross-process slider-visibility token

// Bitmask of surfaces currently showing a forced slider, published by
// MediaRemoteUI, read by SpringBoard: a visible slider is the volume UI, so
// hardware-button presses must not stack the system ribbon on top. Apple's own
// suppression is per-process and cannot see views in MediaRemoteUI. All
// publishers run on MediaRemoteUI's main thread (single-writer).
//
// Wire format: surface bits in the low byte, the publisher's wall-clock second
// above them. Every clear path needs a cooperative teardown (a layout pass,
// viewDidDisappear, the relaunch ctor); scene invalidation without appearance
// callbacks, jetsam and suspension skip all of them, and a stale bit that
// never expires suppresses the volume ribbon until MediaRemoteUI relaunches.
// So the word expires instead of latching: the publisher re-stamps it every
// kRSIVVisibleBeat while any bit is set, readers drop a word older than
// kRSIVVisibleMaxAge. A visible slider implies a foreground scene, so the
// publisher is always running to keep the word fresh.
#define kRSIVVisibleNotify "com.tu.recordingsharingan.volume.visible"
#define kRSIVVisibleLS (1ULL << 0)
#define kRSIVVisibleDI (1ULL << 1)
#define kRSIVVisibleBitsMask 0xFFull
#define kRSIVVisibleBeat   2 // s; re-stamp interval while any bit is set
#define kRSIVVisibleMaxAge 6 // s; older words read as a dead publisher

uint64_t RSIVVisibleGet(void);
void RSIVVisibleSetBit(uint64_t bit, BOOL on);
void RSIVVisibleClearAll(void);
