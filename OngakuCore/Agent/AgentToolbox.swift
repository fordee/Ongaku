//
//  AgentToolbox.swift
//  OngakuCore
//

import Foundation

/// Every tool an agent can use in Ongaku, and the guide agents get when they connect.
public enum AgentToolbox {
  public static let tools: [AgentTool] =
    readingTools + songTools + trackTools + noteTools + sessionPlayerTools + mixingTools + listeningTools + libraryTools

  public static func tool(named name: String) -> AgentTool? {
    tools.first { $0.name == name }
  }

  /// Runs a tool by name.
  @MainActor
  public static func call(_ name: String, arguments: [String: AgentValue], in session: any AgentSession) async throws -> AgentValue {
    guard let tool = tool(named: name) else { throw AgentError.unknownTool(name) }
    return try await tool.call(arguments, in: session)
  }

  /// What an agent is told when it connects: how Ongaku's tools describe music, and a way
  /// to work.
  public static let instructions = """
    Ongaku Studio is a Mac DAW like Logic Pro. These tools work on the song open in its \
    frontmost window; the person sees every change as you make it, and each tool call is \
    one step they can undo.

    Units:
    - Positions are "bar:beat", 1-based: "1:1" is the start of the song, "5:3" is beat 3 of \
    bar 5, "5:2.5" is halfway through beat 2. A bare bar number ("5") is the start of the bar.
    - Note timing inside a region is in beats (quarter notes) from the region's start: \
    start 0 is the region's first beat, length 0.5 is an eighth note.
    - Pitches are MIDI numbers or names with C4 = 60 (middle C), such as "F#3" or "Bb2". \
    On drum tracks, General MIDI drum names work: "kick", "snare", "closed hat", "crash". \
    Ongaku's Piano Roll, like Logic, labels middle C "C3", so a note the person reads off \
    the Piano Roll as C3 is C4 here.
    - Ids are short strings from get_song and get_track; tracks can also be named or numbered.

    A good way to make a song:
    1. get_song to see what's there; set_tempo, set_time_signature and set_key.
    2. set_arrangement to lay out sections (Intro, Verse, Chorus…).
    3. set_chords, from chord symbols or a progression (list_session_players lists them).
    4. add_drummer, then add_session_player for bass and keys; they follow the sections \
    and chords.
    5. create_track and create_region with notes for melodies and parts of your own. If \
    the person has added sound libraries, list_instruments with a search finds their \
    instruments (a sampled piano, strings…), and find_loops and add_loop their loops.
    6. play so the person can listen; ask what they think, and keep changing it.
    7. Mix: update_track for levels and pan, add_effect (EQ, compression), an aux track \
    with a Reverb and set_send to it, add_automation for fades and builds.
    8. analyze_mix to measure loudness and balance (you can't hear it, but this tells you \
    what stands out), then master_song, and bounce for a file.
    """
}
