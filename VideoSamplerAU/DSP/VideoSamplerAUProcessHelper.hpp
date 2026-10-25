#pragma once

#import <AudioToolbox/AudioToolbox.h>
#include <algorithm>
#include <vector>
#include "VideoSamplerDSPKernel.hpp"

class VideoSamplerAUProcessHelper {
public:
    explicit VideoSamplerAUProcessHelper(VideoSamplerDSPKernel& kernel) : mKernel(kernel) {}

    void setChannelCount(UInt32 channelCount, AUAudioFrameCount maxFrames) {
        mOutputPointers.resize(channelCount);
        mOwnedOutput.resize(channelCount);
        for (auto& channel : mOwnedOutput) { channel.resize(maxFrames, 0.0f); }
    }

    void processWithEvents(
        AudioBufferList* outputData,
        const AudioTimeStamp* timestamp,
        AUAudioFrameCount frameCount,
        const AURenderEvent* events
    ) {
        for (UInt32 channel = 0; channel < outputData->mNumberBuffers; ++channel) {
            if (outputData->mBuffers[channel].mData == nullptr) {
                outputData->mBuffers[channel].mData = mOwnedOutput[channel].data();
                outputData->mBuffers[channel].mDataByteSize = frameCount * sizeof(float);
            }
        }

        AUEventSampleTime now = static_cast<AUEventSampleTime>(timestamp->mSampleTime);
        AUAudioFrameCount remaining = frameCount;
        const AURenderEvent* nextEvent = events;

        auto render = [this, outputData](AUEventSampleTime time, AUAudioFrameCount frames, AUAudioFrameCount offset) {
            const UInt32 channels = std::min<UInt32>(
                outputData->mNumberBuffers,
                static_cast<UInt32>(mOutputPointers.size())
            );
            for (UInt32 channel = 0; channel < channels; ++channel) {
                auto* data = static_cast<float*>(outputData->mBuffers[channel].mData);
                mOutputPointers[channel] = data == nullptr ? nullptr : data + offset;
            }
            mKernel.process(mOutputPointers, time, frames);
        };

        while (remaining > 0) {
            if (nextEvent == nullptr) {
                render(now, remaining, frameCount - remaining);
                return;
            }

            const AUEventSampleTime delta = std::max<AUEventSampleTime>(0, nextEvent->head.eventSampleTime - now);
            const AUAudioFrameCount segment = std::min<AUAudioFrameCount>(remaining, static_cast<AUAudioFrameCount>(delta));
            if (segment > 0) {
                render(now, segment, frameCount - remaining);
                remaining -= segment;
                now += segment;
            }

            do {
                mKernel.handleOneEvent(now, nextEvent);
                nextEvent = nextEvent->head.next;
            } while (nextEvent != nullptr && nextEvent->head.eventSampleTime <= now);
        }
    }

    AUInternalRenderBlock internalRenderBlock() {
        return ^AUAudioUnitStatus(
            AudioUnitRenderActionFlags*,
            const AudioTimeStamp* timestamp,
            AUAudioFrameCount frameCount,
            NSInteger,
            AudioBufferList* outputData,
            const AURenderEvent* realtimeEventListHead,
            AURenderPullInputBlock __unsafe_unretained
        ) {
            if (frameCount > mKernel.maximumFramesToRender()) {
                return kAudioUnitErr_TooManyFramesToProcess;
            }
            processWithEvents(outputData, timestamp, frameCount, realtimeEventListHead);
            return noErr;
        };
    }

private:
    VideoSamplerDSPKernel& mKernel;
    std::vector<float*> mOutputPointers;
    std::vector<std::vector<float>> mOwnedOutput;
};
