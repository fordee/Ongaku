//
//  AudioUnitViewController.swift
//  OngakuEffects
//

import CoreAudioKit
import os
import SwiftUI

private let log = Logger(subsystem: "net.4dware.Ongaku.OngakuEffects", category: "AudioUnitViewController")

/// Creates the extension's Audio Units (every effect shares this factory) and shows the
/// interface of the one it created.
@MainActor
public class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
  var audioUnit: OngakuEffectsAudioUnit?

  var hostingController: HostingController<OngakuEffectsMainView>?

  public override func viewDidLoad() {
    super.viewDidLoad()
    if let audioUnit {
      preferredContentSize = audioUnit.effect.windowSize
      configureSwiftUIView(audioUnit: audioUnit)
    }
  }

  nonisolated public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
    if Thread.isMainThread {
      return try MainActor.assumeIsolated { try makeAudioUnit(componentDescription) }
    }
    return try DispatchQueue.main.sync { try makeAudioUnit(componentDescription) }
  }

  private func makeAudioUnit(_ componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
    let audioUnit = try OngakuEffectsAudioUnit(componentDescription: componentDescription, options: [])
    self.audioUnit = audioUnit
    // Build the interface once the parameter tree exists.
    DispatchQueue.main.async {
      if self.isViewLoaded {
        self.configureSwiftUIView(audioUnit: audioUnit)
      }
    }
    return audioUnit
  }

  private func configureSwiftUIView(audioUnit: OngakuEffectsAudioUnit) {
    if let host = hostingController {
      host.removeFromParent()
      host.view.removeFromSuperview()
    }
    let session = PluginSession(audioUnit: audioUnit)
    guard let observableParameterTree = audioUnit.observableParameterTree(onUserChange: { [weak session] address, oldValue in
      session?.noteUserChange(address: address, oldValue: oldValue)
    }) else {
      log.error("The Audio Unit has no parameter tree")
      return
    }
    let drummerModel = audioUnit.drummer.map { SessionDrummerModel(controller: $0, session: session) }
    let content = OngakuEffectsMainView(
      audioUnit: audioUnit, parameterTree: observableParameterTree, session: session, drummerModel: drummerModel)
    // Hosts size the window from the view (or from the preferred size); give them both.
    preferredContentSize = audioUnit.effect.windowSize
    view.setFrameSize(audioUnit.effect.windowSize)
    let host = HostingController(rootView: content)
    addChild(host)
    host.view.frame = view.bounds
    view.addSubview(host.view)
    hostingController = host

    // Fill the area the host gives the view.
    host.view.translatesAutoresizingMaskIntoConstraints = false
    host.view.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
    host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
    host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor).isActive = true
    host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
  }
}
