//
//  BounceInPlaceView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// Bounce in Place: what's being bounced, the dialog's choices, and the render while it runs.
@MainActor
@Observable
final class BounceInPlaceModel {
  private static let optionsKey = "BounceInPlaceOptions"
  private static let sourceKey = "BounceInPlaceSource"

  let trackID: Track.ID
  let regionIDs: Set<Region.ID>
  /// Remembered between bounces and launches, like the Bounce dialog's settings.
  var options: TrackRenderOptions {
    didSet { UserDefaults.standard.set(try? JSONEncoder().encode(options), forKey: Self.optionsKey) }
  }
  var source: BounceInPlace.Source {
    didSet { UserDefaults.standard.set(source.rawValue, forKey: Self.sourceKey) }
  }
  /// While rendering, from 0 to 1.
  var progress: Double?
  @ObservationIgnored var task: Task<Void, Never>?

  init(trackID: Track.ID, regionIDs: Set<Region.ID>) {
    self.trackID = trackID
    self.regionIDs = regionIDs
    options = UserDefaults.standard.data(forKey: Self.optionsKey)
      .flatMap { try? JSONDecoder().decode(TrackRenderOptions.self, from: $0) } ?? TrackRenderOptions()
    source = UserDefaults.standard.string(forKey: Self.sourceKey).flatMap(BounceInPlace.Source.init) ?? .mute
  }
}

extension ProjectWindowModel {
  /// What Bounce in Place would bounce: the selected regions, if they're all on one track,
  /// otherwise every region on the selected track.
  var bounceInPlaceTarget: (trackID: Track.ID, regionIDs: Set<Region.ID>)? {
    let tracks = project.tracks.filter { $0.kind.hasRegions }
    if !selectedRegionIDs.isEmpty {
      let owners = tracks.filter { $0.regions.contains { selectedRegionIDs.contains($0.id) } }
      guard owners.count == 1, let track = owners.first else { return nil }
      return (track.id, Set(track.regions.map(\.id)).intersection(selectedRegionIDs))
    }
    guard let track = selectedTrack, track.kind.hasRegions, !track.regions.isEmpty else { return nil }
    return (track.id, Set(track.regions.map(\.id)))
  }

  /// Opens the Bounce in Place dialog (Track › Bounce in Place, ⌃B), stopping playback.
  func showBounceInPlace() {
    guard let target = bounceInPlaceTarget else { return }
    engine.stop()
    bounceInPlace = BounceInPlaceModel(trackID: target.trackID, regionIDs: target.regionIDs)
  }

  func closeBounceInPlace() {
    bounceInPlace?.task?.cancel()
    bounceInPlace = nil
  }

  /// Renders the dialog's track on its own and puts the result on a new audio track below it.
  /// Returns the work, for tests to wait on.
  @discardableResult
  func startBounceInPlace() -> Task<Void, Never>? {
    guard let dialog = bounceInPlace, let track = project.track(withID: dialog.trackID) else { return nil }
    let (regionIDs, options, source) = (dialog.regionIDs, dialog.options, dialog.source)
    let sampleRate = engine.outputSampleRate
    dialog.progress = 0
    let task = Task { [weak self, document] in
      // Flexed regions bounce as they play, so their renders have to be ready first.
      await self?.finishFlexRenders()
      guard let self, !Task.isCancelled else { return }
      let rendered = projectWithCurrentPluginStates()
      guard let alone = rendered.isolating(track.id, regionIDs: regionIDs, options: options),
        let span = rendered.span(ofTrack: track.id, regionIDs: regionIDs)
      else {
        errorMessage = "There’s nothing on “\(track.name)” to bounce: its regions are muted."
        bounceInPlace = nil
        return
      }
      do {
        let url = try document.newRenderedAudioURL()
        let file = try await ProjectBouncer.renderInPlace(
          alone, range: span, sampleRate: sampleRate, to: url,
          locateAudioFile: { [weak document] file in document?.url(for: file) }
        ) { [weak dialog] progress in dialog?.progress = progress }
        let reference = try document.adoptRecordedAudio(
          at: url, sampleRate: file.sampleRate, channelCount: file.channelCount, frameCount: file.frameCount,
          preferredName: "\(track.name) Bounce", reservedNames: document.savedAudioFileNames)
        let newTrack = makeTrack(name: "\(track.name) Bounce", kind: .audio)
        if perform(BounceInPlace(track.id, regions: regionIDs, file: reference, into: newTrack, source: source)) {
          selectedTrackID = newTrack.id
        }
      } catch is CancellationError {
      } catch {
        errorMessage = "“\(track.name)” couldn’t be bounced: \(error.localizedDescription)"
      }
      bounceInPlace = nil
    }
    dialog.task = task
    return task
  }
}

/// Logic's Bounce in Place dialog: what happens to the regions bounced, and what the render
/// keeps of the channel strip.
struct BounceInPlaceView: View {
  let model: ProjectWindowModel
  @Bindable var dialog: BounceInPlaceModel

  var body: some View {
    let track = model.project.track(withID: dialog.trackID)
    VStack(alignment: .leading, spacing: 16) {
      Text("Bounce “\(track?.name ?? "")” in Place").font(.headline)
      if let progress = dialog.progress {
        VStack(alignment: .leading, spacing: 6) {
          ProgressView(value: progress)
          Text("Rendering…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(minHeight: 150)
      } else {
        Form {
          if let span = model.project.span(ofTrack: dialog.trackID, regionIDs: dialog.regionIDs) {
            LabeledContent(
              dialog.regionIDs.count == 1 ? "1 region" : "\(dialog.regionIDs.count) regions",
              value: model.describeRange(span))
          }
          Picker("Source Regions", selection: $dialog.source) {
            ForEach(BounceInPlace.Source.allCases, id: \.self) { Text($0.name).tag($0) }
          }
          .help("What happens to the regions once they're bounced")
          Toggle("Include effect plug-ins", isOn: $dialog.options.includesEffects)
            .help("Render through the track's insert plug-ins; off, only the instrument and MIDI effects")
          Toggle("Include volume and pan", isOn: $dialog.options.includesVolumeAndPan)
            .help("Render at the fader's level and pan, with their automation; off, at 0 dB in the centre")
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 190)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.closeBounceInPlace() }
          .keyboardShortcut(.cancelAction)
        Button("Bounce") { model.startBounceInPlace() }
          .keyboardShortcut(.defaultAction)
          .disabled(dialog.progress != nil)
      }
    }
    .padding(20)
    .frame(width: 400)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Bounce in Place")
    .accessibilityIdentifier("bounce-in-place")
  }
}

#Preview {
  let model = ProjectWindowModel(document: OngakuDocument(project: .previewSong))
  let track = model.project.tracks[1]
  BounceInPlaceView(model: model, dialog: BounceInPlaceModel(trackID: track.id, regionIDs: Set(track.regions.map(\.id))))
}
