#pragma once

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VideoSamplerDSPBridge : NSObject

@property(nonatomic) AUAudioFrameCount maximumFramesToRender;
@property(nonatomic, getter=isBypassed) BOOL bypassed;
@property(nonatomic, getter=isRenderingOffline) BOOL renderingOffline;
@property(nonatomic, readonly) uint64_t visualActivityGeneration;
@property(nonatomic) float gain;
@property(nonatomic, readonly) MIDIProtocolID midiProtocol;
@property(nonatomic, readonly) AUInternalRenderBlock renderBlock;

- (void)initializeWithChannelCount:(int32_t)channelCount sampleRate:(double)sampleRate;
- (void)deInitialize;
- (void)reset;
- (void)setChannelCount:(uint32_t)channelCount maximumFrames:(AUAudioFrameCount)maximumFrames;

- (void)setClipForNote:(int32_t)note
                  left:(const float*)left
                 right:(nullable const float*)right
            frameCount:(int32_t)frameCount
            sampleRate:(double)sampleRate NS_SWIFT_NAME(setClip(note:left:right:frameCount:sampleRate:));
- (void)clearClipForNote:(int32_t)note;
- (uint32_t)consumeNextTriggerEvent;
- (void)discardTriggerEvents;

@end

NS_ASSUME_NONNULL_END
