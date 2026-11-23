#pragma once

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSUInteger, CrIOSBrowsingDataTypes) {
  CrIOSBrowsingDataTypesCookies = 1UL << 0,
  CrIOSBrowsingDataTypesCache = 1UL << 1,
  CrIOSBrowsingDataTypesSiteStorage = 1UL << 2,
  CrIOSBrowsingDataTypesDownloads = 1UL << 3,
  CrIOSBrowsingDataTypesAll = CrIOSBrowsingDataTypesCookies |
                             CrIOSBrowsingDataTypesCache |
                             CrIOSBrowsingDataTypesSiteStorage |
                             CrIOSBrowsingDataTypesDownloads,
};

typedef NS_OPTIONS(NSUInteger, CrIOSMediaPermissionTypes) {
  CrIOSMediaPermissionTypesCamera = 1UL << 0,
  CrIOSMediaPermissionTypesMicrophone = 1UL << 1,
};

typedef NS_ENUM(NSInteger, CrIOSDownloadState) {
  CrIOSDownloadStatePending = 0,
  CrIOSDownloadStateInProgress = 1,
  CrIOSDownloadStateCompleted = 2,
  CrIOSDownloadStateCancelled = 3,
  CrIOSDownloadStateFailed = 4,
};

@protocol CrIOSBrowserHostV1;

NS_SWIFT_UI_ACTOR
@protocol CrIOSTabHostingV1 <NSObject>

@property (nonatomic, copy, readonly) NSString *tabID;
/// The extensions API's numeric tab ID, or -1 until assigned.
@property (nonatomic, readonly) int32_t extensionTabID;
@property (nonatomic, strong, readonly) UIView *webView;
@property (nonatomic, strong, readonly, nullable) UIScrollView *scrollView;
@property (nonatomic, copy, readonly, nullable) NSURL *currentURL;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, readonly) BOOL isLoading;
/// Fraction of the current load completed, from 0 through 1.
@property (nonatomic, readonly) double estimatedProgress;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly) BOOL usesDesktopUserAgent;
@property (nonatomic, strong, readonly, nullable) UIColor *pageCanvasColor;
@property (nonatomic, readonly) BOOL isWebFullscreen;

- (void)loadURL:(NSURL *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
- (void)setUsesDesktopUserAgent:(BOOL)desktop;
- (void)presentFindInPage;
/// Sets a positive zoom factor; 1.0 restores the default scale.
- (void)setPageZoomScale:(CGFloat)scale;
- (void)takeSnapshotWithCompletion:
    (void (^NS_SWIFT_UI_ACTOR)(UIImage *_Nullable image))completion;

@optional
/// Maximum height of the floating top controls in points. Zero disables the band.
@property (nonatomic) CGFloat topControlsHeight;
/// Compositor shown fraction, from 0 through 1. Observe this key via KVO on the main thread.
@property (nonatomic, readonly) CGFloat topControlsShownRatio;

@property (nonatomic, readonly) BOOL hasPlayingVideo;
@property (nonatomic, readonly) BOOL isPictureInPictureActive;
- (void)enterPictureInPicture;
- (void)exitPictureInPicture;
/// The effective HTTP User-Agent string for this tab (respecting Desktop mode and active profile).
@property (nonatomic, copy, readonly, nullable) NSString *effectiveUserAgent;

@end

/// Swift can cast a tab to this protocol to get a writable height property.
NS_SWIFT_UI_ACTOR
@protocol CrIOSTabBrowserControlsV1 <CrIOSTabHostingV1>

@property (nonatomic) CGFloat topControlsHeight;
@property (nonatomic, readonly) CGFloat topControlsShownRatio;

@end

NS_SWIFT_UI_ACTOR
@protocol CrIOSDownloadTaskV1 <NSObject>

@property (nonatomic, copy, readonly) NSString *downloadID;
@property (nonatomic, copy, readonly, nullable) NSString *sourceTabID;
@property (nonatomic, copy, readonly, nullable) NSURL *originalURL;
@property (nonatomic, copy, readonly) NSString *suggestedFilename;
@property (nonatomic, copy, readonly, nullable) NSString *mimeType;
/// The expected size in bytes, or -1 when unknown.
@property (nonatomic, readonly) int64_t totalBytes;
@property (nonatomic, readonly) int64_t receivedBytes;
@property (nonatomic, readonly) CrIOSDownloadState state;

/// Starts a pending task at a file URL. Completion reports the saved URL or an error.
- (void)startWithDestinationURL:(NSURL *)destinationURL
                     completion:(void (^NS_SWIFT_UI_ACTOR)(NSURL *_Nullable savedFileURL,
                                                            NSError *_Nullable error))completion;
- (void)cancel;

@optional
/// YES for Content-Disposition: attachment, <a download>, or context-menu downloads.
@property (nonatomic, readonly) BOOL isExplicitDownload;
/// YES when the download originated from the primary main frame rather than an embedded subframe.
@property (nonatomic, readonly) BOOL isMainFrame;
/// HTTP method ("GET" or "POST") that initiated the download.
@property (nonatomic, copy, readonly) NSString *httpMethod;

@end

NS_SWIFT_UI_ACTOR
@protocol CrIOSBrowserHostDelegateV1 <NSObject>

/// The tab list, its order, or the active tab changed.
- (void)browserHostDidUpdateTabs:(id<CrIOSBrowserHostV1>)host;
- (void)browserHost:(id<CrIOSBrowserHostV1>)host
       didUpdateTab:(id<CrIOSTabHostingV1>)tab;

@optional

/// The point is in the tab's web view coordinates. Return nil to decline a menu.
- (void)browserHost:(id<CrIOSBrowserHostV1>)host
    contextMenuConfigurationForTab:(id<CrIOSTabHostingV1>)tab
                            linkURL:(nullable NSURL *)linkURL
                           imageURL:(nullable NSURL *)imageURL
                        sourcePoint:(CGPoint)sourcePoint
                         completion:
                             (void (^NS_SWIFT_UI_ACTOR)(
                                 UIContextMenuConfiguration *_Nullable configuration))completion;

/// Accept types are HTML accept tokens; the capture hint is the HTML capture value, if present.
/// Pass readable file URLs to completion, or nil if the user cancels.
- (void)browserHost:(id<CrIOSBrowserHostV1>)host
    runFileChooserForTab:(id<CrIOSTabHostingV1>)tab
             acceptTypes:(NSArray<NSString *> *)acceptTypes
 allowsMultipleSelection:(BOOL)allowsMultipleSelection
             captureHint:(nullable NSString *)captureHint
              completion:
                  (void (^NS_SWIFT_UI_ACTOR)(NSArray<NSURL *> *_Nullable fileURLs))completion;

/// Pass the granted subset of the requested permissions, or zero to deny all.
- (void)browserHost:(id<CrIOSBrowserHostV1>)host
    requestMediaPermissions:(CrIOSMediaPermissionTypes)permissions
                     origin:(NSURL *)origin
                     forTab:(id<CrIOSTabHostingV1>)tab
                 completion:
                     (void (^NS_SWIFT_UI_ACTOR)(
                         CrIOSMediaPermissionTypes grantedPermissions))completion;

- (void)browserHost:(id<CrIOSBrowserHostV1>)host
    didCreateDownload:(id<CrIOSDownloadTaskV1>)download;

/// Observes subresource response metadata. Status is 0 without an HTTP response,
/// and content length is -1 when unknown.
- (void)browserHost:(id<CrIOSBrowserHostV1>)host
                   tab:(id<CrIOSTabHostingV1>)tab
    didLoadResourceURL:(NSURL *)url
              mimeType:(nullable NSString *)mimeType
        httpStatusCode:(NSInteger)httpStatusCode
         contentLength:(int64_t)contentLength;

/// Additive subresource load event for Media Radar (pre-filtered in C++ to skip
/// static page assets). Keys: url, originalURL, referrer, frameURL, frameOrigin,
/// mimeType, httpStatusCode, contentLength, requestDestination.
- (void)browserHost:(id<CrIOSBrowserHostV1>)host
                     tab:(id<CrIOSTabHostingV1>)tab
    didLoadResourceEvent:(NSDictionary<NSString *, id> *)event;

/// Called on the main thread after a document commits in the tab's main frame.
/// Error pages are excluded. The navigation ID is unique while the engine runs.
- (void)browserHost:(id<CrIOSBrowserHostV1>)host
                         tab:(id<CrIOSTabHostingV1>)tab
    didCommitNavigationToURL:(NSURL *)url
                navigationID:(int64_t)navigationID
              isSameDocument:(BOOL)isSameDocument
                    isReload:(BOOL)isReload;

@end

NS_SWIFT_UI_ACTOR
@protocol CrIOSBrowserHostV1 <NSObject>

@property (nonatomic, weak, nullable) id<CrIOSBrowserHostDelegateV1> delegate;
@property (nonatomic, copy, readonly) NSArray<id<CrIOSTabHostingV1>> *tabs;
@property (nonatomic, strong, readonly, nullable) id<CrIOSTabHostingV1> activeTab;

/// A nil URL selects the engine's default new-tab contents.
- (nullable id<CrIOSTabHostingV1>)createTabWithURL:(nullable NSURL *)url
                                         activate:(BOOL)activate;
- (BOOL)activateTabWithID:(NSString *)tabID;
- (BOOL)closeTabWithID:(NSString *)tabID;
- (void)clearBrowsingDataOfTypes:(CrIOSBrowsingDataTypes)types
                   modifiedSince:(NSDate *)date
                      completion:(void (^NS_SWIFT_UI_ACTOR)(NSError *_Nullable error))completion;
/// Uses the named tab's cookie context. A nil result has no header to send.
- (void)cookieHeaderForURL:(NSURL *)url
              inTabWithID:(NSString *)tabID
               completion:(void (^NS_SWIFT_UI_ACTOR)(NSString *_Nullable cookieHeader))completion;

@end

NS_ASSUME_NONNULL_END
