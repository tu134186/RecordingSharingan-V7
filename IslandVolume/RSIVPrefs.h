// Derived from Yves000/Crescendo (GPL-3.0), upstream 33c60a69d76454c268709b381ad987832403e534.
// Modified 2026-10-28: isolated namespace/domain and opt-in integration in RecordingSharingan.
// User-preferences layer, two channels: the Settings pane persists booleans to
// CFPreferences (domain kRSIVPrefsDomain) and mirrors the live state into a
// Darwin notify_state token (kRSIVStateNotify). Injected processes read the
// token — global, immediate, sandbox-crossing; cross-process CFPreferences
// reads are cached/stale. CFPreferences remains the persisted fallback (token
// state is cleared by notifyd on reboot).
#import <Foundation/Foundation.h>

#define kRSIVPrefsDomain "com.tu.recordingsharingan.volume"        // CFPreferences app id / plist domain
#define kRSIVStateNotify "com.tu.recordingsharingan.volume.state"  // notify_state: live toggle bitmask + change signal

// bit63 marks the token as published — until Settings sets it, readers fall
// back to CFPreferences. Value bits 0..31; bit (n + 32) mirrors value bit n
// and means "the publishing Settings build knew this key" (an unknown bit
// falls back to CFPreferences). Adding a key WITHOUT its state bit fails
// silently: the toggle looks right in Settings but never applies live.
//
// Bit positions are wire format: SpringBoard and MediaRemoteUI can briefly run
// different builds mid-upgrade, so retired bits (bit 1) are not reassigned.
#define kRSIVStateValidBit      (1ULL << 63)
#define kRSIVStateEnabled       (1ULL << 0)   // "Enabled"        (master)
#define kRSIVStateLockScreen    (1ULL << 2)   // "showLockScreen"
#define kRSIVStateDynamicIsland (1ULL << 3)   // "showDynamicIsland"
#define kRSIVStateKnownShift    32

static inline uint64_t RSIVStateBitForKey(NSString *key) {
    if ([key isEqualToString:@"Enabled"])           return kRSIVStateEnabled;
    if ([key isEqualToString:@"showLockScreen"])    return kRSIVStateLockScreen;
    if ([key isEqualToString:@"showDynamicIsland"]) return kRSIVStateDynamicIsland;
    return 0;
}

// Read a boolean pref. Prefers the live notify-state token; falls back to
// CFPreferences (with `def`). Uses the caller-provided default; the integrated master defaults off.
BOOL RSIVPrefBool(NSString *key, BOOL def);

// Master on/off switch (key "Enabled", default NO).
BOOL RSIVEnabled(void);

// Register once per process for the change signal; `onChange` runs on main.
void RSIVPrefsObserve(dispatch_block_t onChange);

// Publish the current CFPreferences values into the notify-state token and
// post the change signal. Called by the Settings controller after each write.
void RSIVPrefsPublishState(void);

#pragma mark - Apple's Lock Screen switch (iOS 18.2+)

// Accessibility → Audio & Visual → Always Show Volume Control. It reaches the
// player through -[MRUserSettings alwaysShowVolumeControls] and flips the same
// showVolumeControlsView Crescendo forces, so from 18.2 the lock screen is
// Apple's and the Settings toggle mirrors this switch.
//
// Resolved at runtime from /usr/lib/libAccessibility.dylib, which must never
// become an LC_LOAD_DYLIB (see the Makefile). Symbol presence is the version
// gate — finer than RSIVIOSMajor() can express.

// Posted by libAccessibility when the switch changes.
#define kRSIVNativeVolumeNotify "com.apple.accessibility.alwaysshowvolume.status"

BOOL RSIVNativeVolumeSupported(void);
BOOL RSIVNativeVolumeEnabled(void);
void RSIVNativeVolumeSetEnabled(BOOL on);
