#pragma once

#import <UIKit/UIKit.h>

@protocol CrIOSBrowserHostV1;
@protocol CrIOSExtensionManagingV1;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CrIOSFingerprintErrorCode) {
  CrIOSFingerprintErrorInvalidJSON = 1,
  CrIOSFingerprintErrorUnsupportedSchema = 2,
  CrIOSFingerprintErrorPayloadTooLarge = 3,
  CrIOSFingerprintErrorInvalidField = 4,
  CrIOSFingerprintErrorInvalidProfileID = 5,
  CrIOSFingerprintErrorProfileUnavailable = 6,
  CrIOSFingerprintErrorProfileLocked = 7,
  CrIOSFingerprintErrorAlreadyFrozen = 8,
};

__attribute__((unused)) static NSString *const CrIOSFingerprintErrorDomain =
    @"com.appautomaton.curium.fingerprint";

#ifdef __cplusplus
extern "C" {
#endif

/// Enters the engine's application loop on the main thread.
int ChromeMain(int argc, char *_Nullable *_Nonnull argv);

#ifdef __cplusplus
}
#endif

NS_SWIFT_UI_ACTOR
@protocol CrIOSShellBootstrapDelegate <NSObject>

/// Creates the scene's shell around the engine-supplied browser host.
- (UIViewController *)makeRootViewControllerForScene:(UIWindowScene *)windowScene
                                       browserHost:(id<CrIOSBrowserHostV1>)browserHost
                                  extensionManager:(nullable id<CrIOSExtensionManagingV1>)extensionManager
    NS_SWIFT_NAME(makeRootViewController(for:browserHost:extensionManager:));

@end

/// Provided by chrome_framework once it exports the bootstrap implementation.
/// Standalone previews may resolve the class by name and dispatch dynamically,
/// or supply a stub or a weak link. Importing this header does not supply it.
NS_SWIFT_UI_ACTOR
@interface CrIOSEngineBootstrap : NSObject

/// Retains the delegate until it is replaced or cleared with nil.
+ (void)registerShellBootstrapDelegate:(nullable id<CrIOSShellBootstrapDelegate>)delegate;
+ (nullable id<CrIOSShellBootstrapDelegate>)shellBootstrapDelegate;

/// Returns supported fingerprint contract schema version, activation scopes,
/// and feature capabilities. Probe via respondsToSelector: on older engines.
+ (NSDictionary<NSString *, id> *)fingerprintCapabilities;

/// Validates, binds the isolated profile directory, and freezes launch-scoped
/// fingerprint configuration before ChromeMain starts. Passing nil or empty
/// data preserves Build 39 (0105) default behavior. Fails closed with a
/// CrIOSFingerprintErrorDomain error if invalid, unsupported, or unavailable.
+ (BOOL)configureLaunchFingerprintConfigJSON:(nullable NSData *)jsonData
                                       error:(NSError *__autoreleasing _Nullable *_Nullable)error;

/// Returns the engine's authoritative acknowledgement of the active profile ID,
/// whether DIR_USER_DATA has opened, applied config revision, state, and any
/// rejection details.
+ (NSDictionary<NSString *, id> *)activeFingerprintStatus;

/// Applies a bounded UTF-8 runtime privacy policy JSON (<= 16 KiB,
/// policySchemaVersion: 1) atomically to the active profile and syncs live
/// WebContents and Blink runtime features without restarting the process.
/// Probe via respondsToSelector: on engines older than Build 43.
+ (BOOL)applyRuntimePolicyJSON:(NSData *)jsonData
                         error:(NSError *__autoreleasing _Nullable *_Nullable)error;

/// Returns the engine's authoritative snapshot of the active runtime privacy
/// policy (runtimePolicyVersion, appliedPolicyRevision, farblingActive,
/// farbling, webrtcIpHandlingPolicy, enableDoNotTrack,
/// enableGlobalPrivacyControl, hideSpeechVoices).
/// Probe via respondsToSelector: on engines older than Build 43.
+ (NSDictionary<NSString *, id> *)activeRuntimePolicyStatus;

@end

NS_ASSUME_NONNULL_END
