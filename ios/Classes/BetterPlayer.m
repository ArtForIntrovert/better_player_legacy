// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "BetterPlayer.h"
#import <better_player/better_player-Swift.h>

static void* timeRangeContext = &timeRangeContext;
static void* statusContext = &statusContext;
static void* playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void* playbackBufferEmptyContext = &playbackBufferEmptyContext;
static void* playbackBufferFullContext = &playbackBufferFullContext;
static void* presentationSizeContext = &presentationSizeContext;


#if TARGET_OS_IOS
void (^__strong _Nonnull _restoreUserInterfaceForPIPStopCompletionHandler)(BOOL);
API_AVAILABLE(ios(9.0))
AVPictureInPictureController *_pipController;
BetterPlayer *_pipPrimaryPlayer;
#endif

@implementation BetterPlayer

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _frame = CGRectNull;
    _isInitialized = false;
    _isPlaying = false;
    _disposed = false;
    _exitingPictureInPicture = false;
    _restoreInterface = false;
    _player = [[AVPlayer alloc] init];
    _player.appliesMediaSelectionCriteriaAutomatically = NO;
    _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    ///Fix for loading large videos
    if (@available(iOS 10.0, *)) {
        _player.automaticallyWaitsToMinimizeStalling = true;
    }

    self._observersAdded = false;
    return self;
}

- (nonnull UIView *)view {
    BetterPlayerView *playerView = [[BetterPlayerView alloc] initWithFrame:CGRectZero];
    playerView.player = _player;
    
    [BetterPlayerLogger log:@"player view allocated"];
    
    return playerView;
}

- (void)addObservers:(AVPlayerItem*)item {
    if (_disposed) return;
       
    if (!self._observersAdded){
        [_player addObserver:self forKeyPath:@"rate" options:0 context:nil];
        [_player addObserver:self forKeyPath:@"reasonForWaitingToPlay" options:0 context:nil];
        [item addObserver:self forKeyPath:@"loadedTimeRanges" options:0 context:timeRangeContext];
        [item addObserver:self forKeyPath:@"status" options:0 context:statusContext];
        [item addObserver:self forKeyPath:@"presentationSize" options:0 context:presentationSizeContext];
        [item addObserver:self
               forKeyPath:@"playbackLikelyToKeepUp"
                  options:0
                  context:playbackLikelyToKeepUpContext];
        [item addObserver:self
               forKeyPath:@"playbackBufferEmpty"
                  options:0
                  context:playbackBufferEmptyContext];
        [item addObserver:self
               forKeyPath:@"playbackBufferFull"
                  options:0
                  context:playbackBufferFullContext];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(itemDidPlayToEndTime:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:item];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handlePlaybackStalled:) name:AVPlayerItemPlaybackStalledNotification object:item];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleFailedToPlayToEnd:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:item];

        self._observersAdded = true;
    }
}

- (void)clear {
    _isInitialized = false;
    _isPlaying = false;
    _disposed = false;
    _failedCount = 0;
    _key = nil;
    if (_player.currentItem == nil) {
        return;
    }

    if (_player.currentItem == nil) {
        return;
    }

    [self removeObservers];
    AVAsset* asset = [_player.currentItem asset];
    [asset cancelLoading];
}

- (void) removeObservers{
    if (self._observersAdded){
        [_player removeObserver:self forKeyPath:@"rate" context:nil];
        [[_player currentItem] removeObserver:self forKeyPath:@"status" context:statusContext];
        [[_player currentItem] removeObserver:self forKeyPath:@"presentationSize" context:presentationSizeContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"loadedTimeRanges"
                                      context:timeRangeContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackLikelyToKeepUp"
                                      context:playbackLikelyToKeepUpContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackBufferEmpty"
                                      context:playbackBufferEmptyContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackBufferFull"
                                      context:playbackBufferFullContext];
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        self._observersAdded = false;
    }
}

- (void)itemDidPlayToEndTime:(NSNotification*)notification {
    [BetterPlayerLogger log:[NSString stringWithFormat:@"AVPlayerItemDidPlayToEndTimeNotification dispatched"]];

    if (_isLooping) {
        AVPlayerItem* p = [notification object];
        [p seekToTime:kCMTimeZero completionHandler:nil];
    } else {
        if (_eventSink) {
            _eventSink(@{@"event" : @"completed", @"key" : _key});
            [self removeObservers];
        }
    }
}


- (void)handleFailedToPlayToEnd:(NSNotification*)notification {
    [BetterPlayerLogger log:[NSString stringWithFormat:@"AVPlayerItemFailedToPlayToEndTimeNotification dispatched"] force:true];
        
    _eventSink([FlutterError
            errorWithCode:@"FailedToPlayToEnd"
            message:@"AVPlayerItemFailedToPlayToEndTimeNotification dispatched"
            details:nil]);
}

- (void)handlePlaybackStalled:(NSNotification *)notification {
    [BetterPlayerLogger log:[NSString stringWithFormat:@"AVPlayerItemPlaybackStalledNotification dispatched"] force:true];

    _eventSink(@{@"event" : @"notification", @"code": @"PlaybackStalled", @"key" : _key});
}

static inline CGFloat radiansToDegrees(CGFloat radians) {
    // Input range [-pi, pi] or [-180, 180]
    CGFloat degrees = GLKMathRadiansToDegrees((float)radians);
    if (degrees < 0) {
        // Convert -90 to 270 and -180 to 180
        return degrees + 360;
    }
    // Output degrees in between [0, 360[
    return degrees;
};

- (AVMutableVideoComposition*)getVideoCompositionWithTransform:(CGAffineTransform)transform
                                                     withAsset:(AVAsset*)asset
                                                withVideoTrack:(AVAssetTrack*)videoTrack {
    AVMutableVideoCompositionInstruction* instruction =
    [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, [asset duration]);
    AVMutableVideoCompositionLayerInstruction* layerInstruction =
    [AVMutableVideoCompositionLayerInstruction
     videoCompositionLayerInstructionWithAssetTrack:videoTrack];
    [layerInstruction setTransform:_preferredTransform atTime:kCMTimeZero];

    AVMutableVideoComposition* videoComposition = [AVMutableVideoComposition videoComposition];
    instruction.layerInstructions = @[ layerInstruction ];
    videoComposition.instructions = @[ instruction ];

    // If in portrait mode, switch the width and height of the video
    CGFloat width = videoTrack.naturalSize.width;
    CGFloat height = videoTrack.naturalSize.height;
    NSInteger rotationDegrees =
    (NSInteger)round(radiansToDegrees(atan2(_preferredTransform.b, _preferredTransform.a)));
    if (rotationDegrees == 90 || rotationDegrees == 270) {
        width = videoTrack.naturalSize.height;
        height = videoTrack.naturalSize.width;
    }
    videoComposition.renderSize = CGSizeMake(width, height);

    float nominalFrameRate = videoTrack.nominalFrameRate;
    int fps = 30;
    if (nominalFrameRate > 0) {
        fps = (int) ceil(nominalFrameRate);
    }
    videoComposition.frameDuration = CMTimeMake(1, fps);
    
    return videoComposition;
}

- (CGAffineTransform)fixTransform:(AVAssetTrack*)videoTrack {
  CGAffineTransform transform = videoTrack.preferredTransform;
  // TODO(@recastrodiaz): why do we need to do this? Why is the preferredTransform incorrect?
  // At least 2 user videos show a black screen when in portrait mode if we directly use the
  // videoTrack.preferredTransform Setting tx to the height of the video instead of 0, properly
  // displays the video https://github.com/flutter/flutter/issues/17606#issuecomment-413473181
  NSInteger rotationDegrees = (NSInteger)round(radiansToDegrees(atan2(transform.b, transform.a)));
  if (rotationDegrees == 90) {
    transform.tx = videoTrack.naturalSize.height;
    transform.ty = 0;
  } else if (rotationDegrees == 180) {
    transform.tx = videoTrack.naturalSize.width;
    transform.ty = videoTrack.naturalSize.height;
  } else if (rotationDegrees == 270) {
    transform.tx = 0;
    transform.ty = videoTrack.naturalSize.width;
  }
  return transform;
}

- (void)setDataSourceAsset:(NSString*)asset withKey:(NSString*)key withCertificateUrl:(NSString*)certificateUrl withLicenseUrl:(NSString*)licenseUrl cacheKey:(NSString*)cacheKey cacheManager:(CacheManager*)cacheManager overriddenDuration:(int) overriddenDuration result:(FlutterResult) result {
    if (_disposed) {
        result(nil);
        return;
    }
       
    NSString* path = [[NSBundle mainBundle] pathForResource:asset ofType:nil];
    return [self setDataSourceURL:[NSURL fileURLWithPath:path] withKey:key withCertificateUrl:certificateUrl withLicenseUrl:(NSString*)licenseUrl withHeaders: @{} withCache: false cacheKey:cacheKey cacheManager:cacheManager overriddenDuration:overriddenDuration videoExtension: nil result:result];
}

- (void)setDataSourceURL:(NSURL*)url withKey:(NSString*)key withCertificateUrl:(NSString*)certificateUrl withLicenseUrl:(NSString*)licenseUrl withHeaders:(NSDictionary*)headers withCache:(BOOL)useCache cacheKey:(NSString*)cacheKey cacheManager:(CacheManager*)cacheManager overriddenDuration:(int) overriddenDuration videoExtension: (NSString*) videoExtension result:(FlutterResult) result {
    if (_disposed) {
        result(nil);
        return;
    }
       
    _overriddenDuration = 0;
    if (headers == [NSNull null] || headers == NULL){
        headers = @{};
    }
    
    AVPlayerItem* item;
    if (useCache){
        if (cacheKey == [NSNull null]){
            cacheKey = nil;
        }
        if (videoExtension == [NSNull null]){
            videoExtension = nil;
        }
        
        item = [cacheManager getCachingPlayerItemForNormalPlayback:url cacheKey:cacheKey videoExtension: videoExtension headers:headers];
    } else {
        AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url
                                                options:@{@"AVURLAssetHTTPHeaderFieldsKey" : headers}];
        if (certificateUrl && certificateUrl != [NSNull null] && [certificateUrl length] > 0) {
            NSURL * certificateNSURL = [[NSURL alloc] initWithString: certificateUrl];
            NSURL * licenseNSURL = [[NSURL alloc] initWithString: licenseUrl];
            _loaderDelegate = [[BetterPlayerEzDrmAssetsLoaderDelegate alloc] init:certificateNSURL withLicenseURL:licenseNSURL];
            dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, -1);
            dispatch_queue_t streamQueue = dispatch_queue_create("streamQueue", qos);
            [asset.resourceLoader setDelegate:_loaderDelegate queue:streamQueue];
        }
        item = [AVPlayerItem playerItemWithAsset:asset];
    }

    if (@available(iOS 10.0, *) && overriddenDuration > 0) {
        _overriddenDuration = overriddenDuration;
    }
    
    return [self setDataSourcePlayerItem:item withKey:key result:result];
}

- (void)setDataSourcePlayerItem:(AVPlayerItem*)item withKey:(NSString*)key result:(FlutterResult) result{
    if (_disposed) {
        result(nil);
        return;
    }
       
    _key = key;
    _stalledCount = 0;
    _isStalledCheckStarted = false;
    _playerRate = 1;
    [_player replaceCurrentItemWithPlayerItem:item];

    AVAsset* asset = [item asset];
    void (^assetCompletionHandler)(void) = ^{
        if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
            NSArray* tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
            if ([tracks count] > 0) {
                AVAssetTrack* videoTrack = tracks[0];
                void (^trackCompletionHandler)(void) = ^{
                    if (self->_disposed) return;
                    if ([videoTrack statusOfValueForKey:@"preferredTransform"
                                                  error:nil] == AVKeyValueStatusLoaded) {
                        // Rotate the video by using a videoComposition and the preferredTransform
                        self->_preferredTransform = [self fixTransform:videoTrack];
                        // Note:
                        // https://developer.apple.com/documentation/avfoundation/avplayeritem/1388818-videocomposition
                        // Video composition can only be used with file-based media and is not supported for
                        // use with media served using HTTP Live Streaming.
                        AVMutableVideoComposition* videoComposition =
                        [self getVideoCompositionWithTransform:self->_preferredTransform
                                                     withAsset:asset
                                                withVideoTrack:videoTrack];
                        item.videoComposition = videoComposition;
                    }
                    
                    result(nil);
                };
                [videoTrack loadValuesAsynchronouslyForKeys:@[ @"preferredTransform" ]
                                          completionHandler:trackCompletionHandler];
            } else {
                result(nil);
            }
        } else {
            result(nil);
        }
    };

    [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:assetCompletionHandler];
    [self addObservers:item];
}

-(void)handleStalled {
    if (_isStalledCheckStarted){
        return;
    }
    
    _isStalledCheckStarted = true;
    [self startStalledCheck];
}

-(void)startStalledCheck{
    if (_disposed) return;
    [BetterPlayerLogger log:[NSString stringWithFormat:@"Do stall check - %o", _stalledCount]];
       
    if (_player.currentItem.playbackLikelyToKeepUp ||
        [self availableDuration] - CMTimeGetSeconds(_player.currentItem.currentTime) > 10.0) {
        [BetterPlayerLogger log:[NSString stringWithFormat:@"Stall check completed after %o iterations", _stalledCount]];
        [self play];
    } else {
        _stalledCount++;
        if (_stalledCount > 60) {
            [BetterPlayerLogger log:@"Failed to load video: playback stalled"];
            if (_eventSink != nil) {
                _eventSink([FlutterError
                        errorWithCode:@"VideoError"
                        message:@"Failed to load video: playback stalled"
                        details:nil]);
            }
            return;
        }
        
        [self performSelector:@selector(startStalledCheck) withObject:nil afterDelay:1];
    }
}

- (NSTimeInterval) availableDuration
{
    NSArray *loadedTimeRanges = [[_player currentItem] loadedTimeRanges];
    if (loadedTimeRanges.count > 0){
        CMTimeRange timeRange = [[loadedTimeRanges objectAtIndex:0] CMTimeRangeValue];
        Float64 startSeconds = CMTimeGetSeconds(timeRange.start);
        Float64 durationSeconds = CMTimeGetSeconds(timeRange.duration);
        NSTimeInterval result = startSeconds + durationSeconds;
        return result;
    } else {
        return 0;
    }

}

- (void)observeValueForKeyPath:(NSString*)path
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {

    if (_disposed) return;
    
    if ([path isEqualToString:@"reasonForWaitingToPlay"]) {
        [BetterPlayerLogger log:[NSString stringWithFormat:@"Reason for waiting to play change - %@", _player.reasonForWaitingToPlay] force:true];
    }
       
    if ([path isEqualToString:@"rate"]) {
        if (@available(iOS 10.0, *)) {
            if (_pipController.pictureInPictureActive == true){
                if (_player.rate > 0) {
                    if (_isPlaying == true) return;
                    
                    _isPlaying = true;
                } else if (_player.rate == 0) {
                    if (_isPlaying == false) return;
                    
                    _isPlaying = false;
                }
                    
                [BetterPlayerLogger log:[NSString stringWithFormat:@"Playing state changed - isPlaying: %o", _isPlaying]];
                [self emitIsPlayingChanged];
            }
        }

        if (_player.rate == 0 && //if player rate dropped to 0
            CMTIME_COMPARE_INLINE(_player.currentItem.currentTime, >, kCMTimeZero) && //if video was started
            CMTIME_COMPARE_INLINE(_player.currentItem.currentTime, <, _player.currentItem.duration) && //but not yet finished
            _isPlaying) { //instance variable to handle overall state (changed to YES when user triggers playback)
            [BetterPlayerLogger log:@"Stall detected - handling"];
            [self handleStalled];
        }
    }

    if (context == timeRangeContext) {
        if (_eventSink != nil) {
            NSMutableArray<NSArray<NSNumber*>*>* values = [[NSMutableArray alloc] init];
            for (NSValue* rangeValue in [object loadedTimeRanges]) {
                CMTimeRange range = [rangeValue CMTimeRangeValue];
                int64_t start = [BetterPlayerTimeUtils FLTCMTimeToMillis:(range.start)];
                int64_t end = start + [BetterPlayerTimeUtils FLTCMTimeToMillis:(range.duration)];
                if (!CMTIME_IS_INVALID(_player.currentItem.forwardPlaybackEndTime)) {
                    int64_t endTime = [BetterPlayerTimeUtils FLTCMTimeToMillis:(_player.currentItem.forwardPlaybackEndTime)];
                    if (end > endTime){
                        end = endTime;
                    }
                }

                [values addObject:@[ @(start), @(end) ]];
            }
            _eventSink(@{@"event" : @"bufferingUpdate", @"values" : values, @"key" : _key});
        }
    }
    else if (context == presentationSizeContext){
        if (_player.rate > 0 && self._playerLayer == nil && _pipPrimaryPlayer == self)
            [self usePlayerLayer];
        
        [BetterPlayerLogger log:@"Ready to play because 'presentationSizeContext'"];
        [self onReadyToPlay];
    }

    else if (context == statusContext) {
        AVPlayerItem* item = (AVPlayerItem*)object;
        switch (item.status) {
            case AVPlayerItemStatusFailed:
                [BetterPlayerLogger log:[NSString stringWithFormat:@"Failed to load video:\n%lo - %@", item.error.code, item.error.debugDescription] force:true];

                if (_eventSink != nil) {
                    _eventSink([FlutterError
                                errorWithCode:@"VideoError"
                                message:[@"Failed to load video: "
                                         stringByAppendingString:[item.error localizedDescription]]
                                details:nil]);
                }
                break;
            case AVPlayerItemStatusUnknown:
                break;
            case AVPlayerItemStatusReadyToPlay:
                [BetterPlayerLogger log:@"Ready to play"];
                [self onReadyToPlay];
                break;
        }
    } else if (context == playbackLikelyToKeepUpContext) {
        [BetterPlayerLogger log:[NSString stringWithFormat:@"isPlaybackLikelyToKeepUp changed - %o", [[_player currentItem] isPlaybackLikelyToKeepUp]]];
        if ([[_player currentItem] isPlaybackLikelyToKeepUp]) {
            [self updatePlayingState];
            if (_eventSink != nil) {
                _eventSink(@{@"event" : @"bufferingEnd", @"key" : _key});
            }
        }
    } else if (context == playbackBufferEmptyContext) {
        [BetterPlayerLogger log:@"Buffer is empty"];
        if (_eventSink != nil) {
            _eventSink(@{@"event" : @"bufferingStart", @"key" : _key});
        }
    } else if (context == playbackBufferFullContext) {
        [BetterPlayerLogger log:@"Buffer filled"];
        if (_eventSink != nil) {
            _eventSink(@{@"event" : @"bufferingEnd", @"key" : _key});
        }
    }
}

- (void)updatePlayingState {
    if (_disposed) return;
       
    if (!_isInitialized || !_key) {
        return;
    }
    if (!self._observersAdded){
        [self addObservers:[_player currentItem]];
    }
    
    if (_isPlaying && (_player.rate != _playerRate)) {
        if (@available(iOS 10.0, *)) {
            [_player playImmediatelyAtRate:1.0];
            _player.rate = _playerRate;
        } else {
            [_player play];
            _player.rate = _playerRate;
        }
    } else if (!_isPlaying && _player.rate != 0) {
        [_player pause];
    }
}

- (void)onReadyToPlay {
    if (_disposed) return;
       
    if (_eventSink && !_isInitialized && _key) {
        if (!_player.currentItem) {
            return;
        }
        if (_player.status != AVPlayerStatusReadyToPlay) {
            return;
        }

        CGSize size = [_player currentItem].presentationSize;
        CGFloat width = size.width;
        CGFloat height = size.height;


        AVAsset *asset = _player.currentItem.asset;
        bool onlyAudio =  [[asset tracksWithMediaType:AVMediaTypeVideo] count] == 0;

        // The player has not yet initialized.
        if (!onlyAudio && height == CGSizeZero.height && width == CGSizeZero.width) {
            [BetterPlayerLogger log:@"Player not initialized yet - no size" force:true];
            return;
        }
        const BOOL isLive = CMTIME_IS_INDEFINITE([_player currentItem].duration);
        // The player may be initialized but still needs to determine the duration.
        if (isLive == false && [self duration] == 0) {
            [BetterPlayerLogger log:@"Player not initialized yet - no duration" force:true];
            return;
        }

        //Fix from https://github.com/flutter/flutter/issues/66413
        AVPlayerItemTrack *track = [self.player currentItem].tracks.firstObject;
        CGSize naturalSize = track.assetTrack.naturalSize;
        CGAffineTransform prefTrans = track.assetTrack.preferredTransform;
        CGSize realSize = CGSizeApplyAffineTransform(naturalSize, prefTrans);

        int64_t duration = [BetterPlayerTimeUtils FLTCMTimeToMillis:(_player.currentItem.asset.duration)];
        if (_overriddenDuration > 0 && duration > _overriddenDuration){
            _player.currentItem.forwardPlaybackEndTime = CMTimeMake(_overriddenDuration/1000, 1);
        }

        _isInitialized = true;
        [self updatePlayingState];
        [BetterPlayerLogger log:@"Player is initialized"];
        _eventSink(@{
            @"event" : @"initialized",
            @"duration" : @([self duration]),
            @"width" : @(fabs(realSize.width) ? : width),
            @"height" : @(fabs(realSize.height) ? : height),
            @"key" : _key
        });
    }
}

- (void)retry {
    AVAsset* asset = [_player currentItem].asset;
    AVPlayerItem* item = [AVPlayerItem playerItemWithAsset:asset];
    CMTime position = [_player currentTime];
    
    [self removeObservers];
    [self addObservers:item];
    [_player replaceCurrentItemWithPlayerItem:item];
    [_player seekToTime:position];
        
    [self updatePlayingState];
}

- (void)play {
    if (_disposed) return;
    
    if (@available(iOS 10.0, *)) {
        if (_exitingPictureInPicture) {
            return;
        }
    }
    
    _stalledCount = 0;
    _isStalledCheckStarted = false;
    _isPlaying = true;
    [self updatePlayingState];
    [BetterPlayerLogger log:@"Play called"];
}

- (void)pause {
    if (_disposed) return;

    if (@available(iOS 10.0, *)) {
        if (_exitingPictureInPicture) {
            return;
        }
    }
    
    _isPlaying = false;
    [self updatePlayingState];
    [BetterPlayerLogger log:@"Pause called"];
}

- (int64_t)position {
    return [BetterPlayerTimeUtils FLTCMTimeToMillis:([_player currentTime])];
}

- (int64_t)absolutePosition {
    return [BetterPlayerTimeUtils FLTNSTimeIntervalToMillis:([[[_player currentItem] currentDate] timeIntervalSince1970])];
}

- (int64_t)duration {
    CMTime time;
    if (@available(iOS 13, *)) {
        time =  [[_player currentItem] duration];
    } else {
        time =  [[[_player currentItem] asset] duration];
    }
    
    if (!CMTIME_IS_INVALID(_player.currentItem.forwardPlaybackEndTime)) {
        time = [[_player currentItem] forwardPlaybackEndTime];
    }
    
    if (CMTIME_IS_INDEFINITE(time)) {
        return 0;
    }

    return [BetterPlayerTimeUtils FLTCMTimeToMillis:(time)];
}

- (void)seekTo:(int)location result:(FlutterResult) result {
    if (_disposed) {
        result(nil);
        return;
    }

    [BetterPlayerLogger log:[NSString stringWithFormat:@"Seek to called - %d", location]];
    [_player seekToTime:CMTimeMake(location, 1000)
        toleranceBefore:kCMTimeZero
        toleranceAfter:kCMTimeZero
        completionHandler:^(BOOL seekResult) {
        if (result != NULL) {
            result(nil);
        }
    }];
}

- (void)seekToWithTolerance:(int)location {
    if (_disposed) return;

    [BetterPlayerLogger log:[NSString stringWithFormat:@"Seek to with tolerance called - %d", location]];
    [_player seekToTime:CMTimeMake(location, 1000)
      completionHandler:^(BOOL result) {
        self->_player.currentItem.videoComposition = [self->_player.currentItem.videoComposition mutableCopy];
    }];
}

- (void)setIsLooping:(bool)isLooping {
    _isLooping = isLooping;
}

- (void)setVolume:(double)volume {
    if (_disposed) return;
    
    _player.volume = (float)((volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume));
}

- (void)setSpeed:(double)speed result:(FlutterResult)result {
    if (_disposed) {
        result(nil);
        return;
    }
    
    if (speed == 1.0 || speed == 0.0) {
        _playerRate = 1;
        result(nil);
        
        if (_isPlaying){
            _player.rate = _playerRate;
        }
        return;
    } else if (speed < 0) {
        result([FlutterError errorWithCode:@"unsupported_speed"
                                   message:@"Speed must be >= 0.0 and <= 2.0"
                                   details:nil]);
        return;
    }
    
    if (@available(iOS 7.0, *)) {
        if (speed <= 2 || (speed > 2 && _player.currentItem.canPlayFastForward)) {
            _playerRate = speed;
            result(nil);
        } else {
            result([FlutterError errorWithCode:@"unsupported_speed"
                                       message:@"Speed must be >= 0.0 and <= 2.0"
                                       details:nil]);
        }
    } else if ((speed > 1.0 && _player.currentItem.canPlayFastForward) ||
               (speed < 1.0 && _player.currentItem.canPlaySlowForward)) {
        _playerRate = speed;
        result(nil);
    } else {
        if (speed > 1.0) {
            result([FlutterError errorWithCode:@"unsupported_fast_forward"
                                       message:@"This video cannot be played fast forward"
                                       details:nil]);
        } else {
            result([FlutterError errorWithCode:@"unsupported_slow_forward"
                                       message:@"This video cannot be played slow forward"
                                       details:nil]);
        }
    }

    if (_isPlaying){
        _player.rate = _playerRate;
    }
}


- (void)setTrackParameters:(int) width: (int) height: (int)bitrate {
    if (_disposed) return;
    
    _player.currentItem.preferredPeakBitRate = bitrate;
    if (@available(iOS 11.0, *)) {
        if (width == 0 && height == 0){
            _player.currentItem.preferredMaximumResolution = CGSizeZero;
        } else {
            _player.currentItem.preferredMaximumResolution = CGSizeMake(width, height);
        }
    }
}

- (void)setPictureInPicture:(BOOL)pictureInPicture
{
    if (_disposed) return;
       
    self._pictureInPicture = pictureInPicture;
    
    [BetterPlayerLogger log:[NSString stringWithFormat:@"PIP player layer - %@, %@", self._playerLayer, _pipController.playerLayer]];
    
    if (@available(iOS 9.0, *)) {
        if (_pipController && self._pictureInPicture && ![_pipController isPictureInPictureActive]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [_pipController startPictureInPicture];
            });
        } else if (_pipController && !self._pictureInPicture && [_pipController isPictureInPictureActive]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [_pipController stopPictureInPicture];
            });
        } else {
            // Fallback on earlier versions
        }
    }
}

#if TARGET_OS_IOS
- (void)setRestoreUserInterfaceForPIPStopCompletionHandler:(BOOL)restore
{
    if (_restoreUserInterfaceForPIPStopCompletionHandler != NULL) {
        _restoreUserInterfaceForPIPStopCompletionHandler(restore);
        _restoreUserInterfaceForPIPStopCompletionHandler = NULL;
    }
}

- (bool)setPIPPrimary:(BOOL)isPrimary {
    if (isPrimary && _pipPrimaryPlayer != self) {
        if (_pipPrimaryPlayer != NULL) {
            [_pipPrimaryPlayer setPIPPrimary:false];
        }
        
        _pipPrimaryPlayer = self;
        [self usePlayerLayer];
        
        [BetterPlayerLogger log:@"PIP controller created" method:@"setPIPPrimary(true)"];
        return true;
    } else if (!isPrimary && _pipPrimaryPlayer == self) {
        [BetterPlayerLogger log:@"PIP controller disposed" method:@"setPIPPrimary(false)"];
        __playerLayer = NULL;
        _pipController = NULL;
        _pipPrimaryPlayer = NULL;
        
        _exitingPictureInPicture = false;
        _restoreInterface = false;

        return true;
    }
    
    return false;
}

- (void)setupPipController {
    if (@available(iOS 9.0, *)) {
        [[AVAudioSession sharedInstance] setActive: YES error: nil];
        [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
        if (!_pipController && self._playerLayer && [AVPictureInPictureController isPictureInPictureSupported]) {
            _pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:self._playerLayer];
            _pipController.delegate = self;
         
            if (@available(iOS 14.2, *)) {
                _pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
            }
        }
    } else {
        // Fallback on earlier versions
    }
}

- (void) enablePictureInPicture {
    if (_disposed) return;
    if ([_pipController isPictureInPictureActive]) return;
    
    [self setPictureInPicture:true];
}

- (void)setPictureInPictureOverlayRect:(CGRect)frame {
    self.frame = frame;
    
    if (_pipPrimaryPlayer != self) return;
    
    AVPlayerLayer* layer = [self usePlayerLayer];
    if (_player && !_pipController.isPictureInPictureActive && layer != NULL && !CGRectIsEmpty(self.frame)) {
        layer.frame = self.frame;
    }
}

- (void)emitPIPStartEvent {
    
}

- (AVPlayerLayer*)usePlayerLayer
{
    if (self._playerLayer != NULL) return self._playerLayer;
    
    if( _player )
    {
        // Create new controller passing reference to the AVPlayerLayer
        self._playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
        UIViewController* vc = [[[UIApplication sharedApplication] keyWindow] rootViewController];
        self._playerLayer.needsDisplayOnBoundsChange = YES;
        
        [BetterPlayerLogger log:@"PIP player layer created"];
        
        // We set the opacity to 0.0001 because it is an overlay.
        // Picture-in-picture will show a placeholder over other widgets when better_player is used in a
        // ScrollView, PageView or in a widget that changes location.
        self._playerLayer.opacity = .0001;

        [vc.view.layer addSublayer:self._playerLayer];
        vc.view.layer.needsDisplayOnBoundsChange = YES;
        if (@available(iOS 9.0, *)) {
            if (_pipController != nil) {
                [BetterPlayerLogger log:@"PIP controller disposed"];
                
                _pipController = NULL;
            }
        }
        
        [self setupPipController];
                
        if (!CGRectIsEmpty(self.frame)) {
            [self setPictureInPictureOverlayRect:self.frame];
        }
        
        return self._playerLayer;
    }
    
    return nil;
}

- (void)disablePictureInPicture
{
    if (_disposed) return;
    if (![_pipController isPictureInPictureActive]) return;
    
    [_pipController stopPictureInPicture];
       
    if (__playerLayer){
        if (_eventSink != nil) {
            [BetterPlayerLogger log:[NSString stringWithFormat:@"PIP – pip stop event emitted { \"restoreInterface\": %o }", _restoreInterface]];
            
            _eventSink(@{@"event" : @"pipStop", @"restore_interface": @(_restoreInterface)});
        }
        
        if (_restoreInterface) {
            if (_player.rate == 0 && _isPlaying) {
                [_player play];
            }
        } else {
            [self pause];
        }
    }
}
#endif

#if TARGET_OS_IOS

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    [BetterPlayerLogger log:[NSString stringWithFormat:@"[BetterPlayer]: Pre PIP Start – player.rate = %f, _isPlaying = %o",
                             _player.rate, _isPlaying]];
        
    if (_eventSink != nil) {
        _eventSink(@{@"event" : @"pipStart"});
    }
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController  API_AVAILABLE(ios(9.0)){
    [BetterPlayerLogger log:[NSString stringWithFormat:@"[BetterPlayer]: Post PIP Start – player.rate = %f, _isPlaying = %o",
                             _player.rate, _isPlaying]];
}

bool _restoreInterface = false;
- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    [BetterPlayerLogger log:[NSString stringWithFormat:@"PIP Restore interface event – player.rate = %f, _isPlaying = %o", _player.rate, _isPlaying]];
    
    _restoreInterface = true;
    _isPlaying = _player.rate > 0;
    
    [self emitIsPlayingChanged];
    [self setRestoreUserInterfaceForPIPStopCompletionHandler: true];
}

- (void)emitIsPlayingChanged {
    if (_eventSink == NULL) return;
    
    CMTime time = _player.currentTime;
    int64_t millis = [BetterPlayerTimeUtils FLTCMTimeToMillis:(time)];

    _eventSink(@{
        @"event" : @"isPlayingChanged",
        @"value" : @(_isPlaying),
        @"position": @(millis),
        @"key" : _key
    });
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController  API_AVAILABLE(ios(9.0)){
    [BetterPlayerLogger log:[NSString stringWithFormat:@"PIP Will Stop – player.rate = %f, _isPlaying = %o",
                             _player.rate, _isPlaying]];
    _exitingPictureInPicture = true;
    [self disablePictureInPicture];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController  API_AVAILABLE(ios(9.0)){
    [BetterPlayerLogger log:[NSString stringWithFormat:@"PIP Did Stop – player.rate = %f, _isPlaying = %o", _player.rate, _isPlaying]];
    _exitingPictureInPicture = false;
    _restoreInterface = false;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {

}

- (void) setAudioTrack:(NSString*) name index:(int) index{
    if (_disposed) return;
       
    AVMediaSelectionGroup *audioSelectionGroup = [[[_player currentItem] asset] mediaSelectionGroupForMediaCharacteristic: AVMediaCharacteristicAudible];
    NSArray* options = audioSelectionGroup.options;


    for (int audioTrackIndex = 0; audioTrackIndex < [options count]; audioTrackIndex++) {
        AVMediaSelectionOption* option = [options objectAtIndex:audioTrackIndex];
        NSArray *metaDatas = [AVMetadataItem metadataItemsFromArray:option.commonMetadata withKey:@"title" keySpace:@"comn"];
        if (metaDatas.count > 0) {
            NSString *title = ((AVMetadataItem*)[metaDatas objectAtIndex:0]).stringValue;
            if ([name compare:title] == NSOrderedSame && audioTrackIndex == index ){
                [[_player currentItem] selectMediaOption:option inMediaSelectionGroup: audioSelectionGroup];
            }
        }

    }

}

- (void)setAllowExternalPlayback:(bool)allowExternalPlayback {
    _player.allowsExternalPlayback = allowExternalPlayback;
}

- (void)setMixWithOthers:(bool)mixWithOthers {
  if (mixWithOthers) {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                           error:nil];
  } else {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
  }
}


#endif

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
    _eventSink = nil;
    return nil;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
    _eventSink = events;
    // TODO(@recastrodiaz): remove the line below when the race condition is resolved:
    // https://github.com/flutter/flutter/issues/21483
    // This line ensures the 'initialized' event is sent when the event
    // 'AVPlayerItemStatusReadyToPlay' fires before _eventSink is set (this function
    // onListenWithArguments is called)
    [self onReadyToPlay];
    return nil;
}

/// This method allows you to dispose without touching the event channel.  This
/// is useful for the case where the Engine is in the process of deconstruction
/// so the channel is going to die or is already dead.
- (void)disposeSansEventChannel {
    @try{
        [self clear];
    }
    @catch(NSException *exception) {
        [BetterPlayerLogger log:exception.debugDescription force:true];
    }
}

- (void)dispose {
    if (_disposed) return;
       
    [self pause];
    [self disposeSansEventChannel];
    [_eventChannel setStreamHandler:nil];
    
    if (self._playerLayer != NULL) {
        [self disablePictureInPicture];
        [self setPictureInPicture:false];
        
        [self._playerLayer removeFromSuperlayer];
        AVPlayerLayer* layer = self._playerLayer;
        self._playerLayer = nil;
        
        [BetterPlayerLogger log:@"PIP player layer disposed"];
        if (_pipController.playerLayer == layer) {
            [BetterPlayerLogger log:@"pip controller disposed"];
            _pipController = nil;
        }
        
    }
    
    _disposed = true;
    _player = nil;
}

@end
