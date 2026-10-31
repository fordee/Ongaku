//
//  ContentView.swift
//  OngakuEffectsPreviews
//

import SwiftUI

/// Every Ongaku plug-in's window, chosen from a list. This app exists to host SwiftUI
/// previews of the plug-ins' windows (their extension can't); run, it shows them too.
struct ContentView: View {
  @State private var selection: OngakuEffect? = .mastering

  var body: some View {
    NavigationSplitView {
      List(OngakuEffect.allCases, id: \.self, selection: $selection) { effect in
        Text(String(describing: effect))
      }
      .navigationSplitViewColumnWidth(min: 160, ideal: 180)
    } detail: {
      if let selection {
        ScrollView([.horizontal, .vertical]) {
          PluginPreview(effect: selection)
            .id(selection)
        }
      }
    }
  }
}

#Preview {
  ContentView()
}
