//
//  ImpulseResponsePicker.swift
//  Ongaku
//

import AVFAudio
import OngakuCore
import OngakuEngine
import SwiftUI

/// Impulse responses from the sound libraries for the Convolution Reverb.
///
/// The reverb runs in the Ongaku Effects extension, whose sandbox can't see the libraries'
/// folders, so the app reads the file and hands the reverb its audio in the plug-in's
/// settings, where a response loaded in its own window is kept too.
extension ProjectWindowModel {
  /// The settings key the Convolution Reverb keeps a loaded impulse response under, and how
  /// long a response it uses.
  static let impulseStateKey = "ongakuImpulse"
  static let maximumImpulseSeconds = 8.0

  /// Gives a Convolution Reverb insert the impulse response in `url`, as one undo step.
  func useImpulseResponse(at url: URL, forInsert pluginID: PluginReference.ID, on channelID: Track.ID) throws {
    let current = engine.insertState(pluginID, onTrack: channelID) ?? plugin(pluginID, on: channelID)?.state
    var state = current.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
    state[Self.impulseStateKey] = try Self.impulseState(contentsOf: url)
    let data = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    // Undo goes back to the settings the reverb has now, which reach the song only when its
    // window closes: store them first, as saving does.
    if let current {
      var settled = project
      try? SetPluginState(current, forPlugin: pluginID, on: channelID).apply(to: &settled)
      document.editor.load(settled)
    }
    perform(SetPluginState(data, forPlugin: pluginID, on: channelID))
  }

  private func plugin(_ pluginID: PluginReference.ID, on channelID: Track.ID) -> PluginReference? {
    let inserts = channelID == Project.stereoOutID ? project.stereoOutInserts : project.track(withID: channelID)?.channel.inserts
    return inserts?.first { $0.id == pluginID }
  }

  /// An impulse response as the reverb keeps it: its name, sample rate, and up to two
  /// channels of 32-bit floats one after the other, at most 8 seconds.
  nonisolated static func impulseState(contentsOf url: URL) throws -> [String: Any] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat
    let frames = AVAudioFrameCount(min(Double(file.length), maximumImpulseSeconds * format.sampleRate))
    guard frames > 1, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    try file.read(into: buffer, frameCount: frames)
    guard let channels = buffer.floatChannelData, buffer.frameLength > 1 else { throw CocoaError(.fileReadCorruptFile) }
    let channelCount = min(2, Int(format.channelCount))
    var audio = Data(capacity: Int(buffer.frameLength) * channelCount * MemoryLayout<Float>.size)
    for channel in 0..<channelCount {
      audio.append(UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)))
    }
    return [
      "name": url.deletingPathExtension().lastPathComponent, "sampleRate": format.sampleRate,
      "channels": channelCount, "audio": audio,
    ]
  }
}

/// A sheet listing the libraries' impulse responses, by library and folder: click one to
/// use it, or its play button to hear it.
struct ImpulseResponsePicker: View {
  let model: ProjectWindowModel
  let pluginID: PluginReference.ID
  let channelID: Track.ID

  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var error: String?

  private struct Entry: Identifiable {
    var libraryID: UUID
    var item: SoundLibraryItem
    var id: String { "\(libraryID)/\(item.path)" }
  }

  /// A folder of impulse responses, as on disk, with the folders inside it.
  private final class Folder {
    let id: String
    let name: String
    var folders: [Folder] = []
    var byName: [String: Folder] = [:]
    var entries: [Entry] = []

    init(id: String, name: String) {
      self.id = id
      self.name = name
    }

    func folder(_ name: String) -> Folder {
      if let existing = byName[name] { return existing }
      let folder = Folder(id: "\(id)/\(name)", name: name)
      byName[name] = folder
      folders.append(folder)
      return folder
    }

    var isEmpty: Bool { entries.isEmpty && folders.allSatisfy(\.isEmpty) }
  }

  /// A row: a folder's name, or an impulse response, indented by how deep it is.
  private struct Row: Identifiable {
    enum Kind {
      case folder(name: String, isOpen: Bool)
      case entry(Entry)
    }

    var id: String
    var depth: Int
    var kind: Kind
  }

  @State private var expanded: Set<String> = []

  /// One folder per library holding the impulse responses that match the search.
  private var libraryFolders: [Folder] {
    let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .split(whereSeparator: \.isWhitespace).map(String.init)
    return SoundLibraries.shared.libraries.compactMap { library in
      let root = Folder(id: library.id.uuidString, name: library.name)
      for (item, text) in zip(library.items, library.searchTexts) where item.kind == .impulseResponse {
        guard words.allSatisfy({ text.contains($0) }) else { continue }
        item.folders.reduce(root) { $0.folder($1) }.entries.append(Entry(libraryID: library.id, item: item))
      }
      return root.isEmpty ? nil : root
    }
  }

  /// The rows of the open folders (every folder while searching).
  private func rows(_ folders: [Folder]) -> [Row] {
    let isSearching = !query.trimmingCharacters(in: .whitespaces).isEmpty
    var rows: [Row] = []
    func add(_ folder: Folder, depth: Int) {
      guard !folder.isEmpty else { return }
      let isOpen = isSearching || expanded.contains(folder.id)
      rows.append(Row(id: "folder-\(folder.id)", depth: depth, kind: .folder(name: folder.name, isOpen: isOpen)))
      guard isOpen else { return }
      for child in folder.folders { add(child, depth: depth + 1) }
      rows += folder.entries.map { Row(id: $0.id, depth: depth + 1, kind: .entry($0)) }
    }
    for folder in folders { add(folder, depth: 0) }
    return rows
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Impulse Responses").font(Theme.font(13, weight: .semibold))
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(12)
      TextField("Search", text: $query)
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
      if let error {
        Text(error)
          .font(Theme.font(11))
          .foregroundStyle(Theme.record)
          .padding(.horizontal, 12)
          .padding(.bottom, 6)
      }
      Rectangle().fill(Theme.separator).frame(height: 1)
      let folders = libraryFolders
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(rows(folders)) { row in
            switch row.kind {
            case .folder(let name, let isOpen):
              folderRow(name: name, id: String(row.id.dropFirst("folder-".count)), depth: row.depth, isOpen: isOpen)
            case .entry(let entry):
              self.row(entry, depth: row.depth)
            }
          }
        }
      }
      .overlay {
        if folders.isEmpty {
          ContentUnavailableView(
            query.isEmpty ? "No Impulse Responses" : "No Matches", systemImage: "waveform.path",
            description: Text(query.isEmpty
              ? "Add a library with impulse responses (such as Logic’s Space Designer files) in Settings › Libraries."
              : "No impulse responses match “\(query)”."))
        }
      }
    }
    .frame(width: 440, height: 520)
    .background(Theme.panel)
    // Each library starts open, showing its own folders.
    .onAppear { expanded.formUnion(SoundLibraries.shared.libraries.map(\.id.uuidString)) }
    .onDisappear { LoopPreviewer.shared.stop() }
  }

  private func folderRow(name: String, id: String, depth: Int, isOpen: Bool) -> some View {
    Button {
      if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(Theme.font(9, weight: .semibold))
          .foregroundStyle(Theme.tertiaryText)
          .rotationEffect(.degrees(isOpen ? 90 : 0))
          .frame(width: 12)
        Image(systemName: "folder")
          .foregroundStyle(Theme.secondaryText)
        Text(name).fontWeight(.medium).lineLimit(1)
        Spacer()
      }
      .padding(.leading, 12 + CGFloat(depth) * 14)
      .padding(.trailing, 12)
      .padding(.vertical, 4)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
  }

  private func row(_ entry: Entry, depth: Int) -> some View {
    let isPlaying = LoopPreviewer.shared.isPlaying(entry.item, in: entry.libraryID)
    return HStack(spacing: 8) {
      Button(isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill") {
        guard let url = url(for: entry) else { return }
        LoopPreviewer.shared.toggle(entry.item, at: url, in: entry.libraryID, project: model.project, position: .zero)
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      Button {
        choose(entry)
      } label: {
        HStack {
          Text(entry.item.name).lineLimit(1)
          Spacer()
          if let duration = entry.item.duration {
            Text(String(format: "%.1f s", duration))
              .font(Theme.font(10).monospacedDigit())
              .foregroundStyle(Theme.secondaryText)
          }
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
    }
    .padding(.leading, 12 + CGFloat(depth) * 14)
    .padding(.trailing, 12)
    .padding(.vertical, 4)
    .background(isPlaying ? Theme.accent.opacity(0.2) : .clear)
  }

  private func url(for entry: Entry) -> URL? {
    SoundLibraries.shared.library(withID: entry.libraryID)?.url(for: entry.item)
  }

  private func choose(_ entry: Entry) {
    guard let url = url(for: entry) else { return }
    LoopPreviewer.shared.stop()
    do {
      try model.useImpulseResponse(at: url, forInsert: pluginID, on: channelID)
      dismiss()
    } catch {
      self.error = "“\(entry.item.name)” couldn’t be loaded: \(error.localizedDescription)"
    }
  }
}

#Preview {
  func response(_ path: String, _ seconds: Double) -> SoundLibraryItem {
    SoundLibraryItem(path: path, kind: .impulseResponse, duration: seconds, category: .fx)
  }
  SoundLibraries.shared = SoundLibraries(previewItems: [
    "Spaces": [
      response("Large Spaces/Cathedral.SDIR", 7.0), response("Large Spaces/Concert Hall.SDIR", 3.4),
      response("Small Spaces/Wood Room.SDIR", 0.8), response("Small Spaces/Vocal Booth.SDIR", 0.3),
      response("Warped/Spring Tank.SDIR", 2.1),
    ],
  ])
  let model = ProjectWindowModel(document: OngakuDocument(project: .previewSong))
  return ImpulseResponsePicker(model: model, pluginID: UUID(), channelID: UUID())
}
