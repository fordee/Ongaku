//
//  AgentPrompts.swift
//  OngakuCore
//

import Foundation

/// Ready-made requests an agent's user can pick (MCP prompts): ways of working with
/// Ongaku's tools, written out step by step so any agent does them well.
public struct AgentPrompt: Sendable {
  public struct Argument: Sendable {
    public var name: String
    public var description: String
    public var isRequired: Bool
  }

  public var name: String
  public var title: String
  public var description: String
  public var arguments: [Argument]
  let text: @Sendable ([String: String]) -> String

  /// The request, with the person's answers filled in.
  public func message(_ values: [String: String]) throws -> String {
    for argument in arguments where argument.isRequired && (values[argument.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
      throw AgentError.missingArgument(argument.name)
    }
    return text(values)
  }

  public static let all: [AgentPrompt] = [sketchSong, arrangeIdea, writeMelody, mixAndMaster]

  public static func named(_ name: String) -> AgentPrompt? {
    all.first { $0.name == name }
  }

  static let sketchSong = AgentPrompt(
    name: "sketch_song", title: "Sketch a Song",
    description: "Builds a whole song in Ongaku Studio from a style and a mood: sections, chords, drums, bass, keys, a melody and a rough mix.",
    arguments: [
      Argument(name: "style", description: "The kind of music, such as \"lo-fi hip-hop\", \"indie folk\" or \"synth-pop\".", isRequired: true),
      Argument(name: "mood", description: "How it should feel, such as \"wistful\" or \"driving\".", isRequired: false),
      Argument(name: "length", description: "Roughly how long, such as \"2 minutes\" or \"32 bars\".", isRequired: false),
    ]
  ) { values in
    let mood = values["mood"].map { ", feeling \($0)" } ?? ""
    let length = values["length"].map { ", about \($0) long" } ?? ""
    return """
      Make a \(values["style"] ?? "") song in Ongaku Studio\(mood)\(length). Work step by step and \
      tell me briefly what you're doing:

      1. get_song to see what's there. Choose a tempo, time signature and key that suit the \
      style, and set them.
      2. set_arrangement with sections that suit the style (an intro, verses, choruses, \
      perhaps a bridge, an outro).
      3. set_chords for each section: chord symbols bar by bar, with the chorus lifting from \
      the verse. list_session_players has progressions if you want one.
      4. add_drummer in a style that suits (list_session_players), then add_session_player \
      for bass and for keys, choosing styles and settings per section.
      5. create_track for a lead sound (list_instruments) and write a melody with \
      create_region notes: a memorable chorus hook, a calmer verse, singable ranges.
      6. A rough mix: update_track levels and pan so the parts sit together.
      7. play from the start, and ask me what to change.
      """
  }

  static let arrangeIdea = AgentPrompt(
    name: "arrange_idea", title: "Arrange This Idea",
    description: "Turns what's in the song now (a loop or a few bars) into a full arrangement with sections, chords and session players.",
    arguments: [
      Argument(name: "direction", description: "Anything to aim for, such as \"build slowly\" or \"radio length\".", isRequired: false),
    ]
  ) { values in
    let direction = values["direction"].map { " Aim for this: \($0)." } ?? ""
    return """
      The song in Ongaku Studio has an idea in it. Turn it into a full arrangement.\(direction)

      1. get_song, then get_track and get_notes on the tracks with content, to understand \
      the idea: its tempo, key, chords (detect them from the notes if the Chord track is \
      empty) and length.
      2. Plan sections around it (intro, verse, chorus, bridge, outro), using the idea where \
      it fits best, and set_arrangement.
      3. copy_region and edit_region to place the idea's parts across the sections, varying \
      them so it develops: drop parts out in the intro and bridge, bring everything in for \
      the choruses.
      4. set_chords across the sections, then add_drummer and add_session_player parts that \
      follow them.
      5. play from the start and tell me what you did; ask what to change.
      """
  }

  static let writeMelody = AgentPrompt(
    name: "write_melody", title: "Write a Melody",
    description: "Writes a melody over the chords of a section, on a new track.",
    arguments: [
      Argument(name: "section", description: "Which section, such as \"Chorus\" (the first chorus if there are several).", isRequired: true),
      Argument(name: "sound", description: "The instrument, such as \"Flute\" or \"Retro Synth\".", isRequired: false),
      Argument(name: "character", description: "What it should be like, such as \"catchy and simple\" or \"soaring\".", isRequired: false),
    ]
  ) { values in
    let sound = values["sound"] ?? "a lead sound that suits the song"
    let character = values["character"].map { " Make it \($0)." } ?? ""
    return """
      Write a melody for the \(values["section"] ?? "") section of the song in Ongaku Studio, \
      played by \(sound).\(character)

      1. get_song for the key, tempo, sections and the Chord track under that section.
      2. create_track with that instrument, then create_region over the section.
      3. Write the notes with add_notes: land on chord tones on strong beats, move by step \
      with a few leaps, leave space to breathe, and repeat and vary a short motif so it's \
      memorable. Keep it in a singable range.
      4. play the section (set_cycle around it first) and ask me what I think.
      """
  }

  static let mixAndMaster = AgentPrompt(
    name: "mix_and_master", title: "Mix and Master",
    description: "Balances the song, adds EQ, compression and a shared reverb, checks it with analyze_mix, masters it and bounces it.",
    arguments: [
      Argument(name: "goal", description: "How it should sound, such as \"warm and intimate\" or \"loud and punchy\".", isRequired: false),
    ]
  ) { values in
    let goal = values["goal"].map { " Aim for: \($0)." } ?? ""
    return """
      Mix and master the song in Ongaku Studio.\(goal) Explain each step briefly.

      1. get_song, and analyze_mix to measure where it starts.
      2. Balance: update_track levels so the main part (vocal or lead) is clear, drums and \
      bass are solid, and the rest supports; pan parts apart for width.
      3. add_effect: a Channel EQ to clear low end from parts that don't need it, and a \
      Compressor where parts need evening out.
      4. Make an aux track with a Reverb (create_track kind aux, add_effect) and set_send \
      to it from the parts that need space.
      5. add_automation where a section should lift or a part should fade.
      6. analyze_mix again and compare: fix anything its notes point out.
      7. master_song, then analyze_mix to check the loudness, and bounce.
      8. Tell me the bounce's path, and ask me to listen.
      """
  }
}
