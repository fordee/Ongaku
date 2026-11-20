//
//  AudioUnitMenuItems.swift
//  Ongaku
//

import OngakuEngine
import SwiftUI

/// Installed Audio Units in a menu, a submenu per maker as in Logic.
struct AudioUnitMenuItems: View {
  let entries: [InstrumentLibrary.Entry]
  /// Shown when there are none.
  let emptyMessage: String
  let choose: (InstrumentLibrary.Entry) -> Void

  var body: some View {
    if entries.isEmpty {
      Text(emptyMessage)
    }
    let makers = Dictionary(grouping: entries, by: \.manufacturer)
    ForEach(makers.keys.sorted(), id: \.self) { maker in
      Menu(maker) {
        ForEach(makers[maker] ?? []) { entry in
          Button(entry.name) { choose(entry) }
        }
      }
    }
  }
}
