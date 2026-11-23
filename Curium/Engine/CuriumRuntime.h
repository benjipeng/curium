#import <Foundation/Foundation.h>
@import CuriumEngineContract;

NS_ASSUME_NONNULL_BEGIN

void CuriumSetDesktopSite(id<CrIOSTabHostingV1> tab, BOOL enabled);
void CuriumSetPageZoom(id<CrIOSTabHostingV1> tab, CGFloat scale);
uint64_t CuriumAvailableMemoryBytes(void);
// 0 = Jitless, 1 = BrowserEngineCore, 2 = Native MAP_JIT, 3 = TXM Split-W^X.
NSInteger CuriumActiveV8JitMode(void);
NSArray<NSDictionary<NSString *, NSString *> *> *CuriumRuntimeHookStatuses(void);
NSString *CuriumNormalizedAcceptLanguages(NSArray<NSString *> *_Nullable preferred);
NSDictionary<NSString *, id> *_Nullable CuriumEngineFingerprintCapabilitiesDict(void);
BOOL CuriumConfigureLaunchFingerprint(NSData *_Nullable jsonData, NSError *_Nullable *_Nullable error);
NSDictionary<NSString *, id> *_Nullable CuriumEngineActiveFingerprintStatusDict(void);
BOOL CuriumRegisterShell(id<CrIOSShellBootstrapDelegate> delegate);
id<CrIOSExtensionManagingV1> _Nullable CuriumSharedExtensionManager(void);

typedef void (^NS_SWIFT_UI_ACTOR CuriumExtensionResult)(
    NSDictionary<NSString *, id> *_Nullable result, NSError *_Nullable error);

void CuriumPrepareExtension(id<CrIOSExtensionManagingV1> manager,
                            NSString *source, BOOL isStore,
                            CuriumExtensionResult completion);
void CuriumConfirmExtension(id<CrIOSExtensionManagingV1> manager, NSString *token,
                            CuriumExtensionResult completion);
void CuriumCancelExtension(id<CrIOSExtensionManagingV1> manager, NSString *token);
void CuriumRemoveExtension(id<CrIOSExtensionManagingV1> manager, NSString *identifier,
                           void (^NS_SWIFT_UI_ACTOR completion)(BOOL, NSError *_Nullable));
NSString *_Nullable CuriumTrustedUnpackedExtensionsDirectory(
    id<CrIOSExtensionManagingV1> manager,
    NSError *_Nullable *_Nullable error);
void CuriumInstallTrustedUnpackedExtension(
    id<CrIOSExtensionManagingV1> manager,
    NSString *directoryPath,
    CuriumExtensionResult completion);

NSDictionary<NSString *, id> *_Nullable CuriumExtensionAction(
    id<CrIOSExtensionManagingV1> manager, NSString *identifier, int32_t tabID);
NSNumber *_Nullable CuriumExtensionBlockedCount(
    id<CrIOSExtensionManagingV1> manager, NSString *identifier, int32_t tabID);
id<CrIOSExtensionPopupHostingV1> _Nullable CuriumExtensionPopup(
    id<CrIOSExtensionManagingV1> manager, NSString *identifier, int32_t tabID,
    NSError **error);

NS_ASSUME_NONNULL_END
