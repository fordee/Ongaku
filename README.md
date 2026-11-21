# Ongaku Studio

A Logic Pro–style digital audio workstation for the Mac, written in Swift and SwiftUI.

![Ongaku Studio's project window: tracks with session player regions, a melody, a vocal and a drum loop, above the mixer](Docs/Manual/images/project-window.png)

Ongaku Studio is a personal project: a DAW I'm building for myself, in the open. It aims to work the way Logic Pro does, with a dark arrange window, piano roll, mixer and session players, while being small enough for one person to read and change.

The [user manual](Docs/Manual/README.md) explains every feature, step by step.

## Features

**Arranging and editing**
- Audio and software instrument tracks, regions, fades and crossfades, looped regions
- Logic-style tools (pointer, pencil, eraser, scissors, glue, mute, fade), clipboard, repeat, option-drag copies and section edits between the locators
- Markers, arrangement, tempo, signature and Chord tracks
- Track stacks (summing stacks), track freeze and plug-in delay compensation
- Drag tracks to reorder them, vertical zoom, and hidden tracks

**MIDI**

![The Piano Roll, with notes coloured by velocity and the velocity lane below](Docs/Manual/images/piano-roll.png)

- Piano Roll with quantize (including triplet and mixed grids), velocity and note functions
- Score editor: regions as notation (grand and drum staves, triplets, chord symbols) with Pencil and Eraser, printing, PDF and MusicXML export
- Step Editor, Event List, Step Sequencer pattern regions and MIDI Draw lanes for controllers, pitch bend and aftertouch
- MIDI FX: Arpeggiator, Chord Trigger, Scale Quantize, Note Repeater, Transposer and more

**Recording and audio editing**
- Audio and MIDI recording, cycle recording into take folders, quick-swipe comping
- Flex Time, Flex Pitch and Smart Tempo (pure Swift and Accelerate DSP)

**Session players**
- A Drummer that plays each section of the song, and bass and keyboard players that follow the Chord track

**Mixing**
- Channel strips with inserts, aux sends, groups, meters and automation of volume, pan, sends and the parameters of inserts, instruments and MIDI effect plug-ins
- Other makers' Audio Unit instruments, effects and MIDI effects, with a Plug-in Manager, presets, side chains and multi-output instruments
- Bounce to audio files

**Ongaku plug-ins**
- An AUv3 extension inside the app, with C++ real-time kernels behind SwiftUI windows: Channel EQ, Compressor, Reverb, Convolution Reverb, Delay, Noise Gate, Transient Shaper, Maximizer, De-Esser, Saturation, Doubler, Vocal Strip, Chorus, Flanger, Phaser, Tremolo, Multiband Compressor, Gain and Tuner; Retro Synth, Drum Machine, Sampler (with key and velocity zones), Electric Piano, Organ and Session Drummer instruments
- They're ordinary Audio Units, so they also work in Logic Pro, GarageBand and other Mac hosts

**Sounds and interchange**
- Sound libraries from any folder (Logic Pro's or GarageBand's, sample packs, SoundFonts): a Loop Browser whose loops follow the song's tempo and key, and EXS, SoundFont, DLS and SFZ sampler instruments
- Standard MIDI files in and out
- Stem Splitter: any audio region split into drums, bass, other and vocals on this Mac (Meta's HTDemucs, run in Swift)
- DAWproject in and out: whole songs (audio, mixer, Audio Unit plug-ins, automation) to and from Bitwig, Studio One, Cubase, Reaper and others
- MusicXML and PDF export of the Score editor's notation

**AI agents**
- The Assistant: ask for a change in plain words and Apple Intelligence makes it in the open song, on this Mac, with the same tools MCP agents use. Every change can be undone.
- An optional MCP server, off by default, that lets agents such as Claude Code compose, arrange, mix, master and bounce in the open song, one undoable step at a time. See [Chapter 11 of the manual](Docs/Manual/11-ai-agents.md).

## Requirements

- macOS 27 or later
- Xcode 27 or later

## Building

1. Clone the repository and open `Ongaku.xcodeproj`.
2. Choose your own team under Signing & Capabilities for each target (the app, OngakuCore, OngakuEngine and OngakuEffects), or build with "Sign to Run Locally".
3. For the Stem Splitter, run `Scripts/fetch-stem-model.sh` once. It downloads Meta's HTDemucs model (84 MB, MIT licence) into `Ongaku/StemModel` and checks it, and the build bundles it with the app. It isn't kept in git; without it, the app builds and runs, but Split into Stems says the model isn't installed.
4. Build and run the **Ongaku** scheme.

The Ongaku plug-ins register with the system once the app has run. You can check them with `auval -a | grep Ongk`.

## Project layout

| Folder | What's in it |
| --- | --- |
| `OngakuCore` | The model, edit commands with undo, persistence, MIDI file import and export, DSP and the playback plan; no UI or audio engine |
| `OngakuEngine` | The real-time engine on AVAudioEngine: track channels, instruments, recording, metronome, bounce |
| `OngakuEffects` | The AUv3 extension with the Ongaku effects and instruments (C++ DSP, SwiftUI windows) |
| `Ongaku` | The app: arrange window, editors, mixer, inspector, Library and settings |
| `OngakuCoreTests`, `OngakuTests`, `OngakuUITests` | Swift Testing unit tests and XCUITest UI tests |

## Tests

Run the tests from Xcode (Product › Test). A few tests read files that exist only on my Mac and are skipped elsewhere.

## A note on Logic Pro

Ongaku Studio takes its workflow from Logic Pro, but it isn't affiliated with or endorsed by Apple, and it can't open Logic projects or use Logic's own instruments and effects. If you have Logic's or GarageBand's sound library, you can add it as a sound library and play its loops and sampler instruments from your own copy. The repository doesn't include any Apple sound content. The General MIDI sounds and drum kits Ongaku can play come with macOS.

## Contributing

This is a personal project, so I may not get to issues or merge pull requests quickly, or at all. Bug reports and ideas are still welcome.

## License

Copyright © 2026 John Forde.

Ongaku Studio is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. It's distributed in the hope that it will be useful, but without any warranty; without even the implied warranty of merchantability or fitness for a particular purpose. See [LICENSE](LICENSE) for the full terms.

In short: you can use, study, change and share it, including selling copies, as long as anything you distribute that's based on it is also released under the GPL with its source code.

## Third-party code

Swift packages, fetched by Xcode when you build:

| Package | Licence |
| --- | --- |
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | MIT and Apache 2.0 |
| [SwiftNIO](https://github.com/apple/swift-nio), [Swift Log](https://github.com/apple/swift-log), [Swift System](https://github.com/apple/swift-system), [Swift Collections](https://github.com/apple/swift-collections), [Swift Atomics](https://github.com/apple/swift-atomics) | Apache 2.0 |
| [EventSource](https://github.com/mattt/eventsource) | MIT |

Bundled with the app:

| Component | Licence |
| --- | --- |
| [HTDemucs](https://github.com/facebookresearch/demucs) (Hybrid Transformer Demucs) model weights, used by the Stem Splitter; run by Ongaku's own Swift code | MIT (Meta Platforms), included as `Ongaku/StemModel/Demucs-LICENSE.txt` |
