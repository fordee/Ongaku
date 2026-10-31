//
//  GeneralMIDI.swift
//  OngakuCore
//

import Foundation

/// The General MIDI Level 1 instrument set, which the built-in sampler plays from the
/// system's sound bank.
public enum GeneralMIDI {
  public struct Family: Identifiable, Sendable {
    public var name: String
    /// The first program number in the family; each family has eight programs.
    public var firstProgram: Int
    public var id: Int { firstProgram }

    public var programs: Range<Int> { firstProgram..<(firstProgram + 8) }
  }

  public static let families: [Family] = [
    "Piano", "Chromatic Percussion", "Organ", "Guitar", "Bass", "Strings", "Ensemble", "Brass",
    "Reed", "Pipe", "Synth Lead", "Synth Pad", "Synth Effects", "Ethnic", "Percussive", "Sound Effects",
  ].enumerated().map { Family(name: $1, firstProgram: $0 * 8) }

  /// The 0-based MIDI channel General MIDI reserves for drums (channel 10 on hardware).
  public static let percussionChannel = 9

  /// The GS drum kits in the system sound bank, by program number. (The bank answers to
  /// Room and Jazz too, but plays the standard kit for them, so they aren't listed.)
  public static let drumKits: [(kit: Int, name: String)] = [
    (0, "Standard Kit"), (16, "Power Kit"), (24, "Electronic Kit"), (25, "TR-808 Kit"),
    (40, "Brush Kit"), (48, "Orchestra Kit"), (56, "Sound Effects Kit"),
  ]

  public static func drumKitName(_ kit: Int) -> String {
    drumKits.first { $0.kit == kit }?.name ?? "Drum Kit"
  }

  public static func programName(_ program: Int) -> String {
    programNames.indices.contains(program) ? programNames[program] : "Program \(program + 1)"
  }

  private static let programNames = [
    "Acoustic Grand Piano", "Bright Acoustic Piano", "Electric Grand Piano", "Honky-tonk Piano",
    "Electric Piano 1", "Electric Piano 2", "Harpsichord", "Clavinet",
    "Celesta", "Glockenspiel", "Music Box", "Vibraphone", "Marimba", "Xylophone", "Tubular Bells", "Dulcimer",
    "Drawbar Organ", "Percussive Organ", "Rock Organ", "Church Organ", "Reed Organ", "Accordion", "Harmonica",
    "Tango Accordion",
    "Nylon Guitar", "Steel Guitar", "Jazz Guitar", "Clean Guitar", "Muted Guitar", "Overdriven Guitar",
    "Distortion Guitar", "Guitar Harmonics",
    "Acoustic Bass", "Fingered Bass", "Picked Bass", "Fretless Bass", "Slap Bass 1", "Slap Bass 2", "Synth Bass 1",
    "Synth Bass 2",
    "Violin", "Viola", "Cello", "Contrabass", "Tremolo Strings", "Pizzicato Strings", "Orchestral Harp", "Timpani",
    "String Ensemble 1", "String Ensemble 2", "Synth Strings 1", "Synth Strings 2", "Choir Aahs", "Voice Oohs",
    "Synth Voice", "Orchestra Hit",
    "Trumpet", "Trombone", "Tuba", "Muted Trumpet", "French Horn", "Brass Section", "Synth Brass 1", "Synth Brass 2",
    "Soprano Sax", "Alto Sax", "Tenor Sax", "Baritone Sax", "Oboe", "English Horn", "Bassoon", "Clarinet",
    "Piccolo", "Flute", "Recorder", "Pan Flute", "Blown Bottle", "Shakuhachi", "Whistle", "Ocarina",
    "Square Lead", "Sawtooth Lead", "Calliope Lead", "Chiff Lead", "Charang Lead", "Voice Lead", "Fifths Lead",
    "Bass + Lead",
    "New Age Pad", "Warm Pad", "Polysynth Pad", "Choir Pad", "Bowed Pad", "Metallic Pad", "Halo Pad", "Sweep Pad",
    "Rain", "Soundtrack", "Crystal", "Atmosphere", "Brightness", "Goblins", "Echoes", "Sci-Fi",
    "Sitar", "Banjo", "Shamisen", "Koto", "Kalimba", "Bagpipe", "Fiddle", "Shanai",
    "Tinkle Bell", "Agogo", "Steel Drums", "Woodblock", "Taiko Drum", "Melodic Tom", "Synth Drum", "Reverse Cymbal",
    "Guitar Fret Noise", "Breath Noise", "Seashore", "Bird Tweet", "Telephone Ring", "Helicopter", "Applause",
    "Gunshot",
  ]
}
