#import "VideoSamplerDSPBridge.h"
#import "VideoSamplerDSPKernel.hpp"
#import "VideoSamplerAUProcessHelper.hpp"

#include <memory>

@implementation VideoSamplerDSPBridge {
    std::unique_ptr<VideoSamplerDSPKernel> _kernel;
    std::unique_ptr<VideoSamplerAUProcessHelper> _processHelper;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _kernel = std::make_unique<VideoSamplerDSPKernel>();
        _processHelper = std::make_unique<VideoSamplerAUProcessHelper>(*_kernel);
    }
    return self;
}

- (AUAudioFrameCount)maximumFramesToRender { return _kernel->maximumFramesToRender(); }
- (void)setMaximumFramesToRender:(AUAudioFrameCount)value { _kernel->setMaximumFramesToRender(value); }
- (BOOL)isBypassed { return _kernel->isBypassed(); }
- (void)setBypassed:(BOOL)value { _kernel->setBypass(value); }
- (BOOL)isRenderingOffline { return _kernel->isRenderingOffline(); }
- (void)setRenderingOffline:(BOOL)value { _kernel->setRenderingOffline(value); }
- (uint64_t)visualActivityGeneration { return _kernel->visualActivityGeneration(); }
- (float)gain { return _kernel->getGain(); }
- (void)setGain:(float)value { _kernel->setGain(value); }
- (MIDIProtocolID)midiProtocol { return _kernel->AudioUnitMIDIProtocol(); }
- (AUInternalRenderBlock)renderBlock { return _processHelper->internalRenderBlock(); }

- (void)initializeWithChannelCount:(int32_t)channelCount sampleRate:(double)sampleRate {
    _kernel->initialize(channelCount, sampleRate);
}

- (void)deInitialize { _kernel->deInitialize(); }
- (void)reset { _kernel->reset(); }

- (void)setChannelCount:(uint32_t)channelCount maximumFrames:(AUAudioFrameCount)maximumFrames {
    _processHelper->setChannelCount(channelCount, maximumFrames);
}

- (void)setClipForNote:(int32_t)note
                  left:(const float*)left
                 right:(const float*)right
            frameCount:(int32_t)frameCount
            sampleRate:(double)sampleRate {
    _kernel->setClip(note, left, right, frameCount, sampleRate);
}

- (void)clearClipForNote:(int32_t)note { _kernel->clearClip(note); }
- (uint32_t)consumeNextTriggerEvent { return _kernel->consumeNextTriggerEvent(); }
- (void)discardTriggerEvents { _kernel->discardTriggerEvents(); }

@end
