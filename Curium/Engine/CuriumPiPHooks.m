#import "CuriumPiPHooks.h"
#import "CuriumHookSupport.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <execinfo.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <math.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <pthread.h>
#import <stdarg.h>
#import <stdint.h>
#import <string.h>
#import <time.h>

static NSString *const kCuriumPiPHookName = @"PiP Skip Controls";
static const CFTimeInterval kCuriumPiPSeekGuardWindowSeconds = 3.5;
static const double kCuriumPiPSeekLandingToleranceSeconds = 2.5;
static const double kCuriumPiPMinDropSeparationSeconds = 1.5;
static const double kCuriumPiPRenderPreSeekSlackSeconds = 1.5;
static const double kCuriumPiPRenderPreSeekMaxAdvanceSeconds = 2.5;
static const double kCuriumPiPDiscontinuityBackwardToleranceSeconds = 0.05;
static const double kCuriumPiPDiscontinuityForwardToleranceSeconds = 1.5;
static const double kCuriumPiPTimebaseOffsetThresholdSeconds = 2.0;
static const NSUInteger kCuriumPiPNotReadyFlushThreshold = 8;

static inline double CuriumPiPSanitizedRate(BOOL paused, double rate) {
    if (paused) {
        return 0.0;
    }
    // Chromium's cached or buffering MediaPosition can carry playback_rate == 0.0
    // while playing; default to 1.0x so controlTimebase and position estimation
    // never stall at 0.0x.
    if (!isfinite(rate) || rate <= 0.0) {
        return 1.0;
    }
    return rate;
}

static inline double CuriumPiPClampPosition(double value, double durationSeconds) {
    if (!isfinite(value) || value < 0.0) {
        value = 0.0;
    }
    if (CuriumPiPIsSeekableDuration(durationSeconds) && value > durationSeconds) {
        value = durationSeconds;
    }
    return value;
}

BOOL CuriumPiPIsSeekableDuration(double durationSeconds) {
    return isfinite(durationSeconds) && durationSeconds > 0.0;
}

double CuriumPiPEstimateMediaPosition(double basePositionSeconds,
                                      double durationSeconds,
                                      BOOL paused,
                                      double playbackRate,
                                      CFTimeInterval baseWallTime,
                                      CFTimeInterval now) {
    double pos = isfinite(basePositionSeconds) ? basePositionSeconds : 0.0;
    double rate = CuriumPiPSanitizedRate(paused, playbackRate);
    if (!paused && rate > 0.0 && baseWallTime > 0.0 && isfinite(now) && now > baseWallTime) {
        pos += (now - baseWallTime) * rate;
    }
    return CuriumPiPClampPosition(pos, durationSeconds);
}

double CuriumPiPComputeSkipTarget(double currentPositionSeconds,
                                  double durationSeconds,
                                  double deltaSeconds) {
    if (!CuriumPiPIsSeekableDuration(durationSeconds)) {
        return CuriumPiPClampPosition(currentPositionSeconds, durationSeconds);
    }
    double base = CuriumPiPClampPosition(currentPositionSeconds, durationSeconds);
    double delta = isfinite(deltaSeconds) ? deltaSeconds : 0.0;
    return CuriumPiPClampPosition(base + delta, durationSeconds);
}

double CuriumPiPInferTimebaseOffset(double timebaseSeconds,
                                    double currentPositionSeconds) {
    if (!isfinite(timebaseSeconds) || !isfinite(currentPositionSeconds)) {
        return 0.0;
    }
    // An unprimed display layer starts at 0 s while MediaPosition may already be
    // mid-stream; avoid capturing a bogus negative offset in that case.
    if (timebaseSeconds <= 0.5 && currentPositionSeconds >= kCuriumPiPTimebaseOffsetThresholdSeconds) {
        return 0.0;
    }
    double delta = timebaseSeconds - currentPositionSeconds;
    return fabs(delta) >= kCuriumPiPTimebaseOffsetThresholdSeconds ? delta : 0.0;
}

static os_unfair_lock gCuriumPiPLogLock = OS_UNFAIR_LOCK_INIT;
static void (^gCuriumPiPLogHandler)(NSString *message) = nil;

void CuriumSetPiPDiagnosticLogHandler(void (^_Nullable handler)(NSString *message)) {
    void (^copied)(NSString *) = [handler copy];
    os_unfair_lock_lock(&gCuriumPiPLogLock);
    gCuriumPiPLogHandler = copied;
    os_unfair_lock_unlock(&gCuriumPiPLogLock);
}

static void CuriumPiPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void CuriumPiPLog(NSString *format, ...) {
    os_unfair_lock_lock(&gCuriumPiPLogLock);
    void (^handler)(NSString *) = gCuriumPiPLogHandler;
    os_unfair_lock_unlock(&gCuriumPiPLogLock);
    if (!handler || !format) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (msg.length > 0) {
        handler(msg);
    }
}

CMTimeRange CuriumPiPComputePlayableTimeRange(double durationSeconds,
                                              double estimatedPositionSeconds,
                                              double timebaseSeconds) {
    if (!CuriumPiPIsSeekableDuration(durationSeconds)) {
        return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
    }
    double estPos = CuriumPiPClampPosition(estimatedPositionSeconds, durationSeconds);
    double startSec = 0.0;
    double span = durationSeconds;
    if (isfinite(timebaseSeconds)) {
        double tbNonNeg = fmax(0.0, timebaseSeconds);
        // Handle small, medium, and high-PTS HLS/DVR epochs cleanly while
        // keeping start == 0 when controlTimebase is unprimed at 0 s mid-stream.
        if (tbNonNeg > estPos + kCuriumPiPTimebaseOffsetThresholdSeconds) {
            startSec = fmax(0.0, tbNonNeg - estPos);
        }
        // Guarantee [startSec, startSec + span] always contains tbNonNeg so
        // AVKit never concludes playback ended from a slightly ahead timebase.
        if (tbNonNeg < startSec) {
            startSec = tbNonNeg;
        }
        if (tbNonNeg > startSec + span) {
            span = tbNonNeg - startSec;
        }
    }
    return CMTimeRangeMake(CMTimeMakeWithSeconds(startSec, 1000000),
                           CMTimeMakeWithSeconds(span, 1000000));
}

@implementation CuriumPiPSkipTracker {
    os_unfair_lock _lock;
    uint64_t _generation;
    BOOL _hasObservedGeneration;

    BOOL _hasPositionWallTime;
    CFTimeInterval _positionWallTime;
    double _lastKnownPositionSeconds;
    BOOL _lastKnownPaused;
    double _lastKnownRate;

    BOOL _pendingSeekActive;
    double _pendingTargetSeconds;
    CFTimeInterval _pendingSeekSetAt;
    CFTimeInterval _mediaSeekGuardUntil;

    BOOL _renderSeekGuardActive;
    uint64_t _renderSeekGuardGeneration;
    CFTimeInterval _renderSeekGuardStartedAt;
    CFTimeInterval _renderSeekGuardUntil;
    BOOL _hasPreSeekPts;
    double _preSeekPts;
    double _expectedTargetPts;
    CFTimeInterval _expectedTargetAnchorWallTime;
    double _expectedTargetRate;
    BOOL _expectedTargetPaused;

    BOOL _hasLastRenderedPts;
    double _lastRenderedPts;
    NSUInteger _consecutiveNotReadyCount;

    BOOL _hasPendingSetPlaying;
    BOOL _pendingSetPlayingValue;
    BOOL _preSetPlayingPaused;
    uint64_t _pendingSetPlayingToken;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _lastKnownRate = 1.0;
        _expectedTargetRate = 1.0;
    }
    return self;
}

- (void)resetForGenerationLocked:(uint64_t)generation {
    BOOL isSubsequentSession = _hasObservedGeneration && _generation != 0 && generation != _generation;
    _generation = generation;
    _hasObservedGeneration = YES;

    _pendingSeekActive = NO;
    _pendingTargetSeconds = 0.0;
    _pendingSeekSetAt = 0.0;
    _mediaSeekGuardUntil = 0.0;

    _renderSeekGuardActive = NO;
    _renderSeekGuardGeneration = generation;
    _renderSeekGuardStartedAt = 0.0;
    _renderSeekGuardUntil = 0.0;
    _hasPreSeekPts = NO;
    _preSeekPts = 0.0;
    _expectedTargetPts = 0.0;
    _expectedTargetAnchorWallTime = 0.0;
    _expectedTargetRate = 1.0;
    _expectedTargetPaused = NO;

    _hasLastRenderedPts = NO;
    _lastRenderedPts = 0.0;
    _consecutiveNotReadyCount = 0;

    _hasPendingSetPlaying = NO;
    _pendingSetPlayingValue = NO;
    _preSetPlayingPaused = NO;
    _pendingSetPlayingToken += 1;

    if (isSubsequentSession) {
        _hasPositionWallTime = NO;
        _positionWallTime = 0.0;
        _lastKnownPositionSeconds = 0.0;
    }
}

- (void)ensureGenerationLocked:(uint64_t)generation {
    if (!_hasObservedGeneration || _generation != generation) {
        [self resetForGenerationLocked:generation];
    }
}

- (double)currentPendingTargetLocked:(double)durationSeconds
                              paused:(BOOL)paused
                                rate:(double)rate
                                 now:(CFTimeInterval)now {
    double effRate = CuriumPiPSanitizedRate(paused, rate);
    double pos = _pendingTargetSeconds;
    if (!paused && effRate > 0.0 && isfinite(now) && now > _pendingSeekSetAt) {
        pos += (now - _pendingSeekSetAt) * effRate;
    }
    return CuriumPiPClampPosition(pos, durationSeconds);
}

- (double)currentExpectedTargetPtsLocked:(CFTimeInterval)now {
    double pts = _expectedTargetPts;
    if (!_expectedTargetPaused && _expectedTargetRate > 0.0 &&
        isfinite(now) && now > _expectedTargetAnchorWallTime) {
        pts += (now - _expectedTargetAnchorWallTime) * _expectedTargetRate;
    }
    return pts;
}

- (void)expireGuardsIfNeededLocked:(uint64_t)generation now:(CFTimeInterval)now {
    if (_pendingSeekActive &&
        (_generation != generation || !isfinite(now) || now >= _mediaSeekGuardUntil)) {
        _pendingSeekActive = NO;
    }
    if (_renderSeekGuardActive &&
        (_renderSeekGuardGeneration != generation || !isfinite(now) || now >= _renderSeekGuardUntil)) {
        _renderSeekGuardActive = NO;
        _hasPreSeekPts = NO;
    }
}

- (BOOL)hasPendingSeek {
    os_unfair_lock_lock(&_lock);
    BOOL value = _pendingSeekActive;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (BOOL)isSeekGuardActive {
    os_unfair_lock_lock(&_lock);
    BOOL value = _pendingSeekActive || _renderSeekGuardActive;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (BOOL)isRenderSeekGuardActive {
    os_unfair_lock_lock(&_lock);
    BOOL value = _renderSeekGuardActive;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (double)preSeekPts {
    os_unfair_lock_lock(&_lock);
    double value = _hasPreSeekPts ? _preSeekPts : NAN;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (double)expectedTargetPts {
    os_unfair_lock_lock(&_lock);
    double value = _expectedTargetPts;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (double)lastRenderedPts {
    os_unfair_lock_lock(&_lock);
    double value = _hasLastRenderedPts ? _lastRenderedPts : NAN;
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (void)noteGeneration:(uint64_t)generation {
    os_unfair_lock_lock(&_lock);
    [self ensureGenerationLocked:generation];
    os_unfair_lock_unlock(&_lock);
}

- (void)recordPlaybackUpdateWithGeneration:(uint64_t)generation
                                    paused:(BOOL)paused
                                      rate:(double)rate
                               hasPosition:(BOOL)hasPosition
                           positionSeconds:(double)positionSeconds
                           durationSeconds:(double)durationSeconds
                                       now:(CFTimeInterval)now {
    os_unfair_lock_lock(&_lock);
    [self ensureGenerationLocked:generation];
    [self expireGuardsIfNeededLocked:generation now:now];

    double effRate = CuriumPiPSanitizedRate(paused, rate);
    BOOL wasPaused = _lastKnownPaused;
    double prevRate = _lastKnownRate;
    BOOL validPos = hasPosition && isfinite(positionSeconds);
    double clampedPos = validPos ? CuriumPiPClampPosition(positionSeconds, durationSeconds) : 0.0;

    if (_renderSeekGuardActive) {
        // Keep expectedTargetPts aligned across pause/resume toggles while the
        // render seek guard awaits the first post-seek frame. Never disarm the
        // render seek guard on buffering (paused == NO && raw rate <= 0.0) updates.
        _expectedTargetPts = [self currentExpectedTargetPtsLocked:now];
        _expectedTargetAnchorWallTime = now;
        _expectedTargetPaused = paused;
        _expectedTargetRate = effRate;
    }

    if (_pendingSeekActive) {
        double expectedPos = [self currentPendingTargetLocked:durationSeconds
                                                       paused:wasPaused
                                                         rate:prevRate
                                                          now:now];
        if (validPos &&
            fabs(clampedPos - expectedPos) <= kCuriumPiPSeekLandingToleranceSeconds) {
            // Post-seek MediaPosition landed near the optimistic target.
            _lastKnownPositionSeconds = clampedPos;
            _positionWallTime = now;
            _hasPositionWallTime = YES;
            _pendingSeekActive = NO;
        } else {
            // Either a stale pre-seek MediaPosition arrived or play/pause toggled
            // mid-seek. Never poison _lastKnownPositionSeconds with stale pre-seek
            // data; re-anchor optimistic media time cleanly.
            _pendingTargetSeconds = expectedPos;
            _pendingSeekSetAt = now;
            _pendingSeekActive = YES;
        }
    } else {
        // Normal (non-seeking) update. Preserve extrapolated position across
        // playing -> paused transitions and avoid extrapolating idle pause time
        // across paused -> playing transitions when MediaPosition is omitted.
        if (!validPos && _hasPositionWallTime) {
            if (!wasPaused && paused) {
                _lastKnownPositionSeconds = CuriumPiPEstimateMediaPosition(
                    _lastKnownPositionSeconds, durationSeconds, NO, prevRate,
                    _positionWallTime, now);
                _positionWallTime = now;
            } else if (wasPaused && !paused) {
                _positionWallTime = now;
            }
        } else if (validPos) {
            _lastKnownPositionSeconds = clampedPos;
            _positionWallTime = now;
            _hasPositionWallTime = YES;
        }
    }

    _lastKnownPaused = paused;
    _lastKnownRate = effRate;

    os_unfair_lock_unlock(&_lock);
}

- (double)estimatedPositionWithGeneration:(uint64_t)generation
                      fallbackPositionSec:(double)fallbackPositionSec
                          durationSeconds:(double)durationSeconds
                                   paused:(BOOL)paused
                             playbackRate:(double)playbackRate
                                      now:(CFTimeInterval)now {
    os_unfair_lock_lock(&_lock);
    [self ensureGenerationLocked:generation];
    [self expireGuardsIfNeededLocked:generation now:now];

    double result = 0.0;
    if (_pendingSeekActive && isfinite(now) && now < _mediaSeekGuardUntil) {
        result = [self currentPendingTargetLocked:durationSeconds
                                           paused:paused
                                             rate:playbackRate
                                              now:now];
    } else {
        _pendingSeekActive = NO;
        double basePos = _hasPositionWallTime ? _lastKnownPositionSeconds : fallbackPositionSec;
        CFTimeInterval wallTime = _hasPositionWallTime ? _positionWallTime : 0.0;
        result = CuriumPiPEstimateMediaPosition(basePos, durationSeconds, paused,
                                                playbackRate, wallTime, now);
    }

    os_unfair_lock_unlock(&_lock);
    return result;
}

- (double)beginSkipWithGeneration:(uint64_t)generation
                     deltaSeconds:(double)deltaSeconds
              fallbackPositionSec:(double)fallbackPositionSec
                  durationSeconds:(double)durationSeconds
                           paused:(BOOL)paused
                     playbackRate:(double)playbackRate
                  timebaseSeconds:(double)timebaseSeconds
                              now:(CFTimeInterval)now
         outTargetTimebaseSeconds:(double *_Nullable)outTargetTimebaseSeconds {
    os_unfair_lock_lock(&_lock);
    [self ensureGenerationLocked:generation];
    [self expireGuardsIfNeededLocked:generation now:now];

    double effRate = CuriumPiPSanitizedRate(paused, playbackRate);
    double curPos = 0.0;
    if (_pendingSeekActive && isfinite(now) && now < _mediaSeekGuardUntil) {
        curPos = [self currentPendingTargetLocked:durationSeconds
                                           paused:paused
                                             rate:effRate
                                              now:now];
    } else {
        double basePos = _hasPositionWallTime ? _lastKnownPositionSeconds : fallbackPositionSec;
        CFTimeInterval wallTime = _hasPositionWallTime ? _positionWallTime : 0.0;
        curPos = CuriumPiPEstimateMediaPosition(basePos, durationSeconds, paused,
                                                effRate, wallTime, now);
    }

    double targetSec = CuriumPiPComputeSkipTarget(curPos, durationSeconds, deltaSeconds);
    double tbOffset = CuriumPiPInferTimebaseOffset(timebaseSeconds, curPos);
    double targetTb = targetSec + tbOffset;

    _pendingSeekActive = YES;
    _pendingTargetSeconds = targetSec;
    _pendingSeekSetAt = now;
    _mediaSeekGuardUntil = now + kCuriumPiPSeekGuardWindowSeconds;

    if (!_renderSeekGuardActive) {
        if (_hasLastRenderedPts) {
            _preSeekPts = _lastRenderedPts;
            _hasPreSeekPts = YES;
        } else if (isfinite(timebaseSeconds)) {
            _preSeekPts = timebaseSeconds;
            _hasPreSeekPts = YES;
        } else {
            _preSeekPts = 0.0;
            _hasPreSeekPts = NO;
        }
        _renderSeekGuardStartedAt = now;
    }

    _renderSeekGuardActive = YES;
    _renderSeekGuardGeneration = generation;
    _renderSeekGuardUntil = now + kCuriumPiPSeekGuardWindowSeconds;
    _expectedTargetPts = targetTb;
    _expectedTargetAnchorWallTime = now;
    _expectedTargetRate = effRate;
    _expectedTargetPaused = paused;
    _consecutiveNotReadyCount = 0;

    if (outTargetTimebaseSeconds) {
        *outTargetTimebaseSeconds = targetTb;
    }

    os_unfair_lock_unlock(&_lock);
    return targetSec;
}

- (CuriumPiPRenderFrameAction)evaluateRenderFramePTS:(double)framePtsSeconds
                                       forGeneration:(uint64_t)generation
                                                 now:(CFTimeInterval)now {
    if (!isfinite(framePtsSeconds)) {
        return CuriumPiPRenderFrameActionRenderNormal;
    }

    os_unfair_lock_lock(&_lock);
    [self ensureGenerationLocked:generation];
    [self expireGuardsIfNeededLocked:generation now:now];

    if (_renderSeekGuardActive) {
        double expectedNow = [self currentExpectedTargetPtsLocked:now];
        double preNow = _preSeekPts;
        if (_hasPreSeekPts && !_expectedTargetPaused && _expectedTargetRate > 0.0 &&
            isfinite(now) && now > _renderSeekGuardStartedAt) {
            double adv = (now - _renderSeekGuardStartedAt) * _expectedTargetRate;
            preNow += fmin(adv, kCuriumPiPRenderPreSeekMaxAdvanceSeconds);
        }

        double seekSeparation = _hasPreSeekPts ? fabs(expectedNow - _preSeekPts) : 0.0;
        double distToTarget = fabs(framePtsSeconds - expectedNow);
        double distToPre = _hasPreSeekPts
            ? fmin(fabs(framePtsSeconds - _preSeekPts), fabs(framePtsSeconds - preNow))
            : INFINITY;

        BOOL inPreSeekWindow = _hasPreSeekPts &&
                               framePtsSeconds >= (_preSeekPts - 0.5) &&
                               framePtsSeconds <= (preNow + kCuriumPiPRenderPreSeekSlackSeconds);
        if (seekSeparation >= kCuriumPiPMinDropSeparationSeconds &&
            inPreSeekWindow &&
            distToTarget > 1.2 &&
            distToPre < distToTarget) {
            os_unfair_lock_unlock(&_lock);
            return CuriumPiPRenderFrameActionDropStalePreSeek;
        }

        // A post-seek frame landed: flush stale decoder state, re-prime
        // _renderTimebase on this frame's PTS, and disarm the render seek guard.
        _renderSeekGuardActive = NO;
        _hasPreSeekPts = NO;
        _lastRenderedPts = framePtsSeconds;
        _hasLastRenderedPts = YES;
        _consecutiveNotReadyCount = 0;
        os_unfair_lock_unlock(&_lock);
        return CuriumPiPRenderFrameActionFlushAndRenderPostSeek;
    }

    BOOL discontinuity = NO;
    if (_hasLastRenderedPts) {
        if (framePtsSeconds < _lastRenderedPts - kCuriumPiPDiscontinuityBackwardToleranceSeconds ||
            framePtsSeconds > _lastRenderedPts + kCuriumPiPDiscontinuityForwardToleranceSeconds) {
            discontinuity = YES;
        }
    }

    _lastRenderedPts = framePtsSeconds;
    _hasLastRenderedPts = YES;
    if (discontinuity) {
        _consecutiveNotReadyCount = 0;
        os_unfair_lock_unlock(&_lock);
        return CuriumPiPRenderFrameActionFlushDiscontinuity;
    }

    os_unfair_lock_unlock(&_lock);
    return CuriumPiPRenderFrameActionRenderNormal;
}

- (NSUInteger)recordNotReadyFrameForGeneration:(uint64_t)generation {
    os_unfair_lock_lock(&_lock);
    [self ensureGenerationLocked:generation];
    _consecutiveNotReadyCount += 1;
    NSUInteger count = _consecutiveNotReadyCount;
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (void)resetNotReadyCountForGeneration:(uint64_t)generation {
    os_unfair_lock_lock(&_lock);
    [self ensureGenerationLocked:generation];
    _consecutiveNotReadyCount = 0;
    os_unfair_lock_unlock(&_lock);
}

- (uint64_t)recordSetPlaying:(BOOL)playing
               currentPaused:(BOOL)currentPaused
               forGeneration:(uint64_t)generation
         shouldScheduleFlush:(BOOL *_Nullable)outShouldScheduleFlush {
    playing = playing ? YES : NO;
    currentPaused = currentPaused ? YES : NO;
    os_unfair_lock_lock(&_lock);
    [self ensureGenerationLocked:generation];

    BOOL shouldSchedule = NO;
    if (!_hasPendingSetPlaying) {
        _preSetPlayingPaused = currentPaused;
        _pendingSetPlayingValue = playing;
        _pendingSetPlayingToken += 1;
        if (playing != (!_preSetPlayingPaused)) {
            _hasPendingSetPlaying = YES;
            shouldSchedule = YES;
        }
    } else {
        _pendingSetPlayingValue = playing;
        _pendingSetPlayingToken += 1;
        if (playing == (!_preSetPlayingPaused)) {
            // Transient toggle (e.g. AVKit's pause-before-skip + resume-after-skip)
            // returned to its pre-batch state within the same runloop turn.
            _hasPendingSetPlaying = NO;
            shouldSchedule = NO;
        } else {
            _hasPendingSetPlaying = YES;
            shouldSchedule = YES;
        }
    }

    uint64_t token = _pendingSetPlayingToken;
    os_unfair_lock_unlock(&_lock);
    if (outShouldScheduleFlush) {
        *outShouldScheduleFlush = shouldSchedule;
    }
    return token;
}

- (BOOL)consumePendingSetPlayingForToken:(uint64_t)token
                              generation:(uint64_t)generation
                              outPlaying:(BOOL *_Nullable)outPlaying {
    os_unfair_lock_lock(&_lock);
    if (!_hasObservedGeneration || _generation != generation ||
        !_hasPendingSetPlaying || _pendingSetPlayingToken != token) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    _hasPendingSetPlaying = NO;
    BOOL targetPlaying = _pendingSetPlayingValue;
    BOOL isNoOp = (targetPlaying == (!_preSetPlayingPaused));
    os_unfair_lock_unlock(&_lock);
    if (isNoOp) {
        return NO;
    }
    if (outPlaying) {
        *outPlaying = targetPlaying;
    }
    return YES;
}

- (BOOL)effectivePausedForSkipWithCurrentPaused:(BOOL)currentPaused
                                     generation:(uint64_t)generation {
    currentPaused = currentPaused ? YES : NO;
    os_unfair_lock_lock(&_lock);
    [self ensureGenerationLocked:generation];
    BOOL effectivePaused = (_hasPendingSetPlaying && !_pendingSetPlayingValue)
        ? _preSetPlayingPaused
        : currentPaused;
    os_unfair_lock_unlock(&_lock);
    return effectivePaused;
}

@end

#pragma mark - Build 40 CuriumPiPBridge Runtime Hooks

#if defined(__arm64__) || defined(__aarch64__)

typedef struct {
    int32_t width;
    int32_t height;
} CuriumPiPIntSize;

typedef struct {
    const void *flag;
    void *ptr;
} CuriumPiPWeakPtrLayout;

// Verified Build 40 std::optional<media_session::MediaPosition> layout (48B).
typedef struct {
    double playback_rate;          // +0x00
    int64_t duration_us;           // +0x08
    int64_t position_us;           // +0x10
    int64_t last_updated_time_us;  // +0x18
    uint8_t end_of_media;          // +0x20
    uint8_t _pad[7];               // +0x21..0x27
    uint8_t engaged;               // +0x28
} CuriumPiPMediaPositionOptionalLayout;

static const char kCuriumPiPTrackerAssocKey = 0;
static const char kCuriumRenderQueueSpecificKey = 0;

// Verified Build 40 (8b550ce / Chromium 160.0.8171.0) CuriumPiPBridge layout.
static const unsigned int kExpectedBuild40IvarCount = 38;
static const ptrdiff_t kExpectedOffsetOwner = 8;
static const ptrdiff_t kExpectedOffsetRenderQueue = 32;
static const ptrdiff_t kExpectedOffsetDisplayLayer = 48;
static const ptrdiff_t kExpectedOffsetPipController = 56;
static const ptrdiff_t kExpectedOffsetPipActive = 106;
static const ptrdiff_t kExpectedOffsetStartAttemptActive = 107;
static const ptrdiff_t kExpectedOffsetStartAttemptGeneration = 112;
static const ptrdiff_t kExpectedOffsetMainPlaybackPaused = 145;
static const ptrdiff_t kExpectedOffsetMainDurationSeconds = 152;
static const ptrdiff_t kExpectedOffsetMainPlaybackRate = 160;
static const ptrdiff_t kExpectedOffsetMainPositionSeconds = 168;
static const ptrdiff_t kExpectedOffsetMainPositionTimestamp = 176;
static const ptrdiff_t kExpectedOffsetActiveGeneration = 184;
static const ptrdiff_t kExpectedOffsetAtomicGeneration = 192;
static const ptrdiff_t kExpectedOffsetRenderRenderer = 200;
static const ptrdiff_t kExpectedOffsetRenderTimebase = 208;
static const ptrdiff_t kExpectedOffsetRenderPlaybackPaused = 216;
static const ptrdiff_t kExpectedOffsetRenderPlaybackRate = 224;
static const ptrdiff_t kExpectedOffsetRenderTimebasePrimed = 232;
static const ptrdiff_t kExpectedOffsetIsFlushing = 233;
static const ptrdiff_t kExpectedOffsetConsecutiveFailures = 236;
static const ptrdiff_t kExpectedOffsetSlotLock = 240;
static const ptrdiff_t kExpectedOffsetLatestSlot = 304;

// Verified Build 40 PendingFrameSlot, media::VideoFrame, ClientSharedImage, and
// MappableBufferIOSurface offsets (identical across ios-arm64 & ios-arm64-simulator).
static const size_t kPendingFrameSlotFrameOffset = 0x00;
static const size_t kPendingFrameSlotHwBufferOffset = 0x08;
static const size_t kPendingFrameSlotGenerationOffset = 0x10;
static const size_t kPendingFrameSlotEngagedOffset = 0x18;
static const size_t kVideoFrameCodedWidthOffset = 0x14;
static const size_t kVideoFrameCodedHeightOffset = 0x18;
static const size_t kVideoFrameWrappedFrameOffset = 0x50;
static const size_t kVideoFrameStorageTypeOffset = 0x60;
static const size_t kVideoFrameSharedImageOffset = 0xe8;
static const size_t kVideoFrameTimestampUsOffset = 0x1b8;
static const uint32_t kVideoFrameStorageOpaque = 1;
static const size_t kClientSharedImageMappableBufferOffset = 0xd8;
static const size_t kMappableBufferWidthOffset = 0x08;
static const size_t kMappableBufferHeightOffset = 0x0c;
static const size_t kMappableBufferTypeOffset = 0x18;
static const uint64_t kGpuMemoryBufferTypeIOSurface = 2;
static const size_t kMappableBufferIOSurfaceOffset = 0x58;
static const int64_t kMediaNoTimestampUs = INT64_MIN;

// Verified Build 40 C++ offsets on IOSVideoOverlayWindow and
// VideoPictureInPictureWindowControllerImpl.
static const size_t kWeakFlagInvalidatedOffset = 4;
static const size_t kOverlayWindowControllerOffset = 8;
static const size_t kControllerWebContentsOffset = 0x30;
static const size_t kControllerSeekToHandledOffset = 0x6a;
static const size_t kControllerActiveSessionOffset = 0x70;
static const size_t kControllerPendingNativeStartOffset = 0x130;
static const size_t kSessionHasPlayerIdOffset = 0x4c;
static const size_t kSessionIsStoppingOffset = 0x50;
static const size_t kSessionMediaPlayerBoundOffset = 0x58;
static const size_t kSessionMediaPlayerProxyOffset = 0x68;
static const size_t kControllerSeekToVtableSlot = 27;  // vtable + 0xd8

static Ivar gIvarOwner = NULL;
static Ivar gIvarRenderQueue = NULL;
static Ivar gIvarDisplayLayer = NULL;
static Ivar gIvarPipController = NULL;
static Ivar gIvarPipActive = NULL;
static Ivar gIvarStartAttemptActive = NULL;
static Ivar gIvarStartAttemptGeneration = NULL;
static Ivar gIvarMainPlaybackPaused = NULL;
static Ivar gIvarMainDurationSeconds = NULL;
static Ivar gIvarMainPlaybackRate = NULL;
static Ivar gIvarMainPositionSeconds = NULL;
static Ivar gIvarMainPositionTimestamp = NULL;
static Ivar gIvarActiveGeneration = NULL;
static Ivar gIvarAtomicGeneration = NULL;
static Ivar gIvarRenderRenderer = NULL;
static Ivar gIvarRenderTimebase = NULL;
static Ivar gIvarRenderPlaybackPaused = NULL;
static Ivar gIvarRenderPlaybackRate = NULL;
static Ivar gIvarRenderTimebasePrimed = NULL;
static Ivar gIvarIsFlushing = NULL;
static Ivar gIvarConsecutiveFailures = NULL;
static Ivar gIvarSlotLock = NULL;
static Ivar gIvarLatestSlot = NULL;

typedef void (*CuriumPiPPrepareHostIMP)(id, SEL, UIWindow *, CuriumPiPIntSize, uint64_t);
typedef void (*CuriumPiPDrainFrameIMP)(id, SEL);
typedef void (*CuriumPiPStopDetachIMP)(id, SEL, BOOL);
typedef void (*CuriumPiPDelegateEventIMP)(id, SEL, AVPictureInPictureController *);
typedef void (*CuriumPiPDelegateFailIMP)(id, SEL, AVPictureInPictureController *, NSError *);
typedef void (*CuriumPiPSetPlayingIMP)(id, SEL, AVPictureInPictureController *, BOOL);

static CuriumPiPPrepareHostIMP gOrigPrepareHost = NULL;
static CuriumPiPDrainFrameIMP gOrigDrainFrame = NULL;
static CuriumPiPStopDetachIMP gOrigStopDetach = NULL;
static CuriumPiPDelegateEventIMP gOrigDidStart = NULL;
static CuriumPiPDelegateFailIMP gOrigFailedToStart = NULL;
static CuriumPiPDelegateEventIMP gOrigDidStop = NULL;
static CuriumPiPSetPlayingIMP gOrigSetPlaying = NULL;

static inline Ivar _Nullable CuriumExpectIvarAtOffset(Class cls,
                                                      const char *name,
                                                      const char *encoding,
                                                      ptrdiff_t expectedOffset) {
    Ivar ivar = CuriumExpectIvar(cls, name, encoding);
    if (!ivar || ivar_getOffset(ivar) != expectedOffset) {
        return NULL;
    }
    return ivar;
}

static inline id _Nullable CuriumPiPReadObjectIvar(__unsafe_unretained id obj, Ivar ivar) {
    if (!obj || !ivar) {
        return nil;
    }
    return *(id __unsafe_unretained const *)CuriumIvarAddress(obj, ivar);
}

static inline BOOL CuriumPiPReadBoolIvar(__unsafe_unretained id obj, Ivar ivar) {
    return *(const BOOL *)CuriumIvarAddress(obj, ivar);
}

static inline double CuriumPiPReadDoubleIvar(__unsafe_unretained id obj, Ivar ivar) {
    return *(const double *)CuriumIvarAddress(obj, ivar);
}

static inline uint64_t CuriumPiPReadUInt64Ivar(__unsafe_unretained id obj, Ivar ivar) {
    return *(const uint64_t *)CuriumIvarAddress(obj, ivar);
}

static inline uint64_t CuriumPiPReadAtomicUInt64Ivar(__unsafe_unretained id obj, Ivar ivar) {
    return __atomic_load_n((const uint64_t *)CuriumIvarAddress(obj, ivar), __ATOMIC_ACQUIRE);
}

static inline CMTimebaseRef _Nullable CuriumPiPReadRenderTimebase(__unsafe_unretained id obj) {
    return *(CMTimebaseRef const *)CuriumIvarAddress(obj, gIvarRenderTimebase);
}

static inline int64_t CuriumPiPCurrentTimeTicksMicroseconds(void) {
    return (int64_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000ULL);
}

static inline double CuriumPiPMediaPositionDurationSeconds(
    const CuriumPiPMediaPositionOptionalLayout *pos) {
    if (pos->duration_us == INT64_MIN) {
        return -INFINITY;
    }
    if (pos->duration_us == INT64_MAX) {
        return INFINITY;
    }
    return (double)pos->duration_us / 1000000.0;
}

static inline double CuriumPiPComputeMediaPositionSeconds(
    const CuriumPiPMediaPositionOptionalLayout *pos,
    int64_t nowTicksUs) {
    int64_t elapsedUs = 0;
    if (nowTicksUs > pos->last_updated_time_us) {
        uint64_t diff = (uint64_t)nowTicksUs - (uint64_t)pos->last_updated_time_us;
        elapsedUs = diff > (uint64_t)INT64_MAX ? INT64_MAX : (int64_t)diff;
    }
    double basePosSec = (pos->position_us == INT64_MIN) ? -INFINITY :
                        (pos->position_us == INT64_MAX) ? INFINITY :
                        ((double)pos->position_us / 1000000.0);
    double durSec = CuriumPiPMediaPositionDurationSeconds(pos);
    double posSec = basePosSec;
    if (isfinite(pos->playback_rate) && pos->playback_rate != 0.0 && elapsedUs > 0) {
        posSec += ((double)elapsedUs / 1000000.0) * pos->playback_rate;
    }
    if (isnan(posSec) || posSec < 0.0) {
        posSec = 0.0;
    }
    if (isfinite(durSec) && durSec >= 0.0 && posSec > durSec) {
        posSec = durSec;
    } else if (durSec < 0.0 && isfinite(durSec)) {
        posSec = 0.0;
    }
    return posSec;
}

static inline void CuriumPiPFlushVideoRendererOnRenderQueue(id bridge) {
    AVSampleBufferVideoRenderer *renderer = CuriumPiPReadObjectIvar(bridge, gIvarRenderRenderer);
    if (renderer) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [renderer flush];
        #pragma clang diagnostic pop
    }
    *(int *)CuriumIvarAddress(bridge, gIvarConsecutiveFailures) = 0;
    *(BOOL *)CuriumIvarAddress(bridge, gIvarRenderTimebasePrimed) = NO;
}

static inline void CuriumPiPRepairRenderPlaybackRateBeforeDrain(id bridge) {
    BOOL renderPaused = CuriumPiPReadBoolIvar(bridge, gIvarRenderPlaybackPaused);
    double *renderRatePtr = (double *)CuriumIvarAddress(bridge, gIvarRenderPlaybackRate);
    double effRate = CuriumPiPSanitizedRate(renderPaused, *renderRatePtr);
    if (*renderRatePtr != effRate) {
        *renderRatePtr = effRate;
    }
}

static inline void CuriumPiPRepairRenderTimebaseRateIfNeeded(id bridge) {
    BOOL renderPaused = CuriumPiPReadBoolIvar(bridge, gIvarRenderPlaybackPaused);
    if (renderPaused) {
        return;
    }
    CMTimebaseRef tb = CuriumPiPReadRenderTimebase(bridge);
    if (!tb) {
        return;
    }
    double tbRate = CMTimebaseGetRate(tb);
    if (!isfinite(tbRate) || tbRate <= 0.0) {
        double renderRate = CuriumPiPReadDoubleIvar(bridge, gIvarRenderPlaybackRate);
        CMTimebaseSetRate(tb, CuriumPiPSanitizedRate(NO, renderRate));
    }
}

static os_unfair_lock gCuriumPiPTrackerAssocLock = OS_UNFAIR_LOCK_INIT;

static CuriumPiPSkipTracker *CuriumPiPTrackerForBridge(id bridge) {
    os_unfair_lock_lock(&gCuriumPiPTrackerAssocLock);
    CuriumPiPSkipTracker *tracker = objc_getAssociatedObject(bridge, &kCuriumPiPTrackerAssocKey);
    if (!tracker) {
        tracker = [[CuriumPiPSkipTracker alloc] init];
        objc_setAssociatedObject(bridge, &kCuriumPiPTrackerAssocKey, tracker,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    os_unfair_lock_unlock(&gCuriumPiPTrackerAssocLock);
    return tracker;
}

static void CuriumPiPConfigureNonLinearPlaybackAtInit(id bridge) {
    AVPictureInPictureController *pip = CuriumPiPReadObjectIvar(bridge, gIvarPipController);
    if (!pip) {
        return;
    }
    // Configure requiresLinearPlayback = NO once at controller creation time.
    // AVKit's AVPictureInPicturePlatformAdapter automatically marks infinite
    // live time ranges ([0, +Inf)) as live/linear without mutating this property
    // mid-transition after PiP has started.
    if (pip.requiresLinearPlayback) {
        pip.requiresLinearPlayback = NO;
    }
}

static void CuriumPiPAnchorTimebase(CMTimebaseRef _Nullable tb, double seconds, double rate) {
    if (!tb || !isfinite(seconds)) {
        return;
    }
    double safeRate = isfinite(rate) && rate >= 0.0 ? rate : 0.0;
    CMTime anchor = CMTimeMakeWithSeconds(seconds, 1000000);
    CMTime hostNow = CMClockGetTime(CMClockGetHostTimeClock());
    CMTimebaseSetRateAndAnchorTime(tb, safeRate, anchor, hostNow);
}

static BOOL CuriumPiPInvokeNativeSeekTo(id bridge, double targetSeconds, NSString *_Nonnull *_Nullable outReason) {
    if (!bridge || !isfinite(targetSeconds) || targetSeconds < 0.0) {
        if (outReason) *outReason = @"invalid-target";
        return NO;
    }
    if (![NSThread isMainThread]) {
        __weak id weakBridge = bridge;
        dispatch_async(dispatch_get_main_queue(), ^{
            id strongBridge = weakBridge;
            if (strongBridge) {
                NSString *asyncReason = nil;
                BOOL ok = CuriumPiPInvokeNativeSeekTo(strongBridge, targetSeconds, &asyncReason);
                CuriumPiPLog(@"seek(async) target=%.2f ok=%d reason=%@",
                             targetSeconds, ok ? 1 : 0, asyncReason ?: @"ok");
            }
        });
        if (outReason) *outReason = @"dispatched-main";
        return YES;
    }

    const CuriumPiPWeakPtrLayout *weakOwner =
        (const CuriumPiPWeakPtrLayout *)CuriumIvarAddress(bridge, gIvarOwner);
    if (!weakOwner || !weakOwner->flag || !weakOwner->ptr) {
        if (outReason) *outReason = @"null-owner";
        return NO;
    }
    // Release-build base::internal::WeakReference::Flag::IsValid():
    // invalidated_ is an atomic uint8_t at flag + 4 (0 == valid).
    uint8_t invalidated = __atomic_load_n(
        (const uint8_t *)weakOwner->flag + kWeakFlagInvalidatedOffset,
        __ATOMIC_ACQUIRE);
    if (invalidated != 0) {
        if (outReason) *outReason = @"owner-invalidated";
        return NO;
    }

    void *controller = *(void *const *)((const uint8_t *)weakOwner->ptr + kOverlayWindowControllerOffset);
    if (!controller) {
        if (outReason) *outReason = @"null-controller";
        return NO;
    }

    // Verify the exact runtime preconditions checked inside
    // VideoPictureInPictureWindowControllerImpl::SeekTo so neither branch can
    // dereference NULL or trip CHECK(media_player_remote_.is_bound()).
    uint8_t seekToHandled =
        *(const uint8_t *)((const uint8_t *)controller + kControllerSeekToHandledOffset);
    if (seekToHandled != 0) {
        void *webContents = *(void *const *)((const uint8_t *)controller + kControllerWebContentsOffset);
        if (!webContents) {
            if (outReason) *outReason = @"null-webcontents";
            return NO;
        }
    } else {
        void *activeSession = *(void *const *)((const uint8_t *)controller + kControllerActiveSessionOffset);
        if (!activeSession) {
            if (outReason) *outReason = @"null-session";
            return NO;
        }
        void *remoteState = *(void *const *)((const uint8_t *)activeSession + kSessionMediaPlayerBoundOffset);
        void *remoteProxy = *(void *const *)((const uint8_t *)activeSession + kSessionMediaPlayerProxyOffset);
        if (!remoteState || !remoteProxy) {
            if (outReason) *outReason = @"unbound-remote";
            return NO;
        }
    }

    void *const *vtable = *(void *const *const *)controller;
    if (!vtable) {
        if (outReason) *outReason = @"null-vtable";
        return NO;
    }
    typedef void (*SeekToFn)(void *controller, int64_t microseconds);
    SeekToFn seekTo = (SeekToFn)vtable[kControllerSeekToVtableSlot];
    if (!seekTo) {
        if (outReason) *outReason = @"null-seekto";
        return NO;
    }

    int64_t targetMicros = (int64_t)llround(targetSeconds * 1000000.0);
    if (targetMicros < 0) {
        targetMicros = 0;
    }
    seekTo(controller, targetMicros);
    if (outReason) *outReason = seekToHandled ? @"media-session" : @"player-remote";
    return YES;
}

static BOOL CuriumPiPIsPointerInChromeFramework(const void *ptr) {
    if (!ptr) {
        return NO;
    }
    static dispatch_once_t onceToken;
    static uintptr_t sImageStart = 0;
    static uintptr_t sImageEnd = 0;
    dispatch_once(&onceToken, ^{
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const char *name = _dyld_get_image_name(i);
            if (!name || !strstr(name, "chrome_framework.framework/chrome_framework")) {
                continue;
            }
            const struct mach_header_64 *hdr =
                (const struct mach_header_64 *)_dyld_get_image_header(i);
            if (!hdr || hdr->magic != MH_MAGIC_64) {
                continue;
            }
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            uintptr_t low = UINTPTR_MAX;
            uintptr_t high = 0;
            const uint8_t *cmdPtr = (const uint8_t *)(hdr + 1);
            for (uint32_t c = 0; c < hdr->ncmds; c++) {
                const struct load_command *lc = (const struct load_command *)cmdPtr;
                if (lc->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *seg =
                        (const struct segment_command_64 *)cmdPtr;
                    if (seg->vmsize > 0 && strcmp(seg->segname, "__PAGEZERO") != 0) {
                        uintptr_t segStart = (uintptr_t)((intptr_t)seg->vmaddr + slide);
                        uintptr_t segEnd = segStart + (uintptr_t)seg->vmsize;
                        if (segStart < low) low = segStart;
                        if (segEnd > high) high = segEnd;
                    }
                }
                cmdPtr += lc->cmdsize;
            }
            if (low < high) {
                sImageStart = low;
                sImageEnd = high;
            }
            break;
        }
    });
    uintptr_t addr = (uintptr_t)ptr;
    return sImageStart != 0 && addr >= sImageStart && addr < sImageEnd;
}

// Resolves a zero-copy CVPixelBufferRef from a Build 40 STORAGE_OPAQUE
// VideoFrame backed by ClientSharedImage -> MappableBufferIOSurface (used by
// GpuMemoryBufferVideoFramePool for software-decoded AV1/VP9/H.264 streams and
// iOS Simulator frames when VideoToolbox's ios_pip_buffer_token is absent).
// Caller must hold _slotLock so `framePtr` stays alive throughout inspection.
static CVPixelBufferRef _Nullable CuriumPiPCopyPixelBufferFromSharedImageLocked(
    const void *framePtr) {
    const uint8_t *vf = (const uint8_t *)framePtr;
    for (int hop = 0; hop < 4 && vf != NULL; hop++) {
        const uint8_t *wrapped = *(const uint8_t *const *)(vf + kVideoFrameWrappedFrameOffset);
        if (!wrapped) {
            break;
        }
        vf = wrapped;
    }
    if (!vf) {
        return NULL;
    }
    if (*(const uint32_t *)(vf + kVideoFrameStorageTypeOffset) != kVideoFrameStorageOpaque) {
        return NULL;
    }
    int32_t codedW = *(const int32_t *)(vf + kVideoFrameCodedWidthOffset);
    int32_t codedH = *(const int32_t *)(vf + kVideoFrameCodedHeightOffset);
    if (codedW <= 0 || codedW > 8192 || codedH <= 0 || codedH > 8192) {
        return NULL;
    }
    const uint8_t *si = *(const uint8_t *const *)(vf + kVideoFrameSharedImageOffset);
    if (!si) {
        return NULL;
    }
    const uint8_t *mb = *(const uint8_t *const *)(si + kClientSharedImageMappableBufferOffset);
    if (!mb) {
        return NULL;
    }
    const void *vtable = *(const void *const *)mb;
    if (!CuriumPiPIsPointerInChromeFramework(vtable)) {
        return NULL;
    }
    int32_t mbW = *(const int32_t *)(mb + kMappableBufferWidthOffset);
    int32_t mbH = *(const int32_t *)(mb + kMappableBufferHeightOffset);
    if (mbW < codedW || mbH < codedH || mbW > 8192 || mbH > 8192 ||
        *(const uint64_t *)(mb + kMappableBufferTypeOffset) != kGpuMemoryBufferTypeIOSurface) {
        return NULL;
    }
    void *surfPtr = *(void *const *)(mb + kMappableBufferIOSurfaceOffset);
    if (!surfPtr || CFGetTypeID((CFTypeRef)surfPtr) != IOSurfaceGetTypeID()) {
        return NULL;
    }
    IOSurfaceRef surf = (IOSurfaceRef)surfPtr;
    if (IOSurfaceGetWidth(surf) != (size_t)mbW ||
        IOSurfaceGetHeight(surf) != (size_t)mbH) {
        return NULL;
    }
    CVPixelBufferRef pb = NULL;
    CVReturn cr = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surf, NULL, &pb);
    return (cr == kCVReturnSuccess && pb != NULL) ? pb : NULL;
}

static void CuriumPiPEnsurePlaybackAudioSession(void) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    AVAudioSessionCategory cat = session.category;
    if (![cat isEqualToString:AVAudioSessionCategoryPlayback] &&
        ![cat isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
        [session setCategory:AVAudioSessionCategoryPlayback
                        mode:AVAudioSessionModeDefault
                     options:0
                       error:nil];
    }
    [session setActive:YES error:nil];
}

static void CuriumPiPHookPrepareHost(id self, SEL _cmd, UIWindow *window,
                                     CuriumPiPIntSize naturalSize, uint64_t generation) {
    CuriumPiPEnsurePlaybackAudioSession();
    gOrigPrepareHost(self, _cmd, window, naturalSize, generation);
    dispatch_queue_t renderQueue = CuriumPiPReadObjectIvar(self, gIvarRenderQueue);
    if (renderQueue &&
        dispatch_queue_get_specific(renderQueue, &kCuriumRenderQueueSpecificKey) == NULL) {
        dispatch_queue_set_specific(renderQueue, &kCuriumRenderQueueSpecificKey,
                                    (void *)&kCuriumRenderQueueSpecificKey, NULL);
    }

    CuriumPiPSkipTracker *tracker = CuriumPiPTrackerForBridge(self);
    [tracker noteGeneration:generation];
    CuriumPiPConfigureNonLinearPlaybackAtInit(self);
    AVPictureInPictureController *pip = CuriumPiPReadObjectIvar(self, gIvarPipController);
    double dur = CuriumPiPReadDoubleIvar(self, gIvarMainDurationSeconds);
    CuriumPiPLog(@"prepareHost gen=%llu size=%dx%d dur=%.1f pip=%d linear=%d",
                 generation, naturalSize.width, naturalSize.height, dur,
                 pip != nil ? 1 : 0, pip.requiresLinearPlayback ? 1 : 0);
}

static void CuriumPiPHookUpdatePlaybackPaused(id self, SEL _cmd, BOOL paused,
                                              const void *positionPtr) {
    (void)_cmd;
    paused = paused ? YES : NO;
    const CuriumPiPMediaPositionOptionalLayout *posOpt =
        (const CuriumPiPMediaPositionOptionalLayout *)positionPtr;
    BOOL hasPosition = (posOpt != NULL) && (posOpt->engaged != 0);

    BOOL prevPaused = CuriumPiPReadBoolIvar(self, gIvarMainPlaybackPaused);
    double prevDur = CuriumPiPReadDoubleIvar(self, gIvarMainDurationSeconds);
    double prevMainRate = CuriumPiPReadDoubleIvar(self, gIvarMainPlaybackRate);
    double posSec = CuriumPiPReadDoubleIvar(self, gIvarMainPositionSeconds);
    double dur = prevDur;
    double rawRate = paused ? 0.0 : (isfinite(prevMainRate) && prevMainRate > 0.0 ? prevMainRate : 1.0);

    *(BOOL *)CuriumIvarAddress(self, gIvarMainPlaybackPaused) = paused;
    if (hasPosition) {
        int64_t nowTicksUs = CuriumPiPCurrentTimeTicksMicroseconds();
        dur = CuriumPiPMediaPositionDurationSeconds(posOpt);
        rawRate = paused ? 0.0 : posOpt->playback_rate;
        posSec = CuriumPiPComputeMediaPositionSeconds(posOpt, nowTicksUs);

        *(double *)CuriumIvarAddress(self, gIvarMainDurationSeconds) = dur;
        *(double *)CuriumIvarAddress(self, gIvarMainPositionSeconds) = posSec;
        *(int64_t *)CuriumIvarAddress(self, gIvarMainPositionTimestamp) = nowTicksUs;
    }

    double effectiveRate = CuriumPiPSanitizedRate(paused, rawRate);
    *(double *)CuriumIvarAddress(self, gIvarMainPlaybackRate) = effectiveRate;

    uint64_t generation = CuriumPiPReadUInt64Ivar(self, gIvarActiveGeneration);
    CuriumPiPSkipTracker *tracker = CuriumPiPTrackerForBridge(self);
    [tracker recordPlaybackUpdateWithGeneration:generation
                                         paused:paused
                                           rate:rawRate
                                    hasPosition:hasPosition
                                positionSeconds:posSec
                                durationSeconds:dur
                                            now:CACurrentMediaTime()];

    // NEVER call gOrigUpdatePlayback or CMTimebaseSetRateAndAnchorTime with
    // zero-based posSec here: on high-PTS HLS streams that slams controlTimebase
    // backward by hours and tricks AVKit into ending playback. Only update
    // _renderPlaybackPaused, _renderPlaybackRate, and CMTimebaseSetRate.
    dispatch_queue_t renderQueue = CuriumPiPReadObjectIvar(self, gIvarRenderQueue);
    if (renderQueue) {
        __weak id weakSelf = self;
        dispatch_async(renderQueue, ^{
            id strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (CuriumPiPReadAtomicUInt64Ivar(strongSelf, gIvarAtomicGeneration) != generation) {
                return;
            }
            *(BOOL *)CuriumIvarAddress(strongSelf, gIvarRenderPlaybackPaused) = paused;
            *(double *)CuriumIvarAddress(strongSelf, gIvarRenderPlaybackRate) = effectiveRate;
            CMTimebaseRef tb = CuriumPiPReadRenderTimebase(strongSelf);
            if (tb) {
                CMTimebaseSetRate(tb, effectiveRate);
            }
        });
    }

    AVPictureInPictureController *pip = CuriumPiPReadObjectIvar(self, gIvarPipController);
    [pip invalidatePlaybackState];

    BOOL durStateChanged =
        (CuriumPiPIsSeekableDuration(prevDur) != CuriumPiPIsSeekableDuration(dur)) ||
        (isnan(prevDur) != isnan(dur)) ||
        (isinf(prevDur) != isinf(dur));
    BOOL enteredZeroRateBuffering = (!paused && hasPosition && (!isfinite(rawRate) || rawRate <= 0.0));
    if (prevPaused != paused || durStateChanged || enteredZeroRateBuffering) {
        AVSampleBufferDisplayLayer *layer = CuriumPiPReadObjectIvar(self, gIvarDisplayLayer);
        CMTimebaseRef tb = layer ? layer.controlTimebase : NULL;
        double tbSec = tb ? CMTimeGetSeconds(CMTimebaseGetTime(tb)) : NAN;
        CuriumPiPLog(@"update gen=%llu paused=%d hasPos=%d dur=%.1f pos=%.2f rawRate=%.2f effRate=%.2f tb=%.2f",
                     generation, paused ? 1 : 0, hasPosition ? 1 : 0, dur, posSec,
                     rawRate, effectiveRate, tbSec);
    }
}

static void CuriumPiPHookDrainLatestFrame(id self, SEL _cmd) {
    // Respect any genuine in-flight engine flush so we never clobber _isFlushing.
    if (CuriumPiPReadBoolIvar(self, gIvarIsFlushing)) {
        gOrigDrainFrame(self, _cmd);
        return;
    }

    // Peek _latestSlot under _slotLock to read the queued VideoFrame PTS, and
    // bridge zero-copy IOSurface-backed ClientSharedImage frames (AV1/VP9/SW
    // GpuMemoryBufferVideoFramePool & Simulator) when hw_buffer is absent.
    pthread_mutex_t *slotMutex = (pthread_mutex_t *)CuriumIvarAddress(self, gIvarSlotLock);
    uint8_t *slotBase = (uint8_t *)CuriumIvarAddress(self, gIvarLatestSlot);

    pthread_mutex_lock(slotMutex);
    uint8_t engaged = *(const uint8_t *)(slotBase + kPendingFrameSlotEngagedOffset);
    const void *framePtr = engaged
        ? *(const void *const *)(slotBase + kPendingFrameSlotFrameOffset)
        : NULL;
    uint64_t slotGen = engaged
        ? *(const uint64_t *)(slotBase + kPendingFrameSlotGenerationOffset)
        : 0;
    int64_t tsUs = framePtr
        ? *(const int64_t *)((const uint8_t *)framePtr + kVideoFrameTimestampUsOffset)
        : kMediaNoTimestampUs;
    if (engaged && framePtr &&
        *(CVPixelBufferRef *)(slotBase + kPendingFrameSlotHwBufferOffset) == NULL) {
        CVPixelBufferRef bridged = CuriumPiPCopyPixelBufferFromSharedImageLocked(framePtr);
        if (bridged) {
            *(CVPixelBufferRef *)(slotBase + kPendingFrameSlotHwBufferOffset) = bridged;
        }
    }
    pthread_mutex_unlock(slotMutex);

    if (!engaged || !framePtr || tsUs == kMediaNoTimestampUs) {
        gOrigDrainFrame(self, _cmd);
        return;
    }

    uint64_t activeGen = CuriumPiPReadAtomicUInt64Ivar(self, gIvarAtomicGeneration);
    if (activeGen != slotGen) {
        gOrigDrainFrame(self, _cmd);
        return;
    }

    double framePtsSec = (double)tsUs / 1000000.0;
    CFTimeInterval now = CACurrentMediaTime();
    CuriumPiPSkipTracker *tracker = CuriumPiPTrackerForBridge(self);
    CuriumPiPRenderFrameAction action = [tracker evaluateRenderFramePTS:framePtsSec
                                                         forGeneration:slotGen
                                                                   now:now];

    // Zero-leak stale pre-seek frame drop: temporarily setting _isFlushing = YES
    // makes Build 40's drainLatestFrameOnRenderQueue pop _latestSlot, clear
    // _drainScheduled, and release hw_buffer + VideoFrame without touching the
    // renderer or controlTimebase.
    if (action == CuriumPiPRenderFrameActionDropStalePreSeek) {
        *(BOOL *)CuriumIvarAddress(self, gIvarIsFlushing) = YES;
        gOrigDrainFrame(self, _cmd);
        *(BOOL *)CuriumIvarAddress(self, gIvarIsFlushing) = NO;
        CuriumPiPRepairRenderTimebaseRateIfNeeded(self);
        return;
    }

    AVSampleBufferVideoRenderer *renderer = CuriumPiPReadObjectIvar(self, gIvarRenderRenderer);
    BOOL needsInvalidatePlaybackState = NO;

    if (action == CuriumPiPRenderFrameActionFlushAndRenderPostSeek ||
        action == CuriumPiPRenderFrameActionFlushDiscontinuity) {
        CuriumPiPFlushVideoRendererOnRenderQueue(self);
        [tracker resetNotReadyCountForGeneration:slotGen];
        needsInvalidatePlaybackState = YES;
        if (action == CuriumPiPRenderFrameActionFlushAndRenderPostSeek) {
            CuriumPiPLog(@"seekLanded gen=%llu pts=%.2f", slotGen, framePtsSec);
        } else {
            CuriumPiPLog(@"discFlush gen=%llu pts=%.2f", slotGen, framePtsSec);
        }
    } else if (renderer) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        BOOL needsRecovery =
            (renderer.status == AVQueuedSampleBufferRenderingStatusFailed ||
             renderer.requiresFlushToResumeDecoding);
        #pragma clang diagnostic pop
        if (needsRecovery) {
            int failures = *(const int *)CuriumIvarAddress(self, gIvarConsecutiveFailures);
            CuriumPiPLog(@"flushRecovery gen=%llu pts=%.2f failures=%d",
                         slotGen, framePtsSec, failures);
        } else if (!renderer.isReadyForMoreMediaData) {
            NSUInteger notReadyCount = [tracker recordNotReadyFrameForGeneration:slotGen];
            if (notReadyCount >= kCuriumPiPNotReadyFlushThreshold) {
                CuriumPiPFlushVideoRendererOnRenderQueue(self);
                [tracker resetNotReadyCountForGeneration:slotGen];
                needsInvalidatePlaybackState = YES;
                CuriumPiPLog(@"notReadyFlush gen=%llu pts=%.2f count=%lu",
                             slotGen, framePtsSec, (unsigned long)notReadyCount);
            }
        } else {
            [tracker resetNotReadyCountForGeneration:slotGen];
        }
    }

    CuriumPiPRepairRenderPlaybackRateBeforeDrain(self);
    gOrigDrainFrame(self, _cmd);
    CuriumPiPRepairRenderTimebaseRateIfNeeded(self);

    if (needsInvalidatePlaybackState) {
        __weak id weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            id strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            if (CuriumPiPReadAtomicUInt64Ivar(strongSelf, gIvarAtomicGeneration) != slotGen) {
                return;
            }
            AVPictureInPictureController *pip = CuriumPiPReadObjectIvar(strongSelf, gIvarPipController);
            [pip invalidatePlaybackState];
        });
    }
}

static CMTimeRange CuriumPiPHookTimeRangeForPlayback(id self, SEL _cmd,
                                                     AVPictureInPictureController *pipController) {
    (void)_cmd;
    (void)pipController;
    double dur = CuriumPiPReadDoubleIvar(self, gIvarMainDurationSeconds);
    if (!CuriumPiPIsSeekableDuration(dur)) {
        return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
    }

    uint64_t generation = CuriumPiPReadUInt64Ivar(self, gIvarActiveGeneration);
    BOOL paused = CuriumPiPReadBoolIvar(self, gIvarMainPlaybackPaused);
    double rate = CuriumPiPReadDoubleIvar(self, gIvarMainPlaybackRate);
    double posSec = CuriumPiPReadDoubleIvar(self, gIvarMainPositionSeconds);

    CuriumPiPSkipTracker *tracker = CuriumPiPTrackerForBridge(self);
    double estPos = [tracker estimatedPositionWithGeneration:generation
                                         fallbackPositionSec:posSec
                                             durationSeconds:dur
                                                      paused:paused
                                                playbackRate:rate
                                                         now:CACurrentMediaTime()];

    AVSampleBufferDisplayLayer *layer = CuriumPiPReadObjectIvar(self, gIvarDisplayLayer);
    CMTimebaseRef tb = layer ? layer.controlTimebase : NULL;
    double tbSec = tb ? CMTimeGetSeconds(CMTimebaseGetTime(tb)) : NAN;
    return CuriumPiPComputePlayableTimeRange(dur, estPos, tbSec);
}

static void CuriumPiPHookSkipByInterval(id self, SEL _cmd,
                                        AVPictureInPictureController *pipController,
                                        CMTime skipInterval,
                                        void (^completionHandler)(void)) {
    (void)_cmd;
    AVPictureInPictureController *ownedPip = CuriumPiPReadObjectIvar(self, gIvarPipController);
    if (!ownedPip || pipController != ownedPip) {
        if (completionHandler) {
            completionHandler();
        }
        return;
    }

    double dur = CuriumPiPReadDoubleIvar(self, gIvarMainDurationSeconds);
    if (!CuriumPiPIsSeekableDuration(dur) || !CMTIME_IS_NUMERIC(skipInterval)) {
        if (completionHandler) {
            completionHandler();
        }
        return;
    }

    double deltaSec = CMTimeGetSeconds(skipInterval);
    if (!isfinite(deltaSec)) {
        if (completionHandler) {
            completionHandler();
        }
        return;
    }

    uint64_t generation = CuriumPiPReadUInt64Ivar(self, gIvarActiveGeneration);
    CuriumPiPSkipTracker *tracker = CuriumPiPTrackerForBridge(self);
    BOOL rawMainPaused = CuriumPiPReadBoolIvar(self, gIvarMainPlaybackPaused);
    BOOL paused = [tracker effectivePausedForSkipWithCurrentPaused:rawMainPaused
                                                        generation:generation];
    double rate = CuriumPiPReadDoubleIvar(self, gIvarMainPlaybackRate);
    double effRate = CuriumPiPSanitizedRate(paused, rate);
    double posSec = CuriumPiPReadDoubleIvar(self, gIvarMainPositionSeconds);

    AVSampleBufferDisplayLayer *layer = CuriumPiPReadObjectIvar(self, gIvarDisplayLayer);
    CMTimebaseRef tb = layer ? layer.controlTimebase : NULL;
    double tbBefore = tb ? CMTimeGetSeconds(CMTimebaseGetTime(tb)) : NAN;

    double targetTb = 0.0;
    double targetSec = [tracker beginSkipWithGeneration:generation
                                           deltaSeconds:deltaSec
                                    fallbackPositionSec:posSec
                                        durationSeconds:dur
                                                 paused:paused
                                           playbackRate:effRate
                                        timebaseSeconds:tbBefore
                                                    now:CACurrentMediaTime()
                               outTargetTimebaseSeconds:&targetTb];

    NSString *seekReason = nil;
    BOOL seekSent = CuriumPiPInvokeNativeSeekTo(self, targetSec, &seekReason);

    // Synchronously flush stale sample buffers on _renderQueue and anchor
    // _renderTimebase before completionHandler() and invalidatePlaybackState.
    // _renderQueue never dispatches synchronously back to the main thread, so
    // Main -> _renderQueue -> _lock/_slotLock is strictly acyclic.
    dispatch_queue_t renderQueue = CuriumPiPReadObjectIvar(self, gIvarRenderQueue);
    void (^flushAndAnchor)(void) = ^{
        if (CuriumPiPReadAtomicUInt64Ivar(self, gIvarAtomicGeneration) != generation) {
            return;
        }
        CuriumPiPFlushVideoRendererOnRenderQueue(self);
        *(BOOL *)CuriumIvarAddress(self, gIvarRenderPlaybackPaused) = paused;
        *(double *)CuriumIvarAddress(self, gIvarRenderPlaybackRate) = effRate;
        CMTimebaseRef renderTb = CuriumPiPReadRenderTimebase(self);
        CuriumPiPAnchorTimebase(renderTb ? renderTb : tb, targetTb, effRate);
    };
    if (renderQueue &&
        dispatch_get_specific(&kCuriumRenderQueueSpecificKey) != &kCuriumRenderQueueSpecificKey) {
        dispatch_sync(renderQueue, flushAndAnchor);
    } else if (renderQueue) {
        flushAndAnchor();
    } else {
        CuriumPiPAnchorTimebase(tb, targetTb, effRate);
    }

    CuriumPiPLog(@"skip gen=%llu delta=%.1f paused=%d pos=%.2f->%.2f tb=%.2f->%.2f sent=%d (%@)",
                 generation, deltaSec, paused ? 1 : 0, posSec, targetSec, tbBefore, targetTb,
                 seekSent ? 1 : 0, seekReason ?: @"unknown");

    // Invoke completionHandler() BEFORE invalidatePlaybackState so AVKit's
    // post-seek togglePlaybackEvenWhenInBackground: observes the transient
    // paused state from pre-seek setPlaying:NO and toggles back to playing=YES
    // (cancelling the coalesced pause without ever pausing Chromium).
    if (completionHandler) {
        completionHandler();
    }
    [ownedPip invalidatePlaybackState];
}

static NSString *CuriumPiPSessionStateSummary(id bridge) {
    if (![NSThread isMainThread]) {
        return @"bg-thread";
    }
    const CuriumPiPWeakPtrLayout *weakOwner =
        (const CuriumPiPWeakPtrLayout *)CuriumIvarAddress(bridge, gIvarOwner);
    if (!weakOwner || !weakOwner->flag || !weakOwner->ptr) {
        return @"owner=nil";
    }
    uint8_t invalidated = __atomic_load_n(
        (const uint8_t *)weakOwner->flag + kWeakFlagInvalidatedOffset,
        __ATOMIC_ACQUIRE);
    if (invalidated != 0) {
        return @"owner=dead";
    }
    void *controller = *(void *const *)((const uint8_t *)weakOwner->ptr + kOverlayWindowControllerOffset);
    if (!controller) {
        return @"ctrl=nil";
    }
    void *activeSession = *(void *const *)((const uint8_t *)controller + kControllerActiveSessionOffset);
    void *pendingStart = *(void *const *)((const uint8_t *)controller + kControllerPendingNativeStartOffset);
    if (!activeSession) {
        return [NSString stringWithFormat:@"sess=0 pend=%d", pendingStart != NULL ? 1 : 0];
    }
    uint8_t hasPid = *(const uint8_t *)((const uint8_t *)activeSession + kSessionHasPlayerIdOffset);
    uint8_t isStopping = *(const uint8_t *)((const uint8_t *)activeSession + kSessionIsStoppingOffset);
    void *mpState = *(void *const *)((const uint8_t *)activeSession + kSessionMediaPlayerBoundOffset);
    return [NSString stringWithFormat:@"sess=1(stop=%u,pid=%u,mp=%d) pend=%d",
            isStopping, hasPid, mpState != NULL ? 1 : 0, pendingStart != NULL ? 1 : 0];
}

static NSString *CuriumPiPFormatStopDetachCallstack(void) {
    void *frames[8];
    int count = backtrace(frames, 8);
    if (count <= 1) {
        return @"none";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:4];
    int limit = count < 5 ? count : 5;
    for (int i = 1; i < limit; ++i) {
        Dl_info info;
        if (dladdr(frames[i], &info) && info.dli_fname && info.dli_fbase) {
            const char *base = strrchr(info.dli_fname, '/');
            const char *img = base ? base + 1 : info.dli_fname;
            uintptr_t off = (uintptr_t)frames[i] - (uintptr_t)info.dli_fbase;
            if (strcmp(img, "chrome_framework") == 0) {
                [parts addObject:[NSString stringWithFormat:@"cf+0x%lx", (unsigned long)off]];
            } else if (info.dli_sname) {
                [parts addObject:[NSString stringWithFormat:@"%s:%s+0x%lx",
                                  img, info.dli_sname,
                                  (unsigned long)((uintptr_t)frames[i] - (uintptr_t)info.dli_saddr)]];
            } else {
                [parts addObject:[NSString stringWithFormat:@"%s+0x%lx", img, (unsigned long)off]];
            }
        } else {
            [parts addObject:[NSString stringWithFormat:@"0x%lx", (unsigned long)(uintptr_t)frames[i]]];
        }
    }
    return [parts componentsJoinedByString:@","];
}

static void CuriumPiPHookStopDetach(id self, SEL _cmd, BOOL removeImage) {
    uint64_t gen = CuriumPiPReadUInt64Ivar(self, gIvarActiveGeneration);
    BOOL pipActive = CuriumPiPReadBoolIvar(self, gIvarPipActive);
    AVPictureInPictureController *pip = CuriumPiPReadObjectIvar(self, gIvarPipController);
    NSString *sess = CuriumPiPSessionStateSummary(self);
    NSString *bt = CuriumPiPFormatStopDetachCallstack();
    CuriumPiPLog(@"stopDetach gen=%llu rm=%d pip=%d av=%d %@ bt=[%@]",
                 gen, removeImage ? 1 : 0, pipActive ? 1 : 0,
                 pip.isPictureInPictureActive ? 1 : 0, sess, bt);
    gOrigStopDetach(self, _cmd, removeImage);
}

static void CuriumPiPHookDidStart(id self, SEL _cmd, AVPictureInPictureController *pip) {
    AVPictureInPictureController *owned = CuriumPiPReadObjectIvar(self, gIvarPipController);
    uint64_t gen = CuriumPiPReadUInt64Ivar(self, gIvarActiveGeneration);
    BOOL attemptActive = gIvarStartAttemptActive ? CuriumPiPReadBoolIvar(self, gIvarStartAttemptActive) : NO;
    uint64_t attemptGen = gIvarStartAttemptGeneration ? CuriumPiPReadUInt64Ivar(self, gIvarStartAttemptGeneration) : 0;
    CuriumPiPLog(@"didStart gen=%llu attemptGen=%llu attemptActive=%d samePip=%d linear=%d",
                 gen, attemptGen, attemptActive ? 1 : 0, pip == owned ? 1 : 0,
                 pip.requiresLinearPlayback ? 1 : 0);
    gOrigDidStart(self, _cmd, pip);
}

static void CuriumPiPHookFailedToStart(id self, SEL _cmd, AVPictureInPictureController *pip, NSError *error) {
    uint64_t gen = CuriumPiPReadUInt64Ivar(self, gIvarActiveGeneration);
    CuriumPiPLog(@"failedToStart gen=%llu err=%@(%ld) %@",
                 gen, error.domain ?: @"nil", (long)error.code,
                 error.localizedDescription ?: @"");
    gOrigFailedToStart(self, _cmd, pip, error);
}

static void CuriumPiPHookDidStop(id self, SEL _cmd, AVPictureInPictureController *pip) {
    uint64_t gen = CuriumPiPReadUInt64Ivar(self, gIvarActiveGeneration);
    BOOL pipActive = CuriumPiPReadBoolIvar(self, gIvarPipActive);
    CuriumPiPLog(@"didStop gen=%llu pipActive=%d", gen, pipActive ? 1 : 0);
    gOrigDidStop(self, _cmd, pip);
}

static void CuriumPiPHookSetPlaying(id self, SEL _cmd, AVPictureInPictureController *pip, BOOL playing) {
    AVPictureInPictureController *ownedPip = CuriumPiPReadObjectIvar(self, gIvarPipController);
    if (!ownedPip || pip != ownedPip) {
        if (gOrigSetPlaying) {
            gOrigSetPlaying(self, _cmd, pip, playing);
        }
        return;
    }

    playing = playing ? YES : NO;
    uint64_t gen = CuriumPiPReadUInt64Ivar(self, gIvarActiveGeneration);
    BOOL prevPaused = CuriumPiPReadBoolIvar(self, gIvarMainPlaybackPaused);

    // Satisfy AVKit's synchronous AVPictureInPictureSampleBufferPlaybackDelegate
    // contract: -[AVSampleBufferDisplayLayerPlayerController setPlaying:] calls
    // -[self invalidatePlaybackState] immediately after this delegate returns
    // and queries pictureInPictureControllerIsPlaybackPaused:. Without updating
    // _mainPlaybackPaused synchronously, AVKit's seekByTimeInterval: completion
    // block sees isPlaying == YES and toggles playback OFF instead of resuming.
    *(BOOL *)CuriumIvarAddress(self, gIvarMainPlaybackPaused) = !playing;

    CuriumPiPSkipTracker *tracker = CuriumPiPTrackerForBridge(self);
    BOOL shouldSchedule = NO;
    uint64_t token = [tracker recordSetPlaying:playing
                                 currentPaused:prevPaused
                                 forGeneration:gen
                           shouldScheduleFlush:&shouldSchedule];

    if (!shouldSchedule) {
        CuriumPiPLog(@"setPlaying gen=%llu playing=%d (coalesced-noop)", gen, playing ? 1 : 0);
        return;
    }

    CuriumPiPLog(@"setPlaying gen=%llu playing=%d (scheduled)", gen, playing ? 1 : 0);
    __weak id weakSelf = self;
    __weak AVPictureInPictureController *weakPip = pip;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strongSelf = weakSelf;
        AVPictureInPictureController *strongPip = weakPip;
        if (!strongSelf || !strongPip) {
            return;
        }
        if (CuriumPiPReadUInt64Ivar(strongSelf, gIvarActiveGeneration) != gen ||
            CuriumPiPReadObjectIvar(strongSelf, gIvarPipController) != strongPip) {
            return;
        }
        BOOL targetPlaying = NO;
        if (![tracker consumePendingSetPlayingForToken:token generation:gen outPlaying:&targetPlaying]) {
            return;
        }
        *(BOOL *)CuriumIvarAddress(strongSelf, gIvarMainPlaybackPaused) = !targetPlaying;
        CuriumPiPLog(@"setPlaying gen=%llu playing=%d (dispatched)", gen, targetPlaying ? 1 : 0);
        if (gOrigSetPlaying) {
            gOrigSetPlaying(strongSelf, _cmd, strongPip, targetPlaying);
        }
    });
}

void CuriumInstallPiPSkipHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"CuriumPiPBridge");
        if (!cls) {
            CuriumRecordHookStatus(kCuriumPiPHookName, @"skipped",
                                   @"CuriumPiPBridge class not present");
            return;
        }

        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(cls, &ivarCount);
        free(ivars);
        if (ivarCount != kExpectedBuild40IvarCount) {
            CuriumRecordHookStatus(
                kCuriumPiPHookName, @"skipped",
                [NSString stringWithFormat:@"CuriumPiPBridge ivar count mismatch (%u != %u)",
                 ivarCount, kExpectedBuild40IvarCount]);
            return;
        }

        Ivar owner = CuriumExpectIvarAtOffset(
            cls, "_owner",
            "{WeakPtr<web::IOSVideoOverlayWindow>=\"ref_\"{WeakReference=\"flag_\"{scoped_refptr<const base::internal::WeakReference::Flag>=\"ptr_\"^{Flag}}}\"ptr_\"^{IOSVideoOverlayWindow}}",
            kExpectedOffsetOwner);
        Ivar renderQueue = CuriumExpectIvarAtOffset(
            cls, "_renderQueue", "@\"NSObject<OS_dispatch_queue>\"", kExpectedOffsetRenderQueue);
        Ivar displayLayer = CuriumExpectIvarAtOffset(
            cls, "_displayLayer", "@\"AVSampleBufferDisplayLayer\"", kExpectedOffsetDisplayLayer);
        Ivar pipController = CuriumExpectIvarAtOffset(
            cls, "_pipController", "@\"AVPictureInPictureController\"", kExpectedOffsetPipController);
        Ivar pipActive = CuriumExpectIvarAtOffset(
            cls, "_pipActive", "B", kExpectedOffsetPipActive);
        Ivar mainPaused = CuriumExpectIvarAtOffset(
            cls, "_mainPlaybackPaused", "B", kExpectedOffsetMainPlaybackPaused);
        Ivar mainDuration = CuriumExpectIvarAtOffset(
            cls, "_mainDurationSeconds", "d", kExpectedOffsetMainDurationSeconds);
        Ivar mainRate = CuriumExpectIvarAtOffset(
            cls, "_mainPlaybackRate", "d", kExpectedOffsetMainPlaybackRate);
        Ivar mainPosition = CuriumExpectIvarAtOffset(
            cls, "_mainPositionSeconds", "d", kExpectedOffsetMainPositionSeconds);
        Ivar mainPositionTs = CuriumExpectIvarAtOffset(
            cls, "_mainPositionTimestamp",
            "{TimeTicks=\"us_\"{ClampedNumeric<long long>=\"value_\"q}}",
            kExpectedOffsetMainPositionTimestamp);
        Ivar activeGen = CuriumExpectIvarAtOffset(
            cls, "_activeGeneration", "Q", kExpectedOffsetActiveGeneration);
        Ivar atomicGen = CuriumExpectIvarAtOffset(
            cls, "_atomicGeneration",
            "{atomic<unsigned long long>=\"__a_\"{__cxx_atomic_impl<unsigned long long, std::__cxx_atomic_base_impl<unsigned long long>>=\"__a_value\"AQ}}",
            kExpectedOffsetAtomicGeneration);
        Ivar renderRenderer = CuriumExpectIvarAtOffset(
            cls, "_renderRenderer", "@\"AVSampleBufferVideoRenderer\"", kExpectedOffsetRenderRenderer);
        Ivar renderTb = CuriumExpectIvarAtOffset(
            cls, "_renderTimebase",
            "{ScopedTypeRef<OpaqueCMTimebase *, base::apple::internal::ScopedCFTypeRefTraits<OpaqueCMTimebase *>>=\"object_\"^{OpaqueCMTimebase}}",
            kExpectedOffsetRenderTimebase);
        Ivar renderPaused = CuriumExpectIvarAtOffset(
            cls, "_renderPlaybackPaused", "B", kExpectedOffsetRenderPlaybackPaused);
        Ivar renderRate = CuriumExpectIvarAtOffset(
            cls, "_renderPlaybackRate", "d", kExpectedOffsetRenderPlaybackRate);
        Ivar renderTbPrimed = CuriumExpectIvarAtOffset(
            cls, "_renderTimebasePrimed", "B", kExpectedOffsetRenderTimebasePrimed);
        Ivar isFlushing = CuriumExpectIvarAtOffset(
            cls, "_isFlushing", "B", kExpectedOffsetIsFlushing);
        Ivar consecutiveFailures = CuriumExpectIvarAtOffset(
            cls, "_consecutiveFailures", "i", kExpectedOffsetConsecutiveFailures);
        Ivar slotLock = CuriumExpectIvarAtOffset(
            cls, "_slotLock",
            "{Lock=\"lock_\"{LockImpl=\"native_handle_\"{_opaque_pthread_mutex_t=\"__sig\"q\"__opaque\"[56c]}}}",
            kExpectedOffsetSlotLock);
        Ivar latestSlot = CuriumExpectIvarAtOffset(
            cls, "_latestSlot",
            "{optional<(anonymous namespace)::PendingFrameSlot>=\"\"(?=\"__null_state_\"c\"__val_\"{PendingFrameSlot=\"frame\"{scoped_refptr<media::VideoFrame>=\"ptr_\"^{VideoFrame}}\"hw_buffer\"{ScopedTypeRef<__CVBuffer *, base::apple::internal::ScopedCFTypeRefTraits<__CVBuffer *>>=\"object_\"^{__CVBuffer}}\"generation\"Q})\"__engaged_\"B}",
            kExpectedOffsetLatestSlot);

        if (!owner || !renderQueue || !displayLayer || !pipController || !pipActive ||
            !mainPaused || !mainDuration || !mainRate || !mainPosition || !mainPositionTs ||
            !activeGen || !atomicGen || !renderRenderer || !renderTb || !renderPaused ||
            !renderRate || !renderTbPrimed || !isFlushing || !consecutiveFailures ||
            !slotLock || !latestSlot) {
            CuriumRecordHookStatus(kCuriumPiPHookName, @"skipped",
                                   @"CuriumPiPBridge ivar layout changed (expected Build 40)");
            return;
        }

        Method mPrepare = CuriumExpectMethod(
            cls, "prepareHostInWindow:naturalSize:generation:",
            "v40@0:8@16{Size=ii}24Q32");
        Method mUpdate = CuriumExpectMethod(
            cls, "updatePlaybackPaused:position:",
            "v68@0:8B16{optional<media_session::MediaPosition>=(?=c{MediaPosition=d{TimeDelta={ClampedNumeric<long long>=q}}{TimeDelta={ClampedNumeric<long long>=q}}{TimeTicks={ClampedNumeric<long long>=q}}B})B}20");
        Method mDrain = CuriumExpectMethod(
            cls, "drainLatestFrameOnRenderQueue", "v16@0:8");
        Method mTimeRange = CuriumExpectMethod(
            cls, "pictureInPictureControllerTimeRangeForPlayback:",
            "{?={?=qiIq}{?=qiIq}}24@0:8@16");
        Method mSkip = CuriumExpectMethod(
            cls, "pictureInPictureController:skipByInterval:completionHandler:",
            "v56@0:8@16{?=qiIq}24@?48");
        Method mSetPlaying = CuriumExpectMethod(
            cls, "pictureInPictureController:setPlaying:", "v28@0:8@16B24");

        if (!mPrepare || !mUpdate || !mDrain || !mTimeRange || !mSkip || !mSetPlaying) {
            CuriumRecordHookStatus(kCuriumPiPHookName, @"skipped",
                                   @"CuriumPiPBridge method encodings changed (expected Build 40)");
            return;
        }

        gIvarOwner = owner;
        gIvarRenderQueue = renderQueue;
        gIvarDisplayLayer = displayLayer;
        gIvarPipController = pipController;
        gIvarPipActive = pipActive;
        gIvarStartAttemptActive = CuriumExpectIvarAtOffset(
            cls, "_startAttemptActive", "B", kExpectedOffsetStartAttemptActive);
        gIvarStartAttemptGeneration = CuriumExpectIvarAtOffset(
            cls, "_startAttemptGeneration", "Q", kExpectedOffsetStartAttemptGeneration);
        gIvarMainPlaybackPaused = mainPaused;
        gIvarMainDurationSeconds = mainDuration;
        gIvarMainPlaybackRate = mainRate;
        gIvarMainPositionSeconds = mainPosition;
        gIvarMainPositionTimestamp = mainPositionTs;
        gIvarActiveGeneration = activeGen;
        gIvarAtomicGeneration = atomicGen;
        gIvarRenderRenderer = renderRenderer;
        gIvarRenderTimebase = renderTb;
        gIvarRenderPlaybackPaused = renderPaused;
        gIvarRenderPlaybackRate = renderRate;
        gIvarRenderTimebasePrimed = renderTbPrimed;
        gIvarIsFlushing = isFlushing;
        gIvarConsecutiveFailures = consecutiveFailures;
        gIvarSlotLock = slotLock;
        gIvarLatestSlot = latestSlot;

        gOrigPrepareHost = (CuriumPiPPrepareHostIMP)method_setImplementation(
            mPrepare, (IMP)CuriumPiPHookPrepareHost);
        (void)method_setImplementation(
            mUpdate, (IMP)CuriumPiPHookUpdatePlaybackPaused);
        gOrigDrainFrame = (CuriumPiPDrainFrameIMP)method_setImplementation(
            mDrain, (IMP)CuriumPiPHookDrainLatestFrame);
        (void)method_setImplementation(
            mTimeRange, (IMP)CuriumPiPHookTimeRangeForPlayback);
        (void)method_setImplementation(
            mSkip, (IMP)CuriumPiPHookSkipByInterval);
        gOrigSetPlaying = (CuriumPiPSetPlayingIMP)method_setImplementation(
            mSetPlaying, (IMP)CuriumPiPHookSetPlaying);

        // Optional low-frequency lifecycle diagnostic observers.
        Method mStopDetach = CuriumExpectMethod(cls, "stopPiPAndDetach:", "v20@0:8B16");
        if (mStopDetach) {
            gOrigStopDetach = (CuriumPiPStopDetachIMP)method_setImplementation(
                mStopDetach, (IMP)CuriumPiPHookStopDetach);
        }
        Method mDidStart = CuriumExpectMethod(
            cls, "pictureInPictureControllerDidStartPictureInPicture:", "v24@0:8@16");
        if (mDidStart) {
            gOrigDidStart = (CuriumPiPDelegateEventIMP)method_setImplementation(
                mDidStart, (IMP)CuriumPiPHookDidStart);
        }
        Method mFailed = CuriumExpectMethod(
            cls, "pictureInPictureController:failedToStartPictureInPictureWithError:", "v32@0:8@16@24");
        if (mFailed) {
            gOrigFailedToStart = (CuriumPiPDelegateFailIMP)method_setImplementation(
                mFailed, (IMP)CuriumPiPHookFailedToStart);
        }
        Method mDidStop = CuriumExpectMethod(
            cls, "pictureInPictureControllerDidStopPictureInPicture:", "v24@0:8@16");
        if (mDidStop) {
            gOrigDidStop = (CuriumPiPDelegateEventIMP)method_setImplementation(
                mDidStop, (IMP)CuriumPiPHookDidStop);
        }

        CuriumRecordHookStatus(kCuriumPiPHookName, @"active",
                               @"VOD skip + AVKit setPlaying coalesce + SharedImage IOSurface + HLS guard (Build 40)");
    });
}

#else

void CuriumInstallPiPSkipHooks(void) {
    CuriumRecordHookStatus(kCuriumPiPHookName, @"skipped",
                           @"PiP skip runtime hook requires arm64");
}

#endif
