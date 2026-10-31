//
//  OngakuEffectsMainView.swift
//  OngakuEffects
//

import SwiftUI

/// The interface of whichever effect the Audio Unit is.
struct OngakuEffectsMainView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameterTree: ObservableAUParameterGroup
  let session: PluginSession
  /// The Session Drummer's song, for its window (made once, with the window).
  var drummerModel: SessionDrummerModel?

  var body: some View {
    VStack(spacing: 0) {
      PluginHeader(effect: audioUnit.effect, session: session)
      effectView
    }
    .background(EffectStyle.background)
  }

  private var effectView: some View {
    FitToWindow(design: audioUnit.effect.preferredSize) {
      switch audioUnit.effect {
      case .channelEQ:
        if let controls = EQControls(parameterTree) {
          ChannelEQView(audioUnit: audioUnit, controls: controls)
        }
      case .compressor:
        if let controls = CompressorControls(parameterTree) {
          CompressorView(audioUnit: audioUnit, controls: controls)
        }
      case .reverb:
        if let controls = ReverbControls(parameterTree) {
          ReverbView(audioUnit: audioUnit, controls: controls)
        }
      case .delay:
        if let controls = DelayControls(parameterTree) {
          DelayView(audioUnit: audioUnit, controls: controls)
        }
      case .retroSynth:
        RetroSynthView(audioUnit: audioUnit, tree: parameterTree)
      case .drumMachine:
        DrumMachineView(audioUnit: audioUnit, tree: parameterTree)
      case .sampler:
        SamplerView(audioUnit: audioUnit, tree: parameterTree)
      case .noiseGate:
        NoiseGateView(audioUnit: audioUnit, parameters: EffectParameters(tree: parameterTree))
      case .transientShaper:
        TransientShaperView(audioUnit: audioUnit, parameters: EffectParameters(tree: parameterTree))
      case .maximizer:
        MaximizerView(audioUnit: audioUnit, parameters: EffectParameters(tree: parameterTree))
      case .deEsser:
        DeEsserView(audioUnit: audioUnit, parameters: EffectParameters(tree: parameterTree))
      case .saturation:
        SaturationView(audioUnit: audioUnit, parameters: EffectParameters(tree: parameterTree))
      case .doubler:
        DoublerView(audioUnit: audioUnit, parameters: EffectParameters(tree: parameterTree))
      case .convolutionReverb:
        ConvolutionReverbView(audioUnit: audioUnit, parameters: EffectParameters(tree: parameterTree))
      case .vocalStrip:
        VocalStripView(audioUnit: audioUnit, parameters: EffectParameters(tree: parameterTree))
      case .sessionDrummer:
        if let drummerModel {
          SessionDrummerView(audioUnit: audioUnit, parameters: EffectParameters(tree: parameterTree), model: drummerModel)
        }
      case .mastering:
        MasteringView(audioUnit: audioUnit, parameters: EffectParameters(tree: parameterTree), session: session)
      }
    }
    .background(EffectStyle.background)
  }
}

/// Lays an effect out at the size it was designed for, and scales it down to fit if the
/// host gives it a smaller window (so nothing is ever cut off).
private struct FitToWindow<Content: View>: View {
  let design: CGSize
  @ViewBuilder let content: Content

  var body: some View {
    GeometryReader { geometry in
      let scale = min(1, geometry.size.width / design.width, geometry.size.height / design.height)
      content
        .frame(width: design.width, height: design.height)
        .scaleEffect(scale, anchor: .center)
        .frame(width: geometry.size.width, height: geometry.size.height)
    }
  }
}
