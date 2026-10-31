//
//  OngakuCommands.swift
//  Ongaku
//

import AppKit
import OngakuCore
import OngakuEngine
import SwiftUI

extension FocusedValues {
  /// The model of the frontmost project window, for menu commands.
  @Entry var projectWindow: ProjectWindowModel?
}

/// Menu bar commands for the frontmost project window.
///
/// Logic's single-key shortcuts (Space, Return, comma, period, Delete, R, C, K, E, X, Y, I, A, G)
/// are shown on their menu items here and handled by `KeyCommandMonitor`. Their actions go
/// through `singleKey`, so a key press the monitor handled isn't acted on twice, and one
/// typed into a text field goes there.
struct OngakuCommands: Commands {
  @FocusedValue(\.projectWindow) private var window

  /// Whether a text field is being edited, in which case Cut, Copy, Paste and Select All are
  /// its own.
  private var isEditingText: Bool {
    NSApp.keyWindow?.firstResponder is NSText
  }

  /// Runs an edit on the regions, or the standard text action while typing.
  private func edit(text action: Selector, regions: (ProjectWindowModel) -> Void) {
    if isEditingText || window == nil {
      NSApp.sendAction(action, to: nil, from: nil)
    } else if let window {
      regions(window)
    }
  }

  /// Runs a menu item that has a single-key shortcut, unless the key press that chose it
  /// was already handled by `KeyCommandMonitor` or was typed into a text field.
  private func singleKey(_ action: () -> Void) {
    if KeyCommandMonitor.shared.menuShouldPerform() { action() }
  }

  var body: some Commands {
    CommandGroup(replacing: .pasteboard) {
      Button("Cut") { edit(text: #selector(NSText.cut(_:))) { $0.editCut() } }
        .keyboardShortcut("x", modifiers: .command)
      Button("Copy") { edit(text: #selector(NSText.copy(_:))) { $0.editCopy() } }
        .keyboardShortcut("c", modifiers: .command)
      Button("Paste") { edit(text: #selector(NSText.paste(_:))) { $0.editPaste() } }
        .keyboardShortcut("v", modifiers: .command)
      Button("Select All") { edit(text: #selector(NSText.selectAll(_:))) { $0.editSelectAll() } }
        .keyboardShortcut("a", modifiers: .command)
    }

    CommandGroup(after: .pasteboard) {
      Divider()
      Button(window?.isPianoRollEditing == true ? "Repeat Notes" : "Repeat Regions") { window?.editRepeat() }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(window?.canRepeat != true)
      Button("Split Regions at Playhead") { window?.splitAtPlayhead() }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(window == nil)
      Button("Join Regions") { window?.joinSelectedRegions() }
        .keyboardShortcut("j", modifiers: .command)
        .disabled((window?.selectedRegionIDs.count ?? 0) < 2)
      // Not Logic's ⌃⌘F, which is the system's Enter Full Screen.
      Button("Pack Take Folder") { window?.packTakeFolder() }
        .keyboardShortcut("f", modifiers: [.command, .option])
        .disabled((window?.selectedRegionIDs.count ?? 0) < 2)
      Button("Delete Selection") { singleKey { window?.deleteSelectionInActiveArea() } }
        .keyboardShortcut(.delete, modifiers: [])
        .disabled(window == nil)
      Divider()
      Menu("Section Between Locators") {
        Button("Cut Section") { window?.cutSection() }
          .keyboardShortcut("x", modifiers: [.command, .control])
        Button("Insert Silence") { window?.insertSilence() }
          .keyboardShortcut("z", modifiers: [.command, .control])
        Button("Repeat Section") { window?.repeatSection() }
          .keyboardShortcut("r", modifiers: [.command, .control])
      }
      .disabled(window?.locatorRange == nil)
    }

    CommandMenu("Track") {
      Group {
        Button("New Audio Track") { window?.addTrack(.audio) }
          .keyboardShortcut("a", modifiers: [.command, .option])
        Button("New Software Instrument Track") { window?.addTrack(.softwareInstrument) }
          .keyboardShortcut("s", modifiers: [.command, .option])
        Button("New Aux Track") { window?.addTrack(.aux) }
        Button("New Drummer Track") { window?.addDrummerTrack() }
          .keyboardShortcut("u", modifiers: [.command, .option])
        Button("New Drummer Track (Drum Machine)") { window?.addDrummerTrack(style: .electronic, kit: .drumMachine) }
        Button("New Bass Player Track") { window?.addPlayerTrack(.bass) }
        Button("New Keyboard Player Track") { window?.addPlayerTrack(.keys) }
      }
      .disabled(window == nil)
      Button("Duplicate Track") { window?.duplicateSelectedTrack() }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(window?.canDuplicateSelectedTrack != true)
      Button((window?.selectedTrackIDs.count ?? 0) > 1 ? "Delete Tracks" : "Delete Track") {
        edit(text: #selector(NSResponder.deleteToBeginningOfLine(_:))) { $0.deleteSelectedTracks() }
      }
      .keyboardShortcut(.delete, modifiers: .command)
      .disabled(window?.canDeleteSelectedTracks != true)
      Divider()
      Button("New Pattern Region") { window?.createPatternRegionAtPlayhead() }
        .disabled(window?.canCreatePatternRegionAtPlayhead != true)
      Divider()
      Button("Create Summing Stack") { window?.createSummingStack() }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(window?.canCreateSummingStack != true)
      Button("Flatten Stack") {
        if let window, let stackID = window.selectedStackID { window.flattenStack(stackID) }
      }
      .disabled(window?.selectedStackID == nil)
      Divider()
      Button(window?.isGlobalTracksVisible == true ? "Hide Global Tracks" : "Show Global Tracks") {
        singleKey { window?.toggleGlobalTracks() }
      }
      .keyboardShortcut("g", modifiers: [])
      .disabled(window == nil)
      Button("Add Arrangement Marker") { window?.addArrangementSection() }
        .disabled(window == nil)
      Button("Detect Chords") { window?.detectChordsInSelection() }
        .disabled(window?.chordDetectionRegionIDs.isEmpty != false)
      Divider()
      Button(window?.selectedTracksAreFrozen == true ? "Unfreeze Tracks" : "Freeze Tracks") {
        window?.toggleFreezeSelectedTracks()
      }
      .disabled(window?.canFreezeSelectedTracks != true)
    }

    CommandGroup(replacing: .importExport) {
      Group {
        Button("Import Audio Files…") { window?.activeImporter = .audio }
          .keyboardShortcut("i", modifiers: [.command, .shift])
        Button("Import MIDI File…") { window?.activeImporter = .midi }
        Divider()
        Button("Bounce…") { window?.showBounce() }
          .keyboardShortcut("b", modifiers: .command)
        Button("Export Project as MIDI File…") { window?.isShowingMIDIExporter = true }
        Divider()
        Button("Mastering…") { window?.showMastering() }
        Button("Analyze Whole Song for Mastering") { window?.analyzeSongForMastering() }
          .disabled(window?.songAnalysis != nil)
      }
      .disabled(window == nil)
    }

    CommandMenu("Transport") {
      Group {
        Button(window?.engine.isPlaying == true ? "Stop" : "Play") { singleKey { window?.togglePlayback() } }
          .keyboardShortcut(.space, modifiers: [])
        Button("Go to Beginning") { singleKey { window?.goToBeginning() } }
          .keyboardShortcut(.return, modifiers: [])
        Button("Back One Bar") { singleKey { window?.moveByBars(-1) } }
          .keyboardShortcut(",", modifiers: [])
        Button("Forward One Bar") { singleKey { window?.moveByBars(1) } }
          .keyboardShortcut(".", modifiers: [])
        Button(window?.engine.isRecording == true ? "Stop Recording" : "Record") { singleKey { window?.toggleRecording() } }
          .keyboardShortcut("r", modifiers: [])
        Divider()
        Button(window?.project.cycle.isEnabled == true ? "Turn Cycle Off" : "Turn Cycle On") { singleKey { window?.toggleCycle() } }
          .keyboardShortcut("c", modifiers: [])
        Button(window?.project.isMetronomeEnabled == true ? "Turn Metronome Off" : "Turn Metronome On") {
          singleKey { window?.toggleMetronome() }
        }
        .keyboardShortcut("k", modifiers: [])
        Divider()
        // Logic's marker key commands.
        Button("Create Marker") { window?.createMarker() }
          .keyboardShortcut("'", modifiers: .option)
        Button("Go to Previous Marker") { window?.goToMarker(forward: false) }
          .keyboardShortcut(",", modifiers: .option)
        Button("Go to Next Marker") { window?.goToMarker(forward: true) }
          .keyboardShortcut(".", modifiers: .option)
      }
      .disabled(window == nil)
    }

    CommandGroup(after: .toolbar) {
      Button(window?.isLibraryVisible == true ? "Hide Library" : "Show Library") { singleKey { window?.toggleLibrary() } }
        .keyboardShortcut("y", modifiers: [])
        .disabled(window == nil)
      Button(window?.isInspectorVisible == true ? "Hide Inspector" : "Show Inspector") { singleKey { window?.toggleInspector() } }
        .keyboardShortcut("i", modifiers: [])
        .disabled(window == nil)
      Button(window?.isAutomationVisible == true ? "Hide Automation" : "Show Automation") { singleKey { window?.toggleAutomation() } }
        .keyboardShortcut("a", modifiers: [])
        .disabled(window == nil)
      Button(window?.isEditorVisible == true ? "Hide Editor" : "Show Editor") { singleKey { window?.toggleEditor() } }
        .keyboardShortcut("e", modifiers: [])
        .disabled(window == nil)
      Button(window?.bottomPane == .mixer ? "Hide Mixer" : "Show Mixer") { singleKey { window?.toggleMixer() } }
        .keyboardShortcut("x", modifiers: [])
        .disabled(window == nil)
      Button("Zoom In") { window?.zoom(by: 1.5) }
        .keyboardShortcut("=", modifiers: .command)
        .disabled(window == nil)
      Button("Zoom Out") { window?.zoom(by: 1 / 1.5) }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(window == nil)
      Divider()
    }
  }
}
