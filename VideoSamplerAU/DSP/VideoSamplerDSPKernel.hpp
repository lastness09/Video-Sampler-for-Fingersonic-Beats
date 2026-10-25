#pragma once

#import <AudioToolbox/AudioToolbox.h>
#import <CoreMIDI/CoreMIDI.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <limits>
#include <span>
#include <vector>

class VideoSamplerDSPKernel {
public:
    struct Clip {
        std::vector<float> left;
        std::vector<float> right;
        double sampleRate = 44100.0;
    };

    struct Voice {
        std::shared_ptr<const Clip> clip;
        double position = 0.0;
        float gain = 1.0f;
        bool active = false;
    };

    VideoSamplerDSPKernel() {
        for (auto& note : mClips) {
            std::atomic_store(&note, std::shared_ptr<const Clip>{});
        }
    }

    void initialize(int channelCount, double sampleRate) {
        mChannelCount = std::max(1, channelCount);
        mOutputSampleRate = std::max(1.0, sampleRate);
        resetVoices();
        mNextVoice = 0;
        invalidateVisualActivity();
    }

    void deInitialize() {
        resetVoices();
        invalidateVisualActivity();
    }

    void reset() {
        resetVoices();
        mNextVoice = 0;
        invalidateVisualActivity();
    }

    bool isRenderingOffline() const { return mRenderingOffline.load(std::memory_order_acquire); }
    void setRenderingOffline(bool value) {
        if (mRenderingOffline.exchange(value, std::memory_order_acq_rel) != value) {
            invalidateVisualActivity();
        }
    }

    uint64_t visualActivityGeneration() const {
        return mVisualActivityGeneration.load(std::memory_order_acquire);
    }

    // Consumer only: do not reset either ring index from the render thread.
    void discardTriggerEvents() {
        mTriggerRead.store(mTriggerWrite.load(std::memory_order_acquire), std::memory_order_release);
    }

    bool isBypassed() const { return mBypassed.load(std::memory_order_relaxed); }
    void setBypass(bool value) { mBypassed.store(value, std::memory_order_relaxed); }

    AUAudioFrameCount maximumFramesToRender() const { return mMaxFramesToRender; }
    void setMaximumFramesToRender(AUAudioFrameCount value) { mMaxFramesToRender = value; }

    MIDIProtocolID AudioUnitMIDIProtocol() const { return kMIDIProtocol_1_0; }

    void setGain(float value) {
        mMasterGain.store(std::clamp(value, 0.0f, 1.5f), std::memory_order_relaxed);
    }

    float getGain() const { return mMasterGain.load(std::memory_order_relaxed); }

    void setClip(
        int32_t note,
        const float* left,
        const float* right,
        int32_t frameCount,
        double sampleRate
    ) {
        if (note < 0 || note > 127 || left == nullptr || frameCount <= 0) { return; }
        auto clip = std::make_shared<Clip>();
        clip->left.assign(left, left + frameCount);
        if (right != nullptr) {
            clip->right.assign(right, right + frameCount);
        } else {
            clip->right = clip->left;
        }
        clip->sampleRate = std::max(1.0, sampleRate);
        std::atomic_store(&mClips[static_cast<size_t>(note)], std::shared_ptr<const Clip>(clip));
    }

    void clearClip(int32_t note) {
        if (note < 0 || note > 127) { return; }
        std::atomic_store(
            &mClips[static_cast<size_t>(note)],
            std::shared_ptr<const Clip>{}
        );
    }

    uint32_t consumeNextTriggerEvent() {
        for (uint32_t count = 0; count < kTriggerQueueCapacity; ++count) {
            const uint32_t read = mTriggerRead.load(std::memory_order_relaxed);
            if (read == mTriggerWrite.load(std::memory_order_acquire)) { break; }
            const TriggerEvent event = mTriggerEvents[read];
            mTriggerRead.store((read + 1) % kTriggerQueueCapacity, std::memory_order_release);
            if (!isRenderingOffline() && event.generation == visualActivityGeneration()) {
                return event.packed;
            }
        }
        return std::numeric_limits<uint32_t>::max();
    }

    void process(
        std::span<float*> outputBuffers,
        AUEventSampleTime,
        AUAudioFrameCount frameCount
    ) {
        for (float* output : outputBuffers) {
            if (output != nullptr) { std::fill_n(output, frameCount, 0.0f); }
        }
        if (isBypassed() || outputBuffers.empty()) { return; }

        const float masterGain = mMasterGain.load(std::memory_order_relaxed);
        for (auto& voice : mVoices) {
            if (!voice.active || !voice.clip) { continue; }
            const Clip& clip = *voice.clip;
            const size_t available = clip.left.size();
            if (available == 0) {
                voice.active = false;
                continue;
            }

            const double increment = clip.sampleRate / mOutputSampleRate;
            for (AUAudioFrameCount frame = 0; frame < frameCount; ++frame) {
                const size_t index = static_cast<size_t>(voice.position);
                if (index >= available) {
                    voice.active = false;
                    break;
                }

                const size_t next = std::min(index + 1, available - 1);
                const float fraction = static_cast<float>(voice.position - static_cast<double>(index));
                const float left = clip.left[index] + (clip.left[next] - clip.left[index]) * fraction;
                const auto& rightSamples = clip.right.empty() ? clip.left : clip.right;
                const float right = rightSamples[index] + (rightSamples[next] - rightSamples[index]) * fraction;
                const float amplitude = voice.gain * masterGain;

                if (outputBuffers[0] != nullptr) { outputBuffers[0][frame] += left * amplitude; }
                if (outputBuffers.size() > 1 && outputBuffers[1] != nullptr) {
                    outputBuffers[1][frame] += right * amplitude;
                }
                for (size_t channel = 2; channel < outputBuffers.size(); ++channel) {
                    if (outputBuffers[channel] != nullptr) {
                        outputBuffers[channel][frame] += (left + right) * 0.5f * amplitude;
                    }
                }
                voice.position += increment;
            }
        }

        for (float* output : outputBuffers) {
            if (output == nullptr) { continue; }
            for (AUAudioFrameCount frame = 0; frame < frameCount; ++frame) {
                output[frame] = std::clamp(output[frame], -1.0f, 1.0f);
            }
        }
    }

    void handleOneEvent(AUEventSampleTime now, const AURenderEvent* event) {
        switch (event->head.eventType) {
            case AURenderEventMIDI:
                handleMIDI1(event->MIDI);
                break;
            case AURenderEventMIDIEventList:
                handleMIDIEventList(now, &event->MIDIEventsList);
                break;
            case AURenderEventParameter:
            case AURenderEventParameterRamp:
                if (event->parameter.parameterAddress == 0) {
                    setGain(event->parameter.value);
                }
                break;
            default:
                break;
        }
    }

private:
    void trigger(uint8_t note, uint16_t velocity, uint16_t velocityMax) {
        const auto clip = std::atomic_load(&mClips[static_cast<size_t>(note)]);
        const uint8_t normalizedVelocity = static_cast<uint8_t>(
            std::min<uint32_t>(
                127,
                (static_cast<uint32_t>(velocity) * 127) / velocityMax
            )
        );
        enqueueTrigger(note, normalizedVelocity);
        if (!clip) { return; }

        // Fingersonic Beats is polyphonic: each pad hit receives its own voice.
        // Prefer an idle slot; when all 16 are busy, steal the oldest slot in
        // round-robin order so the render thread never allocates or blocks.
        Voice& voice = acquireVoice();
        voice.clip = clip;
        voice.position = 0.0;
        voice.gain = static_cast<float>(velocity) / static_cast<float>(velocityMax);
        voice.active = true;
    }

    void enqueueTrigger(uint8_t note, uint8_t velocity) {
        // Offline Bounce can run hundreds of times faster than the GUI. It
        // must only mix PCM, never queue AVPlayer work or depend on a timer.
        if (isRenderingOffline()) { return; }
        const uint32_t write = mTriggerWrite.load(std::memory_order_relaxed);
        const uint32_t next = (write + 1) % kTriggerQueueCapacity;
        if (next == mTriggerRead.load(std::memory_order_acquire)) {
            return;
        }
        mTriggerEvents[write] = {
            static_cast<uint16_t>(note | (static_cast<uint16_t>(velocity) << 8)),
            visualActivityGeneration()
        };
        mTriggerWrite.store(next, std::memory_order_release);
    }

    Voice& acquireVoice() {
        for (size_t offset = 0; offset < mVoices.size(); ++offset) {
            const size_t index = (mNextVoice + offset) % mVoices.size();
            if (!mVoices[index].active) {
                mNextVoice = (index + 1) % mVoices.size();
                return mVoices[index];
            }
        }
        Voice& voice = mVoices[mNextVoice];
        mNextVoice = (mNextVoice + 1) % mVoices.size();
        return voice;
    }

    void handleMIDI1(const AUMIDIEvent& event) {
        if (event.length < 3) { return; }
        const uint8_t status = event.data[0] & 0xF0;
        const uint8_t note = event.data[1] & 0x7F;
        const uint8_t velocity = event.data[2] & 0x7F;
        if (status == 0x90 && velocity > 0) {
            trigger(note, velocity, 127);
        }
    }

    void handleMIDIEventList(AUEventSampleTime, const AUMIDIEventList* midiEvent) {
        auto visitor = [](void* context, MIDITimeStamp, MIDIUniversalMessage message) {
            auto* kernel = static_cast<VideoSamplerDSPKernel*>(context);
            if (message.type == kMIDIMessageTypeChannelVoice2 &&
                message.channelVoice2.status == kMIDICVStatusNoteOn &&
                message.channelVoice2.note.velocity > 0) {
                kernel->trigger(
                    message.channelVoice2.note.number,
                    message.channelVoice2.note.velocity,
                    std::numeric_limits<uint16_t>::max()
                );
            } else if (message.type == kMIDIMessageTypeChannelVoice1 &&
                       message.channelVoice1.status == kMIDICVStatusNoteOn &&
                       message.channelVoice1.note.velocity > 0) {
                kernel->trigger(
                    message.channelVoice1.note.number,
                    message.channelVoice1.note.velocity,
                    127
                );
            }
        };
        MIDIEventListForEachEvent(&midiEvent->eventList, visitor, this);
    }

    void resetVoices() {
        for (auto& voice : mVoices) {
            voice.active = false;
            voice.clip.reset();
            voice.position = 0.0;
        }
    }

    void invalidateVisualActivity() {
        mVisualActivityGeneration.fetch_add(1, std::memory_order_acq_rel);
    }

    struct TriggerEvent {
        uint16_t packed = 0;
        uint64_t generation = 0;
    };

    std::array<std::shared_ptr<const Clip>, 128> mClips;
    std::array<Voice, 16> mVoices;
    size_t mNextVoice = 0;
    static constexpr uint32_t kTriggerQueueCapacity = 128;
    std::array<TriggerEvent, kTriggerQueueCapacity> mTriggerEvents {};
    std::atomic<uint32_t> mTriggerRead { 0 };
    std::atomic<uint32_t> mTriggerWrite { 0 };
    std::atomic<bool> mRenderingOffline { false };
    std::atomic<uint64_t> mVisualActivityGeneration { 0 };
    int mChannelCount = 2;
    double mOutputSampleRate = 44100.0;
    std::atomic<float> mMasterGain { 1.0f };
    std::atomic<bool> mBypassed { false };
    AUAudioFrameCount mMaxFramesToRender = 4096;
};
