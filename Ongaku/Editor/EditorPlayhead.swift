//
//  EditorPlayhead.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// The playhead in an editor that scrolls its own content (Takes, Flex Pitch): a line at
/// the song's position within the open region, `leading` points in from the content's left
/// edge. It reads the playhead itself, so only it redraws as the song plays. (The Piano
/// Roll pins its own over the viewport.)
struct EditorPlayhead: View {
  let model: PianoRollModel
  let region: Region
  var leading: CGFloat = 0

  var body: some View {
    let position = model.window.engine.playheadPosition
    if position >= region.start, position <= region.end {
      Rectangle()
        .fill(Theme.playhead.opacity(0.9))
        .frame(width: 1)
        .frame(maxHeight: .infinity)
        .offset(x: leading + model.x(for: position - region.start))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
}
