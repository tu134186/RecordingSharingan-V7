// Derived from Yves000/Crescendo (GPL-3.0), upstream 33c60a69d76454c268709b381ad987832403e534.
// Modified 2026-10-28: isolated namespace/domain and opt-in integration in RecordingSharingan.
#import "RSIVPrefs.h"
#import <os/lock.h>
#import <notify.h>
#import <dlfcn.h>

#pragma mark - notify_state token

// One registration per process. notify_register_check gives a token usable for
// both get_state and set_state; the state itself is global to the name, so
// Settings' set_state is visible here.
static int RSIVStateToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (notify_register_check(kRSIVStateNotify, &token) != NOTIFY_STATUS_OK) token = -1;
    });
    return token;
}

// Memoized behind notify_check (a shared-memory test, no notifyd round-trip):
// the force predicate reads this several times per layout pass, and an
// unconditional notify_get_state each time is a MIG call to notifyd.
static BOOL RSIVStateRead(uint64_t *out) {
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static uint64_t cached;
    static BOOL primed;
    int t = RSIVStateToken();
    if (t == -1) return NO;
    os_unfair_lock_lock(&lock);
    int changed = 0;
    if (!primed || (notify_check(t, &changed) == NOTIFY_STATUS_OK && changed))
        primed = notify_get_state(t, &cached) == NOTIFY_STATUS_OK;
    BOOL ok = primed;
    *out = cached;
    os_unfair_lock_unlock(&lock);
    return ok;
}

#pragma mark - CFPreferences fallback (persisted; reliable at process start)

// Cached so the token-invalid path (pre-publish / just after reboot) doesn't
// hit cfprefsd on every layout. Once Settings publishes, reads never reach
// here.
static NSMutableDictionary<NSString *, NSNumber *> *gCFCache;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

// `fresh`: Settings must CFPreferencesAppSynchronize before reading (its own
// writes); passive readers must not (cross-process cache).
static BOOL RSIVReadCF(NSString *key, BOOL def, BOOL fresh) {
    if (!fresh) {
        os_unfair_lock_lock(&gLock);
        if (!gCFCache) gCFCache = [NSMutableDictionary new];
        NSNumber *c = gCFCache[key];
        if (c) { BOOL v = c.boolValue; os_unfair_lock_unlock(&gLock); return v; }
        os_unfair_lock_unlock(&gLock);
    } else {
        CFPreferencesAppSynchronize(CFSTR(kRSIVPrefsDomain));
    }
    Boolean present = false;
    Boolean value = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key,
                                                    CFSTR(kRSIVPrefsDomain), &present);
    BOOL result = present ? (BOOL)value : def;
    if (!fresh) {
        os_unfair_lock_lock(&gLock);
        gCFCache[key] = @(result);
        os_unfair_lock_unlock(&gLock);
    }
    return result;
}

#pragma mark - Public

BOOL RSIVPrefBool(NSString *key, BOOL def) {
    uint64_t s = 0;
    if (RSIVStateRead(&s) && (s & kRSIVStateValidBit)) {
        uint64_t bit = RSIVStateBitForKey(key);
        // Only trust bits the publisher knew — see kRSIVStateKnownShift in RSIVPrefs.h.
        if (bit && (s & (bit << kRSIVStateKnownShift))) return (s & bit) != 0;
    }
    return RSIVReadCF(key, def, /*fresh=*/NO);
}

BOOL RSIVEnabled(void) { return RSIVPrefBool(@"Enabled", NO); }

void RSIVPrefsObserve(dispatch_block_t onChange) {
    static int token;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_dispatch(kRSIVStateNotify, &token, dispatch_get_main_queue(), ^(int t) {
            os_unfair_lock_lock(&gLock);
            [gCFCache removeAllObjects]; // token drives reads now; drop stale fallback too
            os_unfair_lock_unlock(&gLock);
            if (onChange) onChange();
        });
    });
}

void RSIVPrefsPublishState(void) {
    // Build the word from the freshly-written plist (Settings' own process, so
    // the read is reliable), stamp it valid, publish, and signal.
    uint64_t mask = kRSIVStateValidBit;
    if (RSIVReadCF(@"Enabled",           NO, /*fresh=*/YES)) mask |= kRSIVStateEnabled;
    if (RSIVReadCF(@"showLockScreen",    NO, YES))           mask |= kRSIVStateLockScreen;
    if (RSIVReadCF(@"showDynamicIsland", YES, YES))           mask |= kRSIVStateDynamicIsland;
    mask |= (kRSIVStateEnabled | kRSIVStateLockScreen | kRSIVStateDynamicIsland)
            << kRSIVStateKnownShift;

    int t = RSIVStateToken();
    if (t != -1) notify_set_state(t, mask);
    notify_post(kRSIVStateNotify);
}

#pragma mark - Apple's Lock Screen switch (iOS 18.2+)

typedef BOOL (*RSIVNativeVolumeGetter)(void);
typedef void (*RSIVNativeVolumeSetter)(BOOL);

static RSIVNativeVolumeGetter gNativeGet;
static RSIVNativeVolumeSetter gNativeSet;

// RTLD_DEFAULT covers the injected processes, where MediaRemote already pulls
// libAccessibility in. Settings loads it only once an Accessibility pane opens,
// hence the explicit dlopen; the library is in the shared cache, so that is a
// lookup rather than a mapping.
static void RSIVNativeResolve(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gNativeGet = (RSIVNativeVolumeGetter)dlsym(RTLD_DEFAULT, "_AXSAlwaysShowVolumeControlEnabled");
        gNativeSet = (RSIVNativeVolumeSetter)dlsym(RTLD_DEFAULT, "_AXSAlwaysShowVolumeControlSetEnabled");
        if (gNativeGet && gNativeSet) return;
        void *lib = dlopen("/usr/lib/libAccessibility.dylib", RTLD_LAZY);
        if (!lib) return;
        if (!gNativeGet) gNativeGet = (RSIVNativeVolumeGetter)dlsym(lib, "_AXSAlwaysShowVolumeControlEnabled");
        if (!gNativeSet) gNativeSet = (RSIVNativeVolumeSetter)dlsym(lib, "_AXSAlwaysShowVolumeControlSetEnabled");
    });
}

BOOL RSIVNativeVolumeSupported(void) {
    RSIVNativeResolve();
    return gNativeGet != NULL && gNativeSet != NULL;
}

// Not memoized here: the getter is a primed cache byte inside libAccessibility,
// already cheaper than the notify_check this file hides its own reads behind.
BOOL RSIVNativeVolumeEnabled(void) {
    RSIVNativeResolve();
    return gNativeGet ? gNativeGet() : NO;
}

// Apple's setter persists the value, invalidates its cross-process cache and
// posts the change — the same call the Accessibility pane makes.
void RSIVNativeVolumeSetEnabled(BOOL on) {
    RSIVNativeResolve();
    if (gNativeSet) gNativeSet(on);
}
