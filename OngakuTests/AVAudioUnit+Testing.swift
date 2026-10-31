//
//  AVAudioUnit+Testing.swift
//  OngakuTests
//

import AVFAudio

extension AVAudioUnit {
  /// The node's Audio Unit, for tests to set up and inspect. (`auAudioUnit` is deprecated in
  /// macOS 27 in favour of `withAUAudioUnit`; the tests keep the node for as long as they use
  /// its Audio Unit, which is what that asks.)
  var au: AUAudioUnit {
    withAUAudioUnit { copy $0 }
  }
}
