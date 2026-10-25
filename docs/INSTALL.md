# Video Sampler for Fingersonic Beats

## Installation and User Guide

Version: 0.4.6 (build 16) · Prepared: October 25, 2026

Video Sampler is a macOS AUv3 instrument. Assign local videos to ten pads, choose a clip for each one, and trigger their pictures and audio with MIDI. Audio is returned directly to your DAW's software instrument track.

## 1. Before you install

- Requires macOS 13.0 or later on an Apple Silicon or Intel Mac.
- Logic Pro is the primary host. Other AUv3 instrument hosts have not been individually verified.
- End users do not need Xcode, ffmpeg, or the source package.
- This is an ad-hoc-signed test distribution without an Apple Developer ID distribution signature or Apple notarization. macOS may block its first launch. Approve it only if you trust the publisher and download source.
- This is an AUv3 plug-in inside Video Sampler.app. Installing the complete app installs its Audio Unit extension; sampling and performance happen inside your host.

AUv3 installation differs from an AUv2 .component. Keep the complete app together. Do not extract VideoSamplerAU.appex or move files into /Library/Audio/Plug-Ins/Components. The installed container app must remain available.

## 2. Install the AUv3 plug-in

1. Save your work and quit Logic Pro and other audio hosts.
2. Double-click the downloaded AUv3 ZIP to extract it.
3. Drag the complete Video Sampler.app into Applications, at /Applications.
4. When upgrading, back up the previous version before replacing it. Avoid keeping extra copies in Downloads or on the Desktop, where macOS may also discover them.
5. Open Video Sampler from Applications once. If it is blocked, follow the next section.
6. The container displays setup instructions. Open Logic Pro launches the installed Logic Pro or Logic Pro Creator Studio. The sampler editor itself opens inside your host.
7. Open Logic Pro, allow its Audio Unit scan to finish, and load the plug-in as described in section 4.

Keep /Applications/Video Sampler.app installed. You can close its setup window and use the AU from Logic without keeping the container window open.

## 3. First launch: unidentified developer approval

Depending on macOS, you may see “unidentified developer,” “developer cannot be verified,” or “Apple could not verify” wording. Approval creates an exception for the app; it does not add Apple notarization.

1. First try opening Video Sampler.app from Applications.
2. If blocked, dismiss the warning while keeping the app.
3. Go to Apple menu → System Settings → Privacy & Security and scroll to Security.
4. Find the warning for Video Sampler and click Open Anyway.
5. Authenticate if requested, then confirm Open.
6. If the Audio Unit extension is separately blocked during scanning, quit Logic, review its warning in the same settings page, and reopen Logic after approving the trusted extension.

If Open Anyway is absent, try opening the installed app again before checking Settings. Managed Macs may require an administrator. Some older systems also offer approval through Control-click → Open; use the Settings procedure on newer versions.

A warning that software “will damage your computer,” a malware detection, or an actually corrupted file needs separate investigation. Stop and obtain a fresh, verified copy from the publisher instead of treating it as an ordinary developer-identification prompt.

No system-wide security changes or SIP changes are required by these instructions.

Apple's official guidance:
https://support.apple.com/en-us/102445

## 4. Load it in Logic Pro

1. Create or open a project and add a Software Instrument track.
2. In the channel strip's Instrument slot, choose AU Instruments → Fingersonic → Video Sampler → Stereo.
3. Open the plug-in editor to see the video display, hardware-style pads, and PAD EDITOR.

Use the Instrument slot. This instrument does not appear in the Audio FX or MIDI FX slots.

## 5. Load and trim a video

1. Click an empty pad, or select a pad and click Choose Video / Choose Local Video.
2. Select a local video that contains audio. Start with MP4 or MOV using H.264 video and AAC audio; actual format support depends on macOS decoding support for both tracks.
3. Newly loaded videos initially use the first two seconds, or the full duration if shorter. Adjust Start and End under PAD EDITOR → CLIP.
4. Dragging a slider previews the corresponding video frame. Releasing it reloads the clip audio; allow that operation to finish before triggering the pad.
5. Click Preview to audition it, or click the loaded pad again.
6. Repeat for the other pads. Each can use a different file and clip range.

Replace Video changes the source. Remove Video clears the selected pad's media. Reset All Pads resets the entire pad configuration.

## 6. Connect MIDI and map the pads

Connect Fingersonic Beats to the Mac using its supported MIDI connection and confirm that Logic receives its MIDI input. Hardware input is managed by Logic, so the plug-in has no separate device selector. You can also use another MIDI controller or draw the corresponding notes in Logic's Piano Roll.

To use MIDI Learn:

1. Select the pad you want to map.
2. Click MIDI Learn. The button changes to Play a MIDI note….
3. Hit the hardware pad or send the desired MIDI note.
4. Hit it again to test. The first hit assigns the note and may not trigger the new mapping.
5. Repeat for other pads. You can also use the Note stepper to assign a number from 0 to 127.

Default mapping:

| Pad | MIDI note number |
| --- | --- |
| OPEN HAT | 46 |
| CRASH | 49 |
| CLOSED HAT | 42 |
| SNARE | 38 |
| TOM 1 | 48 |
| KICK | 36 |
| TOM 2 | 45 |
| RIDE | 53 |
| FLOOR TOM | 43 |
| CRASH 2 | 57 |

Use note numbers rather than octave labels: different programs may call the same note C1 or C2. If your hardware preset uses different numbers, use MIDI Learn.

Velocity controls trigger volume. OUTPUT adjusts the plug-in's overall gain. Audio supports up to 16 simultaneous voices. Video shows up to ten pad sources, and retriggering a pad restarts that pad's picture.

## 7. Record and export

- Record a performance: select the software instrument track, enable the required MIDI input/recording state, and press Record in Logic. This records MIDI; the plug-in generates audio during playback.
- Export audio: use Bounce or Bounce in Place. Offline bounce renders audio without playing video.
- Record onto an audio track: route the instrument to a Bus, create an audio track with that Bus as its input, and record it.
- View the performance: keep the plug-in editor open. Closing it does not stop the audio output.
- Save a performance video: the plug-in has no combined-video exporter. Use a separate screen-recording workflow. A real-time audio bounce still exports audio, not the on-screen video layout.

## 8. Save projects and keep media available

Save your Logic project after configuring the pads. The plug-in stores pad assignments, clip ranges, MIDI notes, output gain, and file-access bookmarks with the host project.

Original videos are not automatically copied into the project. Keep the files available and avoid moving, renaming, or deleting them. When transferring a project to another Mac, transfer the videos too. If access is lost, re-select each affected video in the plug-in and save the project again. Settings that were never saved cannot be recovered from an older project.

Short clips are recommended. Audio is preloaded into memory, and long clips or many high-resolution videos increase memory and playback load.

## 9. Troubleshooting

### Video Sampler is missing in Logic

1. Confirm that the complete app is in /Applications and that first-launch approval is complete.
2. Check the Instrument slot on a Software Instrument track.
3. Quit and reopen Logic. If needed, restart the Mac.
4. Open Logic Pro → Settings (Preferences in older versions) → Plug-in Manager. Search for Fingersonic or Video Sampler and check that it is enabled.
5. If it is listed but validation failed, select it and choose Reset & Rescan Selection.

If the extension is still undiscovered, quit the host and use Terminal to register this installed extension, then reopen Logic:

```bash
pluginkit -a "/Applications/Video Sampler.app/Contents/PlugIns/VideoSamplerAU.appex"
```

Optional Audio Unit validation:

```bash
auval -v aumu vsmr FgSn
```

These are troubleshooting steps, not requirements for a normal installation. Leave the extension inside the app and leave unrelated plug-in files alone.

Apple's plug-in discovery guidance:
https://support.apple.com/en-us/122179

### Picture but no sound

Check that the source has a decodable audio track, loading has finished, OUTPUT is above zero, the Logic track is not muted, and Logic uses the intended output device. Try Preview first to distinguish playback issues from MIDI input or mapping issues.

### Preview works but the hardware does not trigger a pad

Check that Logic receives MIDI from the device and the intended instrument track is selected. Confirm the note number or repeat MIDI Learn.

### A file will not load, or media is missing after reopening a project

Make the video available locally, reconnect its drive if necessary, and use Choose Video / Replace Video to select it again. If needed, convert it to MP4/MOV with an AAC audio track. Renaming a file extension does not convert its encoding.

### Open Logic Pro cannot find the application

Version 0.4.6 discovers Logic Pro and Logic Pro Creator Studio by application identifier, including renamed apps and alternate installation locations registered with macOS. If neither is found, install and open Logic once, then retry. You can also open Logic yourself and load Video Sampler in its Instrument slot.

### The container is not a standalone sampler

This is expected. The container installs the AUv3 extension and shows setup instructions. The sampler editor runs in the host's Video Sampler plug-in window.

## 10. Uninstall and report problems

To uninstall, quit audio hosts and move /Applications/Video Sampler.app to the Trash. Reopen the host, or restart the Mac if its plug-in list has not refreshed. Keep your project and original media separately.

When reporting an issue, include the macOS version, processor type, Logic version, plug-in version, exact error message, and reproduction steps. Actual release test coverage is recorded in VERIFICATION.txt. Including both processor architectures is not a claim that every hardware and OS combination has been tested.
