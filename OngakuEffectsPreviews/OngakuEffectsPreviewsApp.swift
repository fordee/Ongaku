//
//  OngakuEffectsPreviewsApp.swift
//  OngakuEffectsPreviews
//

import SwiftUI

/// Hosts SwiftUI previews of the Ongaku plug-ins' windows, which their Audio Unit extension
/// can't (make this the active scheme to preview them). It builds the extension's code too.
@main
struct OngakuEffectsPreviewsApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    .defaultSize(width: 1180, height: 560)
  }
}
