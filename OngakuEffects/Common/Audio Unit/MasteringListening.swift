//
//  MasteringListening.swift
//  OngakuEffects
//

import AudioToolbox
import Foundation
import OngakuCore

/// `MasteringAnalysis.Result`, named so the Audio Unit's file needn't import OngakuCore.
typealias MasteringAnalysisResult = MasteringAnalysis.Result

/// Mastering's Listen: the render thread measures the song while it plays (see
/// `Mastering::listen` in Mastering.hpp); here the steps it heard are read back, analysed
/// (`MasteringAnalysis` in OngakuCore), and turned into the settings for the song.
extension OngakuEffectsAudioUnit {
  /// Starts and stops listening through the Listen parameter, as a host would, so stopping
  /// analyses what was heard (see `finishListening`).
  func startListening() {
    parameterTree?.parameter(withAddress: OngakuEffectsParameterAddress.mstListen.rawValue)?.value = 1
  }

  func stopListening() {
    parameterTree?.parameter(withAddress: OngakuEffectsParameterAddress.mstListen.rawValue)?.value = 0
  }

  /// Whether it's listening (it stops by itself after 15 minutes).
  var isListening: Bool {
    kernel.pointee.masteringIsListening()
  }

  /// How many 100 ms steps it has heard.
  var listenedBlockCount: Int {
    Int(kernel.pointee.masteringListenedBlocks())
  }

  /// Everything heard since Listen was last started.
  func listenedBlocks() -> [MasteringAnalysis.Block] {
    (0..<listenedBlockCount).map { index in
      let block = kernel.pointee.masteringListenedBlock(Int32(index))
      let bands = withUnsafeBytes(of: block.bands) { bytes in bytes.bindMemory(to: Float.self).map(Double.init) }
      return MasteringAnalysis.Block(
        loudness: Double(block.loudness), bands: bands, mid: Double(block.mid), side: Double(block.side),
        truePeak: Double(block.truePeak))
    }
  }

  /// Listen has been turned off: analyses what was heard and sets the song's settings,
  /// through the window if it's open. Too little music heard sets nothing.
  @MainActor func finishListening() {
    let result = MasteringAnalysis.analyse(listenedBlocks())
    if let result { masteringAnalysis = result }
    if let masteringListenFinished {
      masteringListenFinished(result)
    } else if let result {
      for (address, value) in Self.masteringSettings(for: result) {
        parameterTree?.parameter(withAddress: address)?.value = value
      }
    }
  }

  static let masteringAnalysisKey = "ongakuMasteringAnalysis"

  /// The last listen's findings, for `fullState`.
  var masteringAnalysisState: Data? {
    masteringAnalysis.flatMap { try? JSONEncoder().encode($0) }
  }

  /// Restores the last listen's findings from `fullState` (none, if there weren't any).
  func restoreMasteringAnalysis(_ data: Data?) {
    masteringAnalysis = data.flatMap { try? JSONDecoder().decode(MasteringAnalysis.Result.self, from: $0) }
  }

  /// The parameters an analysis sets: the song's EQ, compressor, width and measured
  /// loudness. Character, Loudness, the amounts and Ceiling are left as the person set them.
  static func masteringSettings(for result: MasteringAnalysis.Result) -> [AUParameterAddress: AUValue] {
    let bands: [OngakuEffectsParameterAddress] = [.mstLowShelf, .mstLowMid, .mstPresence, .mstAir, .mstHighShelf]
    var values: [AUParameterAddress: AUValue] = [:]
    for (address, gain) in zip(bands, result.eq) {
      values[address.rawValue] = AUValue(gain)
    }
    values[OngakuEffectsParameterAddress.mstThreshold.rawValue] = AUValue(result.threshold)
    values[OngakuEffectsParameterAddress.mstRatio.rawValue] = AUValue(result.ratio)
    values[OngakuEffectsParameterAddress.mstWidth.rawValue] = AUValue(result.width)
    values[OngakuEffectsParameterAddress.mstMeasuredLoudness.rawValue] = AUValue(min(max(result.loudness, -70), 0))
    return values
  }
}
