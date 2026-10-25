#import <AudioToolbox/AudioToolbox.h>
#include <array>
#include <cmath>
#include <cstdio>
#include <thread>
#include <span>
#include "../VideoSamplerAU/DSP/VideoSamplerDSPKernel.hpp"

int main() {
    VideoSamplerDSPKernel kernel;
    kernel.initialize(2, 48000.0);

    constexpr std::array<float, 4> left {0.25f, 0.50f, -0.25f, -0.50f};
    constexpr std::array<float, 4> right {-0.25f, -0.50f, 0.25f, 0.50f};
    kernel.setClip(36, left.data(), right.data(), 4, 48000.0);

    AURenderEvent event {};
    event.MIDI.eventType = AURenderEventMIDI;
    event.MIDI.length = 3;
    event.MIDI.data[0] = 0x90;
    event.MIDI.data[1] = 36;
    event.MIDI.data[2] = 127;
    kernel.handleOneEvent(0, &event);

    std::array<float, 4> outLeft {};
    std::array<float, 4> outRight {};
    std::array<float*, 2> pointers {outLeft.data(), outRight.data()};
    kernel.process(std::span<float*>(pointers), 0, 4);

    for (size_t index = 0; index < left.size(); ++index) {
        if (std::abs(outLeft[index] - left[index]) > 0.0001f ||
            std::abs(outRight[index] - right[index]) > 0.0001f) {
            std::fprintf(stderr, "DSP mismatch at frame %zu\n", index);
            return 1;
        }
    }

    const uint32_t firstTrigger = kernel.consumeNextTriggerEvent();
    if ((firstTrigger & 0xFF) != 36 || ((firstTrigger >> 8) & 0xFF) != 127) {
        std::fprintf(stderr, "MIDI trigger was not reported\n");
        return 2;
    }

    kernel.initialize(2, 48000.0);
    constexpr std::array<float, 4> voiceA {0.10f, 0.10f, 0.10f, 0.10f};
    constexpr std::array<float, 4> voiceB {0.20f, 0.20f, 0.20f, 0.20f};
    constexpr std::array<float, 4> voiceC {0.30f, 0.30f, 0.30f, 0.30f};
    kernel.setClip(36, voiceA.data(), voiceA.data(), 4, 48000.0);
    kernel.setClip(38, voiceB.data(), voiceB.data(), 4, 48000.0);
    kernel.setClip(42, voiceC.data(), voiceC.data(), 4, 48000.0);

    for (const uint8_t note : {uint8_t(36), uint8_t(38), uint8_t(42)}) {
        event.MIDI.data[1] = note;
        kernel.handleOneEvent(4, &event);
    }

    std::array<float, 1> polyOutput {};
    std::array<float*, 1> polyPointer {polyOutput.data()};
    kernel.process(std::span<float*>(polyPointer), 4, 1);
    if (std::abs(polyOutput[0] - 0.60f) > 0.0001f) {
        std::fprintf(stderr, "Three simultaneous voices were not mixed\n");
        return 3;
    }

    for (const uint8_t expected : {uint8_t(36), uint8_t(38), uint8_t(42)}) {
        const uint32_t queued = kernel.consumeNextTriggerEvent();
        if ((queued & 0xFF) != expected || ((queued >> 8) & 0xFF) != 127) {
            std::fprintf(stderr, "Simultaneous MIDI trigger queue lost an event\n");
            return 4;
        }
    }
    if (kernel.consumeNextTriggerEvent() != std::numeric_limits<uint32_t>::max()) {
        std::fprintf(stderr, "Trigger queue did not drain\n");
        return 5;
    }

    kernel.reset();
    kernel.setRenderingOffline(true);
    for (const uint8_t note : {uint8_t(36), uint8_t(38), uint8_t(42)}) {
        event.MIDI.data[1] = note;
        kernel.handleOneEvent(0, &event);
    }
    kernel.process(std::span<float*>(polyPointer), 0, 1);
    if (std::abs(polyOutput[0] - 0.60f) > 0.0001f ||
        kernel.consumeNextTriggerEvent() != std::numeric_limits<uint32_t>::max()) {
        std::fprintf(stderr, "Offline polyphony must mix audio without queuing video\n");
        return 6;
    }
    for (int hit = 0; hit < 100000; ++hit) { kernel.handleOneEvent(hit, &event); }
    if (kernel.consumeNextTriggerEvent() != std::numeric_limits<uint32_t>::max()) {
        std::fprintf(stderr, "Offline event storm reached the GUI\n");
        return 7;
    }
    kernel.setRenderingOffline(false);
    kernel.handleOneEvent(0, &event); // Old live event, pending when Bounce starts.
    const auto generation = kernel.visualActivityGeneration();
    kernel.setRenderingOffline(true);
    kernel.setRenderingOffline(false); // Faster than a GUI timer tick.
    if (kernel.visualActivityGeneration() == generation ||
        kernel.consumeNextTriggerEvent() != std::numeric_limits<uint32_t>::max()) {
        std::fprintf(stderr, "A short Bounce replayed stale video events\n");
        return 8;
    }
    kernel.deInitialize();
    kernel.initialize(2, 96000.0);
    kernel.handleOneEvent(0, &event);
    kernel.process(std::span<float*>(polyPointer), 0, 1);
    if (std::abs(polyOutput[0] - 0.30f) > 0.0001f ||
        (kernel.consumeNextTriggerEvent() & 0xFF) != 42) {
        std::fprintf(stderr, "Reallocation lost clips or live MIDI did not resume\n");
        return 9;
    }
    kernel.reset();
    kernel.process(std::span<float*>(polyPointer), 0, 1);
    if (polyOutput[0] != 0.0f) {
        std::fprintf(stderr, "Transport reset left a playing voice\n");
        return 10;
    }

    std::atomic<bool> finished { false };
    std::thread producer([&] {
        for (int hit = 0; hit < 100000; ++hit) {
            if (hit % 1000 == 0) { kernel.setRenderingOffline((hit / 1000) % 2 == 0); }
            kernel.handleOneEvent(hit, &event);
        }
        finished.store(true, std::memory_order_release);
    });
    while (!finished.load(std::memory_order_acquire)) {
        const uint32_t queued = kernel.consumeNextTriggerEvent();
        if (queued != std::numeric_limits<uint32_t>::max() && (queued & 0xFF) != 42) {
            std::fprintf(stderr, "Concurrent trigger ring corrupted an event\n");
            std::abort();
        }
    }
    producer.join();
    kernel.discardTriggerEvents();

    std::puts("DSP tests passed: polyphony, offline event storm, fast mode transitions, reallocation, reset, concurrent queue");
    return 0;
}
