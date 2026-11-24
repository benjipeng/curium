#import "CuriumRuntime.h"
#import "CuriumHookSupport.h"
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <os/log.h>
#import <os/proc.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <UIKit/UIKit.h>

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

static const unsigned int kCuriumCsOpsStatus = 0;
static const uint32_t kCuriumCsDebugged = 0x10000000u;
static const size_t kCuriumDefaultJitPoolBytes = 64ULL * 1024ULL * 1024ULL;

static os_unfair_lock gCuriumHookStatusLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<NSDictionary<NSString *, NSString *> *> *gCuriumHookStatuses = nil;

void CuriumRecordHookStatus(NSString *name, NSString *status, NSString *detail) {
    NSString *safeName = name.length > 0 ? [name copy] : @"unknown";
    NSString *safeStatus = status.length > 0 ? [status copy] : @"failed";
    NSString *safeDetail = detail ? [detail copy] : @"";
    NSDictionary<NSString *, NSString *> *entry = @{
        @"name": safeName,
        @"status": safeStatus,
        @"detail": safeDetail,
    };
    os_unfair_lock_lock(&gCuriumHookStatusLock);
    if (!gCuriumHookStatuses) {
        gCuriumHookStatuses = [NSMutableArray arrayWithCapacity:10];
    }
    NSUInteger existingIndex = NSNotFound;
    for (NSUInteger i = 0; i < gCuriumHookStatuses.count; i++) {
        if ([gCuriumHookStatuses[i][@"name"] isEqualToString:safeName]) {
            existingIndex = i;
            break;
        }
    }
    if (existingIndex != NSNotFound) {
        gCuriumHookStatuses[existingIndex] = entry;
    } else {
        [gCuriumHookStatuses addObject:entry];
    }
    os_unfair_lock_unlock(&gCuriumHookStatusLock);
}

NSArray<NSDictionary<NSString *, NSString *> *> *CuriumRuntimeHookStatuses(void) {
    os_unfair_lock_lock(&gCuriumHookStatusLock);
    NSArray<NSDictionary<NSString *, NSString *> *> *snapshot =
        gCuriumHookStatuses ? [gCuriumHookStatuses copy] : @[];
    os_unfair_lock_unlock(&gCuriumHookStatusLock);
    return snapshot;
}

static void CuriumRunOnMain(dispatch_block_t block) {
    if (!block) {
        return;
    }
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

static void CuriumNoOpLogLaunchMetrics(id self, SEL _cmd, id startupInfo, NSArray *scenes) {
    // Launch metrics walk Chrome's tab model for UMA that Curium never uploads.
    // Skipping them also covers engines older than build 32, whose headless
    // shell has no inactive browser for this method to dereference.
    (void)self;
    (void)_cmd;
    (void)startupInfo;
    (void)scenes;
}

static NSArray<NSString *> *gCuriumAugmentedArguments = nil;
static BOOL gCuriumExplicitFingerprintConfigured = NO;
static BOOL gCuriumEnableGlobalPrivacyControl = NO;
static BOOL gCuriumDisableWebTouchDetection = NO;
static BOOL gCuriumEnableDesktopKeyboardAPI = NO;
static BOOL gCuriumForceSRGBColorProfile = NO;

// Adds a bare switch once.
static BOOL CuriumAddSwitch(NSMutableArray<NSString *> *args, NSString *flag) {
    if ([args containsObject:flag]) {
        return NO;
    }
    [args addObject:flag];
    return YES;
}

// Adds `--name=value` only if neither `--name` nor `--name=...` is already set
// on the process command line (so explicit launch overrides always win).
static BOOL CuriumSetDefaultSwitchValue(NSMutableArray<NSString *> *args,
                                        NSString *name,
                                        NSString *_Nullable value) {
    if (value.length == 0) {
        return NO;
    }
    NSString *prefix = [name stringByAppendingString:@"="];
    for (NSString *arg in args) {
        if ([arg isEqualToString:name] || [arg hasPrefix:prefix]) {
            return NO;
        }
    }
    [args addObject:[prefix stringByAppendingString:value]];
    return YES;
}

// Validates and canonicalizes a BCP-47 language tag (e.g. "zh-Hant-HK",
// "en-US", "es-419") while preserving script subtags so Chromium's
// ExpandLanguageList can derive fallbacks (e.g. "zh-Hant-HK,zh-Hant,zh").
static NSString *_Nullable CuriumCanonicalBCP47Tag(NSString *raw) {
    NSString *cleaned = [[raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]]
                         stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    if (cleaned.length == 0 || cleaned.length > 35) {
        return nil;
    }
    NSArray<NSString *> *parts = [cleaned componentsSeparatedByString:@"-"];
    if (parts.count == 0 || parts.count > 6) {
        return nil;
    }
    NSMutableArray<NSString *> *canonical = [NSMutableArray arrayWithCapacity:parts.count];
    BOOL seenSingleton = NO;
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *subtag = parts[i];
        NSUInteger len = subtag.length;
        if (len == 0 || len > 8) {
            return nil;
        }
        BOOL allLetters = YES;
        for (NSUInteger j = 0; j < len; j++) {
            unichar c = [subtag characterAtIndex:j];
            BOOL isLetter = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
            BOOL isDigit = (c >= '0' && c <= '9');
            if (!isLetter && !isDigit) {
                return nil;
            }
            if (!isLetter) {
                allLetters = NO;
            }
        }
        if (i == 0) {
            if (!allLetters || len < 2) {
                return nil;
            }
            [canonical addObject:subtag.lowercaseString];
            continue;
        }
        if (seenSingleton) {
            [canonical addObject:subtag.lowercaseString];
        } else if (len == 1) {
            if (i + 1 == parts.count) {
                return nil;
            }
            seenSingleton = YES;
            [canonical addObject:subtag.lowercaseString];
        } else if (len == 4 && allLetters) {
            NSString *lower = subtag.lowercaseString;
            NSString *titled = [[[lower substringToIndex:1] uppercaseString]
                                stringByAppendingString:[lower substringFromIndex:1]];
            [canonical addObject:titled];
        } else if (len == 2 && allLetters) {
            [canonical addObject:subtag.uppercaseString];
        } else {
            [canonical addObject:subtag.lowercaseString];
        }
    }
    return [canonical componentsJoinedByString:@"-"];
}

// Validates, deduplicates, and caps preferred BCP-47 language tags for
// --curium-accept-lang. Chromium's ExpandLanguageList appends base fallbacks.
NSString *CuriumNormalizedAcceptLanguages(NSArray<NSString *> *_Nullable preferred) {
    NSMutableArray<NSString *> *tags = [NSMutableArray arrayWithCapacity:4];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:4];
    for (NSString *raw in preferred) {
        if (tags.count >= 4) {
            break;
        }
        NSString *normalized = CuriumCanonicalBCP47Tag(raw);
        if (!normalized) {
            continue;
        }
        NSString *key = normalized.lowercaseString;
        if (![seen containsObject:key]) {
            [seen addObject:key];
            [tags addObject:normalized];
        }
    }
    if (tags.count == 0) {
        return @"en-US,en";
    }
    return [tags componentsJoinedByString:@","];
}

// Appends |items| to a list-valued switch such as --disable-features. Chromium
// keeps only the last occurrence of a switch, so a second copy would silently
// drop the first one's items.
static BOOL CuriumMergeListSwitch(NSMutableArray<NSString *> *args, NSString *name,
                                  NSString *separator, NSString *items) {
    NSString *prefix = [name stringByAppendingString:@"="];
    for (NSUInteger i = args.count; i-- > 0;) {
        if ([args[i] hasPrefix:prefix]) {
            NSString *value = [args[i] substringFromIndex:prefix.length];
            args[i] = value.length
                ? [NSString stringWithFormat:@"%@%@%@%@", prefix, value, separator, items]
                : [prefix stringByAppendingString:items];
            return YES;
        }
    }
    [args addObject:[prefix stringByAppendingString:items]];
    return YES;
}

// Checks whether the effective (last) `--name=...` switch already contains |needle|.
static BOOL CuriumHasSwitchValueToken(NSArray<NSString *> *args,
                                      NSString *name,
                                      NSString *needle) {
    NSString *prefix = [name stringByAppendingString:@"="];
    for (NSUInteger i = args.count; i-- > 0;) {
        NSString *arg = args[i];
        if ([arg hasPrefix:prefix]) {
            NSString *value = [arg substringFromIndex:prefix.length];
            return [value rangeOfString:needle].location != NSNotFound;
        }
        if ([arg isEqualToString:name]) {
            if (i + 1 < args.count) {
                return [args[i + 1] rangeOfString:needle].location != NSNotFound;
            }
            return NO;
        }
    }
    return NO;
}

// Builds the engine's command line once. Inputs from NSBundle and NSUserDefaults
// are read BEFORE swizzling -[NSProcessInfo arguments] so initializing Foundation's
// NSArgumentDomain can never re-enter a dispatch_once lock on the main thread.
static NSArray<NSString *> *CuriumBuildArguments(NSArray<NSString *> *base,
                                                 BOOL supportsDisableSync,
                                                 BOOL hasExplicitFingerprintConfig,
                                                 NSInteger engineContractVersion,
                                                 BOOL enableGlobalPrivacyControl,
                                                 BOOL disableWebTouchDetection,
                                                 BOOL enableDesktopKeyboardAPI,
                                                 BOOL forceSRGBColorProfile,
                                                 NSString *_Nullable jitPref,
                                                 NSString *_Nullable uaBrandPref,
                                                 NSString *_Nullable mobileUAPref,
                                                 NSString *_Nullable acceptLangPref,
                                                 NSString *_Nullable mobileModelPref) {
    NSMutableArray<NSString *> *args = [base mutableCopy];
    BOOL changed = NO;

#if TARGET_OS_SIMULATOR
    // Simulator's MTLSimDevice fails to compile certain complex Skia Graphite/Dawn
    // shaders and hits a fatal CHECK in GraphiteSharedContext; selecting Ganesh/Metal
    // keeps Simulator rendering stable.
    changed |= CuriumAddSwitch(args, @"--disable-skia-graphite");
    changed |= CuriumMergeListSwitch(args, @"--disable-features", @",", @"SkiaGraphite");
#endif

    // Keep the engine from contacting Google unprompted: AI Mode eligibility
    // (www.google.com/async/folae) and the translate ranker stay off.
    changed |= CuriumMergeListSwitch(args, @"--disable-features", @",",
        @"AimEnabled,AimServerEligibilityEnabled,AimServerRequestOnStartupEnabled,"
        @"TranslateRankerQuery,TranslateRankerEnforcement");

    // Enable only after vendoring an engine with patch 0096. Build 32
    // dereferences a missing SyncService at launch with this switch.
    if (supportsDisableSync) {
        changed |= CuriumAddSwitch(args, @"--disable-sync");
    }

    if ([jitPref isEqualToString:@"jitless"]) {
        changed |= CuriumAddSwitch(args, @"--curium-disable-jit");
    } else if ([jitPref isEqualToString:@"forceJIT"]) {
        changed |= CuriumAddSwitch(args, @"--curium-enable-jit");
    }

    if (enableGlobalPrivacyControl && engineContractVersion < 3) {
        // Legacy Build 40-42 engines gate both navigator.globalPrivacyControl and
        // the Sec-GPC header behind the launch-frozen GlobalPrivacyControlApi
        // base::Feature. Build 43+ (contractVersion >= 3) controls it dynamically
        // via patch 0111 with zero navigator.globalPrivacyControl === false leak.
        changed |= CuriumMergeListSwitch(args, @"--enable-features", @",", @"GlobalPrivacyControlApi");
    }

    if (disableWebTouchDetection) {
        // Align WebIDL TouchEvent / ontouchstart exposure with maxTouchPoints == 0 on
        // desktop macOS profiles while keeping native UIKit touch scrolling intact.
        changed |= CuriumSetDefaultSwitchValue(args, @"--touch-events", @"disabled");
        changed |= CuriumMergeListSwitch(args, @"--disable-blink-features", @",",
                                         @"TouchEventFeatureDetection");
        changed |= CuriumSetDefaultSwitchValue(args, @"--force-effective-connection-type", @"4G");
        // Match color profile & dynamic-range to the profile's display depth:
        // 24-bit sRGB external displays use "srgb" (SDR), while 30-bit wide-gamut
        // Mac Retina displays use "extended-srgb" (Display-P3 + HDR).
        changed |= CuriumSetDefaultSwitchValue(args, @"--force-color-profile",
                                               forceSRGBColorProfile ? @"srgb" : @"extended-srgb");
        // Raise V8 old-space limit to ~2.2 GiB desktop Chrome bucket unless already specified.
        if (!CuriumHasSwitchValueToken(args, @"--js-flags", @"--max-old-space-size=")) {
            changed |= CuriumMergeListSwitch(args, @"--js-flags", @" ", @"--max-old-space-size=2048");
        }
    }

    if (enableDesktopKeyboardAPI) {
        // Expose desktop Chrome's navigator.keyboard API on desktop macOS profiles.
        changed |= CuriumMergeListSwitch(args, @"--enable-blink-features", @",",
                                         @"KeyboardLock");
    }

    // Never merge legacy 0105 switches field-by-field into an explicit
    // CuriumFingerprintConfigV1 profile; only synthesize them when running in
    // unconfigured Build 39 default mode.
    if (!hasExplicitFingerprintConfig) {
        changed |= CuriumSetDefaultSwitchValue(args, @"--curium-ua-brand", uaBrandPref);
        changed |= CuriumSetDefaultSwitchValue(args, @"--curium-mobile-ua", mobileUAPref);
        changed |= CuriumSetDefaultSwitchValue(args, @"--curium-accept-lang", acceptLangPref);
        changed |= CuriumSetDefaultSwitchValue(args, @"--curium-mobile-model", mobileModelPref);
    }

    return changed ? [args copy] : base;
}

static NSArray<NSString *> *CuriumAugmentedProcessArguments(id self, SEL _cmd) {
    // IOSChromeMain initializes base::CommandLine from NSProcessInfo.processInfo.arguments
    // rather than ChromeMain(argc, argv).
    (void)self;
    (void)_cmd;
    return gCuriumAugmentedArguments ?: @[];
}

static void CuriumInstallCommandLineGuard(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSProcessInfo *processInfo = [NSProcessInfo processInfo];
        NSArray<NSString *> *base = [processInfo arguments] ?: @[];
        BOOL supportsDisableSync =
            [[NSBundle mainBundle].infoDictionary[@"CuriumEngineSupportsDisableSync"] boolValue];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *jitPref = [[defaults stringForKey:@"curium.jitMode"] copy];
        NSString *uaBrandPref = [[defaults stringForKey:@"curium.uaBrand"] copy];
        NSString *mobileUAPref = [[defaults stringForKey:@"curium.mobileUA"] copy];
        NSString *customAcceptLang = [[defaults stringForKey:@"curium.acceptLang"] copy];
        NSString *acceptLangPref = customAcceptLang.length > 0
            ? customAcceptLang
            : CuriumNormalizedAcceptLanguages([NSLocale preferredLanguages]);
        NSString *mobileModelPref = [[defaults stringForKey:@"curium.mobileModel"] copy];
        BOOL hasExplicitConfig = gCuriumExplicitFingerprintConfigured;
        NSDictionary<NSString *, id> *caps = CuriumEngineFingerprintCapabilitiesDict();
        NSInteger engineContractVersion = [caps[@"contractVersion"] isKindOfClass:[NSNumber class]]
            ? [caps[@"contractVersion"] integerValue] : 0;
        BOOL enableGPC = gCuriumEnableGlobalPrivacyControl;
        BOOL disableTouchDetection = gCuriumDisableWebTouchDetection;
        BOOL enableDesktopKeyboard = gCuriumEnableDesktopKeyboardAPI;
        BOOL forceSRGB = gCuriumForceSRGBColorProfile;
        gCuriumAugmentedArguments = CuriumBuildArguments(
            base, supportsDisableSync, hasExplicitConfig, engineContractVersion,
            enableGPC, disableTouchDetection, enableDesktopKeyboard, forceSRGB,
            jitPref, uaBrandPref, mobileUAPref, acceptLangPref, mobileModelPref);

        Class cls = object_getClass(processInfo);
        SEL sel = @selector(arguments);
        Method method = class_getInstanceMethod(cls, sel);
        if (!method) {
            CuriumRecordHookStatus(@"Command-Line Guard", @"failed",
                                   @"NSProcessInfo arguments method missing");
            return;
        }
        if (!class_addMethod(cls, sel, (IMP)CuriumAugmentedProcessArguments,
                             method_getTypeEncoding(method))) {
            method_setImplementation(method, (IMP)CuriumAugmentedProcessArguments);
        }
        NSString *detail = hasExplicitConfig
            ? [NSString stringWithFormat:@"%lu args (disable-sync=%d, jit=%@, fingerprint=profile-json, contract=v%ld, touchDetect=%d, desktopKbd=%d)",
               (unsigned long)gCuriumAugmentedArguments.count,
               supportsDisableSync ? 1 : 0,
               jitPref.length > 0 ? jitPref : @"automatic",
               (long)engineContractVersion,
               disableTouchDetection ? 0 : 1,
               enableDesktopKeyboard ? 1 : 0]
            : [NSString stringWithFormat:
               @"%lu args (disable-sync=%d, jit=%@, brand=%@, mobile=%@, lang=%@)",
               (unsigned long)gCuriumAugmentedArguments.count,
               supportsDisableSync ? 1 : 0,
               jitPref.length > 0 ? jitPref : @"automatic",
               uaBrandPref.length > 0 ? uaBrandPref : @"chrome",
               mobileUAPref.length > 0 ? mobileUAPref : @"android",
               acceptLangPref];
        CuriumRecordHookStatus(@"Command-Line Guard", @"active", detail);
    });
}

static void *CuriumOpenChromeFrameworkHandle(void) {
    // Resolve via the loaded dyld image list first so LiveContainer's MH_DYLIB
    // / RTLD_LOCAL loading and /var vs /private/var symlink differences never
    // break symbol lookup.
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "chrome_framework.framework/chrome_framework")) {
            continue;
        }
        void *handle = dlopen(name, RTLD_NOLOAD | RTLD_LAZY);
        if (handle) {
            return handle;
        }
    }
    NSString *fwPath = [[[NSBundle mainBundle] privateFrameworksPath]
        stringByAppendingPathComponent:@"chrome_framework.framework/chrome_framework"];
    if (fwPath.length > 0) {
        return dlopen(fwPath.fileSystemRepresentation, RTLD_NOLOAD | RTLD_LAZY);
    }
    return NULL;
}

static void *CuriumResolveChromeSymbol(const char *symbolName) {
    if (!symbolName) {
        return NULL;
    }
    void *handle = CuriumOpenChromeFrameworkHandle();
    if (handle) {
        void *sym = dlsym(handle, symbolName);
        if (sym) {
            return sym;
        }
    }
    return dlsym(RTLD_DEFAULT, symbolName);
}

static void CuriumQueryDebuggerState(uint32_t *csFlagsOut, BOOL *csDebuggedOut, BOOL *tracedOut) {
    uint32_t csFlags = 0;
    BOOL csDebugged = (csops(getpid(), kCuriumCsOpsStatus, &csFlags, sizeof(csFlags)) == 0) &&
                      ((csFlags & kCuriumCsDebugged) != 0);

    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info;
    memset(&info, 0, sizeof(info));
    size_t size = sizeof(info);
    BOOL traced = (sysctl(mib, 4, &info, &size, NULL, 0) == 0) &&
                  (size >= sizeof(info)) &&
                  ((info.kp_proc.p_flag & P_TRACED) != 0);

    if (csFlagsOut) *csFlagsOut = csFlags;
    if (csDebuggedOut) *csDebuggedOut = csDebugged;
    if (tracedOut) *tracedOut = traced;
}

// Prepares V8's iOS JIT memory before ChromeMain installs Crashpad exception
// handlers or spawns threads. IOSJitMemory::Initialize is idempotent, so
// AppendSideloadSwitches reuses the resulting mode when RunContentProcess runs.
static void CuriumPrepareEarlyV8Jit(NSString *_Nullable jitPref) {
    if ([jitPref isEqualToString:@"jitless"]) {
        CuriumRecordHookStatus(@"V8 JIT Probe", @"skipped", @"Jitless Only preference");
        return;
    }

    typedef int (*V8JitPrepareFn)(size_t, int);
    V8JitPrepareFn prepareFn =
        (V8JitPrepareFn)CuriumResolveChromeSymbol("V8IOSJitPrepareForProcess");
    if (!prepareFn) {
        CuriumRecordHookStatus(@"V8 JIT Probe", @"skipped",
                               @"V8IOSJitPrepareForProcess symbol not present");
        return;
    }

#if TARGET_OS_SIMULATOR
    int mode = prepareFn(kCuriumDefaultJitPoolBytes, 0);
    CuriumRecordHookStatus(@"V8 JIT Probe",
                           mode != 0 ? @"active" : @"skipped",
                           [NSString stringWithFormat:@"Simulator mode=%d", mode]);
#else
    BOOL inLiveContainer = getenv("LC_HOME_PATH") != NULL;
    BOOL allowTxm = inLiveContainer || [jitPref isEqualToString:@"forceJIT"];
    uint32_t csFlags = 0;
    BOOL csDebugged = NO;
    BOOL traced = NO;
    CuriumQueryDebuggerState(&csFlags, &csDebugged, &traced);

    if (!allowTxm) {
        CuriumRecordHookStatus(@"V8 JIT Probe", @"skipped",
                               [NSString stringWithFormat:@"Standalone device (cs=%d, traced=%d)",
                                csDebugged ? 1 : 0, traced ? 1 : 0]);
        return;
    }

    if (csDebugged && traced) {
        int mode = prepareFn(kCuriumDefaultJitPoolBytes, 1);
        uint32_t csFlagsAfter = 0;
        BOOL csDebuggedAfter = NO;
        BOOL tracedAfter = NO;
        CuriumQueryDebuggerState(&csFlagsAfter, &csDebuggedAfter, &tracedAfter);
        if (mode != 0) {
            CuriumRecordHookStatus(@"V8 JIT Probe", @"active",
                                   [NSString stringWithFormat:@"TXM ready pre-ChromeMain (mode=%d, traced 1->%d)",
                                    mode, tracedAfter ? 1 : 0]);
        } else {
            CuriumRecordHookStatus(@"V8 JIT Probe", @"failed",
                                   [NSString stringWithFormat:@"TXM probe returned 0 (cs=1, traced 1->%d, csFlags=0x%08x)",
                                    tracedAfter ? 1 : 0, csFlags]);
        }
        return;
    }

    if (csDebugged) {
        CuriumRecordHookStatus(@"V8 JIT Probe", @"skipped",
                               @"CS_DEBUGGED=1, P_TRACED=0 (debugger detached; assign universal.js in StikDebug/LiveContainer)");
    } else {
        CuriumRecordHookStatus(@"V8 JIT Probe", @"skipped",
                               [NSString stringWithFormat:@"No JIT debugger attached (cs=0, traced=%d, csFlags=0x%08x)",
                                traced ? 1 : 0, csFlags]);
    }
#endif
}

static void CuriumInstallHeadlessRuntimeGuards(void) {
    NSString *jitPref =
        [[[NSUserDefaults standardUserDefaults] stringForKey:@"curium.jitMode"] copy];
    CuriumInstallCommandLineGuard();
    CuriumPrepareEarlyV8Jit(jitPref);
    Class metricsMediator = NSClassFromString(@"MetricsMediator");
    if (!metricsMediator) {
        CuriumRecordHookStatus(@"MetricsMediator No-Op", @"skipped",
                               @"MetricsMediator class not present");
        return;
    }
    SEL logLaunch = NSSelectorFromString(@"logLaunchMetricsWithStartupInformation:connectedScenes:");
    Method method = class_getClassMethod(metricsMediator, logLaunch);
    if (method) {
        method_setImplementation(method, (IMP)CuriumNoOpLogLaunchMetrics);
        CuriumRecordHookStatus(@"MetricsMediator No-Op", @"active",
                               @"Suppressed Chrome launch UMA walk");
    } else {
        CuriumRecordHookStatus(@"MetricsMediator No-Op", @"skipped",
                               @"Launch metrics selector not present");
    }
}

void CuriumSetDesktopSite(id<CrIOSTabHostingV1> tab, BOOL enabled) {
    [tab setUsesDesktopUserAgent:enabled];
}

void CuriumSetPageZoom(id<CrIOSTabHostingV1> tab, CGFloat scale) {
    if ([tab respondsToSelector:@selector(setPageZoomScale:)]) {
        [tab setPageZoomScale:scale];
    }
}

uint64_t CuriumAvailableMemoryBytes(void) {
    return os_proc_available_memory();
}

NSInteger CuriumActiveV8JitMode(void) {
    typedef int (*V8JitModeFn)(void);
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static V8JitModeFn fn = NULL;
    os_unfair_lock_lock(&lock);
    V8JitModeFn resolved = fn;
    if (!resolved) {
        resolved = (V8JitModeFn)CuriumResolveChromeSymbol("V8IOSJitGetActiveMode");
        if (resolved) {
            fn = resolved;
        }
    }
    os_unfair_lock_unlock(&lock);
    return resolved ? (NSInteger)resolved() : 0;
}

NSDictionary<NSString *, id> *_Nullable CuriumEngineFingerprintCapabilitiesDict(void) {
    Class bootstrap = NSClassFromString(@"CrIOSEngineBootstrap");
    if (![bootstrap respondsToSelector:@selector(fingerprintCapabilities)]) {
        return nil;
    }
    return [(id)bootstrap fingerprintCapabilities];
}

BOOL CuriumConfigureLaunchFingerprint(NSData *_Nullable jsonData, NSError *_Nullable *_Nullable error) {
    Class bootstrap = NSClassFromString(@"CrIOSEngineBootstrap");
    if (![bootstrap respondsToSelector:@selector(configureLaunchFingerprintConfigJSON:error:)]) {
        if (jsonData.length == 0) {
            CuriumRecordHookStatus(@"Fingerprint Profile", @"skipped",
                                   @"Default Build 39 mode (engine predates launch config contract)");
            return YES;
        }
        if (error) {
            *error = [NSError errorWithDomain:CrIOSFingerprintErrorDomain
                                         code:CrIOSFingerprintErrorUnsupportedSchema
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"The embedded Blink engine does not support launch fingerprint profiles."}];
        }
        CuriumRecordHookStatus(@"Fingerprint Profile", @"failed",
                               @"Engine missing configureLaunchFingerprintConfigJSON:error:");
        return NO;
    }

    NSError *localError = nil;
    BOOL ok = [(id)bootstrap configureLaunchFingerprintConfigJSON:jsonData error:&localError];
    if (!ok) {
        if (error) {
            *error = localError;
        }
        CuriumRecordHookStatus(@"Fingerprint Profile", @"failed",
                               localError.localizedDescription ?: @"Engine rejected fingerprint config");
        return NO;
    }
    if (jsonData.length > 0) {
        gCuriumExplicitFingerprintConfigured = YES;
        id parsed = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)parsed;
            gCuriumEnableGlobalPrivacyControl = [dict[@"enableGlobalPrivacyControl"] isKindOfClass:[NSNumber class]]
                && [dict[@"enableGlobalPrivacyControl"] boolValue];
            NSString *defaultSlot = [dict[@"defaultSlot"] isKindOfClass:[NSString class]] ? dict[@"defaultSlot"] : nil;
            NSDictionary *desktop = [dict[@"desktop"] isKindOfClass:[NSDictionary class]] ? dict[@"desktop"] : nil;
            NSNumber *maxTouchPoints = [desktop[@"maxTouchPoints"] isKindOfClass:[NSNumber class]] ? desktop[@"maxTouchPoints"] : nil;
            BOOL desktopZeroTouch = [defaultSlot isEqualToString:@"desktop"]
                && maxTouchPoints != nil
                && [maxTouchPoints integerValue] == 0;
            gCuriumDisableWebTouchDetection = desktopZeroTouch;
            gCuriumEnableDesktopKeyboardAPI = desktopZeroTouch;
            NSDictionary *desktopScreen = [desktop[@"screen"] isKindOfClass:[NSDictionary class]] ? desktop[@"screen"] : nil;
            NSNumber *colorDepth = [desktopScreen[@"colorDepth"] isKindOfClass:[NSNumber class]] ? desktopScreen[@"colorDepth"] : nil;
            gCuriumForceSRGBColorProfile = desktopZeroTouch && colorDepth != nil && [colorDepth integerValue] == 24;
        } else {
            gCuriumEnableGlobalPrivacyControl = NO;
            gCuriumDisableWebTouchDetection = NO;
            gCuriumEnableDesktopKeyboardAPI = NO;
            gCuriumForceSRGBColorProfile = NO;
        }
        NSDictionary<NSString *, id> *status = CuriumEngineActiveFingerprintStatusDict();
        NSString *profileId = [status[@"appliedProfileId"] isKindOfClass:[NSString class]]
            ? status[@"appliedProfileId"] : @"unknown";
        NSNumber *rev = [status[@"appliedConfigRevision"] isKindOfClass:[NSNumber class]]
            ? status[@"appliedConfigRevision"] : @0;
        BOOL hwOverrides = [status[@"hardwareOverridesActive"] boolValue];
        CuriumRecordHookStatus(@"Fingerprint Profile", @"active",
                               [NSString stringWithFormat:@"profile=%@ rev=%llu hw=%@",
                                profileId, rev.unsignedLongLongValue,
                                hwOverrides ? @"override" : @"native-apple"]);
    } else {
        gCuriumExplicitFingerprintConfigured = NO;
        gCuriumEnableGlobalPrivacyControl = NO;
        gCuriumDisableWebTouchDetection = NO;
        gCuriumEnableDesktopKeyboardAPI = NO;
        gCuriumForceSRGBColorProfile = NO;
        CuriumRecordHookStatus(@"Fingerprint Profile", @"active", @"default (Build 39 0105)");
    }
    return YES;
}

NSDictionary<NSString *, id> *_Nullable CuriumEngineActiveFingerprintStatusDict(void) {
    Class bootstrap = NSClassFromString(@"CrIOSEngineBootstrap");
    if (![bootstrap respondsToSelector:@selector(activeFingerprintStatus)]) {
        return nil;
    }
    return [(id)bootstrap activeFingerprintStatus];
}

BOOL CuriumApplyRuntimePrivacyPolicy(NSData *jsonData, NSError *_Nullable *_Nullable error) {
    Class bootstrap = NSClassFromString(@"CrIOSEngineBootstrap");
    if (![bootstrap respondsToSelector:@selector(applyRuntimePolicyJSON:error:)]) {
        if (error) {
            *error = [NSError errorWithDomain:CrIOSFingerprintErrorDomain
                                         code:CrIOSFingerprintErrorUnsupportedSchema
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"The embedded Blink engine does not support live runtime privacy policy updates (requires Build 43+)."}];
        }
        return NO;
    }

    NSError *localError = nil;
    BOOL ok = [(id)bootstrap applyRuntimePolicyJSON:(jsonData ?: [NSData data]) error:&localError];
    if (!ok) {
        if (error) {
            *error = localError;
        }
        CuriumRecordHookStatus(@"Runtime Privacy Policy", @"failed",
                               localError.localizedDescription ?: @"Engine rejected runtime privacy policy");
        return NO;
    }

    NSDictionary<NSString *, id> *status = CuriumEngineActiveRuntimePolicyStatusDict();
    NSNumber *rev = [status[@"appliedPolicyRevision"] isKindOfClass:[NSNumber class]]
        ? status[@"appliedPolicyRevision"] : @0;
    BOOL farblingActive = [status[@"farblingActive"] isKindOfClass:[NSNumber class]]
        && [status[@"farblingActive"] boolValue];
    BOOL gpc = [status[@"enableGlobalPrivacyControl"] isKindOfClass:[NSNumber class]]
        && [status[@"enableGlobalPrivacyControl"] boolValue];
    CuriumRecordHookStatus(@"Runtime Privacy Policy", @"active",
                           [NSString stringWithFormat:@"rev=%llu farbling=%d gpc=%d",
                            rev.unsignedLongLongValue,
                            farblingActive ? 1 : 0,
                            gpc ? 1 : 0]);
    return YES;
}

NSDictionary<NSString *, id> *_Nullable CuriumEngineActiveRuntimePolicyStatusDict(void) {
    Class bootstrap = NSClassFromString(@"CrIOSEngineBootstrap");
    if (![bootstrap respondsToSelector:@selector(activeRuntimePolicyStatus)]) {
        return nil;
    }
    return [(id)bootstrap activeRuntimePolicyStatus];
}

BOOL CuriumSupportsProfileHotSwap(void) {
    Class bootstrap = NSClassFromString(@"CrIOSEngineBootstrap");
    return [bootstrap respondsToSelector:@selector(switchToProfileWithConfigJSON:beforeProfileCreate:completion:)];
}

void CuriumSwitchToProfile(
    NSData *jsonData,
    void (^NS_SWIFT_UI_ACTOR _Nullable beforeProfileCreate)(void),
    void (^NS_SWIFT_UI_ACTOR completion)(
        id<CrIOSBrowserHostV1> _Nullable browserHost,
        id<CrIOSExtensionManagingV1> _Nullable extensionManager,
        NSError *_Nullable error)) {
    if (!completion) {
        return;
    }
    Class bootstrap = NSClassFromString(@"CrIOSEngineBootstrap");
    if (![bootstrap respondsToSelector:@selector(switchToProfileWithConfigJSON:beforeProfileCreate:completion:)]) {
        NSError *unsupported = [NSError errorWithDomain:CrIOSFingerprintErrorDomain
                                                   code:CrIOSFingerprintErrorHotSwapUnsupported
                                               userInfo:@{NSLocalizedDescriptionKey:
                                                              @"Zero-restart profile hot-swap requires Build 44 or newer."}];
        CuriumRunOnMain(^{
            completion(nil, nil, unsupported);
        });
        return;
    }

    [(id)bootstrap switchToProfileWithConfigJSON:(jsonData ?: [NSData data])
                             beforeProfileCreate:beforeProfileCreate
                                      completion:^(id<CrIOSBrowserHostV1> _Nullable browserHost,
                                                   id<CrIOSExtensionManagingV1> _Nullable extensionManager,
                                                   NSError *_Nullable error) {
        CuriumRunOnMain(^{
            if (browserHost && !error) {
                gCuriumExplicitFingerprintConfigured = YES;
                NSDictionary<NSString *, id> *status = CuriumEngineActiveFingerprintStatusDict();
                NSString *profileId = [status[@"appliedProfileId"] isKindOfClass:[NSString class]]
                    ? status[@"appliedProfileId"] : @"unknown";
                NSNumber *rev = [status[@"appliedConfigRevision"] isKindOfClass:[NSNumber class]]
                    ? status[@"appliedConfigRevision"] : @0;
                CuriumRecordHookStatus(@"Fingerprint Profile", @"active",
                                       [NSString stringWithFormat:@"profile=%@ rev=%llu (hot-swap)",
                                        profileId, rev.unsignedLongLongValue]);
            } else if (error) {
                CuriumRecordHookStatus(@"Profile Hot-Swap", @"failed",
                                       error.localizedDescription ?: @"Profile hot-swap failed");
            }
            completion(browserHost, extensionManager, error);
        });
    }];
}

BOOL CuriumHostSupportsNetworkFetch(id<CrIOSBrowserHostV1> host) {
    if (!host) {
        return NO;
    }
    return [host respondsToSelector:@selector(startFetchRequest:delegate:callbackQueue:)] &&
           NSClassFromString(@"CrIOSNetworkFetchRequestV1") != nil;
}

id<CrIOSNetworkFetchTaskV1> _Nullable CuriumStartNetworkFetch(
    id<CrIOSBrowserHostV1> host,
    NSURL *url,
    NSString *httpMethod,
    NSDictionary<NSString *, NSString *> *_Nullable headers,
    NSURL *_Nullable isolationTopFrameURL,
    BOOL includeCookies,
    BOOL blockPrivateNetworkTargets,
    NSTimeInterval timeoutInterval,
    id<CrIOSNetworkFetchDelegateV1> delegate,
    dispatch_queue_t callbackQueue) {
    if (!host || !url || !delegate || !callbackQueue) {
        return nil;
    }
    if (![host respondsToSelector:@selector(startFetchRequest:delegate:callbackQueue:)]) {
        return nil;
    }
    Class requestClass = NSClassFromString(@"CrIOSNetworkFetchRequestV1");
    if (!requestClass) {
        return nil;
    }
    id rawRequest = [[requestClass alloc] init];
    if (!rawRequest) {
        return nil;
    }
    CrIOSNetworkFetchRequestV1 *request = (CrIOSNetworkFetchRequestV1 *)rawRequest;
    request.URL = url;
    request.HTTPMethod = httpMethod.length > 0 ? httpMethod : @"GET";
    request.headers = headers;
    request.isolationTopFrameURL = isolationTopFrameURL;
    request.includeCookies = includeCookies;
    request.blockPrivateNetworkTargets = blockPrivateNetworkTargets;
    request.timeoutInterval = timeoutInterval;
    return [host startFetchRequest:request delegate:delegate callbackQueue:callbackQueue];
}

BOOL CuriumDiscardTab(id<CrIOSBrowserHostV1> host, NSString *tabID) {
    if (!host || tabID.length == 0) {
        return NO;
    }
    if (![host respondsToSelector:@selector(discardTabWithID:)]) {
        return NO;
    }
    return [host discardTabWithID:tabID];
}

BOOL CuriumRegisterShell(id<CrIOSShellBootstrapDelegate> delegate) {
    Class bootstrap = NSClassFromString(@"CrIOSEngineBootstrap");
    if (![bootstrap respondsToSelector:@selector(registerShellBootstrapDelegate:)]) {
        return NO;
    }
    CuriumInstallHeadlessRuntimeGuards();
    [(id)bootstrap registerShellBootstrapDelegate:delegate];
    return YES;
}

id<CrIOSExtensionManagingV1> CuriumSharedExtensionManager(void) {
    Class manager = NSClassFromString(@"CrIOSExtensionManagerV1");
    if (![manager respondsToSelector:@selector(sharedManager)]) {
        return nil;
    }
    return [(id)manager sharedManager];
}

static NSError *CuriumUnsupported(void) {
    return [NSError errorWithDomain:NSCocoaErrorDomain
                               code:NSFeatureUnsupportedError
                           userInfo:@{NSLocalizedDescriptionKey:
                                          @"This feature is unavailable in the current Blink build."}];
}

void CuriumPrepareExtension(id<CrIOSExtensionManagingV1> manager, NSString *source,
                            BOOL isStore, CuriumExtensionResult completion) {
    if (!completion) {
        return;
    }
    CuriumExtensionResult safeCompletion = ^(NSDictionary<NSString *, id> *result, NSError *error) {
        CuriumRunOnMain(^{
            completion(result, error);
        });
    };
    if (![manager respondsToSelector:@selector(confirmPreparedExtensionWithToken:completion:)] ||
        ![manager respondsToSelector:@selector(cancelPreparedExtensionWithToken:error:)]) {
        safeCompletion(nil, CuriumUnsupported());
    } else if (isStore && [manager respondsToSelector:@selector(prepareStoreExtensionWithID:completion:)]) {
        [manager prepareStoreExtensionWithID:source completion:safeCompletion];
    } else if (!isStore && [manager respondsToSelector:@selector(prepareSignedExtensionAtPath:completion:)]) {
        [manager prepareSignedExtensionAtPath:source completion:safeCompletion];
    } else {
        safeCompletion(nil, CuriumUnsupported());
    }
}

void CuriumConfirmExtension(id<CrIOSExtensionManagingV1> manager, NSString *token,
                            CuriumExtensionResult completion) {
    if (!completion) {
        return;
    }
    CuriumExtensionResult safeCompletion = ^(NSDictionary<NSString *, id> *result, NSError *error) {
        CuriumRunOnMain(^{
            completion(result, error);
        });
    };
    if ([manager respondsToSelector:@selector(confirmPreparedExtensionWithToken:completion:)]) {
        [manager confirmPreparedExtensionWithToken:token completion:safeCompletion];
    } else {
        safeCompletion(nil, CuriumUnsupported());
    }
}

void CuriumCancelExtension(id<CrIOSExtensionManagingV1> manager, NSString *token) {
    if ([manager respondsToSelector:@selector(cancelPreparedExtensionWithToken:error:)]) {
        [manager cancelPreparedExtensionWithToken:token error:nil];
    }
}

void CuriumRemoveExtension(id<CrIOSExtensionManagingV1> manager, NSString *identifier,
                           void (^completion)(BOOL, NSError *)) {
    if (!completion) {
        return;
    }
    void (^safeCompletion)(BOOL, NSError *) = ^(BOOL removed, NSError *error) {
        CuriumRunOnMain(^{
            completion(removed, error);
        });
    };
    if ([manager respondsToSelector:@selector(uninstallExtensionWithID:completion:)]) {
        [manager uninstallExtensionWithID:identifier completion:safeCompletion];
    } else {
        safeCompletion(NO, CuriumUnsupported());
    }
}

@protocol CuriumTrustedUnpackedExtensionManaging <NSObject>
@optional
- (nullable NSString *)trustedUnpackedExtensionsDirectoryWithError:
    (NSError *__autoreleasing _Nullable *_Nullable)error;
- (void)installExtensionFromTrustedDirectory:(NSString *)directoryPath
                                  completion:(void (^)(NSDictionary<NSString *, id> *_Nullable extension,
                                                       NSError *_Nullable error))completion;
@end

NSString *_Nullable CuriumTrustedUnpackedExtensionsDirectory(
    id<CrIOSExtensionManagingV1> manager,
    NSError *_Nullable *_Nullable error) {
    if (!manager || ![manager respondsToSelector:@selector(trustedUnpackedExtensionsDirectoryWithError:)]) {
        if (error) {
            *error = CuriumUnsupported();
        }
        return nil;
    }
    return [(id<CuriumTrustedUnpackedExtensionManaging>)manager
        trustedUnpackedExtensionsDirectoryWithError:error];
}

void CuriumInstallTrustedUnpackedExtension(
    id<CrIOSExtensionManagingV1> manager,
    NSString *directoryPath,
    CuriumExtensionResult completion) {
    if (!completion) {
        return;
    }
    CuriumExtensionResult safeCompletion = ^(NSDictionary<NSString *, id> *result, NSError *error) {
        CuriumRunOnMain(^{
            completion(result, error);
        });
    };
    if (manager && [manager respondsToSelector:@selector(installExtensionFromTrustedDirectory:completion:)]) {
        [(id<CuriumTrustedUnpackedExtensionManaging>)manager
            installExtensionFromTrustedDirectory:directoryPath
                                      completion:safeCompletion];
    } else {
        safeCompletion(nil, CuriumUnsupported());
    }
}

NSDictionary<NSString *, id> *CuriumExtensionAction(
    id<CrIOSExtensionManagingV1> manager, NSString *identifier, int32_t tabID) {
    if (![manager respondsToSelector:@selector(actionPresentationForExtensionWithID:tabID:error:)]) {
        return nil;
    }
    return [manager actionPresentationForExtensionWithID:identifier tabID:tabID error:nil];
}

NSNumber *_Nullable CuriumExtensionBlockedCount(
    id<CrIOSExtensionManagingV1> manager, NSString *identifier, int32_t tabID) {
    if (![manager respondsToSelector:@selector(blockedRequestCountForExtensionWithID:tabID:error:)]) {
        return nil;
    }
    return [manager blockedRequestCountForExtensionWithID:identifier tabID:tabID error:nil];
}

id<CrIOSExtensionPopupHostingV1> CuriumExtensionPopup(
    id<CrIOSExtensionManagingV1> manager, NSString *identifier, int32_t tabID, NSError **error) {
    if (![manager respondsToSelector:@selector(popupForExtensionWithID:tabID:error:)]) {
        if (error) *error = CuriumUnsupported();
        return nil;
    }
    return [manager popupForExtensionWithID:identifier tabID:tabID error:error];
}
