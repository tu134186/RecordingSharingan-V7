// Derived from Yves000/Crescendo (GPL-3.0), upstream 33c60a69d76454c268709b381ad987832403e534.
// Modified 2026-10-28: isolated namespace/domain and opt-in integration in RecordingSharingan.
// Private-API declarations, verified against iOS 16/17/18 runtime header dumps
// and an iOS 26.5 shared-cache dump. Only the members Crescendo touches are
// declared; everything else stays untyped.
//
// All MRU* classes live in MediaControls.framework (a direct dependency of
// MediaRemoteUI, loaded before %ctor runs — no deferred %init needed there).
#import <UIKit/UIKit.h>

// The volume engine (MediaPlayer.framework). On the lock screen Apple wires
// the controller to an MPVolumeControllerRouteDataSource carrying the real
// route. Leave that data source in place: Apple's own code calls
// route-DS-only API on it (-groupRoute), so installing a different source
// class crashes the scene.
@interface MPVolumeController : NSObject
@property (nonatomic, retain) id dataSource;
- (void)updateVolumeValue;
@end
@interface MRUVolumeController : MPVolumeController
@end

// The slider inside the volume row. Declared as UIControl — the common
// ancestor of both generations (iOS 16: MRUSlider : UIControl; 17+: :
// UISlider) — which is all the enable-pin hook needs.
@interface MRUSlider : UIControl
@end

// Monochrome styling engine the media platters share; handing the host view's
// provider to a view we create adopts the platter's white-on-dark look.
@interface MRUVisualStylingProvider : NSObject
@end

// Apple's dormant volume row, present on iOS 16-26. It is its own
// MRUVolumeControllerDelegate: once on screen it tracks route volume by
// itself, and -setVolumeController: wires the controller's delegate to the
// view. iOS 16 slider: classic MRUSlider; 17+: MRUGroupSlider with the private
// fluid configuration.
@interface MRUNowPlayingVolumeControlsView : UIView
// iOS 17+ only (respondsToSelector:-guard every use): volume updates are
// dropped while onScreen is NO.
@property (nonatomic, getter=isOnScreen) BOOL onScreen;
@property (nonatomic, retain) MRUVolumeController *volumeController;
@property (nonatomic, retain) MRUVisualStylingProvider *stylingProvider;
- (void)updateVisibility;
- (void)updateVisualStyling;
- (void)updateVolumeAnimated:(BOOL)animated;
@end

// The now-playing player view. Hosts the volume row on iOS 16/17; lock screen
// and Control Center ≤17 share this class, and the CC expanded card is where
// Apple still turns the flag on itself — the forcing setter must pass
// non-lock-screen hosts through untouched.
@interface MRUNowPlayingView : UIView
@property (nonatomic) BOOL showVolumeControlsView;
@property (nonatomic, readonly) MRUNowPlayingVolumeControlsView *volumeControlsView;
@property (nonatomic, readonly) BOOL showSuggestionsView;
- (void)updateVisibility;
@end

@interface MRUNowPlayingViewController : UIViewController
@property (nonatomic, readonly) long long context;   // 2 == lock screen
// Apple's own wiring entry point (present 16-26): re-derives volume-view
// state, connects the volume controller and (17+) takes the hardware volume
// assertion.
- (void)updateVolumeControls;
// Crescendo (%new in RSIVHooksLockScreen16.x)
- (void)rsiv_stampHostAndForce;
- (void)rsiv_prefsChanged;
- (void)rsiv_syncHeight;
@end

// iOS 18-26 lock-screen platter content (MediaRemoteUI side). Same dormant
// flag as MRUNowPlayingView; exists only in the lock-screen scene.
@interface MRULockscreenView : UIView
@property (nonatomic) BOOL showVolumeControlsView;
@property (nonatomic, readonly) MRUNowPlayingVolumeControlsView *volumeControlsView;
@property (nonatomic, readonly) BOOL showSuggestionsView;
- (void)updateVisibility;
@end

@interface MRULockscreenViewController : UIViewController
- (void)updateVolumeControls;
- (void)updatePreferredContentSize;   // pushes the scene size to SpringBoard
// Crescendo (%new in RSIVHooksLockScreen18.x)
- (void)rsiv_ls18Apply;
@end

// iOS 17-26 Dynamic Island expanded player (MediaRemoteUI, SystemAperture
// scene). The view family has no dormant volume row — Crescendo creates and
// wires its own MRUNowPlayingVolumeControlsView here.
@interface MRUActivityNowPlayingView : UIView
@property (nonatomic, retain) MRUVisualStylingProvider *stylingProvider;
@end

@interface MRUActivityNowPlayingViewController : UIViewController
@property (nonatomic, readonly) long long activeLayoutMode;
- (void)updateLayoutModesPreferringImmediateTransition:(BOOL)immediate
                                    deferInCustomLayout:(BOOL)deferInCustom
                                                 reason:(NSString *)reason;
@end

// iOS 16 Dynamic Island expanded player — the pre-Activity class family, same
// layout-mode / bottom-safe-area API plus a clean -isExpanded.
@interface MRUSessionNowPlayingView : UIView
@property (nonatomic, retain) MRUVisualStylingProvider *stylingProvider;
@end

@interface MRUSessionNowPlayingViewController : UIViewController
@property (nonatomic, readonly) long long activeLayoutMode;
@property (nonatomic, readonly, getter=isExpanded) BOOL expanded;
- (void)updateLayoutModesPreferringImmediateTransition:(BOOL)immediate
                                    deferInCustomLayout:(BOOL)deferInCustom
                                                 reason:(NSString *)reason;
@end
