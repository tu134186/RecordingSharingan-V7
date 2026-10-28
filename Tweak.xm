#import <UIKit/UIKit.h>
#include <unistd.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <notify.h>
#import <dlfcn.h>


// V7.1.2: iOS 15+ safe replacement for deprecated UIApplication.windows.
static NSArray<UIWindow *> *RSAllApplicationWindows(void) {
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        [result addObjectsFromArray:windowScene.windows];
    }
    return result;
}

/*
 * RecordingSharingan v6.1.0-debug (V6.2 Loader Probe)
 *
 * V6.2 Loader Probe 版本：只增加“dylib 是否真正加载”的证据日志，验证注入是否生效。
 * - 不改动画、不改定位、不改设置页、不改任何 V5/V6 既有逻辑。
 * - %ctor 最开始写入：dylib loaded / ctor executed / 进程 / NSBundle / dylib 路径 / 是否 SpringBoard。
 * - 日志同时写入两个位置：
 *     /var/mobile/Library/Logs/RecordingSharingan-V6.log
 *     /var/jb/tmp/RecordingSharingan-V6.log
 *
 * V6 合并目标（基线 V5.7.25，全部旧逻辑保留）：
 * - 保留 v5.5 的安全初始化：%ctor 不直接访问 UIScreen/UIKit 状态。
 * - 保留 v5.6 轮询生命周期 / 主动扫描 / 全局单写轮眼。
 * - 保留 v5.7.15+ 的 capture-off grace、左右弹簧锚点锁、右侧 morph 抑制等稳定逻辑。
 * - 新增 V6.0.0 SystemAperture 精准定位：不再只扫描 _SAUIProvidedViewContainerView，
 *   通过 SBSystemApertureController -> _systemApertureViewController -> _systemApertureManager
 *   -> registeredElements[] -> elementIdentifier（systemApertureElementIdentifierScreenRecording）
 *   -> elementViewControllerForElement: -> SAUIElementView 找到真正的录屏灵动岛元素，
 *   并把写轮眼作为额外动画层挂进该元素子树（宿主跟随，自动随系统 morph 过渡）。
 * - 第一版约定：系统 3-2-1 保留、系统录屏红点保留（默认不再隐藏）、record.circle.fill 不动、
 *   不删除 SBRecordingIndicatorView；写轮眼作为覆盖层显示。
 * - 保留设置总开关、两套素材、旋转速度、左右 X / Y 坐标和左右尺寸实时微调。
 */

static NSString * const RSVersion = @"7.11.9.4.3.2.6.20";
static NSString * const RSLogPath = @"/var/mobile/RecordingSharingan-V7.log";
static CFStringRef const RSPrefsDomain = CFSTR("com.tu.recordingsharingan.settings");
static CFStringRef const RSLegacyPrefsDomain = CFSTR("com.recordingsharigan.settings");
static const char *RSPrefsChangedNotification = "com.tu.recordingsharingan.settings.changed";

static BOOL RSRecordingActive = NO;
static BOOL RSInitialized = NO;
static __weak UIView *RSInstalledContainer = nil;
static __weak UIImageView *RSSharinganView = nil;
static NSTimer *RSPollTimer = nil;
static CADisplayLink *RSGeometryDisplayLink = nil;
static NSTimeInterval RSLastRescan = 0;
// v5.7.3 基线：继续保持安全初始化不动；只收紧录屏候选、改为逐帧几何跟随并移除 Overlay 自身位移动画。
// v5.7.5：仅新增默认关闭的低风险测试记录，不改变上述主逻辑。
// v5.7.6：修正左侧静止位置偏向中间的问题，并修正 presentationLayer 坐标换算；不改安全初始化。
static __weak UIView *RSPendingContainer = nil;
static NSTimeInterval RSPendingSince = 0;
static NSUInteger RSPendingHits = 0;
static NSHashTable<UIView *> *RSBaselineContainers = nil;
static NSUInteger RSBaselineContainerCount = 0; // v5.7.14：用于只锁定“单独原生录屏”弹簧手势，不影响多活动场景。
static const void *RSOriginalAlphaKey = &RSOriginalAlphaKey;
static __weak UIView *RSLastConfirmedContainer = nil;
static CGPoint RSLastConfirmedCenter = {0,0};
static NSTimeInterval RSLastConfirmedAt = 0;
static BOOL RSLastWasRight = NO;
// v5.7.23：锁定一轮已确认录屏的左右身份。尤其右侧独立圆在 Live Activity morph 中
// 会把同一个 22x22 provided container 临时搬到 x≈166；这不是一次真正的 right->left 迁移。
static BOOL RSSessionSideLocked = NO;
static BOOL RSSessionLockedRight = NO;
static NSInteger RSRegisteredElementCount = -1; // updated by existing controller discovery; -1 means unknown
static BOOL RSVisualSideRight = NO;
static NSTimeInterval RSVisualSideLastLog = 0;
static __weak UIView *RSRecentlyStoppedContainer = nil;
static BOOL RSRecentlyStoppedWasRight = NO;
static NSTimeInterval RSRecentlyStoppedAt = 0;
static const NSTimeInterval RSRecentSideIdentityWindow = 2.20;
static BOOL RSEyeGeometryHasSide = NO;
static BOOL RSEyeGeometryRight = NO;
// v5.7.11：仅用于同侧小范围容器重建时的视觉过渡，避免 19.67x19 / 22x22 之间瞬时跳 2~4pt。
static BOOL RSRebindSmoothingActive = NO;
static CGPoint RSRebindFromCenter = {0,0};
static NSTimeInterval RSRebindStartedAt = 0;
// v5.7.15：控制中心原生录屏在展开/收起录屏岛时，UIScreen.isCaptured 会短暂抖成 NO。
// 以前会立刻拆掉写轮眼、停止轮询，再在 0.5~1 秒后重新整套安装，肉眼就会看到“暂停后回去卡一下”。
// 现在给短暂 capture-off 一个很小的宽限期；若很快恢复，则保持同一录屏会话和同一容器身份。
static BOOL RSCaptureStopPending = NO;
static NSUInteger RSCaptureStopGeneration = 0;
static const NSTimeInterval RSCaptureStopGrace = 1.35;
// v5.7.16：grace 期间保留同一个 UIImageView，但冻结旋转并隐藏；恢复时原相位继续。
static BOOL RSEyeGracePaused = NO;
// v5.7.19：APP/Live Activity 场景从右侧独立圆结束录屏时，系统会在真正停止后的尾声
// 短暂把 isCaptured 再抖回 YES。旧版会立刻把 eye 重新显示，形成“右圆结束 -> 长条红点/写轮眼
// 又转一下 -> 再暂停”的视觉回弹。恢复录屏改为“持续 YES 确认”后才显示。
static BOOL RSCaptureResumePending = NO;
static NSUInteger RSCaptureResumeGeneration = 0;
static NSTimeInterval RSCaptureStopStartedAt = 0;
static const NSTimeInterval RSCaptureResumeConfirmLeft = 0.03;
static const NSTimeInterval RSCaptureResumeConfirmRight = 0.75;
// v5.7.20：APP / Live Activity 右侧独立圆在点开、收起、暂停面板切换时，
// 系统会把同一个录屏 provided container 做一段跨区域 morph。Overlay 若逐帧照抄，
// 会出现“写轮眼被拖进长条 / 穿过药丸 / 再弹回右圆”的不自然过渡。
// 右侧过渡期间只做视觉抑制：保持容器身份和红点隐藏，不重绑、不重装。
static BOOL RSRightTransitionSuppressed = NO;
static NSTimeInterval RSRightTransitionStableSince = 0;
static NSTimeInterval RSRightTransitionSuppressedAt = 0;
static NSTimeInterval RSRightForceAnchorUntil = 0;
static BOOL RSEyeResumeVisibilityPending = NO;
static NSUInteger RSEyeVisibilityGeneration = 0;
static const NSTimeInterval RSRightTransitionSettle = 0.12;
static const NSTimeInterval RSRightTransitionMaxSuppress = 0.22;
static const NSTimeInterval RSEyeResumeVisibilityMinDelay = 0.00;
static const NSTimeInterval RSEyeResumeVisibilityMaxDelay = 0.35;
static const NSTimeInterval RSEyeResumeVisibilityCheckInterval = 0.02;
static const CGFloat RSEyeResumeStableTolerance = 5.0;
static const NSTimeInterval RSRightForceAnchorDuration = 0.22;
// v5.7.24：右侧 Live Activity 交接时，overlay 不参与系统 morph；只在保存锚点静默交接。
static NSUInteger RSRedSuppressionGeneration = 0;
static NSHashTable<UIView *> *RSTransientRedLeaves = nil;

// ===== V6.0.0 SystemAperture 元素挂载状态 =====
static __weak UIView *RSEyeHostElement = nil;      // 写轮眼实际挂载宿主（元素自身或非裁剪祖先）
static __weak UIView *RSEyeMountedElement = nil;   // 被挂载的 SAUIElementView（录屏灵动岛元素）
static BOOL RSEyeMountedInElement = NO;            // 当前写轮眼是否已挂进元素子树（防重复 addSubview）
static NSTimeInterval RSElementLastSearch = 0;     // 元素查找冷却，配合 0.25s 重扫避免 layout 风暴
static __weak UIView *RSNativeRecordingIndicatorView = nil; // V7.3: 真正的 SBRecordingIndicatorView
static __weak UIView *RSNativeIndicatorHost = nil;          // V7.3: 与系统红点相同的父视图
static __weak UIView *RSV74CapturedNativeIndicator = nil;     // V7.4: 直接从 SBRecordingIndicatorView Hook 捕获
static NSTimeInterval RSV74LastCaptureLog = 0;
static NSTimeInterval RSV75LastPortalProbeAt = 0;
static NSInteger RSV75PortalProbeRound = 0;

#pragma mark - 日志

static void RSLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] [RecordingSharingan] %@\n", [NSDate date], msg];
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "%{public}s", line.UTF8String);
    @try {
        NSString *dir = [RSLogPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if (![[NSFileManager defaultManager] fileExistsAtPath:RSLogPath])
            [[NSFileManager defaultManager] createFileAtPath:RSLogPath contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:RSLogPath];
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (...) {}
}

static void RSClearLog(void) {
    @try { [[NSFileManager defaultManager] removeItemAtPath:RSLogPath error:nil]; } @catch (...) {}
}

#pragma mark - V6.2 Loader Probe（只写日志，不改任何显示/动画/定位逻辑）

// V6.2 Loader Probe 目的：在 %ctor 最开始输出“dylib 是否真正加载”的最直接证据。
// 只使用 Foundation / dlfcn / os_log，绝不触碰 UIScreen、UIKit 状态或 SpringBoard 视图树，
// 遵守项目“%ctor 安全初始化”红线（与 V5.7.x 起的一致）。
static NSString * const RSV6DebugLogPathMobile = @"/var/mobile/RecordingSharingan-V7.log";
static NSString * const RSV6DebugLogPathTmp    = @"/var/jb/tmp/RecordingSharingan-V7.log";
static NSString * const RSV6DebugLogPathSystemTmp = @"/tmp/RecordingSharingan-V7.log";

// 把一条 [V6.2] 格式记录写入指定文件（自动补目录/建文件/追加）
static void RSDebugWriteFile(NSString *path, NSString *entry) {
    @try {
        NSString *dir = [path stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path])
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        [fh seekToEndOfFile];
        [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (...) {}
}

// V6.2 Loader Probe 日志入口：同时写两个位置 + os_log（不改变既有 RSLog/RecordingSharingan.log 行为）
static void RSDebugLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *entry = [NSString stringWithFormat:@"[V7.1-FUSION]\n%@\n\n", msg];
    RSDebugWriteFile(RSV6DebugLogPathMobile, entry);
    RSDebugWriteFile(RSV6DebugLogPathTmp, entry);
    RSDebugWriteFile(RSV6DebugLogPathSystemTmp, entry);
    @try {
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "[V7.1-FUSION] %{public}s", msg.UTF8String);
    } @catch (...) {}
}

// 每次新进程加载时清空 V6 debug 双日志，保证文件里只有本次加载产生的记录
static void RSDebugClearV6Logs(void) {
    @try { [[NSFileManager defaultManager] removeItemAtPath:RSV6DebugLogPathMobile error:nil]; } @catch (...) {}
    @try { [[NSFileManager defaultManager] removeItemAtPath:RSV6DebugLogPathTmp error:nil]; } @catch (...) {}
    @try { [[NSFileManager defaultManager] removeItemAtPath:RSV6DebugLogPathSystemTmp error:nil]; } @catch (...) {}
}

// 取当前正在执行的 dylib 自身路径（dladdr 指向本函数所在 image）
static NSString *RSDebugDylibPath(void) {
    Dl_info info;
    if (dladdr((const void *)&RSDebugDylibPath, &info) && info.dli_fname) {
        return [NSString stringWithUTF8String:info.dli_fname];
    }
    return @"(unknown)";
}

// 记录：当前进程 / NSBundle 信息 / dylib 路径 / 是否 SpringBoard
static void RSDebugDumpEnvironment(void) {
    @autoreleasepool {
        NSString *processName = @"(unknown)";
        NSString *bundleID = @"(nil)";
        NSString *bundlePath = @"(nil)";
        NSString *executablePath = @"(nil)";
        @try { processName = [NSProcessInfo processInfo].processName; } @catch (...) {}
        @try {
            NSBundle *b = [NSBundle mainBundle];
            bundleID = b.bundleIdentifier ?: @"(nil)";
            bundlePath = b.bundlePath ?: @"(nil)";
            executablePath = b.executablePath ?: @"(nil)";
        } @catch (...) {}

        RSDebugLog(@"process: %@", processName);
        RSDebugLog(@"bundleIdentifier: %@", bundleID);
        RSDebugLog(@"bundlePath: %@", bundlePath);
        RSDebugLog(@"executablePath: %@", executablePath);
        RSDebugLog(@"dylibPath: %@", RSDebugDylibPath());

        BOOL isSpringBoard = [processName isEqualToString:@"SpringBoard"] ||
                             [bundleID isEqualToString:@"com.apple.springboard"];
        if (isSpringBoard) {
            RSDebugLog(@"SpringBoard detected");
        } else {
            RSDebugLog(@"NOT SpringBoard (process=%@ bundle=%@)", processName, bundleID);
        }
    }
}

#pragma mark - 设置

static CFPropertyListRef RSCopyPreference(CFStringRef key) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(key, RSPrefsDomain);
    if (!value) value = CFPreferencesCopyAppValue(key, RSLegacyPrefsDomain);
    return value;
}

static BOOL RSIsEnabled(void) {
    @try {
        CFPropertyListRef value = RSCopyPreference(CFSTR("enabled"));
        if (!value) return YES;
        BOOL enabled = YES;
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            enabled = CFBooleanGetValue((CFBooleanRef)value);
        } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            int n = 1;
            CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &n);
            enabled = (n != 0);
        }
        CFRelease(value);
        return enabled;
    } @catch (...) { return YES; }
}

static BOOL RSTestLoggingEnabled(void) {
    @try {
        CFPropertyListRef value = RSCopyPreference(CFSTR("testLogging"));
        if (!value) return NO; // 测试记录默认关闭，稳定版行为不变。
        BOOL enabled = NO;
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) enabled = CFBooleanGetValue((CFBooleanRef)value);
        else if (CFGetTypeID(value) == CFNumberGetTypeID()) { int n=0; CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &n); enabled=(n!=0); }
        CFRelease(value);
        return enabled;
    } @catch (...) { return NO; }
}

static NSInteger RSEyeStyle(void) {
    @try {
        CFPropertyListRef value = RSCopyPreference(CFSTR("eyeStyle"));
        if (!value) return 1;
        NSInteger style = 1;
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)value, kCFNumberNSIntegerType, &style);
        } else if (CFGetTypeID(value) == CFStringGetTypeID()) {
            style = [(__bridge NSString *)value integerValue];
        }
        CFRelease(value);
        return (style == 2 || style == 3) ? style : 1;
    } @catch (...) { return 1; }
}


static CGFloat RSFloatPreference(CFStringRef key, CGFloat fallback, CGFloat minValue, CGFloat maxValue) {
    @try {
        CFPropertyListRef value = RSCopyPreference(key);
        if (!value) return fallback;
        double n = fallback;
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &n);
        } else if (CFGetTypeID(value) == CFStringGetTypeID()) {
            n = [(__bridge NSString *)value doubleValue];
        }
        CFRelease(value);
        if (!isfinite(n)) n = fallback;
        n = MAX(minValue, MIN(maxValue, n));
        return (CGFloat)n;
    } @catch (...) { return fallback; }
}

static CGFloat RSRotationSpeed(void) { return RSFloatPreference(CFSTR("rotationSpeed"), 1.0, 0.25, 3.0); }
static CGFloat RSLeftXOffset(void)   { return RSFloatPreference(CFSTR("leftXOffset"), 0.0, -20.0, 20.0); }
static CGFloat RSRightXOffset(void)  { return RSFloatPreference(CFSTR("rightXOffset"), 0.0, -20.0, 20.0); }
static CGFloat RSYOffset(void)       { return RSFloatPreference(CFSTR("yOffset"), 0.0, -12.0, 12.0); }
static CGFloat RSLeftSize(void)      { return RSFloatPreference(CFSTR("leftSize"), 31.0, 20.0, 52.0); }
static CGFloat RSRightSize(void)     { return RSFloatPreference(CFSTR("rightSize"), 37.0, 20.0, 56.0); }


// Historical migration must not overwrite manually calibrated numeric settings.
static void RSMigratePreferences5717(void) { }

static BOOL RSIsRecoverySize(UIView *container) {
    if (!container) return NO;
    CGFloat w = CGRectGetWidth(container.bounds), h = CGRectGetHeight(container.bounds);
    // 只允许日志中反复出现的录屏小容器尺寸族做“低分恢复”。
    // 明确排除 34x36 / 38x36 一类媒体/专辑大容器，避免再次误抓。
    BOOL s17x22 = fabs(w - 17.0) < 2.4 && fabs(h - 22.0) < 2.8;
    BOOL s20x19 = fabs(w - 19.67) < 2.5 && fabs(h - 19.0) < 2.5;
    BOOL s22x22 = fabs(w - 22.0) < 2.7 && fabs(h - 22.0) < 2.7;
    BOOL transposed = fabs(h - 17.0) < 2.4 && fabs(w - 22.0) < 2.8;
    return s17x22 || s20x19 || s22x22 || transposed;
}

#pragma mark - 素材

static NSString *RSLeftMaterialChoice = nil;
static NSString *RSRightMaterialChoice = nil;
static NSString *RSLoadedMaterialChoice = nil;
static __weak UIImageView *RSMaterialAppliedView = nil;
static NSMutableDictionary<NSString *,UIImage *> *RSMaterialImageCache = nil;
static BOOL RSMaterialCurrentSide = NO;
static BOOL RSMaterialHasSide = NO;

static BOOL RSIsCustomMaterialName(NSString *name) {
    return [name isKindOfClass:NSString.class] && [name hasPrefix:@"custom-"] && [name isEqualToString:name.lastPathComponent] && [name.pathExtension.lowercaseString isEqualToString:@"png"];
}
static NSString *RSMaterialChoiceForSide(BOOL right) {
    NSString *cached=right ? RSRightMaterialChoice : RSLeftMaterialChoice;
    if(cached)return cached;
    CFPropertyListRef raw=RSCopyPreference(CFSTR("leftMaterial"));
    NSString *choice=(raw && CFGetTypeID(raw)==CFStringGetTypeID()) ? [(__bridge NSString *)raw copy] : nil;
    if(raw)CFRelease(raw);
    if(!([choice isEqualToString:@"builtin:1"] || [choice isEqualToString:@"builtin:2"] || RSIsCustomMaterialName(choice))){
        NSInteger legacy=RSEyeStyle();
        if(legacy==3){
            CFPropertyListRef name=RSCopyPreference(CFSTR("customAssetName"));
            choice=(name && CFGetTypeID(name)==CFStringGetTypeID()) ? [(__bridge NSString *)name copy] : nil;
            if(name)CFRelease(name);
            if(!RSIsCustomMaterialName(choice))choice=@"builtin:1";
        }else choice=legacy==2 ? @"builtin:2" : @"builtin:1";
    }
    if(right)RSRightMaterialChoice=choice;else RSLeftMaterialChoice=choice;
    return choice;
}
static NSString *RSBundledMaterialPath(NSString *name) {
    for(NSString *base in @[@"/var/jb/Library/Application Support/RecordingSharingan/eye",@"/Library/Application Support/RecordingSharingan/eye"]){
        NSString *path=[base stringByAppendingPathComponent:name];
        if([[NSFileManager defaultManager] fileExistsAtPath:path])return path;
    }
    return nil;
}
static UIImage *RSMaterialImageForSide(BOOL right) {
    NSString *choice=RSMaterialChoiceForSide(right);
    if(!RSMaterialImageCache)RSMaterialImageCache=[NSMutableDictionary dictionary];
    UIImage *image=RSMaterialImageCache[choice];if(image)return image;
    NSString *path=RSIsCustomMaterialName(choice) ? [@"/var/mobile/Library/Preferences/RecordingSharinganAssets" stringByAppendingPathComponent:choice] : RSBundledMaterialPath([choice isEqualToString:@"builtin:2"] ? @"replay2.png" : @"replay1.png");
    image=path ? [UIImage imageWithContentsOfFile:path] : nil;
    if(!image){NSString *fallback=RSBundledMaterialPath(@"replay1.png");image=fallback ? [UIImage imageWithContentsOfFile:fallback] : nil;}
    if(image)RSMaterialImageCache[choice]=image;
    return image;
}
static void RSApplyMaterialForSide(UIImageView *eye,BOOL right) {
    if(!eye)return;
    RSMaterialCurrentSide=right;RSMaterialHasSide=YES;
    NSString *choice=RSMaterialChoiceForSide(right);
    if(RSMaterialAppliedView==eye && [RSLoadedMaterialChoice isEqualToString:choice])return;
    UIImage *image=RSMaterialImageForSide(right);
    if(image){eye.image=image;RSLoadedMaterialChoice=choice;RSMaterialAppliedView=eye;}
}


static void RSUpdateEyeGeometry(void);
static BOOL RSContainerGeometryIsAnimating(UIView *container);
static CGPoint RSModelCenterInWindow(UIView *container, UIWindow *window);
static CGPoint RSRawPresentationCenterInWindow(UIView *container, UIWindow *window);
static void RSHideContainer(UIView *container);
static void RSSuppressTransientRecordingRedContainers(void);
static void RSRestoreTransientRedLeaves(void);
static void RSTestSnapshot(NSString *reason);
static void RSV73RestoreNativeIndicator(void);

static void RSStartRotation(UIView *view) {
    if (!view) return;
    [view.layer removeAnimationForKey:@"rs.rotation"];
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    a.fromValue = @0.0;
    a.toValue = @(M_PI * 2.0);
    a.duration = 1.6 / RSRotationSpeed();
    a.repeatCount = HUGE_VALF;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [view.layer addAnimation:a forKey:@"rs.rotation"];
}

// v5.7.16：暂停面板出现时不 remove 写轮眼。
// 只冻结 layer 的本地时间并隐藏，避免后台仍能看到旋转；恢复后从同一动画相位继续，
// 从而保留 v5.7.15 已验证流畅的“同一会话/同一容器/不重装”路径。
static void RSSuppressNativeRedDuringRightHandoff(NSUInteger generation, NSUInteger step) {
    if (generation != RSRedSuppressionGeneration) return;
    UIView *container = RSInstalledContainer;
    if (!container || !container.window || !RSLastWasRight) return;
    RSHideContainer(container);
    RSSuppressTransientRecordingRedContainers();
    // 只在交接最容易重建红色叶子的前 0.42s 做 4 次低频补压；不是常驻 Timer。
    static const NSTimeInterval delays[] = {0.07, 0.11, 0.13};
    if (step < 3) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[step] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            RSSuppressNativeRedDuringRightHandoff(generation, step + 1);
        });
    }
}

static void RSPauseEyeForCaptureGrace(void) {
    UIImageView *eye = RSSharinganView;
    if (!eye || RSEyeGracePaused) return;
    CALayer *layer = eye.layer;
    CFTimeInterval pausedTime = [layer convertTime:CACurrentMediaTime() fromLayer:nil];
    layer.speed = 0.0;
    layer.timeOffset = pausedTime;
    eye.hidden = YES;
    eye.alpha = 1.0;
    RSEyeGracePaused = YES;
    RSEyeResumeVisibilityPending = NO;
    RSEyeVisibilityGeneration++;
    if (RSLastWasRight) {
        NSUInteger redGeneration = ++RSRedSuppressionGeneration;
        RSSuppressNativeRedDuringRightHandoff(redGeneration, 0);
    }
    RSLog(@"eye hidden + rotation paused for capture-off grace");
}

static void RSResumeVisibilityCheck(NSUInteger generation, NSTimeInterval startedAt, NSUInteger stableHits) {
    if (generation != RSEyeVisibilityGeneration) return;
    if (!RSRecordingActive || RSEyeGracePaused || RSCaptureStopPending) return;

    UIImageView *eye = RSSharinganView;
    UIView *container = RSInstalledContainer;
    if (!eye || !container || !container.window) return;

    // v5.7.23：恢复等待期间仍持续压住系统原生红点。
    // V5.7.21 在 eye 隐藏时系统可能重建红色叶子，造成“红点闪一下再变写轮眼”。
    RSHideContainer(container);
    RSSuppressTransientRecordingRedContainers();

    NSTimeInterval now = CACurrentMediaTime();
    NSTimeInterval elapsed = now - startedAt;
    CGPoint modelCenter = RSModelCenterInWindow(container, container.window);
    CGPoint rawCenter = RSRawPresentationCenterInWindow(container, container.window);
    CGFloat modelDrift = hypot(modelCenter.x - RSLastConfirmedCenter.x, modelCenter.y - RSLastConfirmedCenter.y);
    CGFloat rawDrift = hypot(rawCenter.x - RSLastConfirmedCenter.x, rawCenter.y - RSLastConfirmedCenter.y);
    BOOL sameIdentity = (container == RSLastConfirmedContainer && RSLastConfirmedAt > 0);
    BOOL stable = sameIdentity && modelDrift <= RSEyeResumeStableTolerance && rawDrift <= RSEyeResumeStableTolerance && !RSContainerGeometryIsAnimating(container);
    NSUInteger nextHits = stable ? stableHits + 1 : 0;

    BOOL minimumElapsed = elapsed >= RSEyeResumeVisibilityMinDelay;
    BOOL stableEnough = minimumElapsed && nextHits >= 2;
    BOOL timedOut = elapsed >= RSEyeResumeVisibilityMaxDelay;

    if (stableEnough || timedOut) {
        RSEyeResumeVisibilityPending = NO;
        RSRightTransitionSuppressed = NO;
        RSRightTransitionStableSince = 0;
        RSRightTransitionSuppressedAt = 0;

        // 超时也绝不使用 morph 中的临时位置；回到绑定时锚点短暂锁住，
        // 既避免右圆横穿长条，也防止临时跨左侧后套错 leftX/leftSize。
        if (sameIdentity) RSRightForceAnchorUntil = now + RSRightForceAnchorDuration;

        // v5.7.24：不要让 overlay 自己做淡入。实机视频中淡入叠加系统右圆/长条 morph，
        // 会形成“闪一下/阴影弹一下”。恢复时先固定在已确认 anchor，再一次性显示。
        if (sameIdentity && RSLastWasRight) RSRightForceAnchorUntil = now + 0.30;
        RSUpdateEyeGeometry();
        // 在同一主线程事务里恢复临时 sibling leaf，再立刻重新压住当前录屏 leaf；
        // 不会出现可见的一帧红点，同时避免把已经复用为其它内容的临时 leaf 永久设为 0。
        RSRestoreTransientRedLeaves();
        RSHideContainer(container);
        eye.alpha = 1.0;
        eye.hidden = NO;
        if (stableEnough) {
            RSLog(@"eye shown after stable resume geometry hits=%lu drift={raw=%.2f,model=%.2f}", (unsigned long)nextHits, rawDrift, modelDrift);
        } else {
            RSLog(@"eye shown at saved anchor after resume timeout %.2fs drift={raw=%.2f,model=%.2f}", elapsed, rawDrift, modelDrift);
        }
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RSEyeResumeVisibilityCheckInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RSResumeVisibilityCheck(generation, startedAt, nextHits);
    });
}

static void RSResumeEyeAfterCaptureGrace(void) {
    UIImageView *eye = RSSharinganView;
    if (!eye || !RSEyeGracePaused) return;
    CALayer *layer = eye.layer;
    CFTimeInterval pausedTime = layer.timeOffset;
    layer.speed = 1.0;
    layer.timeOffset = 0.0;
    layer.beginTime = 0.0;
    CFTimeInterval timeSincePause = [layer convertTime:CACurrentMediaTime() fromLayer:nil] - pausedTime;
    layer.beginTime = timeSincePause;

    // V7.11.8.4：左侧快速恢复走“先显示、后纠偏”。
    // 稳定版已经证明同一 grace 会话中的保存 anchor/宿主可复用，因此不再让 geometry 稳定检查
    // 阻塞可见性。确认 capture 持续 YES 后，先在当前/保存 anchor 立即点亮 eye；
    // SystemAperture refresh/remount 和 geometry 检查继续在后台完成。0.35s 路径只作为失败兜底。
    RSEyeGracePaused = NO;
    RSEyeResumeVisibilityPending = NO;
    ++RSEyeVisibilityGeneration;
    NSTimeInterval now = CACurrentMediaTime();
    UIView *container = RSInstalledContainer;
    BOOL sameIdentity = container && container.window && container == RSLastConfirmedContainer && RSLastConfirmedAt > 0;
    if (sameIdentity) RSRightForceAnchorUntil = now + RSRightForceAnchorDuration;
    RSUpdateEyeGeometry();
    RSRestoreTransientRedLeaves();
    if (container) RSHideContainer(container);
    RSSuppressTransientRecordingRedContainers();
    eye.alpha = 1.0;
    eye.hidden = NO;
    RSLog(@"[V7.11.8.4] eye shown immediately after capture resume confirmation sameIdentity=%d", sameIdentity);

    // 若宿主随后被系统替换，既有 refresh/remount 链负责重挂载；这里额外保留一次
    // 非阻塞式几何校正，不再把 eye 隐藏等待。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RSEyeResumeVisibilityCheckInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!RSRecordingActive || RSEyeGracePaused || RSCaptureStopPending || !RSSharinganView) return;
        RSUpdateEyeGeometry();
        UIView *c = RSInstalledContainer;
        if (c) RSHideContainer(c);
        RSSuppressTransientRecordingRedContainers();
    });
}

#pragma mark - 系统红点隐藏/恢复

static BOOL RSColorLooksRed(UIColor *color);

static void RSRestoreContainer(UIView *container) {
    if (!container) return;
    NSNumber *oldAlpha = objc_getAssociatedObject(container, RSOriginalAlphaKey);
    if (oldAlpha) {
        container.alpha = oldAlpha.doubleValue;
        objc_setAssociatedObject(container, RSOriginalAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// v5.7.1 安全策略：不再把整个 _SAUIProvidedViewContainerView 设为透明。
// 误判时隐藏整个容器会连音乐封面/导航图标一起消失；因此只隐藏“最小红色叶子视图”。
static UIView *RSFindRedLeaf(UIView *view, NSInteger depth) {
    if (!view || depth > 5) return nil;
    UIView *best = nil; NSInteger bestScore = 0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:view];
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if (v != view) {
            NSInteger red = 0;
            if (RSColorLooksRed(v.backgroundColor)) red += 40;
            if (v.layer.backgroundColor && RSColorLooksRed([UIColor colorWithCGColor:v.layer.backgroundColor])) red += 35;
            CGFloat w=CGRectGetWidth(v.bounds), h=CGRectGetHeight(v.bounds);
            if (w >= 5 && h >= 5 && w <= 28 && h <= 28) red += 15;
            if (red > bestScore) { bestScore=red; best=v; }
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    return bestScore >= 40 ? best : nil;
}

// V6.0.0：第一版默认不再隐藏系统录屏红点（系统 3-2-1 / record.circle.fill / SBRecordingIndicatorView 全保留），
// 写轮眼作为额外动画层覆盖显示。设置里新增“隐藏系统红点”开关（默认关）以兼容旧版观感。
static BOOL RSHideNativeRedEnabled(void) {
    @try {
        CFPropertyListRef value = RSCopyPreference(CFSTR("hideRedDot"));
        if (!value) return NO;
        BOOL on = NO;
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) on = CFBooleanGetValue((CFBooleanRef)value);
        else if (CFGetTypeID(value) == CFNumberGetTypeID()) { int n = 0; CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &n); on = (n != 0); }
        CFRelease(value);
        return on;
    } @catch (...) { return NO; }
}

static void RSHideContainer(UIView *container) {
    if (!RSHideNativeRedEnabled()) return; // V6：默认保留系统红点，不隐藏
    if (!container) return;
    UIView *leaf = RSFindRedLeaf(container, 0);
    if (!leaf) return; // 宁可暂时显示系统红点，也绝不隐藏整个媒体容器。
    if (!objc_getAssociatedObject(leaf, RSOriginalAlphaKey))
        objc_setAssociatedObject(leaf, RSOriginalAlphaKey, @(leaf.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    leaf.alpha = 0.0;
}

static void RSRestoreRedLeaves(UIView *root) {
    if (!root) return;
    NSNumber *old = objc_getAssociatedObject(root, RSOriginalAlphaKey);
    if (old) {
        root.alpha = old.doubleValue;
        objc_setAssociatedObject(root, RSOriginalAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (UIView *sub in root.subviews) RSRestoreRedLeaves(sub);
}

static void RSRemoveSharingan(void) {
    RSRedSuppressionGeneration++;
    RSV73RestoreNativeIndicator();
    RSRestoreTransientRedLeaves();
    UIView *container = RSInstalledContainer;
    RSRestoreContainer(container);
    RSRestoreRedLeaves(container);
    UIImageView *eye = RSSharinganView;
    if (eye) {
        // 若真正停止发生在 grace 内，先把 layer 时间参数恢复为普通状态再销毁，
        // 避免留下 speed=0 / timeOffset 的脏状态。
        eye.layer.speed = 1.0;
        eye.layer.timeOffset = 0.0;
        eye.layer.beginTime = 0.0;
        [eye.layer removeAllAnimations];
        [eye removeFromSuperview];
    }
    RSEyeGracePaused = NO;
    RSEyeResumeVisibilityPending = NO;
    RSEyeVisibilityGeneration++;
    RSRightTransitionSuppressed = NO;
    RSRightTransitionStableSince = 0;
    RSRightTransitionSuppressedAt = 0;
    RSRightForceAnchorUntil = 0;
    RSSharinganView = nil;
    RSInstalledContainer = nil;
    RSEyeGeometryHasSide = NO;
    RSRebindSmoothingActive = NO;
    // V6.0.0：元素挂载状态一并清理
    RSEyeMountedInElement = NO;
    RSEyeHostElement = nil;
    RSEyeMountedElement = nil;
}

#pragma mark - 候选容器识别

static BOOL RSColorLooksRed(UIColor *color) {
    if (!color) return NO;
    CGFloat r=0,g=0,b=0,a=0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        return a > 0.20 && r > 0.55 && r > g * 1.45 && r > b * 1.35;
    }
    return NO;
}

static NSInteger RSRedScoreInView(UIView *view, NSInteger depth) {
    if (!view || depth > 4) return 0;
    NSInteger score = 0;
    if (RSColorLooksRed(view.backgroundColor)) score += 30;
    CGColorRef bg = view.layer.backgroundColor;
    if (bg) {
        UIColor *layerColor = [UIColor colorWithCGColor:bg];
        if (RSColorLooksRed(layerColor)) score += 25;
    }
    for (UIView *sub in [view.subviews copy]) {
        score += RSRedScoreInView(sub, depth + 1);
        if (score >= 80) break;
    }
    return MIN(score, 80);
}

static BOOL RSStringSuggestsRecording(NSString *s) {
    if (s.length == 0) return NO;
    NSString *x = s.lowercaseString;
    return [x containsString:@"record"] || [x containsString:@"capture"] ||
           [x containsString:@"screen recording"] || [x containsString:@"录屏"] ||
           [x containsString:@"屏幕录制"];
}

static NSInteger RSMetadataScore(UIView *view, NSInteger depth) {
    if (!view || depth > 3) return 0;
    NSInteger score = 0;
    if (RSStringSuggestsRecording(NSStringFromClass(view.class))) score += 80;
    if (RSStringSuggestsRecording(view.accessibilityLabel)) score += 100;
    if (RSStringSuggestsRecording(view.accessibilityIdentifier)) score += 100;
    for (UIView *sub in [view.subviews copy]) {
        score += RSMetadataScore(sub, depth + 1);
        if (score >= 120) break;
    }
    return MIN(score, 120);
}

static void RSCollectProvidedContainers(UIView *root, NSInteger depth, NSMutableArray<UIView *> *out) {
    if (!root || depth > 14) return;
    Class c = NSClassFromString(@"_SAUIProvidedViewContainerView");
    if (c && [root isKindOfClass:c]) [out addObject:root];
    for (UIView *sub in [root.subviews copy]) {
        RSCollectProvidedContainers(sub, depth + 1, out);
    }
}

#pragma mark - V6.0.0 SystemAperture 精准定位（ScreenRecording 元素）

// V6 核心思路（用户指定）：
// 录屏开始 -> 识别 ScreenRecording 元素 -> 获取对应 SAUIElementView -> 在里面添加自己的 SharinganView。
// 不再“只”按尺寸/红色/出现时间扫描 _SAUIProvidedViewContainerView；
// 优先从 SystemAperture 控制器拿到带 screenRecording identifier 的元素视图，
// 挂载后由元素自身的 frame/center/layout 驱动写轮眼跟随，天然随系统 morph 过渡。

static BOOL RSViewClassContains(UIView *v, NSString *token) {
    return v && [[NSStringFromClass(v.class) lowercaseString] containsString:[token lowercaseString]];
}

// SpringBoard 导出的 NSString 常量：systemApertureElementIdentifierScreenRecording。
// 运行时用 dlsym 取符号，符号处存的是指向 NSString 的指针；取不到再用字面量兜底。
static NSString *RSRecordingElementIdentifierConstant(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *sym = dlsym(RTLD_DEFAULT, "systemApertureElementIdentifierScreenRecording");
        if (sym) {
            id __strong *slot = (id __strong *)sym;
            id obj = *slot;
            if ([obj isKindOfClass:[NSString class]] && ((NSString *)obj).length) cached = obj;
        }
        if (!cached) cached = @"ScreenRecording";
    });
    return cached;
}

static BOOL RSIdentifierIsScreenRecording(NSString *ident) {
    if (!ident.length) return NO;
    NSString *x = ident.lowercaseString;
    NSString *target = RSRecordingElementIdentifierConstant().lowercaseString;
    if (target.length && [x isEqualToString:target]) return YES;
    if ([x containsString:@"screenrecording"] || [x containsString:@"screen recording"]) return YES;
    return RSStringSuggestsRecording(x);
}

// 安全读取对象实例变量（ivar 名随 iOS 版本可能变化，失败返回 nil）
static id RSInstanceVariable(id obj, const char *name) {
    if (!obj) return nil;
    @try {
        Ivar ivar = class_getInstanceVariable(object_getClass(obj), name);
        if (!ivar) return nil;
        return object_getIvar(obj, ivar);
    } @catch (...) { return nil; }
}

// 无参 selector 的安全调用
static id RSSafeInvoke0(id obj, SEL sel) {
    if (!obj || !sel) return nil;
    @try {
        if (![obj respondsToSelector:sel]) return nil;
        NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
        if (!sig) return nil;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:sel];
        [inv setTarget:obj];
        [inv invoke];
        id ret = nil;
        if (sig.methodReturnLength > 0) {
            const char *t = sig.methodReturnType;
            if (t[0] == '@' || t[0] == '#') {
                void *buf = malloc(sig.methodReturnLength);
                [inv getReturnValue:buf];
                ret = (__bridge id)(*(void **)buf);
                free(buf);
            }
        }
        return ret;
    } @catch (NSException *e) { return nil; }
}

// 单参 selector 的安全调用
static id RSSafeInvoke1(id obj, SEL sel, id arg) {
    if (!obj || !sel) return nil;
    @try {
        if (![obj respondsToSelector:sel]) return nil;
        NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
        if (!sig) return nil;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setSelector:sel];
        [inv setTarget:obj];
        [inv setArgument:&arg atIndex:2];
        [inv invoke];
        id ret = nil;
        if (sig.methodReturnLength > 0) {
            const char *t = sig.methodReturnType;
            if (t[0] == '@' || t[0] == '#') {
                void *buf = malloc(sig.methodReturnLength);
                [inv getReturnValue:buf];
                ret = (__bridge id)(*(void **)buf);
                free(buf);
            }
        }
        return ret;
    } @catch (NSException *e) { return nil; }
}

// SAUIElementView 上的 identifier 探测：先试视图自身键，再试 element 对象透传
static NSString *RSProbeRecordingIdentifier(UIView *element) {
    if (!element) return nil;
    for (NSString *key in @[@"elementIdentifier", @"interfaceElementIdentifier", @"identifier", @"accessibilityIdentifier"]) {
        @try {
            id v = [element valueForKey:key];
            if ([v isKindOfClass:[NSString class]] && ((NSString *)v).length) return v;
        } @catch (...) {}
    }
    @try {
        id elementObj = [element valueForKey:@"element"];
        if (elementObj) {
            for (NSString *key in @[@"elementIdentifier", @"interfaceElementIdentifier", @"identifier"]) {
                @try {
                    id v = [elementObj valueForKey:key];
                    if ([v isKindOfClass:[NSString class]] && ((NSString *)v).length) return v;
                } @catch (...) {}
            }
        }
    } @catch (...) {}
    return nil;
}

static BOOL RSSubtreeContainsSceneElement(UIView *root, NSInteger depth) {
    if (!root || depth > 8) return NO;
    if (RSViewClassContains(root, @"SystemApertureSceneElement")) return YES;
    for (UIView *sub in [root.subviews copy]) {
        if (RSSubtreeContainsSceneElement(sub, depth + 1)) return YES;
    }
    return NO;
}

// 元素内查找 _SAUIProvidedViewContainerView（作为旧管线锚点；没有则用元素本身）
static UIView *RSFindProvidedContainerInElement(UIView *element, NSInteger depth) {
    if (!element) return nil;
    Class c = NSClassFromString(@"_SAUIProvidedViewContainerView");
    if (c && [element isKindOfClass:c]) return element;
    if (depth <= 0) return nil;
    for (UIView *sub in [element.subviews copy]) {
        UIView *found = RSFindProvidedContainerInElement(sub, depth - 1);
        if (found) return found;
    }
    return nil;
}

// 方式 A（主）：SystemAperture 控制器链路。
// [UIApplication systemApertureControllerForMainDisplay] -> _systemApertureViewController
// -> _systemApertureManager -> registeredElements[] -> elementIdentifier 匹配录屏
// -> elementViewControllerForElement: -> view（SAUIElementView）
static UIView *RSV6ElementFromSystemApertureController(void) {
    @try {
        // Intentionally local: this private selector is invoked on UIApplication itself.
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) {
            RSLog(@"V7.2 SystemAperture: UIApplication unavailable");
            return nil;
        }
        SEL controllerSelector = NSSelectorFromString(@"systemApertureControllerForMainDisplay");
        id controller = RSSafeInvoke0(app, controllerSelector);
        if (!controller) {
            RSLog(@"V7.2 SystemAperture: controller unavailable selector=%@", NSStringFromSelector(controllerSelector));
            return nil;
        }
        id viewController = RSInstanceVariable(controller, "_systemApertureViewController");
        if (!viewController) {
            RSLog(@"V7.2 SystemAperture: _systemApertureViewController unavailable controller=%@", NSStringFromClass([controller class]));
            return nil;
        }
        id manager = RSInstanceVariable(viewController, "_systemApertureManager");
        if (!manager) {
            RSLog(@"V7.2 SystemAperture: _systemApertureManager unavailable vc=%@", NSStringFromClass([viewController class]));
            return nil;
        }
        NSArray *elements = RSSafeInvoke0(manager, NSSelectorFromString(@"registeredElements"));
        if (![elements isKindOfClass:[NSArray class]]) {
            RSLog(@"V7.2 SystemAperture: registeredElements unavailable/type=%@", elements ? NSStringFromClass([elements class]) : @"nil");
            return nil;
        }
        RSRegisteredElementCount = (NSInteger)elements.count;
        RSLog(@"V7.2 SystemAperture: registeredElements count=%lu", (unsigned long)elements.count);
        for (id element in elements) {
            NSString *ident = nil;
            @try { ident = RSSafeInvoke0(element, NSSelectorFromString(@"elementIdentifier")); } @catch (...) {}
            if (![ident isKindOfClass:[NSString class]]) ident = nil;
            if (!ident.length) continue;
            RSLog(@"V7.2 SystemAperture: element class=%@ ident=%@", NSStringFromClass([element class]), ident);
            if (!RSIdentifierIsScreenRecording(ident)) continue;
            RSLog(@"V7.2 SystemAperture: ScreenRecording identifier matched=%@", ident);
            id elementVC = RSSafeInvoke1(manager, NSSelectorFromString(@"elementViewControllerForElement:"), element);
            if (!elementVC) continue;
            id view = RSSafeInvoke0(elementVC, NSSelectorFromString(@"view"));
            if ([view isKindOfClass:[UIView class]] && [(UIView *)view window]) {
                RSLog(@"V6 element via SystemApertureController ident=%@ class=%@", ident, NSStringFromClass([view class]));
                return (UIView *)view;
            }
        }
    } @catch (NSException *e) {
        RSLog(@"V6 controller lookup exception: %@", e);
    }
    return nil;
}

// 方式 B（备）：视图树扫描 SAUIElementView；identifier 命中或子树证据（scene element + 红点 + provided 容器）命中
static UIView *RSV6FindRecordingElementInTree(UIView *root, NSInteger depth) {
    if (!root || depth > 16) return nil;
    if (RSViewClassContains(root, @"SAUIElementView")) {
        NSString *ident = RSProbeRecordingIdentifier(root);
        if (RSIdentifierIsScreenRecording(ident)) return root;
        if (RSSubtreeContainsSceneElement(root, 0) &&
            RSRedScoreInView(root, 0) >= 25 &&
            RSFindProvidedContainerInElement(root, 4) != nil) {
            return root;
        }
    }
    for (UIView *sub in [root.subviews copy]) {
        UIView *found = RSV6FindRecordingElementInTree(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

// V6 元素查找总入口（带冷却；已挂载且元素仍在窗口时走快路径）
static UIView *RSV6FindScreenRecordingElement(BOOL force) {
    if (!RSRecordingActive || !RSIsEnabled()) return nil;
    if (RSEyeMountedInElement && RSEyeMountedElement && RSEyeMountedElement.window) {
        return RSEyeMountedElement; // 已挂载：直接复用，避免每轮全树扫描
    }
    NSTimeInterval now = CACurrentMediaTime();
    if (!force && (now - RSElementLastSearch) < 0.20) return RSEyeMountedElement;
    RSElementLastSearch = now;

    UIView *element = RSV6ElementFromSystemApertureController();
    if (!element) {
        for (UIWindow *w in RSAllApplicationWindows()) {
            element = RSV6FindRecordingElementInTree(w, 0);
            if (element) break;
        }
    }
    if (element && !element.window) element = nil;
    return element;
}

// 元素锚点容器：优先元素内 _SAUIProvidedViewContainerView，退回元素本身
static UIView *RSV6AnchorContainerForElement(UIView *element) {
    if (!element) return nil;
    UIView *inner = RSFindProvidedContainerInElement(element, 6);
    return inner ?: element;
}

// 判断一个 provided 容器是否位于录屏元素子树内（供旧管线评分做决定性加分）
static BOOL RSV6IsRecordingContainer(UIView *v) {
    if (!v || !v.window) return NO;
    UIView *cur = v;
    NSInteger hops = 0;
    while (cur && hops++ < 10) {
        if (RSViewClassContains(cur, @"SAUIElementView")) {
            NSString *ident = RSProbeRecordingIdentifier(cur);
            if (RSIdentifierIsScreenRecording(ident)) return YES;
            if (RSSubtreeContainsSceneElement(cur, 0) && RSRedScoreInView(cur, 0) >= 25) return YES;
            return NO;
        }
        cur = cur.superview;
    }
    return NO;
}

// 挂载宿主：元素自身不裁剪直接挂元素；裁剪则向上找第一个非裁剪祖先（保持同一子树内）

static UIImageView *RSEyeViewEnsure(void) {
    UIImageView *eye = RSSharinganView;
    if (eye) return eye;
    UIImage *image = RSMaterialImageForSide(RSLastWasRight);
    if (!image) {
        RSLog(@"eye image unavailable for selected material");
        return nil;
    }
    eye = [[UIImageView alloc] initWithFrame:CGRectZero];
    eye.image = image;
    eye.userInteractionEnabled = NO;
    eye.contentMode = UIViewContentModeScaleAspectFit;
    eye.clipsToBounds = NO;
    eye.layer.masksToBounds = NO;
    RSSharinganView = eye;
    RSLog(@"installed eye style=%ld", (long)RSEyeStyle());
    return eye;
}

// V7.3：从已确认的 ScreenRecording Element 内继续下钻到真正系统红点。
// 优先直接找 SBRecordingIndicatorView；同时处理 _UIPortalView.sourceView，
// 对应真机 FLEX 已确认链：_UIPortalView -> sourceView -> SBRecordingIndicatorView。
static UIView *RSV73FindViewByClassName(UIView *root, NSString *wanted, NSInteger depth) {
    if (!root || depth > 14) return nil;
    if ([NSStringFromClass(root.class) isEqualToString:wanted]) return root;
    for (UIView *sub in [root.subviews copy]) {
        UIView *hit = RSV73FindViewByClassName(sub, wanted, depth + 1);
        if (hit) return hit;
    }
    return nil;
}


static NSString *RSV75SafeViewDesc(UIView *v) {
    if (!v) return @"nil";
    NSString *superName = v.superview ? NSStringFromClass(v.superview.class) : @"nil";
    NSString *windowName = v.window ? NSStringFromClass(v.window.class) : @"nil";
    return [NSString stringWithFormat:@"%@<%p> frame=%@ bounds=%@ alpha=%.3f hidden=%d super=%@ window=%@ subviews=%lu",
            NSStringFromClass(v.class), v,
            NSStringFromCGRect(v.frame), NSStringFromCGRect(v.bounds),
            v.alpha, v.hidden, superName, windowName, (unsigned long)v.subviews.count];
}

static UIView *RSV75PortalSourceView(UIView *portal) {
    if (!portal) return nil;
    UIView *source = nil;
    @try {
        if ([portal respondsToSelector:NSSelectorFromString(@"sourceView")]) {
            id candidate = [portal valueForKey:@"sourceView"];
            if ([candidate isKindOfClass:[UIView class]]) source = candidate;
        }
    } @catch (NSException *e) {
        RSLog(@"V7.5 portal sourceView KVC exception=%@", e.name);
    }
    if (!source) {
        @try {
            id candidate = RSInstanceVariable(portal, "_sourceView");
            if ([candidate isKindOfClass:[UIView class]]) source = candidate;
        } @catch (NSException *e) {}
    }
    return source;
}

static void RSV75DumpViewTree(UIView *root, NSString *label, NSInteger maxDepth, NSInteger maxNodes) {
    if (!root) {
        RSLog(@"V7.5 %@ root=nil", label);
        return;
    }
    NSMutableArray *queue = [NSMutableArray arrayWithObject:@[root, @0]];
    NSInteger emitted = 0;
    while (queue.count && emitted < maxNodes) {
        NSArray *item = queue.firstObject;
        [queue removeObjectAtIndex:0];
        UIView *v = item[0];
        NSInteger depth = [item[1] integerValue];
        RSLog(@"V7.5 %@ d=%ld %@", label, (long)depth, RSV75SafeViewDesc(v));
        emitted++;
        if (depth >= maxDepth) continue;
        for (UIView *sub in [v.subviews copy]) {
            if (sub) [queue addObject:@[sub, @(depth + 1)]];
        }
    }
}

static __attribute__((unused)) void RSV75ProbePortalsAroundElement(UIView *element, BOOL force) {
    if (!element) return;
    NSTimeInterval now = CACurrentMediaTime();
    if (!force && now - RSV75LastPortalProbeAt < 2.0) return;
    RSV75LastPortalProbeAt = now;
    NSInteger round = ++RSV75PortalProbeRound;

    RSLog(@"V7.5 ===== PORTAL PROBE round=%ld BEGIN =====", (long)round);
    RSLog(@"V7.5 element %@", RSV75SafeViewDesc(element));

    // 1) Dump the verified ScreenRecording element tree.
    RSV75DumpViewTree(element, @"element-tree", 5, 90);

    // 2) Walk element ancestors. Portal may be outside the element's child tree.
    UIView *ancestor = element;
    NSInteger up = 0;
    while (ancestor && up < 10) {
        RSLog(@"V7.5 ancestor[%ld] %@", (long)up, RSV75SafeViewDesc(ancestor));
        ancestor = ancestor.superview;
        up++;
    }

    // 3) Scan every SpringBoard window for _UIPortalView and SBRecordingIndicatorView.
    NSInteger windowIndex = 0;
    for (UIWindow *window in RSAllApplicationWindows()) {
        RSLog(@"V7.5 window[%ld] %@", (long)windowIndex++, RSV75SafeViewDesc(window));
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        NSInteger guard = 0;
        while (stack.count && guard++ < 700) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            NSString *name = NSStringFromClass(v.class);

            if ([name rangeOfString:@"Portal"].location != NSNotFound ||
                [name isEqualToString:@"SBRecordingIndicatorView"]) {
                RSLog(@"V7.5 candidate %@", RSV75SafeViewDesc(v));
            }

            if ([name rangeOfString:@"_UIPortalView"].location != NSNotFound) {
                UIView *source = RSV75PortalSourceView(v);
                RSLog(@"V7.5 PORTAL %@ source=%@", RSV75SafeViewDesc(v), RSV75SafeViewDesc(source));
                if (source) {
                    RSV75DumpViewTree(source, @"portal-source-tree", 5, 90);
                    UIView *indicator = RSV73FindViewByClassName(source, @"SBRecordingIndicatorView", 0);
                    if (indicator) {
                        RSLog(@"V7.5 *** SOURCE INDICATOR FOUND *** %@", RSV75SafeViewDesc(indicator));
                    }
                }
            }

            for (UIView *sub in [v.subviews copy]) {
                if (sub) [stack addObject:sub];
            }
        }
    }
    RSLog(@"V7.5 ===== PORTAL PROBE round=%ld END =====", (long)round);
}

static BOOL RSV74LooksLikeNativeIndicator(UIView *v) {
    if (!v) return NO;
    Class indicatorClass = NSClassFromString(@"SBRecordingIndicatorView");
    if (indicatorClass && ![v isKindOfClass:indicatorClass]) return NO;
    if (!indicatorClass && ![NSStringFromClass(v.class) isEqualToString:@"SBRecordingIndicatorView"]) return NO;
    CGFloat w = CGRectGetWidth(v.bounds), h = CGRectGetHeight(v.bounds);
    Class windowClass = NSClassFromString(@"SBRecordingIndicatorWindow");
    BOOL rightWindow = windowClass ? [v.window isKindOfClass:windowClass]
                                   : [NSStringFromClass(v.window.class) isEqualToString:@"SBRecordingIndicatorWindow"];
    // V7.5.1 真机确认：有效红点约 5.6667 x 5.6667；0x0 是占位实例。
    return (w >= 3.0 && h >= 3.0 && w <= 12.0 && h <= 12.0 &&
            v.superview != nil && rightWindow);
}

static CGFloat RSV78IndicatorActivityScore(UIView *v) {
    if (!RSV74LooksLikeNativeIndicator(v)) return -10000.0;
    UIWindow *w = v.window;
    CGFloat score = 0.0;
    // V7.8: presentation migration may leave several valid-sized indicator replicas alive.
    // Prefer the currently visible/active replica instead of the last captured pointer.
    if (!v.hidden) score += 20.0;
    if (v.alpha > 0.01) score += 80.0 + MIN(v.alpha, 1.0) * 20.0;
    if (w && !w.hidden) score += 15.0;
    if (w && w.alpha > 0.01) score += 15.0;
    CGRect screenRect = CGRectZero;
    @try { screenRect = [v convertRect:v.bounds toView:nil]; } @catch (...) {}
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    if (!CGRectIsEmpty(screenRect) && CGRectIntersectsRect(screenRect, screenBounds)) score += 30.0;
    // When two replicas are otherwise equivalent, favor the one that is further left.
    // This is only a tie-breaker; no fixed coordinate is used.
    if (!CGRectIsEmpty(screenRect)) {
        CGFloat mid = CGRectGetMidX(screenRect);
        CGFloat sw = MAX(CGRectGetWidth(screenBounds), 1.0);
        score += MAX(0.0, 5.0 - (mid / sw) * 5.0);
    }
    return score;
}

static UIView *RSV74GlobalNativeIndicator(void) {
    Class indicatorClass = NSClassFromString(@"SBRecordingIndicatorView");
    Class windowClass = NSClassFromString(@"SBRecordingIndicatorWindow");
    UIView *best = nil;
    CGFloat bestScore = -10000.0;

    // V7.8: always enumerate every recording-indicator window.  V7.6 returned the
    // cached pointer first, which could be the old detached/minimal presentation.
    for (UIWindow *w in RSAllApplicationWindows()) {
        BOOL rightWindow = windowClass ? [w isKindOfClass:windowClass]
                                       : [NSStringFromClass(w.class) isEqualToString:@"SBRecordingIndicatorWindow"];
        if (!rightWindow) continue;
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
        NSInteger guard = 0;
        while (stack.count && guard++ < 200) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            BOOL match = indicatorClass ? [v isKindOfClass:indicatorClass]
                                        : [NSStringFromClass(v.class) isEqualToString:@"SBRecordingIndicatorView"];
            if (match && RSV74LooksLikeNativeIndicator(v)) {
                CGFloat score = RSV78IndicatorActivityScore(v);
                if (!best || score > bestScore) { best = v; bestScore = score; }
            }
            for (UIView *sub in [v.subviews copy]) if (sub) [stack addObject:sub];
        }
    }

    UIView *captured = RSV74CapturedNativeIndicator;
    if (RSV74LooksLikeNativeIndicator(captured)) {
        CGFloat score = RSV78IndicatorActivityScore(captured);
        if (!best || score > bestScore) { best = captured; bestScore = score; }
    }
    if (best) RSV74CapturedNativeIndicator = best;
    return best;
}

static UIView *RSV73NativeRecordingIndicatorInElement(UIView *element) {
    if (!element) return nil;

    // V7.4 首选直接 Hook 捕获到的真实 9x9 SBRecordingIndicatorView。
    UIView *captured = RSV74GlobalNativeIndicator();
    if (captured) return captured;

    UIView *direct = RSV73FindViewByClassName(element, @"SBRecordingIndicatorView", 0);
    if (RSV74LooksLikeNativeIndicator(direct)) return direct;

    // Portal 的 sourceView 不一定以普通 subview 形式暴露，因此单独探测。
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:element];
    NSInteger guard = 0;
    while (stack.count && guard++ < 160) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];

        NSString *name = NSStringFromClass(v.class);
        if ([name rangeOfString:@"_UIPortalView"].location != NSNotFound) {
            UIView *source = nil;
            @try {
                id candidate = [v valueForKey:@"sourceView"];
                if ([candidate isKindOfClass:[UIView class]]) source = candidate;
            } @catch (...) {}
            if (!source) {
                id candidate = RSInstanceVariable(v, "_sourceView");
                if ([candidate isKindOfClass:[UIView class]]) source = candidate;
            }
            if (source) {
                UIView *hit = RSV73FindViewByClassName(source, @"SBRecordingIndicatorView", 0);
                if (RSV74LooksLikeNativeIndicator(hit)) return hit;
            }
        }
        for (UIView *sub in [v.subviews copy]) [stack addObject:sub];
    }
    return nil;
}

static void RSV73HideNativeIndicator(UIView *indicator) {
    if (!indicator) return;
    if (!objc_getAssociatedObject(indicator, RSOriginalAlphaKey))
        objc_setAssociatedObject(indicator, RSOriginalAlphaKey, @(indicator.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    indicator.alpha = 0.0;
}

static void RSV73RestoreNativeIndicator(void) {
    UIView *indicator = RSNativeRecordingIndicatorView;
    if (indicator) {
        NSNumber *old = objc_getAssociatedObject(indicator, RSOriginalAlphaKey);
        if (old) {
            indicator.alpha = old.doubleValue;
            objc_setAssociatedObject(indicator, RSOriginalAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    RSNativeRecordingIndicatorView = nil;
    RSNativeIndicatorHost = nil;
}

// V7.11: bind directly to the SystemAperture accessory/portal presentation.
// On iOS 16.5 the 9x9 SBRecordingIndicatorView may not be materialized until the island
// is interacted with.  The 22x22 Accessory/AccessoryPortal presentation exists earlier,
// so use it as the visual host while retaining SAUIElementView(ScreenRecording) as identity.
static void RSV6SyncEyeToElement(UIView *element, BOOL allowShow);

static __weak UIView *RSV711AccessoryPortal = nil;
static __weak UIView *RSV711AccessoryView = nil;
static NSTimeInterval RSV711LastBindLog = 0;
// V7.11.3: hard guard against SystemAperture layout -> mount -> layout recursion.
static BOOL RSV7113MountScheduled = NO;
static BOOL RSV7113Mounting = NO;
static __weak UIView *RSV7113PendingAccessory = nil;

// V7.11.7: event-driven resume remount. o2Split confirms the working tweak watches
// SystemAperture/ScreenRecording private objects (SAUISystemApertureManager,
// SBSystemApertureSceneElement, SAUIElementViewController) rather than relying on a
// long blind refresh loop.  Arm on quick resume and consume the next real Accessory
// presentation lifecycle/geometry transition.
static BOOL RSV7117AwaitingPresentation = NO;
static NSUInteger RSV7117PresentationGeneration = 0;
static __weak UIView *RSV7117BaselinePortal = nil;
static CGRect RSV7117BaselinePortalFrame = {{0,0},{0,0}};
// V7.11.8: SystemAperture layout-refresh gate.  ios16dao handles active island work
// from layoutSubviews; the dance tweak also uses invalidateCache/setNeedsLayout/layoutIfNeeded.
// We therefore request ONE real aperture layout on quick resume and consume it once.
static BOOL RSV7118LayoutRefreshDirty = NO;
static BOOL RSV7118LayoutRefreshInProgress = NO;
static NSUInteger RSV7118LayoutRefreshGeneration = 0;
// V7.11.8.8: stable ScreenRecording presentation host. SystemAperture routinely
// rebuilds transient portal leaves during taps and app foreground/background morphs.
// Keep the visible eye on a still-valid current host. A different candidate must remain
// attached and unchanged across two event-driven confirmations before a seamless move.
// No polling/display-link is added here.
static BOOL RSV71187MigrationScheduled = NO;
static NSUInteger RSV71187MigrationGeneration = 0;
static __weak UIView *RSV71187LastStableHost = nil;
static __weak UIView *RSV71188PendingHost = nil;
static NSUInteger RSV71188PendingHostHits = 0;
static NSTimeInterval RSV71188PendingSince = 0;
static NSTimeInterval RSV71187LastMigrationLog = 0;
// V7.11.9.1: reject an explicitly different SAUIElementView owner; do not
// pretend geometry alone establishes ScreenRecording identity.
static NSTimeInterval RSV71191LastMigrationAt = 0;
static const NSTimeInterval RSV71191MinimumDwell = 0.42;
static UIView *RSV71191NearestElementOwner(UIView *v) {
    for (UIView *p = v; p; p = p.superview) {
        if ([NSStringFromClass(p.class) isEqualToString:@"SAUIElementView"]) return p;
    }
    return nil;
}
static BOOL RSV71191ExplicitlyWrongOwner(UIView *candidate, UIView *recordingElement) {
    UIView *owner = RSV71191NearestElementOwner(candidate);
    UIView *recordingOwner = RSV71191NearestElementOwner(recordingElement);
    // Only reject when BOTH owners can be established; never infer ownership
    // from a pointer, distance or position alone.
    return owner && recordingOwner && owner != recordingOwner;
}
static BOOL RSV71190MigrationCommit = NO;
static __weak UIView *RSV71190MigrationTarget = nil;
static NSUInteger RSV71190ConfirmGeneration = 0;
static void RSV71187SchedulePresentationMigration(NSString *reason);
static void RSV7118RequestSystemApertureRefresh(NSString *reason);
static void RSV7118ConsumeContainerLayout(UIView *container);
static void RSV7117ArmPresentationRemount(void);
static void RSV7117ConsumePresentationEvent(UIView *v, NSString *event);

static void RSV7113ScheduleSingleMount(UIView *v) {
    if (!RSInitialized || !RSRecordingActive || !v || !v.window) return;
    RSV7113PendingAccessory = v;
    if (RSV7113MountScheduled || RSV7113Mounting) return;
    RSV7113MountScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RSV7113MountScheduled = NO;
        if (RSV7113Mounting || !RSInitialized || !RSRecordingActive || !RSEyeMountedElement) return;
        UIView *candidate = RSV7113PendingAccessory;
        if (!candidate || !candidate.window) return;
        RSV7113Mounting = YES;
        @try { RSV6SyncEyeToElement(RSEyeMountedElement, YES); }
        @catch (NSException *e) { RSLog(@"V7.11.3 guarded mount exception: %@", e); }
        RSV7113Mounting = NO;
    });
}

static BOOL RSV711IsAccessoryPortal(UIView *v) {
    if (!v) return NO;
    NSString *n = NSStringFromClass(v.class);
    return [n isEqualToString:@"SBSystemApertureSceneElementAccessoryPortalView"];
}
static BOOL RSV711IsAccessoryView(UIView *v) {
    if (!v) return NO;
    NSString *n = NSStringFromClass(v.class);
    return [n isEqualToString:@"SBSystemApertureSceneElementAccessoryView"];
}
static void RSV711CollectAccessoryViews(UIView *root, NSMutableArray<UIView *> *out, NSUInteger depth) {
    if (!root || depth > 18) return;
    if ((RSV711IsAccessoryPortal(root) || RSV711IsAccessoryView(root)) && root.window && !root.hidden && root.alpha > 0.01)
        [out addObject:root];
    for (UIView *sub in root.subviews) RSV711CollectAccessoryViews(sub, out, depth + 1);
}
static UIView *RSV711BestAccessoryHostForElement(UIView *element) {
    UIWindow *w = element.window;
    if (!w) return nil;
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    RSV711CollectAccessoryViews(w, items, 0);
    if (!items.count) return nil;
    CGRect er = [element convertRect:element.bounds toView:w];
    CGPoint ec = CGPointMake(CGRectGetMidX(er), CGRectGetMidY(er));
    UIView *best = nil; CGFloat bestScore = CGFLOAT_MAX;
    for (UIView *v in items) {
        CGRect r = [v convertRect:v.bounds toView:w];
        if (CGRectIsEmpty(r) || r.size.width < 8 || r.size.height < 8 || r.size.width > 60 || r.size.height > 60) continue;
        CGPoint c = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
        CGFloat dx=c.x-ec.x, dy=c.y-ec.y;
        CGFloat score = dx*dx + dy*dy;
        if (RSV711IsAccessoryPortal(v)) score -= 400.0; // prefer the portal leaf
        if (score < bestScore) { bestScore=score; best=v; }
    }
    return best;
}
static BOOL RSV71188HostIsUsable(UIView *v) {
    if (!v || !v.window || v.hidden || v.alpha <= 0.01) return NO;
    CGFloat w = CGRectGetWidth(v.bounds), h = CGRectGetHeight(v.bounds);
    return (w >= 8.0 && h >= 8.0 && w <= 60.0 && h <= 60.0);
}
static void RSV71188ResetPendingHost(void) {
    RSV71188PendingHost = nil;
    RSV71188PendingHostHits = 0;
    RSV71188PendingSince = 0;
}
static void RSV71187SchedulePresentationMigration(NSString *reason) {
    if (!RSInitialized || !RSRecordingActive || RSCaptureStopPending || !RSEyeMountedElement || !RSEyeMountedElement.window) return;
    if (RSV71187MigrationScheduled) return;
    RSV71187MigrationScheduled = YES;
    NSUInteger generation = ++RSV71187MigrationGeneration;
    // V7.11.9.3: shorten candidate detection during an active morph without
    // bypassing identity checks, two-phase confirmation, or 420ms dwell.
    BOOL currentHostUsableAtSchedule = RSV71188HostIsUsable(RSSharinganView.superview);
    NSTimeInterval handoffDelay = currentHostUsableAtSchedule ? 0.04 : 0.02;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(handoffDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != RSV71187MigrationGeneration) return;
        RSV71187MigrationScheduled = NO;
        if (!RSInitialized || !RSRecordingActive || RSCaptureStopPending || !RSEyeMountedElement || !RSEyeMountedElement.window) return;
        @try {
            UIView *current = RSSharinganView.superview;
            UIView *candidate = RSV711BestAccessoryHostForElement(RSEyeMountedElement);
            BOOL currentUsable = RSV71188HostIsUsable(current);
            BOOL candidateUsable = RSV71188HostIsUsable(candidate);
            if (candidateUsable && RSV71191ExplicitlyWrongOwner(candidate, RSEyeMountedElement)) {
                RSLog(@"[V7.11.9.3] reject candidate: different SAUIElementView owner candidate=%p recording=%p", candidate, RSEyeMountedElement);
                candidateUsable = NO;
            }

            // Normal island morph: the current presentation is still alive. Never tear
            // down a visible eye just because another temporary portal scored better.
            if (currentUsable) {
                RSV71187LastStableHost = current;
                if (!candidateUsable || candidate == current) {
                    RSV71188ResetPendingHost();
                    RSSuppressTransientRecordingRedContainers();
                    return;
                }
                NSTimeInterval now = CACurrentMediaTime();
                if (RSV71188PendingHost != candidate) {
                    RSV71188PendingHost = candidate;
                    RSV71188PendingHostHits = 1;
                    RSV71188PendingSince = now;
                    // MorphSync: bounded 60ms second confirmation. Keep ownership and dwell checks.
                    NSUInteger confirmGeneration = ++RSV71190ConfirmGeneration;
                    __weak UIView *expectedElement = RSEyeMountedElement;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (confirmGeneration != RSV71190ConfirmGeneration ||
                            expectedElement != RSEyeMountedElement || !RSRecordingActive || RSCaptureStopPending) return;
                        RSV71187SchedulePresentationMigration(@"confirm-host");
                    });
                    return;
                }
                RSV71188PendingHostHits++;
                // Prevent A->B->A ping-pong while the previous host is still
                // valid. If it actually detaches, this guard is bypassed.
                if (RSV71191LastMigrationAt > 0 &&
                    now - RSV71191LastMigrationAt < RSV71191MinimumDwell) {
                    NSUInteger confirmGeneration = ++RSV71190ConfirmGeneration;
                    __weak UIView *expectedElement = RSEyeMountedElement;
                    NSTimeInterval wait = RSV71191MinimumDwell - (now - RSV71191LastMigrationAt) + 0.02;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (confirmGeneration == RSV71190ConfirmGeneration && expectedElement == RSEyeMountedElement && RSRecordingActive)
                            RSV71187SchedulePresentationMigration(@"dwell-confirm");
                    });
                    return;
                }
                // While the old host is still visible, require the replacement to survive
                // more than one real layout event. This filters tap/app-transition portals.
                if (RSV71188PendingHostHits < 2 || (now - RSV71188PendingSince) < 0.05) return;
            } else {
                // Old host genuinely left the window. A usable replacement can take over,
                // but it still gets one deferred confirmation through this coalesced path.
                if (!candidateUsable) { RSV71188ResetPendingHost(); return; }
            }

            if (!candidateUsable || candidate == current) { RSV71188ResetPendingHost(); return; }

            // Seamless migration: do NOT pre-hide/pre-zero the eye. UIKit reparents the
            // same UIImageView synchronously, eliminating the explicit blank frame in 8.7.
            RSLog(@"[V7.11.9.3] morph commit t=%.3f old=%p new=%p candidateAgeMs=%.1f oldUsable=%d", CACurrentMediaTime(), current, candidate, (CACurrentMediaTime()-RSV71188PendingSince)*1000.0, currentUsable);
            RSV711AccessoryPortal = candidate;
            RSV71190MigrationTarget = candidate;
            RSV71190MigrationCommit = YES;
            RSV6SyncEyeToElement(RSEyeMountedElement, NO);
            RSV71190MigrationCommit = NO;
            RSV71190MigrationTarget = nil;
            if (RSSharinganView && RSSharinganView.superview == candidate && candidate.window) {
                RSUpdateEyeGeometry();
                if (!RSEyeGracePaused && !RSEyeResumeVisibilityPending && !RSRightTransitionSuppressed) {
                    RSSharinganView.alpha = 1.0;
                    RSSharinganView.hidden = NO;
                }
                [candidate bringSubviewToFront:RSSharinganView];
                RSV71187LastStableHost = candidate;
                RSV71191LastMigrationAt = CACurrentMediaTime();
                RSSuppressTransientRecordingRedContainers();
                NSTimeInterval now = CACurrentMediaTime();
                if (now - RSV71187LastMigrationLog > 0.25) {
                    RSV71187LastMigrationLog = now;
                    RSLog(@"[V7.11.8.8] stable presentation migrated reason=%@ old=%p new=%p class=%@ frame=%@",
                          reason ?: @"unknown", current, candidate, NSStringFromClass(candidate.class), NSStringFromCGRect(candidate.frame));
                }
            }
            RSV71188ResetPendingHost();
        } @catch (NSException *e) { RSLog(@"[V7.11.9.3] presentation migration exception: %@", e); }
        RSV71190MigrationCommit = NO;
        RSV71190MigrationTarget = nil;
    });
}
static void RSV711RememberAccessory(UIView *v, NSString *event) {
    if (!v) return;
    if (RSV711IsAccessoryPortal(v)) {
        UIView *current = RSSharinganView.superview;
        BOOL currentIsPortal = RSV711IsAccessoryPortal(current) && RSV71188HostIsUsable(current);
        // Unrelated music accessory callbacks must not steal the recording cache.
        if (!currentIsPortal && (!RSV71188HostIsUsable(RSV711AccessoryPortal) || RSV711AccessoryPortal == v))
            RSV711AccessoryPortal = v;
    } else if (RSV711IsAccessoryView(v)) RSV711AccessoryView = v;
    if (!v.window) {
        if (RSV711AccessoryPortal == v) RSV711AccessoryPortal = nil;
        if (RSV711AccessoryView == v) RSV711AccessoryView = nil;
    }
    // V7.11.3: lifecycle callbacks never mount synchronously. A single deferred,
    // re-entry-guarded mount is enough to materialize the first recording presentation.
    if (RSInitialized && RSRecordingActive && RSEyeMountedElement && v.window) {
        RSV7113ScheduleSingleMount(v);
    }
    RSV7117ConsumePresentationEvent(v, event);
}

// Preference side is a visual property of the actual recording leaf, not the
// session's initial identity. Keep the session lock for migration safety only.
static BOOL RSPreferenceSideForHost(UIView *host) {
    if (!host || !host.window) return RSVisualSideRight;
    UIWindow *window = host.window;
    CGPoint screenCenter = [host convertPoint:CGPointMake(CGRectGetMidX(host.bounds), CGRectGetMidY(host.bounds)) toView:window];
    CGFloat mid = CGRectGetMidX(window.bounds);
    // Dead band during morph: do not alternate preference sets frame-by-frame.
    BOOL right = RSVisualSideRight;
    if (screenCenter.x > mid + 42.0) right = YES;
    else if (screenCenter.x < mid + 16.0) right = NO;
    if (right != RSVisualSideRight) {
        RSVisualSideRight = right;
        RSLog(@"[SIDEFIX] visual side changed=%@ host=%@ screenX=%.2f mid=%.2f sessionLocked=%@",
              right ? @"right" : @"left", NSStringFromClass(host.class), screenCenter.x, mid,
              RSSessionLockedRight ? @"right" : @"left");
    }
    NSTimeInterval now = CACurrentMediaTime();
    if (now - RSVisualSideLastLog > 1.0) {
        RSVisualSideLastLog = now;
        RSLog(@"[SIDEFIX] side=%@ host=%p screenCenter={%.2f,%.2f} xOffset=%.2f size=%.2f",
              right ? @"right" : @"left", host, screenCenter.x, screenCenter.y,
              right ? RSRightXOffset() : RSLeftXOffset(), right ? RSRightSize() : RSLeftSize());
    }
    return right;
}

// 位置同步：监听 SAUIElementView frame/center/layout，写轮眼跟随宿主
static void RSV6SyncEyeToElement(UIView *element, BOOL allowShow) {
    if (!RSEyeMountedInElement || !RSEyeMountedElement || RSEyeMountedElement != element) return;
    UIImageView *eye = RSSharinganView;
    if (!eye || !element.window) return;

    UIView *indicator = RSV73NativeRecordingIndicatorInElement(element);
    if (indicator && indicator.window && indicator.superview) {
        UIView *host = indicator.superview;

        // 系统 morph 时红点 view 可能被重建；每次同步都允许无闪烁换到新实例。
        if (RSNativeRecordingIndicatorView != indicator) {
            RSV73RestoreNativeIndicator();
            RSNativeRecordingIndicatorView = indicator;
            RSNativeIndicatorHost = host;
            RSLog(@"V7.3 native indicator locked class=%@ frame=%@ host=%@",
                  NSStringFromClass(indicator.class), NSStringFromCGRect(indicator.frame), NSStringFromClass(host.class));
        }

        // V7.3.1：服从设置页已有的“隐藏系统红点”开关。
        if (RSHideNativeRedEnabled()) {
            RSV73HideNativeIndicator(indicator);
        } else {
            NSNumber *oldAlpha = objc_getAssociatedObject(indicator, RSOriginalAlphaKey);
            if (oldAlpha) {
                indicator.alpha = oldAlpha.doubleValue;
                objc_setAssociatedObject(indicator, RSOriginalAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }

        if (eye.superview != host) {
            [eye removeFromSuperview];
            [host addSubview:eye];
        }
        [host bringSubviewToFront:eye];
        RSEyeHostElement = host;

        BOOL right = RSPreferenceSideForHost(indicator);
        RSApplyMaterialForSide(eye,right);
        CGFloat configured = right ? RSRightSize() : RSLeftSize();

        // 真替换：中心严格使用系统红点中心；用户 X/Y 只作为最后微调。
        CGPoint c = [indicator.superview convertPoint:indicator.center toView:host];
        c.x += right ? RSRightXOffset() : RSLeftXOffset();
        c.y += RSYOffset();

        [UIView performWithoutAnimation:^{
            eye.bounds = CGRectMake(0, 0, configured, configured);
            eye.center = c;
        }];
        if (allowShow && !RSEyeGracePaused && !RSEyeResumeVisibilityPending && !RSRightTransitionSuppressed) {
            eye.hidden = NO;
            eye.alpha = 1.0;
        }
        return;
    }

    // V7.11: native dot is still pending. Bind to the current accessory portal directly
    // instead of waiting for a manual island swipe to instantiate SBRecordingIndicatorView.
    UIView *currentPortal = eye.superview;
    UIView *portal = nil;
    if (RSV71190MigrationCommit && RSV71188HostIsUsable(RSV71190MigrationTarget)) {
        portal = RSV71190MigrationTarget;
    } else if (RSV711IsAccessoryPortal(currentPortal) && RSV71188HostIsUsable(currentPortal)) {
        // Keep the visible recording eye in place until the coordinator confirms migration.
        portal = currentPortal;
    } else if (RSV71188HostIsUsable(RSV711AccessoryPortal)) {
        portal = RSV711AccessoryPortal;
    }
    if (!portal) portal = RSV711BestAccessoryHostForElement(element);
    if (portal && portal.window) {
        RSV711AccessoryPortal = portal;
        UIView *host = portal; // keep coordinates local to the 22x22 presentation leaf
        if (eye.superview != host) { [eye removeFromSuperview]; [host addSubview:eye]; }
        [host bringSubviewToFront:eye];
        RSEyeHostElement = host;
        BOOL right = RSPreferenceSideForHost(host);
        RSApplyMaterialForSide(eye,right);
        CGFloat configured = right ? RSRightSize() : RSLeftSize();
        CGPoint c = CGPointMake(CGRectGetMidX(host.bounds), CGRectGetMidY(host.bounds));
        c.x += right ? RSRightXOffset() : RSLeftXOffset();
        c.y += RSYOffset();
        [UIView performWithoutAnimation:^{ eye.bounds = CGRectMake(0,0,configured,configured); eye.center = c; }];
        if (allowShow && !RSEyeGracePaused && !RSEyeResumeVisibilityPending && !RSRightTransitionSuppressed) { eye.hidden=NO; eye.alpha=1.0; }
        NSTimeInterval now = CACurrentMediaTime();
        if (now - RSV711LastBindLog > 0.8) {
            RSV711LastBindLog = now;
            RSLog(@"V7.11 accessory host bound class=%@ frame=%@ window=%@", NSStringFromClass(host.class), NSStringFromCGRect(host.frame), NSStringFromClass(host.window.class));
        }
        return;
    }

    // V7.5：真实红点未捕获时，做 Portal/sourceView 专项探针；同时保留 V7.4 可见 fallback。
    // V7.4：如果真实 SBRecordingIndicatorView 暂时还没被 Hook 捕获，
    // 不再把素材永久 hidden。回退到 V7.2 已验证能显示的 ScreenRecording anchor。
    // 一旦 Hook 捕获真实 9x9 红点，下一轮 sync 会自动把 eye 搬到红点同一 superview。
    UIView *fallback = RSV6AnchorContainerForElement(element);
    if (fallback && fallback.window) {
        if (eye.superview != fallback) {
            [eye removeFromSuperview];
            [fallback addSubview:eye];
        }
        [fallback bringSubviewToFront:eye];
        RSEyeHostElement = fallback;

        BOOL right = RSPreferenceSideForHost(fallback);
        RSApplyMaterialForSide(eye,right);
        CGFloat configured = right ? RSRightSize() : RSLeftSize();
        CGPoint c = CGPointMake(CGRectGetMidX(fallback.bounds), CGRectGetMidY(fallback.bounds));
        c.x += right ? RSRightXOffset() : RSLeftXOffset();
        c.y += RSYOffset();
        [UIView performWithoutAnimation:^{
            eye.bounds = CGRectMake(0, 0, configured, configured);
            eye.center = c;
        }];
        if (allowShow && !RSEyeGracePaused && !RSEyeResumeVisibilityPending && !RSRightTransitionSuppressed) {
            eye.hidden = NO;
            eye.alpha = 1.0;
        }
        static NSTimeInterval lastFallbackLog = 0;
        NSTimeInterval now = CACurrentMediaTime();
        if (now - lastFallbackLog > 1.0) {
            lastFallbackLog = now;
            RSLog(@"V7.8 native dot pending; temporary fallback host=%@", NSStringFromClass(fallback.class));
        }
    } else {
        eye.hidden = YES;
    }
}

// 挂载写轮眼到 ScreenRecording 元素（防重复 addSubview）
static void RSV6MountEyeIntoElement(UIView *element) {
    if (!element || !element.window || !RSRecordingActive || !RSIsEnabled()) return;

    UIImageView *eye = RSEyeViewEnsure();
    if (!eye) return;

    RSEyeMountedElement = element;
    RSEyeMountedInElement = YES;

    // 保留 ScreenRecording element 作为身份锚点，但 V7.3 不再以整个 172x36 element
    // 的中心作为视觉锚点；真正显示必须等 SBRecordingIndicatorView 出现。
    RSInstalledContainer = RSV6AnchorContainerForElement(element);
    RSLastConfirmedContainer = RSInstalledContainer;

    UIView *indicator = RSV73NativeRecordingIndicatorInElement(element);
    if (indicator && indicator.superview) {
        UIWindow *w = element.window;
        CGPoint nativeCenter = nil != w
            ? [indicator convertPoint:CGPointMake(CGRectGetMidX(indicator.bounds), CGRectGetMidY(indicator.bounds)) toView:w]
            : CGPointZero;
        RSLastConfirmedCenter = nativeCenter;
        RSLastConfirmedAt = CACurrentMediaTime();
        if (w) RSLastWasRight = nativeCenter.x > (CGRectGetMidX(w.bounds) + 42.0);
        if (!RSSessionSideLocked) {
            RSSessionSideLocked = YES;
            RSSessionLockedRight = RSLastWasRight;
            RSLog(@"V7.4 session side locked=%@", RSLastWasRight ? @"right" : @"left");
        }
    } else {
        RSLog(@"V7.8 ScreenRecording ready; native dot pending, temporary fallback");
    }

    RSRightTransitionSuppressed = NO;
    RSRightTransitionStableSince = 0;
    RSRightTransitionSuppressedAt = 0;
    RSRightForceAnchorUntil = 0;

    RSV6SyncEyeToElement(element, YES);
    if (![eye.layer animationForKey:@"rs.rotation"]) RSStartRotation(eye);
    if (indicator) {
        RSLog(@"V7.4 replacement active native=%@ nativeBounds=%@ host=%@",
              NSStringFromClass(indicator.class), NSStringFromCGRect(indicator.bounds),
              NSStringFromClass(indicator.superview.class));
        RSTestSnapshot(@"v7.4-native-dot-replaced");
    } else {
        RSTestSnapshot(@"v7.4-visible-fallback");
    }
}


// v5.7.25：右侧 Live Activity 展开/收起时，系统会在同一个 SAUIElementView 子树里
// 重建/搬运原生录屏红点。只压 RSInstalledContainer 自己会漏掉新 leaf，形成红点↔写轮眼闪烁。
// 这里不改绑定、不改 side、不改几何，只在“当前录屏 element 子树”里隐藏小型红色叶子；
// 所有额外隐藏的 leaf 都用弱引用记录，恢复/结束时还原，避免污染其它 Live Activity。
static UIView *RSRecordingElementRoot(void) {
    UIView *v = RSInstalledContainer;
    UIView *best = v;
    NSInteger hops = 0;
    while (v.superview && hops++ < 8) {
        v = v.superview;
        best = v;
        NSString *name = NSStringFromClass(v.class);
        if ([name rangeOfString:@"SAUIElementView"].location != NSNotFound) return v;
        // 不允许一路爬到整窗，避免误伤状态栏/其它活动。
        if (CGRectGetWidth(v.bounds) > 420.0 || CGRectGetHeight(v.bounds) > 180.0) break;
    }
    return best;
}

static void RSSuppressRedLeavesInElement(UIView *root, NSInteger depth) {
    if (!RSHideNativeRedEnabled()) return; // V6：默认保留系统红点
    if (!root || depth > 10) return;
    for (UIView *v in [root.subviews copy]) {
        CGFloat w = CGRectGetWidth(v.bounds), h = CGRectGetHeight(v.bounds);
        BOOL smallLeaf = (w >= 3.0 && h >= 3.0 && w <= 30.0 && h <= 30.0);
        BOOL looksRed = RSColorLooksRed(v.backgroundColor) ||
            (v.layer.backgroundColor && RSColorLooksRed([UIColor colorWithCGColor:v.layer.backgroundColor]));
        if (smallLeaf && looksRed) {
            if (!objc_getAssociatedObject(v, RSOriginalAlphaKey))
                objc_setAssociatedObject(v, RSOriginalAlphaKey, @(v.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!RSTransientRedLeaves) RSTransientRedLeaves = [NSHashTable weakObjectsHashTable];
            [RSTransientRedLeaves addObject:v];
            v.alpha = 0.0;
        }
        RSSuppressRedLeavesInElement(v, depth + 1);
    }
}

static void RSSuppressTransientRecordingRedContainers(void) {
    if (!RSRecordingActive || !RSInstalledContainer || !RSInstalledContainer.window) return;
    UIView *root = RSRecordingElementRoot();
    if (!root || !root.window) return;
    RSSuppressRedLeavesInElement(root, 0);
}

static void RSRestoreTransientRedLeaves(void) {
    for (UIView *v in RSTransientRedLeaves.allObjects) {
        NSNumber *old = objc_getAssociatedObject(v, RSOriginalAlphaKey);
        if (old) {
            v.alpha = old.doubleValue;
            objc_setAssociatedObject(v, RSOriginalAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    [RSTransientRedLeaves removeAllObjects];
}

static NSInteger RSScoreContainer(UIView *v);

static void RSTestSnapshot(NSString *reason) {
    // 低风险黑匣子：只在既有事件点采样，不新增 Timer/DisplayLink/Hook，不逐帧写日志。
    if (!RSTestLoggingEnabled() || !RSInitialized) return;
    @try {
        NSMutableArray<UIView *> *items = [NSMutableArray array];
        for (UIWindow *w in RSAllApplicationWindows()) RSCollectProvidedContainers(w, 0, items);
        RSLog(@"[TEST] snapshot reason=%@ recording=%d candidates=%lu installed=%p eye=%p", reason ?: @"unknown", RSRecordingActive, (unsigned long)items.count, RSInstalledContainer, RSSharinganView);
        NSUInteger shown = 0;
        for (UIView *v in items) {
            CGFloat w=CGRectGetWidth(v.bounds), h=CGRectGetHeight(v.bounds);
            if (w > 32.0 || h > 32.0 || w < 10.0 || h < 10.0) continue;
            UIWindow *win=v.window; CGPoint c=CGPointZero;
            if (win) c=[v convertPoint:CGPointMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds)) toView:win];
            RSLog(@"[TEST] candidate[%lu]=%p bounds=%@ alpha=%.2f hidden=%d red=%ld meta=%ld score=%ld center={%.2f,%.2f}%@", (unsigned long)shown, v, NSStringFromCGRect(v.bounds), v.alpha, v.hidden, (long)RSRedScoreInView(v,0), (long)RSMetadataScore(v,0), (long)RSScoreContainer(v), c.x,c.y, (v==RSInstalledContainer?@" INSTALLED":@""));
            if (++shown >= 12) break; // 严格上限，避免一次事件写太多。
        }
    } @catch (NSException *e) { RSLog(@"[TEST] snapshot exception: %@", e); }
}

static BOOL RSWasPresentAtRecordingStart(UIView *v) {
    return RSBaselineContainers && [RSBaselineContainers containsObject:v];
}

// v5.7.12：原生控制中心专项。
// 实机日志发现：稳定左侧录屏容器通常在屏幕中线左侧约 50pt（17x22 / 19.67x19），
// 但已有 Live Activity 后重新开始录屏时，偶尔先出现 22x22、靠硬件岛左内侧的临时容器
//（样本 center.x≈166，屏幕中线≈196）。它若在新会话 0.1 秒内抢绑，会造成位置突跳。
// 不永久禁止：仅在尚未绑定本次会话时视为过渡候选，给更典型录屏容器一点出现时间。
static BOOL RSLooksLikeInnerLeftTransient22(UIView *v) {
    if (!v || !v.window) return NO;
    CGFloat w = CGRectGetWidth(v.bounds), h = CGRectGetHeight(v.bounds);
    if (fabs(w - 22.0) >= 1.5 || fabs(h - 22.0) >= 1.5) return NO;
    CGPoint c = [v convertPoint:CGPointMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds)) toView:v.window];
    CGFloat midX = CGRectGetMidX(v.window.bounds);
    return (c.x > midX - 44.0 && c.x < midX - 8.0);
}

static NSInteger RSScoreContainer(UIView *v) {
    if (!v || !v.window || v.hidden) return NSIntegerMin / 2;
    if (v != RSInstalledContainer && v.alpha < 0.05) return NSIntegerMin / 2;

    CGFloat w = CGRectGetWidth(v.bounds), h = CGRectGetHeight(v.bounds);
    if (w < 12.0 || h < 12.0 || w > 48.0 || h > 48.0) return -500;

    // v5.7.3 核心防误抓：录屏红点在当前日志里只出现 17x22 / 19.67x19 / 22x22 等小容器。
    // 42x36.67、38x36、34x36 这类媒体/Live Activity 大容器直接禁止成为候选。
    // 即便它们包含红色子视图，也不能靠红色分数把自己抬成“录屏容器”。
    if (w > 30.0 || h > 30.0) return -700;

    CGFloat minSide = MIN(w,h), maxSide = MAX(w,h);
    CGFloat ratio = maxSide / MAX(minSide, 1.0);
    NSInteger score = 0;

    if (ratio <= 1.18) score += 30;
    else if (ratio <= 1.35) score += 20;
    else if (ratio <= 1.55) score += 8;
    else score -= 35;

    if (minSide >= 17.0 && maxSide <= 40.0) score += 18;
    if (fabs(w - 22.0) < 1.5 && fabs(h - 22.0) < 1.5) score += 10;
    if (fabs(w - 19.67) < 2.0 && fabs(h - 19.0) < 2.0) score += 8;
    if (fabs(w - 17.0) < 2.0 && fabs(h - 22.0) < 2.0) score += 6;
    if (fabs(w - 26.0) < 2.0 && fabs(h - 22.0) < 2.0) score += 5;

    score += RSRedScoreInView(v, 0);
    score += RSMetadataScore(v, 0);

    // 录屏通知触发后才新出现的容器优先级更高，降低误抓原有音乐/电池容器的概率。
    if (RSBaselineContainers && !RSWasPresentAtRecordingStart(v)) score += 55;

    // v5.7.12：只在新会话尚未绑定时降低“22x22 + 左内侧临时容器”的抢占优先级。
    // 若它最终确实是录屏容器，后续稳定确认仍允许接管。
    if (!RSInstalledContainer && RSLooksLikeInnerLeftTransient22(v)) score -= 32;

    // v5.7.1：身份连续性持续整个“本次录屏”，不再 3 秒后失忆。
    // 低分恢复仅限 17x22 / 19.67x19 / 22x22 小尺寸族，避免 34x36 / 38x36 媒体容器混入。
    if (RSRecordingActive && RSLastConfirmedAt > 0 && v.window) {
        CGPoint c = [v convertPoint:CGPointMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds)) toView:v.window];
        CGFloat dx = fabs(c.x - RSLastConfirmedCenter.x), dy = fabs(c.y - RSLastConfirmedCenter.y);
        BOOL side = c.x > (CGRectGetMidX(v.window.bounds) + 42.0);
        NSInteger red = RSRedScoreInView(v, 0);
        if (RSIsRecoverySize(v) && dy < 10.0 && red >= 25) {
            score += 18;
            if (dx < 34.0) score += 14;
            if (side == RSLastWasRight) score += 8;
        }
    }

    // V6.0.0：位于 ScreenRecording 元素子树内的 provided 容器给予决定性加分，
    // 从根上避免“切音乐/其他灵动岛活动”时误绑到音乐/媒体容器。
    if (RSV6IsRecordingContainer(v)) score += 160;
    if (v == RSInstalledContainer) score += 12; // 防止正常布局时频繁跳容器
    return score;
}

static UIView *RSFindBestContainer(void) {
    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    for (UIWindow *w in RSAllApplicationWindows()) {
        RSCollectProvidedContainers(w, 0, candidates);
    }

    UIView *best = nil;
    NSInteger bestScore = NSIntegerMin;
    for (UIView *v in candidates) {
        NSInteger s = RSScoreContainer(v);
        if (s > bestScore) {
            bestScore = s;
            best = v;
        }
    }

    // 没有达到最低可信度就先等待下一轮，避免误抓电池/音乐等容器。
    if (bestScore < 28) return nil;
    return best;
}

#pragma mark - 写轮眼 Overlay

static CGPoint RSModelCenterInWindow(UIView *container, UIWindow *window) {
    if (!container || !window) return CGPointZero;
    @try {
        return [container convertPoint:CGPointMake(CGRectGetMidX(container.bounds), CGRectGetMidY(container.bounds)) toView:window];
    } @catch (...) { return CGPointZero; }
}

static CGPoint RSRawPresentationCenterInWindow(UIView *container, UIWindow *window) {
    if (!container || !window) return CGPointZero;
    @try {
        CALayer *presentation = (CALayer *)container.layer.presentationLayer;
        CALayer *windowPresentation = (CALayer *)window.layer.presentationLayer;
        if (presentation && windowPresentation) {
            CGPoint localCenter = CGPointMake(CGRectGetMidX(presentation.bounds), CGRectGetMidY(presentation.bounds));
            CGPoint visual = [presentation convertPoint:localCenter toLayer:windowPresentation];
            if (isfinite(visual.x) && isfinite(visual.y)) return visual;
        }
    } @catch (...) {}
    return RSModelCenterInWindow(container, window);
}

static CGPoint RSVisualCenterInWindow(UIView *container, UIWindow *window) {
    if (!container || !window) return CGPointZero;

    CGPoint modelCenter = RSModelCenterInWindow(container, window);

    // v5.7.13：控制中心原生录屏专项。
    // 灵动岛左右“弹簧”拖拽时 presentationLayer 会出现明显 overshoot。Overlay 在 UIWindow 上，
    // 若逐帧完全照抄该 overshoot，就会被带到岛外；更糟的是旧代码还会把这个视觉位置写回
    // “已确认身份中心”，导致松手后候选连续性被污染，出现卡在外面/回不来的感觉。
    // 这里仍保留系统的小范围实时动画，但对“同一已绑定容器、同一侧”的大幅弹性偏移做限幅。
    @try {
        CALayer *presentation = (CALayer *)container.layer.presentationLayer;
        CALayer *windowPresentation = (CALayer *)window.layer.presentationLayer;
        if (presentation && windowPresentation) {
            CGPoint localCenter = CGPointMake(CGRectGetMidX(presentation.bounds), CGRectGetMidY(presentation.bounds));
            CGPoint visual = [presentation convertPoint:localCenter toLayer:windowPresentation];
            if (isfinite(visual.x) && isfinite(visual.y)) {
                BOOL modelRight = modelCenter.x > (CGRectGetMidX(window.bounds) + 42.0);
                BOOL sameBoundIdentity = (container == RSInstalledContainer && RSLastConfirmedAt > 0 && modelRight == RSLastWasRight);
                if (sameBoundIdentity) {
                    CGFloat dx = visual.x - modelCenter.x;
                    CGFloat dy = visual.y - modelCenter.y;
                    // v5.7.15：单独原生录屏只保留极小的 presentation 跟随。真正的“单独录屏弹簧锁定”
                    // 在 RSUpdateEyeGeometry 里使用录屏会话确认锚点完成，避免右滑把眼睛带出岛外。
                    const CGFloat maxElasticX = 0.75;
                    const CGFloat maxElasticY = 0.75;
                    if (fabs(dx) > maxElasticX) visual.x = modelCenter.x + copysign(maxElasticX, dx);
                    if (fabs(dy) > maxElasticY) visual.y = modelCenter.y + copysign(maxElasticY, dy);
                }
                return visual;
            }
        }
    } @catch (...) {}

    return modelCenter;
}

static BOOL RSContainerGeometryIsAnimating(UIView *container) {
    if (!container || !container.window) return NO;
    @try {
        CALayer *p = (CALayer *)container.layer.presentationLayer;
        if (!p) return NO;
        CGPoint modelPos = container.layer.position;
        CGPoint visualPos = p.position;
        CGFloat dx = fabs(modelPos.x - visualPos.x), dy = fabs(modelPos.y - visualPos.y);
        CGRect mb = container.layer.bounds, pb = p.bounds;
        CGFloat dw = fabs(CGRectGetWidth(mb) - CGRectGetWidth(pb));
        CGFloat dh = fabs(CGRectGetHeight(mb) - CGRectGetHeight(pb));
        return dx > 0.35 || dy > 0.35 || dw > 0.35 || dh > 0.35;
    } @catch (...) { return NO; }
}

static void RSUpdateEyeGeometry(void) {
    // V6.0.0：元素挂载模式下几何由元素子树驱动（宿主跟随系统 morph），不再把 eye 拽回 UIWindow。
    // 放在容器判空之前：元素内 provided 容器被系统重建导致弱引用失效时，逐帧同步仍由元素 hook 驱动。
    if (RSEyeMountedInElement) {
        RSV6SyncEyeToElement(RSEyeMountedElement, YES);
        return;
    }
    UIView *container = RSInstalledContainer;
    UIImageView *eye = RSSharinganView;
    if (!container || !eye || !container.window) return;

    UIWindow *window = container.window;
    if (eye.superview != window) {
        [eye removeFromSuperview];
        [window addSubview:eye];
    }

    CGPoint modelCenter = RSModelCenterInWindow(container, window);
    CGPoint center = RSVisualCenterInWindow(container, window);
    // v5.7.21：视觉侧别优先服从“已确认容器身份”，而不是 morph 中的临时 modelCenter。
    // 同一个已确认右侧录屏容器在点开/收起时会被系统临时拉到左侧；如果按 modelCenter 改成 left，
    // 就会套用左侧尺寸/X 偏移并出现“左滑跑到左边还超出去”。真正换边必须等新容器重新绑定。
    BOOL detectedRight = modelCenter.x > (CGRectGetMidX(window.bounds) + 42.0);
    BOOL right = detectedRight;
    if (container == RSLastConfirmedContainer && RSLastConfirmedAt > 0) right = RSLastWasRight;

    // v5.7.21：右侧 morph 只允许短暂隐藏，最多 0.22s；之后强制回到已确认右侧锚点。
    // 这样既不横穿长条，也不会像 V5.7.20 一样第二次点击后永久消失。
    NSTimeInterval now = CACurrentMediaTime();
    if (right && container == RSLastConfirmedContainer && RSLastWasRight && RSLastConfirmedAt > 0) {
        CGPoint rawVisual = RSRawPresentationCenterInWindow(container, window);
        CGFloat rawDrift = hypot(rawVisual.x - RSLastConfirmedCenter.x, rawVisual.y - RSLastConfirmedCenter.y);
        CGFloat modelDrift = hypot(modelCenter.x - RSLastConfirmedCenter.x, modelCenter.y - RSLastConfirmedCenter.y);
        BOOL morphing = rawDrift > 2.25 || modelDrift > 2.25;

        if (RSRightForceAnchorUntil > now) {
            center = RSLastConfirmedCenter;
            RSRightTransitionSuppressed = NO;
            RSRightTransitionStableSince = 0;
            RSRightTransitionSuppressedAt = 0;
        } else if (morphing) {
            if (!RSRightTransitionSuppressed) {
                RSRightTransitionSuppressed = YES;
                RSRightTransitionSuppressedAt = now;
            }
            RSRightTransitionStableSince = 0;
            if (now - RSRightTransitionSuppressedAt < RSRightTransitionMaxSuppress) {
                if (!RSEyeResumeVisibilityPending) eye.hidden = YES;
                eye.alpha = 1.0;
            } else {
                RSRightTransitionSuppressed = NO;
                RSRightTransitionSuppressedAt = 0;
                RSRightForceAnchorUntil = now + RSRightForceAnchorDuration;
                center = RSLastConfirmedCenter;
                if (!RSEyeGracePaused && !RSEyeResumeVisibilityPending) eye.hidden = NO;
            }
        } else if (RSRightTransitionSuppressed) {
            if (RSRightTransitionStableSince <= 0) RSRightTransitionStableSince = now;
            if (now - RSRightTransitionStableSince < RSRightTransitionSettle) {
                if (!RSEyeResumeVisibilityPending) eye.hidden = YES;
            } else {
                RSRightTransitionSuppressed = NO;
                RSRightTransitionStableSince = 0;
                RSRightTransitionSuppressedAt = 0;
                if (!RSEyeGracePaused && !RSEyeResumeVisibilityPending) eye.hidden = NO;
            }
        }
    } else {
        RSRightTransitionSuppressed = NO;
        RSRightTransitionStableSince = 0;
        RSRightTransitionSuppressedAt = 0;
        RSRightForceAnchorUntil = 0;
    }

    // v5.7.15：控制中心原生“单独录屏”专项弹簧锁。
    // 实机表现：只录屏时右滑灵动岛，presentation/model 会把录屏小容器暂时带离稳定位置；
    // 左滑后又回到原位。V5.7.13 只限制 presentation 最大 5pt 仍然会肉眼看到“跑出去”。
    // 当录屏开始基线容器 <=3、当前仍是已确认的左侧录屏小容器时，
    // 如果系统正在做几何动画或当前位置明显偏离会话确认锚点，就固定使用确认锚点。
    // 松手后系统稳定，不需要重新绑定，也不会出现“卡在外面”。
    BOOL singleRecordingLeft = (RSBaselineContainerCount <= 3 && !right &&
                                container == RSLastConfirmedContainer &&
                                RSLastConfirmedAt > 0 && RSIsRecoverySize(container));
    if (singleRecordingLeft) {
        BOOL animating = RSContainerGeometryIsAnimating(container);
        CGFloat visualDrift = hypot(center.x - RSLastConfirmedCenter.x, center.y - RSLastConfirmedCenter.y);
        CGFloat modelDrift = hypot(modelCenter.x - RSLastConfirmedCenter.x, modelCenter.y - RSLastConfirmedCenter.y);
        if (RSCaptureStopPending || animating || visualDrift > 0.75 || modelDrift > 0.75) {
            center = RSLastConfirmedCenter;
        }
    }

    BOOL preferenceRight = RSPreferenceSideForHost(container);
    RSApplyMaterialForSide(eye,preferenceRight);
    CGFloat size = preferenceRight ? RSRightSize() : RSLeftSize();
    // v5.7.10：不再叠加隐藏的“按容器尺寸自动左移”魔法值。
    // 左/右位置全部统一由设置里的 X 微调负责，方便实机找到准确值，避免不同状态叠加偏移造成回弹。
    // 左侧默认 -2.5pt（远离中间硬件岛），用户可在设置中继续微调。
    if (!preferenceRight) center.x += RSLeftXOffset();
    else center.x += RSRightXOffset();
    center.y += RSYOffset();

    // v5.7.11：系统在同一侧可能把录屏容器从 19.67x19 重建为 22x22，
    // 日志里中心会在约 307 <-> 304 间跳。只对这种“同侧小跳”做 0.14 秒插值；
    // 左右侧真正切换仍直接跟随系统 presentationLayer，不人为跨岛飞行。
    if (RSRebindSmoothingActive && RSEyeGeometryHasSide && right == RSEyeGeometryRight) {
        NSTimeInterval elapsed = CACurrentMediaTime() - RSRebindStartedAt;
        const CGFloat duration = 0.14;
        if (elapsed >= 0.0 && elapsed < duration) {
            CGFloat t = (CGFloat)(elapsed / duration);
            t = t * t * (3.0 - 2.0 * t); // smoothstep
            CGFloat dx = center.x - RSRebindFromCenter.x;
            CGFloat dy = center.y - RSRebindFromCenter.y;
            CGFloat dist = hypot(dx, dy);
            if (dist <= 14.0) {
                center.x = RSRebindFromCenter.x + dx * t;
                center.y = RSRebindFromCenter.y + dy * t;
            } else {
                RSRebindSmoothingActive = NO;
            }
        } else {
            RSRebindSmoothingActive = NO;
        }
    }

    CGRect targetBounds = CGRectMake(0, 0, size, size);
    [UIView performWithoutAnimation:^{
        eye.bounds = targetBounds;
        eye.center = center;
    }];

    // PNG 本身是圆形素材，不裁剪，避免旋转时边缘缺角。
    eye.layer.cornerRadius = 0.0;
    eye.clipsToBounds = NO;
    eye.layer.masksToBounds = NO;

    // v5.7.13：这里是“视觉帧”，不能再反向覆盖录屏容器的稳定身份。
    // RSLastConfirmedCenter / RSLastWasRight / RSLastConfirmedAt 只在真正绑定容器时更新。
    // 否则一次弹簧拖拽就会把临时 presentation 位置记成“已确认中心”，污染后续候选评分。
    RSEyeGeometryRight = right;
    RSEyeGeometryHasSide = YES;
    if (!RSEyeGracePaused && !RSEyeResumeVisibilityPending && !RSRightTransitionSuppressed) {
        // 正常稳定态保证可见。v5.7.23 的恢复门槛有固定上限，不允许无限 hidden。
        if (eye.hidden) eye.hidden = NO;
        if (eye.alpha < 0.01) eye.alpha = 1.0;
    }
    [window bringSubviewToFront:eye];
}

static void RSInstallOnContainer(UIView *container) {
    if (!container || !RSRecordingActive || !RSIsEnabled()) return;
    // V6.0.0：元素挂载模式下禁止再走窗口 overlay 安装（防止双写轮眼/位置打架）
    if (RSEyeMountedInElement) return;

    if (RSInstalledContainer != container) {
        UIView *old = RSInstalledContainer;
        UIImageView *existingEye = RSSharinganView;
        CGPoint previousEyeCenter = existingEye ? existingEye.center : CGPointZero;
        BOOL hadEye = (existingEye != nil && existingEye.superview != nil);
        BOOL previousSideKnown = RSEyeGeometryHasSide;
        BOOL previousSideRight = RSEyeGeometryRight;
        RSRestoreContainer(old);
        RSRestoreRedLeaves(old);
        RSInstalledContainer = container;
        RSHideContainer(container);
        UIWindow *w = container.window;
        CGPoint c = [container convertPoint:CGPointMake(CGRectGetMidX(container.bounds), CGRectGetMidY(container.bounds)) toView:w];
        BOOL measuredRight = c.x > (CGRectGetMidX(w.bounds) + 42.0);
        // v5.7.23：同一轮会话一旦确认右侧独立圆，就不允许 morph 的 x≈166 临时位置改写 side/anchor。
        // 若刚刚 finalize 后系统立刻又以同一个容器抖回 YES，也继承最近右侧身份。
        BOOL recentSameRight = (container == RSRecentlyStoppedContainer && RSRecentlyStoppedWasRight &&
                                (CACurrentMediaTime() - RSRecentlyStoppedAt) <= RSRecentSideIdentityWindow);
        if ((RSSessionSideLocked && RSSessionLockedRight && !measuredRight) || (recentSameRight && !measuredRight)) {
            RSLog(@"ignored transient right->left morph container=%p center={%.2f,%.2f}; right session lock kept", container, c.x, c.y);
            RSInstalledContainer = old;
            if (old) RSHideContainer(old);
            return;
        }
        RSLastConfirmedContainer = container;
        RSLastConfirmedCenter = c;
        RSLastConfirmedAt = CACurrentMediaTime();
        RSLastWasRight = measuredRight;
        if (!RSSessionSideLocked) {
            RSSessionSideLocked = YES;
            RSSessionLockedRight = measuredRight;
            RSLog(@"session side locked=%@", measuredRight ? @"right" : @"left");
        }
        // 只在旧眼睛和新容器处于同一侧时开启短暂平滑，避免把左右独立活动错误连成横穿灵动岛的动画。
        if (hadEye && previousSideKnown && previousSideRight == RSLastWasRight) {
            RSRebindFromCenter = previousEyeCenter;
            RSRebindStartedAt = CACurrentMediaTime();
            RSRebindSmoothingActive = YES;
        } else {
            RSRebindSmoothingActive = NO;
        }
        RSLog(@"bound recording container=%p bounds=%@ score=%ld side=%@ center={%.2f,%.2f}", container, NSStringFromCGRect(container.bounds), (long)RSScoreContainer(container), RSLastWasRight ? @"right" : @"left", c.x, c.y);
        RSTestSnapshot(@"container-bound");
    } else {
        RSHideContainer(container);
    }

    UIImageView *eye = RSEyeViewEnsure();
    if (!eye) return;

    RSUpdateEyeGeometry();
    if (![eye.layer animationForKey:@"rs.rotation"]) RSStartRotation(eye);
}

static void RSReloadEyeImage(void) {
    if (!RSHideNativeRedEnabled()) RSV73RestoreNativeIndicator();
    RSLeftMaterialChoice=nil;RSRightMaterialChoice=nil;RSLoadedMaterialChoice=nil;
    [RSMaterialImageCache removeAllObjects];RSMaterialAppliedView=nil;
    UIImageView *eye=RSSharinganView;
    if(!eye)return;
    RSApplyMaterialForSide(eye,RSMaterialHasSide ? RSMaterialCurrentSide : RSLastWasRight);
    RSStartRotation(eye);
}

static void RSDiscoverAllBody(BOOL forceRescan) {
    if (!RSRecordingActive) return;
    if (!RSIsEnabled()) {
        RSRemoveSharingan();
        return;
    }

    // v5.7.15：短暂 capture-off（展开/收起录屏岛）期间绝不重新选容器。
    // 保持当前绑定和锚点，避免暂停面板收起时重新扫描/重装造成顿一下。
    if (RSCaptureStopPending) {
        UIView *held = RSInstalledContainer;
        if (held && held.window && RSSharinganView) RSHideContainer(held);
        // v5.7.25：grace 期间系统可能把录屏红点重建到另一个临时 provided container。
        // 此时绝不重绑/不跟随几何，只做“严格小尺寸 + 红色叶子 + 顶部区域”的临时红点压制。
        RSSuppressTransientRecordingRedContainers();
        return;
    }

    // V6.0.0：优先走 SystemAperture ScreenRecording 元素精准定位。
    // 找到元素 → 挂载/同步后直接返回；找不到再回退旧 provided-container 管线。
    {
        UIView *element = RSV6FindScreenRecordingElement(forceRescan);
        if (element) {
            RSV6MountEyeIntoElement(element);
            RSV6SyncEyeToElement(element, YES);
            RSLastRescan = CACurrentMediaTime();
            return;
        }
        // 元素不可用但此前已挂载：摘除挂载标记，让旧管线接管（容器可能仍在窗口内）
        if (RSEyeMountedInElement) {
            RSEyeMountedInElement = NO;
            RSEyeHostElement = nil;
            RSEyeMountedElement = nil;
            RSLog(@"V6 element lost; falling back to legacy provided-container pipeline");
        }
    }

    UIView *current = RSInstalledContainer;
    BOOL currentValid = current && current.window && !current.hidden && CGRectGetWidth(current.bounds) > 1.0 && CGRectGetHeight(current.bounds) > 1.0;

    NSTimeInterval now = CACurrentMediaTime();
    BOOL timeForRescan = (now - RSLastRescan) >= 0.25;
    if (forceRescan || !currentValid || timeForRescan) {
        RSLastRescan = now;

        // v5.7.11：Home 手势/灵动岛弹簧过渡中，当前容器 presentationLayer 正在运动时
        // 不抢绑另一个临时容器。继续跟随当前 presentationLayer，等动画稳定后再重新评估。
        if (currentValid && !forceRescan && RSContainerGeometryIsAnimating(current)) {
            RSInstallOnContainer(current);
            if (RSInstalledContainer && RSSharinganView) {
                RSHideContainer(RSInstalledContainer);
                RSUpdateEyeGeometry();
            }
            return;
        }

        UIView *best = RSFindBestContainer();
        if (best) {
            NSInteger bestScore = RSScoreContainer(best);
            NSInteger currentScore = currentValid ? RSScoreContainer(current) : NSIntegerMin / 2;

            if (best == current) {
                // 已锁定的容器继续跟随，不因为布局中的其他临时容器乱跳。
                RSPendingContainer = nil;
                RSPendingSince = 0;
                RSPendingHits = 0;
                RSInstallOnContainer(best);
            } else {
                if (best != RSPendingContainer) {
                    RSPendingContainer = best;
                    RSPendingSince = now;
                    RSPendingHits = 1;
                    RSLog(@"candidate container=%p bounds=%@ score=%ld%@", best, NSStringFromCGRect(best.bounds), (long)bestScore,
                          (!currentValid && RSLooksLikeInnerLeftTransient22(best)) ? @" guard=inner-left-22" : @"");
                } else {
                    RSPendingHits++;
                }

                NSTimeInterval stableFor = now - RSPendingSince;
                // 高可信录屏圆（日志中约 123 分）可以快速接管；70 分左右必须稳定确认。
                // v5.7.12：新会话若首先出现“22x22 + 左内侧”临时容器，延迟约 0.36 秒再允许绑定。
                // 不新增 Timer；仍复用既有发现流程。
                BOOL initialInnerLeftGuard = (!currentValid && RSLooksLikeInnerLeftTransient22(best));
                BOOL highConfidence = initialInnerLeftGuard
                    ? (bestScore >= 95 && RSPendingHits >= 3 && stableFor >= 0.36)
                    : (bestScore >= 105 && RSPendingHits >= 2 && stableFor >= 0.08);
                BOOL stableCandidate = initialInnerLeftGuard
                    ? (bestScore >= 65 && RSPendingHits >= 3 && stableFor >= 0.36)
                    : (bestScore >= 65 && RSPendingHits >= 3 && stableFor >= 0.32);
                BOOL continuityCandidate = NO;
                BOOL sideSwitchCandidate = NO;
                if (RSLastConfirmedAt > 0 && best.window && RSRedScoreInView(best, 0) >= 25 && RSIsRecoverySize(best)) {
                    CGPoint bc = [best convertPoint:CGPointMake(CGRectGetMidX(best.bounds), CGRectGetMidY(best.bounds)) toView:best.window];
                    CGFloat dx=fabs(bc.x-RSLastConfirmedCenter.x), dy=fabs(bc.y-RSLastConfirmedCenter.y);
                    BOOL bestRight = bc.x > (CGRectGetMidX(best.window.bounds) + 42.0);
                    // 整个录屏周期都可恢复，但必须是小尺寸族 + 红色特征 + Y 轴一致 + 稳定多帧。
                    continuityCandidate = (dy < 10.0 && dx < 42.0 && RSPendingHits >= 3 && stableFor >= 0.22);
                    // 左/右独立圆切换时 X 距离可能很大；高可信红色小容器稳定出现即可迁移。
                    sideSwitchCandidate = (!RSSessionSideLocked && bestRight != RSLastWasRight && bestScore >= 88 && dy < 10.0 && RSPendingHits >= 2 && stableFor >= 0.12);
                }
                // v5.7.13：当前容器仍有效时，同一侧不允许被“远处的临时小圆”抢绑。
                // 实机日志里左侧稳定中心约 139~144pt，而弹簧/临时 22x22 会跑到约 166pt；
                // 这类 20+pt 的同侧跳变不是我们要跟随的录屏身份迁移。真正左右侧切换仍允许。
                BOOL sameSideFarTransient = NO;
                if (currentValid && RSLastConfirmedAt > 0 && best.window) {
                    CGPoint bc = [best convertPoint:CGPointMake(CGRectGetMidX(best.bounds), CGRectGetMidY(best.bounds)) toView:best.window];
                    BOOL bestRight = bc.x > (CGRectGetMidX(best.window.bounds) + 42.0);
                    CGFloat dx = fabs(bc.x - RSLastConfirmedCenter.x);
                    CGFloat dy = fabs(bc.y - RSLastConfirmedCenter.y);
                    sameSideFarTransient = (bestRight == RSLastWasRight && dx > 16.0 && dy < 10.0);
                }

                BOOL lockedRightTransientLeft = NO;
                if (RSSessionSideLocked && RSSessionLockedRight && best.window) {
                    CGPoint bc = [best convertPoint:CGPointMake(CGRectGetMidX(best.bounds), CGRectGetMidY(best.bounds)) toView:best.window];
                    BOOL bestRight = bc.x > (CGRectGetMidX(best.window.bounds) + 42.0);
                    lockedRightTransientLeft = !bestRight;
                    if (lockedRightTransientLeft && RSPendingHits == 1)
                        RSLog(@"right session lock rejected transient left candidate=%p center={%.2f,%.2f}", best, bc.x, bc.y);
                }

                BOOL beatsCurrent = !currentValid || bestScore >= currentScore + 18;
                if ((continuityCandidate || sideSwitchCandidate) && (!currentValid || bestScore >= currentScore + 8)) beatsCurrent = YES;
                if (sameSideFarTransient || lockedRightTransientLeft) beatsCurrent = NO;

                if (beatsCurrent && (highConfidence || stableCandidate || continuityCandidate || sideSwitchCandidate)) {
                    RSLog(@"candidate accepted=%p score=%ld hits=%lu stable=%.2f", best, (long)bestScore, (unsigned long)RSPendingHits, stableFor);
                    RSInstallOnContainer(best);
                    RSPendingContainer = nil;
                    RSPendingSince = 0;
                    RSPendingHits = 0;
                }
            }
        }
    }

    if (RSInstalledContainer && RSSharinganView) {
        RSHideContainer(RSInstalledContainer);
        RSUpdateEyeGeometry();
    }
}

// 6.20: discovery may modify the view hierarchy. Never re-enter it from UIKit layout.
static BOOL RS20Discovering = NO;
static void RSDiscoverAll(BOOL forceRescan) {
    if (RS20Discovering || !RSInitialized || !RSRecordingActive) return;
    if (![UIScreen mainScreen].isCaptured) return;
    RS20Discovering = YES;
    @try { RSDiscoverAllBody(forceRescan); }
    @finally { RS20Discovering = NO; }
}

// Coalesce indicator/element callbacks into at most one pending discovery.
// No retained native host and no force-rescan from a native layout callback.
static BOOL RS20RefreshScheduled = NO;
static void RS20ScheduleRefresh(void) {
    if (RS20RefreshScheduled || RS20Discovering || !RSInitialized ||
        !RSRecordingActive || RSCaptureStopPending || RSV7113Mounting) return;
    RS20RefreshScheduled = YES;
    NSUInteger session = RSCaptureStopGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RS20RefreshScheduled = NO;
        if (session != RSCaptureStopGeneration || !RSRecordingActive || RSCaptureStopPending) return;
        @try { RSDiscoverAll(NO); }
        @catch (NSException *e) { RSLog(@"6.20 deferred refresh exception: %@", e); }
    });
}

#pragma mark - 逐帧几何跟随

@interface RSGeometryDriver : NSObject
+ (instancetype)shared;
- (void)tick:(CADisplayLink *)link;
@end

@implementation RSGeometryDriver
+ (instancetype)shared {
    static RSGeometryDriver *driver = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ driver = [RSGeometryDriver new]; });
    return driver;
}
- (void)tick:(CADisplayLink *)link {
    if (!RSRecordingActive || !RSInitialized || !RSSharinganView) return;
    @try {
        // V7.9: the verified ScreenRecording element exists before the user swipes the island.
        // Re-sync it every display frame so initial presentation cannot depend on a later layout callback.
        if (RSEyeMountedInElement && RSEyeMountedElement) {
            RSV6SyncEyeToElement(RSEyeMountedElement, YES);
        }
        if (RSInstalledContainer && [UIScreen mainScreen].isCaptured) RSUpdateEyeGeometry();
    }
    @catch (NSException *e) { RSLog(@"V7.9 geometry frame exception: %@", e); }
}
@end

static void RSStopGeometryDisplayLink(void) {
    [RSGeometryDisplayLink invalidate];
    RSGeometryDisplayLink = nil;
}

static void RSEnsureGeometryDisplayLink(void) {
    if (RSGeometryDisplayLink) return;
    RSGeometryDisplayLink = [CADisplayLink displayLinkWithTarget:[RSGeometryDriver shared] selector:@selector(tick:)];
    [RSGeometryDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    RSLog(@"geometry display link started");
}

#pragma mark - 轮询生命周期


// V7.11.2: removed obsolete V7.10 presentation-refresh burst.
// V7.11 uses AccessoryView/AccessoryPortalView lifecycle binding instead.

static void RSStopPollTimer(void) {
    [RSPollTimer invalidate];
    RSPollTimer = nil;
}

static void RSEnsurePollTimer(void) {
    if (RSPollTimer && RSPollTimer.valid) return;
    RSPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.10
                                                  repeats:YES
                                                    block:^(__unused NSTimer *timer) {
        if (!RSRecordingActive || !RSInitialized) return;
        @try { RSDiscoverAll(NO); }
        @catch (NSException *e) { RSLog(@"poll exception: %@", e); }
    }];
    [[NSRunLoop mainRunLoop] addTimer:RSPollTimer forMode:NSRunLoopCommonModes];
    RSLog(@"polling started");
}

#pragma mark - 录屏状态

static void RSCancelCaptureResumeConfirmation(void) {
    if (!RSCaptureResumePending) return;
    RSCaptureResumePending = NO;
    RSCaptureResumeGeneration++;
}

static void RSV7114ScheduleResumeRemounts(void);
static void RSV7114ResetAccessorySession(void);
static void RSV7114RunRemountAttempt(NSUInteger generation, NSUInteger attempt);
static NSUInteger RSV7114RemountGeneration = 0; // generation storage must be declared before V7.11.8.x refresh callbacks

static void RSV7117ArmPresentationRemount(void) {
    RSV7117AwaitingPresentation = YES;
    NSUInteger generation = ++RSV7117PresentationGeneration;
    UIView *baseline = (RSV711AccessoryPortal && RSV711AccessoryPortal.window) ? RSV711AccessoryPortal : nil;
    RSV7117BaselinePortal = baseline;
    RSV7117BaselinePortalFrame = baseline ? baseline.frame : CGRectZero;
    RSLog(@"[V7.11.8.4] QUICK RESUME -> wait for real SystemAperture presentation event baseline=%@ frame=%@",
          baseline ? NSStringFromClass(baseline.class) : @"nil", NSStringFromCGRect(RSV7117BaselinePortalFrame));

    // Safety fallback only.  Normal path is an AccessoryPortal/Accessory lifecycle event.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!RSV7117AwaitingPresentation || generation != RSV7117PresentationGeneration || !RSRecordingActive) return;
        RSV7117AwaitingPresentation = NO;
        RSLog(@"[V7.11.8.4] presentation-event timeout -> one fallback FORCE REMOUNT");
        RSV7114ResetAccessorySession();
        NSUInteger g = RSV7114RemountGeneration;
        RSV7114RunRemountAttempt(g, 1);
    });
}

static void RSV7117ConsumePresentationEvent(UIView *v, NSString *event) {
    if (!RSV7117AwaitingPresentation || !RSRecordingActive || !v || !v.window) return;
    if (!(RSV711IsAccessoryPortal(v) || RSV711IsAccessoryView(v))) return;

    BOOL movedToWindow = [event rangeOfString:@"didMoveToWindow"].location != NSNotFound;
    BOOL changedObject = RSV711IsAccessoryPortal(v) && v != RSV7117BaselinePortal;
    BOOL changedGeometry = RSV711IsAccessoryPortal(v) && !CGRectEqualToRect(v.frame, RSV7117BaselinePortalFrame);
    BOOL presentationEvent = movedToWindow || changedObject || changedGeometry;
    if (!presentationEvent) return;

    RSV7117AwaitingPresentation = NO;
    ++RSV7117PresentationGeneration;
    RSV7118LayoutRefreshDirty = NO;
    RSV7118LayoutRefreshInProgress = NO;
    ++RSV7118LayoutRefreshGeneration;
    RSLog(@"[V7.11.8.4] fresh SystemAperture presentation event=%@ class=%@ frame=%@ -> FORCE REMOUNT once",
          event, NSStringFromClass(v.class), NSStringFromCGRect(v.frame));
    RSV7114ResetAccessorySession();
    NSUInteger g = RSV7114RemountGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{ RSV7114RunRemountAttempt(g, 1); });
}

static void RSV7118RequestSystemApertureRefresh(NSString *reason) {
    if (!RSInitialized || !RSRecordingActive) return;
    RSV7118LayoutRefreshDirty = YES;
    NSUInteger generation = ++RSV7118LayoutRefreshGeneration;
    RSLog(@"[V7.11.8.4] aperture refresh requested reason=%@ generation=%lu", reason ?: @"unknown", (unsigned long)generation);

    // Defer out of the capture callback.  Request UIKit's normal layout transaction once;
    // never call layoutSubviews directly.  If the private container exposes invalidateCache,
    // use the same cache-invalidating signal seen in the working island tweak.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!RSV7118LayoutRefreshDirty || generation != RSV7118LayoutRefreshGeneration || !RSRecordingActive) return;
        for (UIWindow *w in RSAllApplicationWindows()) {
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
            while (stack.count) {
                UIView *v = stack.lastObject; [stack removeLastObject];
                if ([NSStringFromClass(v.class) isEqualToString:@"SBSystemApertureContainerView"] && v.window) {
                    @try {
                        SEL inv = NSSelectorFromString(@"invalidateCache");
                        if ([v respondsToSelector:inv]) ((void(*)(id,SEL))objc_msgSend)(v, inv);
                        [v setNeedsLayout];
                        // layoutIfNeeded asks UIKit to commit the pending layout now; our hook consumes
                        // the dirty bit BEFORE remounting, preventing layout->mount->layout recursion.
                        [v layoutIfNeeded];
                        RSLog(@"[V7.11.8.4] requested SystemAperture layout class=%@ frame=%@", NSStringFromClass(v.class), NSStringFromCGRect(v.frame));
                    } @catch (NSException *e) { RSLog(@"[V7.11.8.4] aperture refresh request exception %@", e); }
                    return;
                }
                for (UIView *sub in v.subviews) [stack addObject:sub];
            }
        }
        RSLog(@"[V7.11.8.4] SystemApertureContainerView not ready; presentation-event fallback remains armed");
        RSV7117ArmPresentationRemount();
    });
}

static void RSV7118ConsumeContainerLayout(UIView *container) {
    if (!RSV7118LayoutRefreshDirty || RSV7118LayoutRefreshInProgress || !RSRecordingActive || !container.window) return;
    RSV7118LayoutRefreshDirty = NO; // clear FIRST: remount may itself cause another layout
    RSV7118LayoutRefreshInProgress = YES;
    ++RSV7118LayoutRefreshGeneration;
    RSLog(@"[V7.11.8.4] SystemAperture layout consumed -> FORCE REMOUNT once frame=%@", NSStringFromCGRect(container.frame));
    @try {
        RSV7114ResetAccessorySession();
        NSUInteger g = RSV7114RemountGeneration;
        RSV7114RunRemountAttempt(g, 1);
    } @catch (NSException *e) { RSLog(@"[V7.11.8.4] layout consume exception %@", e); }
    RSV7118LayoutRefreshInProgress = NO;
}

static void RSConfirmCaptureResume(NSUInteger generation) {
    if (!RSCaptureStopPending || !RSRecordingActive) return;
    if (!RSCaptureResumePending || generation != RSCaptureResumeGeneration) return;

    BOOL captured = NO;
    @try { captured = [UIScreen mainScreen].isCaptured; }
    @catch (NSException *e) { RSLog(@"UIScreen resume-confirm exception: %@", e); return; }

    if (!captured) {
        RSCaptureResumePending = NO;
        RSLog(@"capture resume confirmation cancelled: capture fell back to off");
        return;
    }

    // 右侧独立圆结束录屏后，旧的 provided container 可能已经被系统撤掉。
    // 如果身份容器已经离开 window，则不要把旧 overlay 重新点亮；继续保持隐藏，
    // 等真正稳定的新录屏状态再走正常 0 -> 1 路径。
    UIView *container = RSInstalledContainer;
    BOOL containerStillValid = container && container.window && !container.hidden &&
        CGRectGetWidth(container.bounds) > 1.0 && CGRectGetHeight(container.bounds) > 1.0;
    if (!containerStillValid) {
        RSCaptureResumePending = NO;
        RSLog(@"capture resume confirmation held: old container no longer valid");
        return;
    }

    RSCaptureResumePending = NO;
    RSCaptureStopPending = NO;
    RSCaptureStopGeneration++;
    // V7.11.6: a fast pause -> resume can happen entirely inside the 1.35s grace window.
    // SystemAperture may reuse the same Portal object but replace its presentation, so merely
    // showing/syncing the old eye leaves it attached to a stale presentation. Treat a stable
    // YES confirmation as a new presentation session and do the same bounded FORCE REMOUNT
    // used by the normal finalized OFF -> ON path.
    RSLog(@"[V7.11.8.4] QUICK RESUME confirmed -> arm SystemAperture presentation event (side=%@)", RSLastWasRight ? @"right" : @"left");
    RSResumeEyeAfterCaptureGrace();
    RSEnsurePollTimer();
    RSEnsureGeometryDisplayLink();
    RSV7118RequestSystemApertureRefresh(@"quick-resume");
}

static void RSScheduleCaptureResumeConfirmation(void) {
    if (!RSCaptureStopPending || !RSRecordingActive || RSCaptureResumePending) return;
    RSCaptureResumePending = YES;
    NSUInteger generation = ++RSCaptureResumeGeneration;
    NSTimeInterval delay = RSLastWasRight ? RSCaptureResumeConfirmRight : RSCaptureResumeConfirmLeft;
    RSLog(@"capture resume candidate: waiting %.2fs stable YES (side=%@)", delay, RSLastWasRight ? @"right" : @"left");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RSConfirmCaptureResume(generation);
    });
}

// V7.11.6: every OFF -> ON transition is a new SystemAperture presentation session.
// Reset only our accessory cache and perform three bounded remount attempts.  This keeps
// V7.11.3's recursion guard while replacing the manual island swipe after pause/resume.
// RSV7114RemountGeneration is declared above the V7.11.8.x refresh callbacks.
static void RSV7114ResetAccessorySession(void) {
    RSV7114RemountGeneration++;
    RSV711AccessoryPortal = nil;
    RSV711AccessoryView = nil;
    RSV71190ConfirmGeneration++;
    RSV71191LastMigrationAt = 0;
    RSV71188ResetPendingHost();
    RSV71190MigrationCommit = NO;
    RSV71190MigrationTarget = nil;
    RSV7113PendingAccessory = nil;
    RSV7113MountScheduled = NO;
    RSV711LastBindLog = 0;
}

static void RSV7114RunRemountAttempt(NSUInteger generation, NSUInteger attempt) {
    if (generation != RSV7114RemountGeneration || !RSInitialized || !RSRecordingActive) return;
    if (RSV7113Mounting || RSCaptureStopPending || ![UIScreen mainScreen].isCaptured) return;
    @try {
        // Refresh ScreenRecording identity first; then resolve the CURRENT portal instead
        // of trusting the object from the previous presentation.
        RSDiscoverAll(YES);
        UIView *element = RSEyeMountedElement;
        if (!element || !element.window) {
            RSLog(@"[V7.11.8.4] remount attempt=%lu waiting for ScreenRecording element", (unsigned long)attempt);
            return;
        }
        UIView *portal = RSV711BestAccessoryHostForElement(element);
        if (portal && portal.window) {
            RSV711AccessoryPortal = portal;
            RSV7113PendingAccessory = portal;
            RSV7113Mounting = YES;
            // V7.11.6: do not merely sync the old mounted state.  Pause/resume can reuse
            // the exact same Portal object while replacing its presentation.  Recreate our
            // eye attachment unconditionally for this session generation.
            UIImageView *oldEye = RSSharinganView;
            if (oldEye) [oldEye removeFromSuperview];
            RSEyeHostElement = nil;
            RSEyeMountedInElement = NO;
            RSEyeMountedElement = nil;
            RSV6MountEyeIntoElement(element);
            RSV7113Mounting = NO;
            RSLog(@"[V7.11.8.4] SESSION ON -> FORCE REMOUNT attempt=%lu host=%@ frame=%@", (unsigned long)attempt,
                  NSStringFromClass(portal.class), NSStringFromCGRect(portal.frame));
        } else {
            RSLog(@"[V7.11.8.4] remount attempt=%lu portal pending", (unsigned long)attempt);
        }
    } @catch (NSException *e) {
        RSV7113Mounting = NO;
        RSLog(@"[V7.11.8.4] remount exception attempt=%lu %@", (unsigned long)attempt, e);
    }
}

static void RSV7114ScheduleResumeRemounts(void) {
    RSV7114ResetAccessorySession();
    NSUInteger generation = RSV7114RemountGeneration;
    const NSTimeInterval delays[] = {0.0, 0.10, 0.30};
    for (NSUInteger i = 0; i < 3; i++) {
        NSTimeInterval delay = delays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            RSV7114RunRemountAttempt(generation, i + 1);
        });
    }
}

static void RSFinalizeRecordingStop(NSUInteger generation) {
    if (!RSCaptureStopPending || generation != RSCaptureStopGeneration) return;

    BOOL captured = NO;
    @try { captured = [UIScreen mainScreen].isCaptured; }
    @catch (NSException *e) { RSLog(@"UIScreen finalize exception: %@", e); return; }

    if (captured) {
        // v5.7.19：绝不在 stop grace 到点时仅凭一次 YES 就重新显示 eye。
        // 真恢复必须通过持续 YES 确认；这能吞掉“结束录屏后的尾部假恢复”。
        RSScheduleCaptureResumeConfirmation();
        RSLog(@"capture stop finalize deferred: capture is YES, waiting stable resume confirmation");
        return;
    }

    RSCaptureStopPending = NO;
    RSCancelCaptureResumeConfirmation();
    RSCaptureStopStartedAt = 0;
    if (!RSRecordingActive) return;

    RSLog(@"recording state 1 -> 0 finalized after %.2fs grace", RSCaptureStopGrace);
    RSLog(@"[V7.11.8.4] SESSION OFF finalized -> invalidate previous presentation");
    RSV7117AwaitingPresentation = NO;
    ++RSV7117PresentationGeneration;
    RSV7118LayoutRefreshDirty = NO;
    RSV7118LayoutRefreshInProgress = NO;
    ++RSV7118LayoutRefreshGeneration;
    RSRecentlyStoppedContainer = RSLastConfirmedContainer ?: RSInstalledContainer;
    RSRecentlyStoppedWasRight = RSSessionSideLocked ? RSSessionLockedRight : RSLastWasRight;
    RSRecentlyStoppedAt = CACurrentMediaTime();
    RSSessionSideLocked = NO;
    RSSessionLockedRight = NO;
    RSRecordingActive = NO;
    RSV71187MigrationScheduled = NO;
    ++RSV71187MigrationGeneration;
    RSV71187LastStableHost = nil;
    RSV71191LastMigrationAt = 0;
    RSV71188ResetPendingHost();
    // V7.11.4: invalidate the previous presentation host before the next recording session.
    RSV7114ResetAccessorySession();
    RSStopPollTimer();
    RSStopGeometryDisplayLink();
    RSRemoveSharingan();
    RSLastRescan = 0;
    RSBaselineContainers = nil;
    RSBaselineContainerCount = 0;
    RSPendingContainer = nil;
    RSPendingSince = 0;
    RSPendingHits = 0;
    RSLastConfirmedContainer = nil;
    RSLastConfirmedAt = 0;
    RSSessionSideLocked = NO;
    RSSessionLockedRight = NO;
    RSTestSnapshot(@"recording-stop");
}

static void RSUpdateRecordingState(void) {
    BOOL captured = NO;
    @try { captured = [UIScreen mainScreen].isCaptured; }
    @catch (NSException *e) { RSLog(@"UIScreen exception: %@", e); return; }

    if (captured) {
        // v5.7.19：capture-off grace 后不再“一看到 YES 就复活 eye”。
        // V7.11.8.4：左侧快速恢复压到 0.03s，并在确认后立即显示；右侧独立圆（APP/Live Activity）仍保留 0.75s，
        // 专门过滤结束录屏后系统尾部的 YES/NO 抖动。
        if (RSCaptureStopPending && RSRecordingActive) {
            RSScheduleCaptureResumeConfirmation();
            return;
        }

        if (RSRecordingActive) return;

        RSLog(@"recording state 0 -> 1");
        RSLog(@"[V7.11.8.4] SESSION ON detected -> schedule FORCE REMOUNT");
        RSRecordingActive = YES;
        RSCaptureStopPending = NO;
        RSCancelCaptureResumeConfirmation();
        RSCaptureStopStartedAt = 0;
        RSCaptureStopGeneration++;

        // 先记录录屏状态切换瞬间已经存在的 provided containers。随后新创建的容器会获得更高评分。
        RSPendingContainer = nil;
        RSPendingSince = 0;
        RSPendingHits = 0;
        RSLastConfirmedContainer = nil;
        RSLastConfirmedAt = 0;
        RSSessionSideLocked = NO;
        RSSessionLockedRight = NO;
        RSBaselineContainers = [NSHashTable weakObjectsHashTable];
        @try {
            NSMutableArray<UIView *> *baseline = [NSMutableArray array];
            for (UIWindow *w in RSAllApplicationWindows()) RSCollectProvidedContainers(w, 0, baseline);
            for (UIView *v in baseline) [RSBaselineContainers addObject:v];
            RSBaselineContainerCount = baseline.count;
            RSLog(@"baseline containers=%lu", (unsigned long)baseline.count);
            RSTestSnapshot(@"recording-start");
        } @catch (...) {}

        RSEnsurePollTimer();
        RSEnsureGeometryDisplayLink();
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                RSDiscoverAll(YES);
                RSDiscoverAll(YES);
            }
            @catch (NSException *e) { RSLog(@"initial discover exception: %@", e); }
        });
        // V7.11.6: force one bounded new-session remount sequence.  On first start this is
        // harmless; after pause -> finalized stop -> resume it replaces the manual swipe.
        RSV7114ScheduleResumeRemounts();
        return;
    }

    if (!RSRecordingActive) return;

    // 若刚才正在等待“持续 YES”确认，现在又跌回 NO，说明这次 YES 很可能只是停止尾声抖动。
    if (RSCaptureStopPending) {
        if (RSCaptureResumePending) {
            RSCancelCaptureResumeConfirmation();
            RSLog(@"capture resume candidate rejected: capture returned to off");
        }

        // 原始 1.35s 宽限已经过去后，再次确认 NO 就可以立即真正收尾，
        // 不因为尾部反复抖动重新等待另一轮 1.35s。
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (RSCaptureStopStartedAt > 0 && now - RSCaptureStopStartedAt >= RSCaptureStopGrace) {
            NSUInteger generation = RSCaptureStopGeneration;
            dispatch_async(dispatch_get_main_queue(), ^{ RSFinalizeRecordingStop(generation); });
        }
        return;
    }

    // v5.7.15~18：短暂 capture-off 时保留同一会话，隐藏 eye 并暂停驱动。
    if (RSInstalledContainer && RSSharinganView) {
        RSCaptureStopPending = YES;
        RSCaptureStopStartedAt = [NSDate timeIntervalSinceReferenceDate];
        RSCancelCaptureResumeConfirmation();
        NSUInteger generation = ++RSCaptureStopGeneration;
        RSPauseEyeForCaptureGrace();
        // v5.7.23：eye 隐藏后继续压住当前容器中的系统红点叶子，
        // 避免暂停/收起 morph 期间闪出一帧原生红点。
        RSHideContainer(RSInstalledContainer);
        RSStopPollTimer();
        RSStopGeometryDisplayLink();
        RSLog(@"capture-off grace started %.2fs (session preserved, eye hidden/paused, drivers suspended)", RSCaptureStopGrace);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RSCaptureStopGrace * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            RSFinalizeRecordingStop(generation);
        });
        return;
    }

    // 尚未成功安装写轮眼时没有必要等待，直接结束当前检测周期。
    RSLog(@"recording state 1 -> 0 (no installed eye)");
    RSRecordingActive = NO;
    RSCaptureStopPending = NO;
    RSCancelCaptureResumeConfirmation();
    RSCaptureStopStartedAt = 0;
    RSStopPollTimer();
    RSStopGeometryDisplayLink();
    RSRemoveSharingan();
    RSLastRescan = 0;
    RSBaselineContainers = nil;
    RSBaselineContainerCount = 0;
    RSPendingContainer = nil;
    RSPendingSince = 0;
    RSPendingHits = 0;
    RSLastConfirmedContainer = nil;
    RSLastConfirmedAt = 0;
    RSTestSnapshot(@"recording-stop");
}

// State-only reconciliation: notification loss must not leave our session active.
// This timer never scans windows, touches native activity state or retries stopRecording.
static NSTimer *RS20StateTimer = nil;
static void RS20EnsureStateTimer(void) {
    if (RS20StateTimer.valid) return;
    RS20StateTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) {
        if (!RSInitialized) return;
        @try { RSUpdateRecordingState(); }
        @catch (NSException *e) { RSLog(@"6.20 state reconciliation exception: %@", e); }
    }];
    RS20StateTimer.tolerance = 0.1;
    [[NSRunLoop mainRunLoop] addTimer:RS20StateTimer forMode:NSRunLoopCommonModes];
}

#pragma mark - 安全初始化

static void RSInitializeAfterLaunch(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ RSInitializeAfterLaunch(); });
        return;
    }
    if (RSInitialized) return;

    @try {
        RSLog(@"SpringBoard launch completed, initializing");
        RSMigratePreferences5717();
        RSInitialized = YES;
        RS20EnsureStateTimer();
        RSUpdateRecordingState();
        if (RSRecordingActive) { RSEnsurePollTimer(); RSEnsureGeometryDisplayLink(); }
        RSLog(@"===== RecordingSharingan v%@ initialized =====", RSVersion);
    } @catch (NSException *e) {
        RSInitialized = NO;
        RSLog(@"initialization exception: %@", e);
    }
}

static void RSSettingsChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            CFPreferencesAppSynchronize(RSPrefsDomain);
            BOOL enabled = RSIsEnabled();
            RSLog(@"settings changed enabled=%d style=%ld speed=%.2f leftX=%.2f rightX=%.2f y=%.2f leftSize=%.2f rightSize=%.2f", enabled, (long)RSEyeStyle(), RSRotationSpeed(), RSLeftXOffset(), RSRightXOffset(), RSYOffset(), RSLeftSize(), RSRightSize());
            RSTestSnapshot(@"settings-changed");
            if (!enabled) {
                RSRemoveSharingan();
            } else {
                RSReloadEyeImage();
                if (RSSharinganView) RSStartRotation(RSSharinganView);
                if (RSRecordingActive) {
                    RSEnsurePollTimer();
                    RSEnsureGeometryDisplayLink();
                    RSDiscoverAll(YES);
                }
            }
        } @catch (NSException *e) { RSLog(@"settings exception: %@", e); }
    });
}

// V7.9: o2/ios16dao-inspired initial-presentation probe.
// The known ScreenRecording tree contains AccessoryView -> AccessoryPortalView before the
// native SBRecordingIndicatorView becomes capturable.  Log these lifecycle transitions and
// force a re-sync, especially setBounds: which ios16dao also observes.
static NSTimeInterval RSV79LastApertureProbeLog = 0;
static void RSV79ProbeApertureView(UIView *v, NSString *event) {
    if (!v || !RSInitialized || !RSRecordingActive) return;
    @try {
        NSTimeInterval now = CACurrentMediaTime();
        if (now - RSV79LastApertureProbeLog > 0.12) {
            RSV79LastApertureProbeLog = now;
            CGRect screenRect = CGRectZero;
            if (v.window) screenRect = [v convertRect:v.bounds toView:nil];
            RSLog(@"V7.9 aperture %@ class=%@ frame=%@ bounds=%@ screen=%@ alpha=%.2f hidden=%d super=%@ window=%@",
                  event, NSStringFromClass(v.class), NSStringFromCGRect(v.frame), NSStringFromCGRect(v.bounds),
                  NSStringFromCGRect(screenRect), v.alpha, v.hidden,
                  v.superview ? NSStringFromClass(v.superview.class) : @"nil",
                  v.window ? NSStringFromClass(v.window.class) : @"nil");
        }
        RSV711RememberAccessory(v, event);
        // V7.11.3: DO NOT sync/discover synchronously from layout/setFrame.
        // Those calls can themselves cause SystemAperture layout and lock SpringBoard.
        // RSV711RememberAccessory schedules at most one guarded mount on the next run-loop.
    } @catch (NSException *e) { RSLog(@"V7.10 aperture refresh exception: %@", e); }
}

#pragma mark - 灵动岛布局 Hook

// V7.4：直接监听真正的系统录屏红点类。
// 这解决 portal/sourceView 不属于 ScreenRecording element 普通 subview 树时无法递归找到的问题。
%hook SBRecordingIndicatorView
- (void)layoutSubviews {
    %orig;
    @try {
        UIView *v = (UIView *)self;
        if (RSV74LooksLikeNativeIndicator(v)) {
            RSV74CapturedNativeIndicator = v;
            NSTimeInterval now = CACurrentMediaTime();
            if (now - RSV74LastCaptureLog > 1.0) {
                RSV74LastCaptureLog = now;
                RSLog(@"V7.8 indicator layout frame=%@ alpha=%.2f hidden=%d host=%@ window=%@ score=%.1f",
                      NSStringFromCGRect(v.frame), v.alpha, v.hidden,
                      NSStringFromClass(v.superview.class), v.window ? NSStringFromClass(v.window.class) : @"nil",
                      RSV78IndicatorActivityScore(v));
            }
            RS20ScheduleRefresh();
        }
    } @catch (NSException *e) { RSLog(@"V7.8 indicator layout exception: %@", e); }
}
- (void)didMoveToSuperview {
    %orig;
    @try {
        UIView *v = (UIView *)self;
        if (RSV74LooksLikeNativeIndicator(v)) {
            RSV74CapturedNativeIndicator = v;
            RSLog(@"V7.8 indicator didMoveToSuperview host=%@ frame=%@ alpha=%.2f", NSStringFromClass(v.superview.class), NSStringFromCGRect(v.frame), v.alpha);
            RS20ScheduleRefresh();
        }
    } @catch (...) {}
}
- (void)didMoveToWindow {
    %orig;
    @try {
        UIView *v = (UIView *)self;
        if (RSV74LooksLikeNativeIndicator(v)) {
            RSV74CapturedNativeIndicator = v;
            RSLog(@"V7.8 indicator didMoveToWindow window=%@ frame=%@ alpha=%.2f", v.window ? NSStringFromClass(v.window.class) : @"nil", NSStringFromCGRect(v.frame), v.alpha);
            RS20ScheduleRefresh();
        }
    } @catch (...) {}
}
- (void)setAlpha:(CGFloat)alpha {
    CGFloat old = ((UIView *)self).alpha;
    %orig;
    if (!RSInitialized || !RSRecordingActive || fabs(old - alpha) < 0.001) return;
    @try {
        UIView *v = (UIView *)self;
        if (RSV74LooksLikeNativeIndicator(v)) {
            RSLog(@"V7.8 indicator alpha %.2f -> %.2f frame=%@", old, alpha, NSStringFromCGRect(v.frame));
            RS20ScheduleRefresh();
        }
    } @catch (...) {}
}
- (void)setHidden:(BOOL)hidden {
    BOOL old = ((UIView *)self).hidden;
    %orig;
    if (!RSInitialized || !RSRecordingActive || old == hidden) return;
    @try {
        UIView *v = (UIView *)self;
        if (RSV74LooksLikeNativeIndicator(v)) {
            RSLog(@"V7.8 indicator hidden %d -> %d frame=%@", old, hidden, NSStringFromCGRect(v.frame));
            RS20ScheduleRefresh();
        }
    } @catch (...) {}
}
- (void)setFrame:(CGRect)frame {
    CGRect old = ((UIView *)self).frame;
    %orig;
    if (!RSInitialized || !RSRecordingActive || CGRectEqualToRect(old, frame)) return;
    @try {
        UIView *v = (UIView *)self;
        if (RSV74LooksLikeNativeIndicator(v)) {
            RS20ScheduleRefresh();
        }
    } @catch (...) {}
}
%end

// V7.9.1: Accessory private classes are hooked at runtime instead of Logos.
// This avoids Logos/Clang generating an invalid nested hook function for these private class names.
static NSMutableDictionary<NSString *, NSValue *> *RSV791OriginalIMPs;

static NSString *RSV791IMPKey(id obj, SEL sel) {
    return [NSString stringWithFormat:@"%@::%@", NSStringFromClass([obj class]), NSStringFromSelector(sel)];
}

static IMP RSV791OriginalIMP(id obj, SEL sel) {
    return (IMP)[RSV791OriginalIMPs[RSV791IMPKey(obj, sel)] pointerValue];
}

static void RSV791VoidHook(id self, SEL _cmd) {
    IMP original = RSV791OriginalIMP(self, _cmd);
    if (original) ((void (*)(id, SEL))original)(self, _cmd);
    NSString *event = [NSString stringWithFormat:@"%@ %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
    RSV79ProbeApertureView((UIView *)self, event);
}

static void RSV791RectHook(id self, SEL _cmd, CGRect value) {
    IMP original = RSV791OriginalIMP(self, _cmd);
    if (original) ((void (*)(id, SEL, CGRect))original)(self, _cmd, value);
    NSString *event = [NSString stringWithFormat:@"%@ %@", NSStringFromClass([self class]), NSStringFromSelector(_cmd)];
    RSV79ProbeApertureView((UIView *)self, event);
}

static BOOL RSV791ClassOwnsSelector(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { found = YES; break; }
    }
    if (methods) free(methods);
    return found;
}

static void RSV791InstallOneRuntimeHook(Class cls, SEL sel, IMP replacement) {
    if (!cls || !sel || !replacement) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    NSString *key = [NSString stringWithFormat:@"%@::%@", NSStringFromClass(cls), NSStringFromSelector(sel)];
    if (!RSV791OriginalIMPs) RSV791OriginalIMPs = [[NSMutableDictionary alloc] init];
    if (RSV791OriginalIMPs[key]) return;
    RSV791OriginalIMPs[key] = [NSValue valueWithPointer:(const void *)original];
    if (RSV791ClassOwnsSelector(cls, sel)) {
        method_setImplementation(method, replacement);
    } else {
        class_addMethod(cls, sel, replacement, types);
    }
}

static void RSV791InstallAccessoryRuntimeHooks(void) {
    NSArray<NSString *> *names = @[@"SBSystemApertureSceneElementAccessoryPortalView", @"SBSystemApertureSceneElementAccessoryView"];
    for (NSString *name in names) {
        Class cls = NSClassFromString(name);
        if (!cls) { RSLog(@"V7.9.1 runtime probe class missing: %@", name); continue; }
        // V7.11.3: avoid layoutSubviews/setBounds feedback storms. didMoveToWindow catches
        // creation/removal; setFrame catches the first real presentation geometry.
        RSV791InstallOneRuntimeHook(cls, @selector(didMoveToWindow), (IMP)RSV791VoidHook);
        RSV791InstallOneRuntimeHook(cls, @selector(setFrame:), (IMP)RSV791RectHook);
        RSLog(@"V7.9.1 runtime probe hooks installed: %@", name);
    }
}

%hook SAUIElementView
- (void)layoutSubviews {
    %orig;
    RS20ScheduleRefresh();
}
- (void)setFrame:(CGRect)frame {
    %orig;
    if ((UIView *)self == RSEyeMountedElement) RS20ScheduleRefresh();
}
- (void)setCenter:(CGPoint)center {
    %orig;
    if ((UIView *)self == RSEyeMountedElement) RS20ScheduleRefresh();
}
- (void)didMoveToWindow {
    %orig;
    if ([(UIView *)self window]) RS20ScheduleRefresh();
}
%end

// V6.0.0：SystemAperture 容器布局触发重扫（灵动岛重新布局时让元素识别及时刷新）
// Only track the last frame we actually expanded; never expand the same frame twice.
// V7.11.9.4.3.2.6: diagnostic build — disable native container +5pt width extension.
%hook SBSystemApertureContainerView
- (void)layoutSubviews {
    %orig;
    if (RSV7118LayoutRefreshDirty && !RSCaptureStopPending) {
        __weak UIView *weakContainer = (UIView *)self;
        NSUInteger generation = RSV7118LayoutRefreshGeneration;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == RSV7118LayoutRefreshGeneration && !RSCaptureStopPending &&
                [UIScreen mainScreen].isCaptured) RSV7118ConsumeContainerLayout(weakContainer);
        });
    }
    // No setFrame: calls from layoutSubviews: prevents recursive width growth.
    RSV79ProbeApertureView((UIView *)self, @"container layout");

    // V7.11.8.8: layout is only a migration SIGNAL.  Coalesce it and compare the
    // ScreenRecording accessory host after the morph settles; never call RSDiscoverAll(YES)
    // from layoutSubviews (that loop caused heat, queued work and slow recording shutdown).
    if (RSInitialized && RSRecordingActive && !RSCaptureStopPending) {
        RSV71187SchedulePresentationMigration(@"container-layout");
    }
}
- (void)didMoveToWindow {
    %orig;
    RSV79ProbeApertureView((UIView *)self, @"container didMoveToWindow");
}
- (void)setFrame:(CGRect)frame {
    // Diagnostic A/B: pass Apple's original frame through unchanged.
    %orig(frame);
    RSV79ProbeApertureView((UIView *)self, @"container setFrame");
}
- (void)setBounds:(CGRect)bounds {
    %orig;
    RSV79ProbeApertureView((UIView *)self, @"container setBounds");
}
%end

#pragma mark - ctor

%ctor {
    @autoreleasepool {
        // ===== V6.2 Loader Probe：%ctor 最开始的加载证据 =====
        // 只写日志；不改动画、不改定位、不改设置、不改任何 V5/V6 既有逻辑。
        RSClearLog();            // 保留原行为：清空主日志
        RSDebugClearV6Logs();    // 同时清空 V6 debug 双日志（本次加载的干净起点）
        RSDebugLog(@"dylib loaded");   // 日志1：dylib 已加载
        RSDebugLog(@"ctor executed");  // 日志2：%ctor 已执行
        RSDebugDumpEnvironment();      // 进程 / NSBundle / dylib 路径 / 是否 SpringBoard
        RSDebugLog(@"loader probe paths: %@ | %@ | %@", RSV6DebugLogPathMobile, RSV6DebugLogPathTmp, RSV6DebugLogPathSystemTmp);
        dispatch_async(dispatch_get_main_queue(), ^{ RSV791InstallAccessoryRuntimeHooks(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            RSDebugLog(@"SpringBoard alive +5s (pid=%d)", getpid());
        });
        // ===== V6.2 Loader Probe end =====

        RSLog(@"===== RecordingSharingan v%@ loaded =====", RSVersion);

        // 只注册通知；绝不在 %ctor 直接调用 UIScreen/mainScreen。
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                RSInitializeAfterLaunch();
            });
        }];

        // 兜底：即使加载时错过 DidFinishLaunching，也延迟初始化；仍然不在 ctor 同步碰 UIKit。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            RSInitializeAfterLaunch();
        });

        [[NSNotificationCenter defaultCenter] addObserverForName:UIScreenCapturedDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *n) {
            if (RSInitialized) RSUpdateRecordingState();
        }];

        int token = 0;
        notify_register_dispatch(RSPrefsChangedNotification, &token, dispatch_get_main_queue(), ^(__unused int changedToken) {
            RSSettingsChanged();
        });
    }
}
