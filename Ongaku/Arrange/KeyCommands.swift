//
//  KeyCommands.swift
//  Ongaku
//

import AppKit
import SwiftUI

/// Logic's single-key shortcuts for a project window: Space (play/stop), Return (go to
/// beginning), comma and period (back and forward a bar), Delete, R (record), C (cycle),
/// K (metronome), E (editor), X (mixer), Y (Library), I (Inspector), A (automation), G
/// (global tracks) and T (the Tool menu, then a tool's key). In the tracks area,
/// Option-Left and Right nudge the selected regions; in the Piano Roll, Q quantizes and
/// Option-arrows transpose and nudge.
///
/// They're handled with a local key monitor rather than SwiftUI focus, so they work wherever
/// you last clicked in the window, never press a focused toolbar button instead, and stay
/// out of the way while a text field is being edited.
///
/// The menus show these keys too, so they can be learned there. SwiftUI's menus may act on
/// them as key equivalents as well as this monitor, and before text fields see them, so
/// each key press is claimed once (see `claim`): whichever of the two comes second leaves
/// it alone, and a menu item chosen by a key typed into a text field gives it to the text
/// field instead. One monitor for the whole app offers each key to the project windows,
/// then sends a key without Command or Control past the menu bar, to the window it was
/// typed in, as AppKit would have done had no menu item matched.
@MainActor
final class KeyCommandMonitor {
  static let shared = KeyCommandMonitor()

  private var monitor: Any?
  private var models: [WeakModel] = []

  private struct WeakModel {
    weak var model: ProjectWindowModel?
  }

  func install(for model: ProjectWindowModel) {
    remove(model)
    models.append(WeakModel(model: model))
    if monitor == nil {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        self?.handle(event) ?? event
      }
    }
  }

  func remove(_ model: ProjectWindowModel) {
    models.removeAll { $0.model == nil || $0.model === model }
  }

  /// The last key press handled, by this monitor or a menu item. SwiftUI's menus can act on
  /// a key equivalent as well as this monitor, in either order, so whichever comes second
  /// for the same key press leaves it alone (otherwise G would show and hide the global
  /// tracks at once).
  private var claimedKeyPress: (timestamp: TimeInterval, keyCode: UInt16, windowNumber: Int)?

  /// Returns `true` the first time it's asked about a key press, `false` after that.
  func claim(_ event: NSEvent) -> Bool {
    let press = (event.timestamp, event.keyCode, event.windowNumber)
    if let claimedKeyPress, claimedKeyPress == press { return false }
    claimedKeyPress = press
    return true
  }

  /// For a menu item with a single-key shortcut: whether the key press that chose it (if
  /// one did) should run it. A press this monitor already handled doesn't; one typed into
  /// a text field goes to the text field instead.
  func menuShouldPerform() -> Bool {
    guard let event = NSApp.currentEvent, event.type == .keyDown else { return true }
    guard claim(event) else { return false }
    if let window = event.window, window.firstResponder is NSText {
      window.sendEvent(event)
      return false
    }
    return true
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    // Keys typed into a text field (the tempo, say) go the usual way, unclaimed: sending
    // them to the window here as well would type each one twice. A menu item they choose
    // hands them back to the field (see `menuShouldPerform`).
    if let window = event.window, window.firstResponder is NSText { return event }
    // A menu item already acted on this key press.
    guard claim(event) else { return nil }
    for entry in models {
      if let model = entry.model, model.handleKeyCommand(event) { return nil }
    }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    guard modifiers.isEmpty, let window = event.window else { return event }
    // A window's own key equivalents still come first (a sheet's default button on Return).
    if !window.performKeyEquivalent(with: event) {
      window.sendEvent(event)
    }
    return nil
  }
}

extension ProjectWindowModel {
  /// Which part of the window Delete applies to: the one clicked most recently. The Chord
  /// track is part of the tracks area, but Delete removes its selected chord when it was
  /// clicked last.
  enum EditingArea {
    case tracks, pianoRoll, chordTrack
  }

  /// Clicking in the tracks area or an editor ends text editing (in the tempo field, say),
  /// as in Logic, so the single-key shortcuts work again straight away.
  func beginEditing(in area: EditingArea) {
    // The tracks area's own click also arrives for clicks on the Chord track, in either order.
    activeEditingArea = area == .tracks && isPointerOverChordTrack ? .chordTrack : area
    isShowingToolMenu = false
    if hostWindow?.firstResponder is NSText {
      hostWindow?.makeFirstResponder(nil)
    }
  }

  /// Returns `true` if the event was a shortcut and has been handled.
  func handleKeyCommand(_ event: NSEvent) -> Bool {
    guard let window = hostWindow, event.window === window, window.isKeyWindow,
      !(window.firstResponder is NSText)
    else { return false }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    if isPianoRollEditing, handlePianoRollKey(event, modifiers: modifiers) { return true }
    if activeEditingArea == .tracks, handleTracksAreaKey(event, modifiers: modifiers) { return true }
    guard modifiers.isEmpty else { return false }

    // While the Tool menu is open, the next key picks a tool (Escape just closes it).
    if isShowingToolMenu {
      if !pickTool(forKey: event.charactersIgnoringModifiers?.lowercased() ?? ""), event.keyCode != 53 {
        return false
      }
      return true
    }

    switch event.keyCode {
    case 49:  // Space
      togglePlayback()
    case 36, 76:  // Return, Enter
      goToBeginning()
    case 51, 117:  // Delete, Forward Delete
      deleteSelectionInActiveArea()
    default:
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "c": toggleCycle()
      case "k": toggleMetronome()
      case "e": toggleEditor()
      case "x": toggleMixer()
      case "r": toggleRecording()
      case "y": toggleLibrary()
      case "o": toggleLoopBrowser()
      case "a": toggleAutomation()
      case "i": toggleInspector()
      case "t": showToolMenu()
      case "g": toggleGlobalTracks()
      case ",": moveByBars(-1)
      case ".": moveByBars(1)
      default: return false
      }
    }
    return true
  }
}

extension ProjectWindowModel {
  /// Whether the Piano Roll's notes are what keys edit: it's showing and was clicked last.
  var isPianoRollEditing: Bool {
    activeEditingArea == .pianoRoll && isEditorVisible && pianoRoll.shownEditor == .pianoRoll && pianoRoll.region != nil
  }

  /// The Piano Roll's own keys, as in Logic: Option-Up and Down transpose the selection a
  /// semitone (Shift for an octave), Option-Left and Right nudge it a grid step, and Q
  /// quantizes it.
  fileprivate func handlePianoRollKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
    guard !isShowingToolMenu else { return false }
    let isOption = modifiers == [.option] || modifiers == [.option, .shift]
    let octave = modifiers.contains(.shift)
    switch event.keyCode {
    case 126 where isOption: pianoRoll.transposeSelection(by: octave ? 12 : 1)  // Up
    case 125 where isOption: pianoRoll.transposeSelection(by: octave ? -12 : -1)  // Down
    case 123 where modifiers == [.option]: pianoRoll.nudgeSelection(by: -1)  // Left
    case 124 where modifiers == [.option]: pianoRoll.nudgeSelection(by: 1)  // Right
    default:
      guard modifiers.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "q" else { return false }
      pianoRoll.quantizeSelection()
    }
    return true
  }
}

extension ProjectWindowModel {
  /// The tracks area's own keys, as in Logic: Option-Left and Right nudge the selected
  /// regions a snap grid step.
  fileprivate func handleTracksAreaKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
    guard !isShowingToolMenu, modifiers == [.option], !selectedRegionIDs.isEmpty else { return false }
    switch event.keyCode {
    case 123: nudgeSelectedRegions(by: -1)  // Left
    case 124: nudgeSelectedRegions(by: 1)  // Right
    default: return false
    }
    return true
  }
}

/// Reports the window a view is in, so key commands can tell which window they belong to.
struct WindowReader: NSViewRepresentable {
  let onWindowChange: (NSWindow?) -> Void

  func makeNSView(context: Context) -> NSView {
    WindowReportingView(onWindowChange: onWindowChange)
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class WindowReportingView: NSView {
    let onWindowChange: (NSWindow?) -> Void

    init(onWindowChange: @escaping (NSWindow?) -> Void) {
      self.onWindowChange = onWindowChange
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onWindowChange(window)
    }
  }
}
