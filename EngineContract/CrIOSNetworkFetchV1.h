#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Request descriptor for Chromium's off-@MainActor SharedURLLoaderFactory streaming fetch pipe
/// (Build 44+, EngineContract v4). Provided by chrome_framework; probe CrIOSBrowserHostV1 via
/// respondsToSelector:@selector(startFetchRequest:delegate:callbackQueue:) and resolve dynamically
/// on older engines.
@interface CrIOSNetworkFetchRequestV1 : NSObject

@property (nonatomic, copy) NSURL *URL;
/// "GET" or "HEAD".
@property (nonatomic, copy) NSString *HTTPMethod;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *headers;
/// Optional top-frame URL used to construct IsolationInfo / SiteForCookies for CookieMonster + CHIPS.
@property (nonatomic, copy, nullable) NSURL *isolationTopFrameURL;
@property (nonatomic) BOOL includeCookies;
@property (nonatomic) BOOL blockPrivateNetworkTargets;
@property (nonatomic) NSTimeInterval timeoutInterval;

@end

/// Handle to an active Chromium URLLoader fetch. Thread-safe; safe to call off @MainActor.
@protocol CrIOSNetworkFetchTaskV1 <NSObject>

- (void)setSuspended:(BOOL)suspended;
- (void)cancel;

@end

/// Non-@MainActor delegate invoked strictly on the caller-supplied callbackQueue.
@protocol CrIOSNetworkFetchDelegateV1 <NSObject>

- (void)networkFetchTask:(id<CrIOSNetworkFetchTaskV1>)task
     willPerformRedirect:(NSURL *)newURL
              statusCode:(NSInteger)statusCode
         responseHeaders:(NSDictionary<NSString *, NSString *> *)headers
         decisionHandler:
             (void (^)(BOOL allowRedirect,
                       NSDictionary<NSString *, NSString *> *_Nullable modifiedHeaders))
                 decisionHandler;

- (void)networkFetchTask:(id<CrIOSNetworkFetchTaskV1>)task
      didReceiveResponse:(NSInteger)statusCode
                finalURL:(NSURL *)finalURL
          expectedLength:(int64_t)expectedLength
         responseHeaders:(NSDictionary<NSString *, NSString *> *)headers;

- (void)networkFetchTask:(id<CrIOSNetworkFetchTaskV1>)task
          didReceiveData:(NSData *)chunk;

- (void)networkFetchTask:(id<CrIOSNetworkFetchTaskV1>)task
    didCompleteWithError:(nullable NSError *)error;

@end

NS_ASSUME_NONNULL_END
