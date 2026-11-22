#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Installs Build 40 runtime hooks on CuriumPiPBridge to enable AVKit skip
// controls (rewind/fast-forward), native VideoPictureInPictureWindowController
// seeking, high-PTS HLS timebase preservation, and render-queue flush/stall
// recovery. Fails closed to "skipped" if any expected ivar offset, type
// encoding, or method signature drifts.
void CuriumInstallPiPSkipHooks(void);

// Registers a low-frequency lifecycle/skip diagnostic callback (never invoked on
// per-frame renders) so PiP transitions are captured in CuriumDiagnostics.
void CuriumSetPiPDiagnosticLogHandler(void (^_Nullable handler)(NSString *message));

// Pure PiP timeline helpers shared by CuriumPiPHooks and CuriumTests.
BOOL CuriumPiPIsSeekableDuration(double durationSeconds);
double CuriumPiPEstimateMediaPosition(double basePositionSeconds,
                                      double durationSeconds,
                                      BOOL paused,
                                      double playbackRate,
                                      CFTimeInterval baseWallTime,
                                      CFTimeInterval now);
double CuriumPiPComputeSkipTarget(double currentPositionSeconds,
                                  double durationSeconds,
                                  double deltaSeconds);
double CuriumPiPInferTimebaseOffset(double timebaseSeconds,
                                    double currentPositionSeconds);
CMTimeRange CuriumPiPComputePlayableTimeRange(double durationSeconds,
                                              double estimatedPositionSeconds,
                                              double timebaseSeconds);

typedef NS_ENUM(NSInteger, CuriumPiPRenderFrameAction) {
    CuriumPiPRenderFrameActionRenderNormal = 0,
    CuriumPiPRenderFrameActionDropStalePreSeek = 1,
    CuriumPiPRenderFrameActionFlushAndRenderPostSeek = 2,
    CuriumPiPRenderFrameActionFlushDiscontinuity = 3,
};

// Lock-protected per-bridge state coordinating main-thread AVKit playback
// delegate callbacks with the serial PiP render queue.
@interface CuriumPiPSkipTracker : NSObject

@property (nonatomic, readonly) BOOL hasPendingSeek;
@property (nonatomic, readonly) BOOL isSeekGuardActive;
@property (nonatomic, readonly) BOOL isRenderSeekGuardActive;
@property (nonatomic, readonly) double preSeekPts;
@property (nonatomic, readonly) double expectedTargetPts;
@property (nonatomic, readonly) double lastRenderedPts;

- (void)noteGeneration:(uint64_t)generation;

// Records an engine playback/position update while protecting optimistic seek
// state from stale pre-seek MediaPositions. Buffering updates (paused == NO
// with raw rate <= 0.0) preserve the render-queue seek guard until a post-seek
// frame actually lands or the seek guard window expires.
- (void)recordPlaybackUpdateWithGeneration:(uint64_t)generation
                                    paused:(BOOL)paused
                                      rate:(double)rate
                               hasPosition:(BOOL)hasPosition
                           positionSeconds:(double)positionSeconds
                           durationSeconds:(double)durationSeconds
                                       now:(CFTimeInterval)now;

// Returns the current estimated playback position in media seconds, honoring an
// active optimistic multi-tap seek target while in flight.
- (double)estimatedPositionWithGeneration:(uint64_t)generation
                      fallbackPositionSec:(double)fallbackPositionSec
                          durationSeconds:(double)durationSeconds
                                   paused:(BOOL)paused
                             playbackRate:(double)playbackRate
                                      now:(CFTimeInterval)now;

// Computes a coalesced skip target in media seconds, arms both media-position
// and render-frame seek guards (preserving the original preSeekPts across rapid
// multi-taps), and outputs the target timebase anchor in *outTargetTimebaseSeconds.
- (double)beginSkipWithGeneration:(uint64_t)generation
                     deltaSeconds:(double)deltaSeconds
              fallbackPositionSec:(double)fallbackPositionSec
                  durationSeconds:(double)durationSeconds
                           paused:(BOOL)paused
                     playbackRate:(double)playbackRate
                  timebaseSeconds:(double)timebaseSeconds
                              now:(CFTimeInterval)now
         outTargetTimebaseSeconds:(double *_Nullable)outTargetTimebaseSeconds;

// Evaluates an incoming render-queue VideoFrame PTS against active seek guards
// and monotonic PTS ordering, returning whether to render normally, drop as a
// stale pre-seek frame, flush on post-seek landing, or flush on discontinuity.
- (CuriumPiPRenderFrameAction)evaluateRenderFramePTS:(double)framePtsSeconds
                                       forGeneration:(uint64_t)generation
                                                 now:(CFTimeInterval)now;

// Tracks consecutive frames dropped because AVSampleBufferVideoRenderer was not
// ready for more media data so the render loop can self-heal via -flush.
- (NSUInteger)recordNotReadyFrameForGeneration:(uint64_t)generation;
- (void)resetNotReadyCountForGeneration:(uint64_t)generation;

// Coalesces same-runloop-turn AVKit setPlaying: transitions. On iOS 27.2,
// -[AVSampleBufferDisplayLayerPlayerController seekByTimeInterval:] calls
// setPlaying:NO before skipByInterval: and toggles back inside completionHandler.
// Synchronously updating _mainPlaybackPaused while deferring the Chromium
// Play/Pause dispatch to the next main-queue turn lets the transient NO -> YES
// pair cancel cleanly without pausing playback or firing a spurious JS pause.
- (uint64_t)recordSetPlaying:(BOOL)playing
               currentPaused:(BOOL)currentPaused
               forGeneration:(uint64_t)generation
         shouldScheduleFlush:(BOOL *_Nullable)outShouldScheduleFlush;
- (BOOL)consumePendingSetPlayingForToken:(uint64_t)token
                              generation:(uint64_t)generation
                              outPlaying:(BOOL *_Nullable)outPlaying;
- (BOOL)effectivePausedForSkipWithCurrentPaused:(BOOL)currentPaused
                                     generation:(uint64_t)generation;

@end

NS_ASSUME_NONNULL_END
