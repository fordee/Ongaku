//
//  Rename.swift
//  Ongaku
//

import OngakuCore
import SwiftUI

extension ProjectWindowModel {
  /// Something being renamed in the window's one Rename alert: a marker, an arrangement
  /// section, a region, a take or a mixer group. (Tracks are renamed in their header, as in
  /// Logic.)
  enum RenameTarget: Identifiable, Equatable {
    case marker(Marker.ID)
    case section(ArrangementSection.ID)
    case region(Region.ID)
    case take(Take.ID, in: Region.ID)
    case group(Int)

    var id: String {
      switch self {
      case .marker(let id): "marker-\(id)"
      case .section(let id): "section-\(id)"
      case .region(let id): "region-\(id)"
      case .take(let id, _): "take-\(id)"
      case .group(let number): "group-\(number)"
      }
    }

    /// The alert's title.
    var title: String {
      switch self {
      case .marker: "Rename Marker"
      case .section: "Rename Arrangement Marker"
      case .region: "Rename Region"
      case .take: "Rename Take"
      case .group: "Rename Group"
      }
    }
  }

  /// The name `target` has now, to start the alert's field with.
  func currentName(of target: RenameTarget) -> String {
    switch target {
    case .marker(let id): project.markers.first { $0.id == id }?.name ?? ""
    case .section(let id): project.arrangement.first { $0.id == id }?.name ?? ""
    case .region(let id): project.region(withID: id)?.name ?? ""
    case .take(let id, let regionID): project.region(withID: regionID)?.takeFolder?.take(withID: id)?.name ?? ""
    case .group(let number): project.groups.first { $0.id == number }?.name ?? ""
    }
  }

  /// Gives `target` a new name (an empty or unchanged name changes nothing).
  func rename(_ target: RenameTarget, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != currentName(of: target) else { return }
    switch target {
    case .marker(let id): renameMarker(id, to: trimmed)
    case .section(let id): renameSection(id, to: trimmed)
    case .region(let id): perform(RenameRegion(id, to: trimmed))
    case .take(let id, let regionID): perform(RenameTake(id, in: regionID, to: trimmed))
    case .group(let number): renameGroup(number, to: trimmed)
    }
  }
}

/// The window's Rename alert, for whatever `model.renameTarget` names.
struct RenameModifier: ViewModifier {
  let model: ProjectWindowModel
  @State private var name = ""

  func body(content: Content) -> some View {
    content
      .alert(
        model.renameTarget?.title ?? "Rename",
        isPresented: Binding(get: { model.renameTarget != nil }, set: { if !$0 { model.renameTarget = nil } })
      ) {
        TextField("Name", text: $name)
        Button("Rename") {
          if let target = model.renameTarget { model.rename(target, to: name) }
          model.renameTarget = nil
        }
        Button("Cancel", role: .cancel) { model.renameTarget = nil }
      }
      .onChange(of: model.renameTarget) { _, target in
        name = target.map(model.currentName(of:)) ?? ""
      }
  }
}
