//
//  AgentAreas.swift
//  OngakuCore
//

import Foundation

/// The agent tools in groups, by what they work on, for the on-device assistant.
///
/// The on-device model's context holds about 4,096 tokens: room for two or three tools'
/// definitions, not all of them. So a first, small request chooses the tools a request needs
/// from a list of them, area by area, and the request is answered with those only.
public enum AgentArea: String, CaseIterable, Sendable {
  case song, tracks, regions, notes, players, mixing, listening, library

  /// What the area covers, for the model that sorts requests.
  public var summary: String {
    switch self {
    case .song: "tempo, time signature, key, sections, markers, chords, the cycle"
    case .tracks: "making, renaming, deleting, reordering tracks; instruments; MIDI effects"
    case .regions: "making, moving, copying, splitting, joining, deleting regions; sections of the song"
    case .notes: "writing, changing, quantizing, transposing, deleting notes in a region"
    case .players: "Drummer and session players: adding, editing, converting to notes"
    case .mixing: "effects, sends, automation, volume and pan"
    case .listening: "playing, stopping, analysing the mix, mastering, bouncing, saving, undo and redo"
    case .library: "loops, samples and impulse responses from sound libraries"
    }
  }

  /// The tools every area has: the song's overview, and undo.
  public static let sharedToolNames = ["get_song", "undo"]

  /// The area's own tools, at most eight.
  public var toolNames: [String] {
    switch self {
    case .song:
      ["set_tempo", "set_time_signature", "set_key", "set_arrangement", "add_marker", "set_chords", "detect_chords", "set_cycle"]
    case .tracks:
      ["create_track", "update_track", "delete_tracks", "move_track", "get_track", "list_instruments", "add_midi_effect", "remove_midi_effect"]
    case .regions:
      ["get_track", "create_region", "edit_region", "copy_region", "delete_regions", "split_region", "join_regions", "edit_section"]
    case .notes:
      ["get_track", "get_notes", "create_region", "add_notes", "delete_notes", "transform_notes", "edit_region"]
    case .players:
      ["list_session_players", "add_drummer", "add_session_player", "edit_session_part", "convert_to_notes", "set_chords"]
    case .mixing:
      ["list_effects", "add_effect", "get_effect", "set_effect", "remove_effect", "set_send", "add_automation", "clear_automation"]
    case .listening:
      ["play", "stop", "redo", "analyze_mix", "master_song", "set_master_volume", "bounce", "save"]
    case .library:
      ["find_loops", "add_loop", "find_impulse_responses", "get_track", "add_effect", "play", "stop"]
    }
  }

  /// The tools a request in this area gets.
  public var tools: [AgentTool] {
    (Self.sharedToolNames + toolNames).compactMap(AgentToolbox.tool(named:))
  }
}

extension AgentToolbox {
  /// A short version of the guide, for the on-device model's small context: how the tools
  /// describe music, and how to behave.
  public static func compactInstructions(pitchNaming: PitchNaming = .logic) -> String {
    """
    You are the assistant in Ongaku Studio, a Mac DAW like Logic Pro. Use the tools to do \
    what the person asks in the open song; every tool call is one step they can undo. Change \
    only what they asked for, and leave out arguments you don't need: tools that add a part \
    (a Drummer, a player, a loop) make its track when "track" is left out. If a tool fails, read its message and try again differently, \
    or explain the problem. Answer in one or two short sentences.
    Positions are "bar:beat" from 1 ("5:3" is beat 3 of bar 5). Note times in a region are in \
    beats from its start. Pitches are MIDI numbers or \(pitchNames(pitchNaming)). Tracks can be \
    given by name or number; regions by the ids get_song and get_track show.
    """
  }
}
