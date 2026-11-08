//
//  OngakuApp.swift
//  Ongaku
//
//  Created by John Forde on 21/10/2026.
//

import AppKit
import OngakuEngine
import SwiftUI

@main
struct OngakuApp: App {
  init() {
    Theme.applyAppearance()
    // One project per window, as in Logic. The control bar takes the title bar's place, so
    // a window tab bar would have nowhere to go; this also removes the tab menu items.
    NSWindow.allowsAutomaticWindowTabbing = false
    // Agents can connect as soon as the app is open, if Settings › Agents allows it.
    AgentServer.shared.applySettings()
    // Songs find their library instruments through the libraries added in Settings.
    SamplerInstrumentResolver.resolve = { try await SoundLibraries.shared.url(for: $0) }
  }

  var body: some Scene {
    DocumentGroup { document in
      ContentView(document: document)
    } makeDocument: { configuration, context in
      OngakuDocument(project: AppSettings.newProjectTemplate.makeProject(), configuration: configuration)
    }
    // Room for the tracks and an editor or mixer below them; macOS fits it to smaller screens.
    .defaultSize(width: 1440, height: 900)
    .commands {
      OngakuCommands()
    }

    Settings {
      SettingsView()
    }

    #if DEBUG
    // Opens only when launched with -OngakuPerformanceCheck YES (see PerformanceCheck).
    Window("Performance Check", id: "performance-check") {
      PerformanceCheckView()
    }
    .defaultSize(width: 1440, height: 900)
    .defaultLaunchBehavior(PerformanceCheck.isRequested ? .presented : .suppressed)
    #endif
  }
}
