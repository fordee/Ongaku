//
//  HTDemucs.swift
//  OngakuEngine
//

import Accelerate
import Foundation

/// Meta's Hybrid Transformer Demucs (htdemucs, MIT licence), run in Swift: it splits a
/// stereo mix at 44.1 kHz into drums, bass, other and vocals. Two U-Nets, one on the
/// spectrogram and one on the waveform, meet in a cross-attention transformer, and their
/// outputs are added. This follows `demucs/htdemucs.py` step by step, for one segment of
/// 7.8 seconds at a time (see `StemSplitter` for whole songs).
final class HTDemucs: @unchecked Sendable {
  static let sources = ["drums", "bass", "other", "vocals"]
  static let sampleRate = 44_100.0
  /// The training segment, 7.8 s: what the model always works on (shorter input is padded).
  let segmentLength: Int

  private let weights: [String: TorchCheckpoint.Tensor]
  private let stft = StemSTFT(size: 4096, hop: 1024)
  private let depth = 4
  private let transformerChannels = 512
  private let heads = 8
  private let transformerLayers = 5

  init(checkpoint url: URL) throws {
    let checkpoint = try TorchCheckpoint(contentsOf: url)
    weights = checkpoint.state
    let segment = checkpoint.kwargs["segment"]?.double ?? 7.8
    segmentLength = Int(segment * Self.sampleRate)
    guard weights["encoder.0.conv.weight"] != nil, weights["crosstransformer.layers.4.linear2.weight"] != nil else {
      throw TorchCheckpoint.CheckpointError.unreadable("not an HTDemucs model")
    }
  }

  private func w(_ name: String) -> [Float] {
    guard let tensor = weights[name] else { fatalError("HTDemucs: missing weight \(name)") }
    return tensor.values
  }

  private func shape(_ name: String) -> [Int] { weights[name]?.shape ?? [] }

  // MARK: - Separation

  /// Separates one segment (left and right, up to `segmentLength` samples): four sources,
  /// each two channels, as long as the input.
  func separate(left: [Float], right: [Float]) -> [[[Float]]] {
    let length = left.count
    let L = segmentLength
    // Shorter input is padded to the training length, and cut back at the end.
    let mixLeft = left + [Float](repeating: 0, count: max(0, L - length))
    let mixRight = right + [Float](repeating: 0, count: max(0, L - length))

    // The spectrogram branch's input: complex as channels, normalized.
    let hop = stft.hop
    let frames = Int((Double(L) / Double(hop)).rounded(.up))
    let pad = hop / 2 * 3
    var spectra: [(real: [[Float]], imaginary: [[Float]])] = []
    for channel in [mixLeft, mixRight] {
      let padded = StemSTFT.reflect(channel, left: pad, right: pad + frames * hop - L)
      let spectrum = stft.forward(padded)
      // Drop the Nyquist bin, and the two frames at each end.
      spectra.append((
        Array(spectrum.real[2..<(2 + frames)]).map { Array($0.dropLast()) },
        Array(spectrum.imaginary[2..<(2 + frames)]).map { Array($0.dropLast()) }))
    }
    let bins = stft.size / 2
    // [4 = (channel, re/im), bins, frames]
    var x = [Float]()
    x.reserveCapacity(4 * bins * frames)
    for c in 0..<2 {
      // [frames, bins] → [bins, frames]
      x += StemOps.transpose(spectra[c].real.flatMap { $0 }, rows: frames, columns: bins)
      x += StemOps.transpose(spectra[c].imaginary.flatMap { $0 }, rows: frames, columns: bins)
    }
    let (mean, std) = Self.meanAndStd(x)
    x = x.map { ($0 - mean) / (1e-5 + std) }

    // The waveform branch's input, normalized.
    var xt = mixLeft + mixRight
    let (meanT, stdT) = Self.meanAndStd(xt)
    xt = xt.map { ($0 - meanT) / (1e-5 + stdT) }

    // Encoders.
    var channels = 4, rows = bins, columns = frames
    var tChannels = 2, tLength = L
    var saved: [(values: [Float], channels: Int, rows: Int)] = []
    var savedT: [(values: [Float], channels: Int, length: Int)] = []
    var lengthsT: [Int] = []
    for index in 0..<depth {
      // The frequency layer.
      let encoded = encoderLayer(prefix: "encoder.\(index)", x: x, channels: channels, rows: rows, columns: columns, freq: true)
      x = encoded.values
      channels = encoded.channels
      rows = encoded.rows
      if index == 0 {
        // The frequency embedding (scale 10 inside, weight 0.2 outside).
        let embedding = w("freq_emb.embedding.weight")
        let embeddingChannels = shape("freq_emb.embedding.weight")[1]
        x.withUnsafeMutableBufferPointer { buffer in
          for c in 0..<channels {
            for f in 0..<rows {
              var value = 0.2 * 10 * embedding[f * embeddingChannels + c]
              let row = buffer.baseAddress! + (c * rows + f) * columns
              vDSP_vsadd(row, 1, &value, row, 1, vDSP_Length(columns))
            }
          }
        }
      }
      saved.append((x, channels, rows))
      // The time layer.
      lengthsT.append(tLength)
      if tLength % 4 != 0 {
        let padded = 4 - tLength % 4
        xt = Self.padColumns(xt, channels: tChannels, columns: tLength, right: padded)
        tLength += padded
      }
      let encodedT = encoderLayer(prefix: "tencoder.\(index)", x: xt, channels: tChannels, rows: 1, columns: tLength, freq: false)
      xt = encodedT.values
      tChannels = encodedT.channels
      tLength = encodedT.columns
      savedT.append((xt, tChannels, tLength))
    }

    // The transformer, between 384-channel bottlenecks widened to 512.
    let bottleneck = channels
    x = StemOps.pointwise(
      x, channels: bottleneck, positions: rows * columns, weight: w("channel_upsampler.weight"), bias: w("channel_upsampler.bias"),
      outChannels: transformerChannels)
    xt = StemOps.pointwise(
      xt, channels: bottleneck, positions: tLength, weight: w("channel_upsampler_t.weight"), bias: w("channel_upsampler_t.bias"),
      outChannels: transformerChannels)
    (x, xt) = crossTransformer(x: x, rows: rows, columns: columns, xt: xt, length: tLength)
    x = StemOps.pointwise(
      x, channels: transformerChannels, positions: rows * columns, weight: w("channel_downsampler.weight"),
      bias: w("channel_downsampler.bias"), outChannels: bottleneck)
    xt = StemOps.pointwise(
      xt, channels: transformerChannels, positions: tLength, weight: w("channel_downsampler_t.weight"),
      bias: w("channel_downsampler_t.bias"), outChannels: bottleneck)

    // Decoders.
    for index in 0..<depth {
      let skip = saved.removeLast()
      let decoded = decoderLayer(
        prefix: "decoder.\(index)", x: x, skip: skip.values, channels: channels, rows: rows, columns: columns, freq: true,
        length: 0, last: index == depth - 1)
      x = decoded.values
      channels = decoded.channels
      rows = decoded.rows
      let skipT = savedT.removeLast()
      let decodedT = decoderLayer(
        prefix: "tdecoder.\(index)", x: xt, skip: skipT.values, channels: tChannels, rows: 1, columns: tLength, freq: false,
        length: lengthsT.removeLast(), last: index == depth - 1)
      xt = decodedT.values
      tChannels = decodedT.channels
      tLength = decodedT.columns
    }

    // The spectrogram branch's output: 4 sources × 2 channels × (re, im), back to audio.
    let sourceCount = Self.sources.count
    var output = [[[Float]]](repeating: [[Float]](repeating: [], count: 2), count: sourceCount)
    for s in 0..<sourceCount {
      for c in 0..<2 {
        let reChannel = s * 4 + c * 2, imChannel = reChannel + 1
        // Each channel [bins, frames] → [frames, bins], un-normalized, then one array per
        // frame with a zero Nyquist bin, and two empty frames at each end.
        func frameArrays(_ channel: Int) -> [[Float]] {
          var plane = StemOps.transpose(Array(x[(channel * bins * frames)..<((channel + 1) * bins * frames)]), rows: bins, columns: frames)
          var scale = std, shift = mean
          vDSP_vsmsa(plane, 1, &scale, &shift, &plane, 1, vDSP_Length(plane.count))
          let empty = [Float](repeating: 0, count: bins + 1)
          return [empty, empty] + (0..<frames).map { Array(plane[($0 * bins)..<(($0 + 1) * bins)]) + [0] } + [empty, empty]
        }
        let real = frameArrays(reChannel), imaginary = frameArrays(imChannel)
        let fullLength = hop * frames + 2 * pad
        let audio = stft.inverse(real: real, imaginary: imaginary, length: fullLength)
        // Plus the waveform branch.
        var source = [Float](repeating: 0, count: L)
        var scale = stdT, shift = meanT
        xt.withUnsafeBufferPointer { time in
          vDSP_vsmsa(time.baseAddress! + (s * 2 + c) * tLength, 1, &scale, &shift, &source, 1, vDSP_Length(L))
        }
        audio.withUnsafeBufferPointer { spec in
          vDSP_vadd(source, 1, spec.baseAddress! + pad, 1, &source, 1, vDSP_Length(L))
        }
        output[s][c] = Array(source.prefix(length))
      }
    }
    return output
  }

  // MARK: - Layers

  /// HEncLayer: a strided convolution (over frequency, or time), GELU, the DConv residual
  /// branch, then a 1×1 "rewrite" and a GLU.
  private func encoderLayer(prefix: String, x: [Float], channels: Int, rows: Int, columns: Int, freq: Bool)
    -> (values: [Float], channels: Int, rows: Int, columns: Int)
  {
    let convShape = shape("\(prefix).conv.weight")
    let out = convShape[0]
    var y: [Float]
    var outRows = rows, outColumns = columns
    if freq {
      let result = StemOps.convRows(
        x, channels: channels, rows: rows, columns: columns, weight: w("\(prefix).conv.weight"), bias: w("\(prefix).conv.bias"),
        outChannels: out, kernel: 8, stride: 4, padding: 2)
      y = result.values
      outRows = result.rows
    } else {
      let result = StemOps.convColumns(
        x, channels: channels, rows: 1, columns: columns, weight: w("\(prefix).conv.weight"), bias: w("\(prefix).conv.bias"),
        outChannels: out, kernel: 8, stride: 4, padding: 2)
      y = result.values
      outColumns = result.columns
    }
    StemOps.gelu(&y)
    y = dconv(prefix: "\(prefix).dconv", x: y, channels: out, rows: outRows, columns: outColumns)
    let rewritten = StemOps.pointwise(
      y, channels: out, positions: outRows * outColumns, weight: w("\(prefix).rewrite.weight"), bias: w("\(prefix).rewrite.bias"),
      outChannels: 2 * out)
    return (StemOps.glu(rewritten, channels: 2 * out, positions: outRows * outColumns), out, outRows, outColumns)
  }

  /// HDecLayer: add the skip, a rewrite (3×3 over frequency and time, or 3 over time) and
  /// GLU, the DConv branch, then a transposed convolution back up (GELU except at the end).
  private func decoderLayer(
    prefix: String, x: [Float], skip: [Float], channels: Int, rows: Int, columns: Int, freq: Bool, length: Int, last: Bool
  ) -> (values: [Float], channels: Int, rows: Int, columns: Int) {
    var y = x
    vDSP_vadd(y, 1, skip, 1, &y, 1, vDSP_Length(y.count))
    let rewritten: [Float]
    if freq {
      rewritten = StemOps.conv3x3(
        y, channels: channels, rows: rows, columns: columns, weight: w("\(prefix).rewrite.weight"), bias: w("\(prefix).rewrite.bias"),
        outChannels: 2 * channels)
    } else {
      rewritten = StemOps.convColumns(
        y, channels: channels, rows: 1, columns: columns, weight: w("\(prefix).rewrite.weight"), bias: w("\(prefix).rewrite.bias"),
        outChannels: 2 * channels, kernel: 3, padding: 1
      ).values
    }
    y = StemOps.glu(rewritten, channels: 2 * channels, positions: rows * columns)
    y = dconv(prefix: "\(prefix).dconv", x: y, channels: channels, rows: rows, columns: columns)
    let out = shape("\(prefix).conv_tr.weight")[1]
    let transposed = StemOps.convTranspose(
      y, channels: channels, rows: rows, columns: columns, weight: w("\(prefix).conv_tr.weight"), bias: w("\(prefix).conv_tr.bias"),
      outChannels: out, kernel: 8, stride: 4, alongRows: freq)
    var z: [Float]
    var outRows = transposed.rows, outColumns = transposed.columns
    if freq {
      // Crop the padding (2) from each end of the frequencies.
      let kept = transposed.rows - 4
      z = [Float](repeating: 0, count: out * kept * columns)
      for o in 0..<out {
        for r in 0..<kept {
          let from = (o * transposed.rows + r + 2) * columns
          let to = (o * kept + r) * columns
          z.replaceSubrange(to..<(to + columns), with: transposed.values[from..<(from + columns)])
        }
      }
      outRows = kept
    } else {
      // Crop to the length before this layer's encoder.
      z = [Float](repeating: 0, count: out * length)
      for o in 0..<out {
        let from = o * transposed.columns + 2
        z.replaceSubrange((o * length)..<((o + 1) * length), with: transposed.values[from..<(from + length)])
      }
      outColumns = length
    }
    if !last { StemOps.gelu(&z) }
    return (z, out, outRows, outColumns)
  }

  /// DConv: two residual branches (dilation 1 then 2), each a 3-tap convolution down to a
  /// quarter… (compress 8), group norm, GELU, a 1×1 back up to twice the channels, group
  /// norm, GLU and a learned scale. Along time, each frequency row separately.
  private func dconv(prefix: String, x: [Float], channels: Int, rows: Int, columns: Int) -> [Float] {
    var x = x
    for layer in 0..<2 {
      let base = "\(prefix).layers.\(layer)"
      let hidden = shape("\(base).0.weight")[0]
      let dilation = 1 << layer
      // The norms are over each row's channels and time together (GroupNorm(1) on
      // [rows, C, T]), so work row by row.
      var branch = [Float](repeating: 0, count: x.count)
      let convWeight = w("\(base).0.weight"), convBias = w("\(base).0.bias")
      let norm1Weight = w("\(base).1.weight"), norm1Bias = w("\(base).1.bias")
      let pointWeight = w("\(base).3.weight"), pointBias = w("\(base).3.bias")
      let norm2Weight = w("\(base).4.weight"), norm2Bias = w("\(base).4.bias")
      let scale = w("\(base).6.scale")
      // Gather each row as [C, T].
      var row = [Float](repeating: 0, count: channels * columns)
      for r in 0..<rows {
        x.withUnsafeBufferPointer { source in
          row.withUnsafeMutableBufferPointer { destination in
            for c in 0..<channels {
              StemOps.copy(source.baseAddress! + (c * rows + r) * columns, to: destination.baseAddress! + c * columns, count: columns)
            }
          }
        }
        var h = StemOps.convColumns(
          row, channels: channels, rows: 1, columns: columns, weight: convWeight, bias: convBias, outChannels: hidden, kernel: 3,
          padding: dilation, dilation: dilation
        ).values
        StemOps.groupNorm(&h, channels: hidden, positions: columns, weight: norm1Weight, bias: norm1Bias)
        StemOps.gelu(&h)
        var g = StemOps.pointwise(h, channels: hidden, positions: columns, weight: pointWeight, bias: pointBias, outChannels: 2 * channels)
        StemOps.groupNorm(&g, channels: 2 * channels, positions: columns, weight: norm2Weight, bias: norm2Bias)
        let gated = StemOps.glu(g, channels: 2 * channels, positions: columns)
        for c in 0..<channels {
          var s = scale[c]
          let to = (c * rows + r) * columns
          gated.withUnsafeBufferPointer { source in
            branch.withUnsafeMutableBufferPointer { destination in
              vDSP_vsmul(source.baseAddress! + c * columns, 1, &s, destination.baseAddress! + to, 1, vDSP_Length(columns))
            }
          }
        }
      }
      vDSP_vadd(x, 1, branch, 1, &x, 1, vDSP_Length(x.count))
    }
    return x
  }

  // MARK: - Transformer

  /// The cross-domain transformer: the spectrogram's tokens (frames × frequencies) and the
  /// waveform's, each with positional embeddings, through alternating self-attention and
  /// cross-attention layers.
  private func crossTransformer(x: [Float], rows: Int, columns: Int, xt: [Float], length: Int) -> ([Float], [Float]) {
    let c = transformerChannels
    let tokens = rows * columns
    // To tokens (t1 major, frequency minor), [tokens, C].
    // [C, F·T] → [F·T, C] (rows f-major), then reorder the rows to t-major.
    let fMajor = StemOps.transpose(x, rows: c, columns: tokens)
    var a = [Float](repeating: 0, count: tokens * c)
    fMajor.withUnsafeBufferPointer { source in
      a.withUnsafeMutableBufferPointer { destination in
        for f in 0..<rows {
          for t in 0..<columns { StemOps.copy(source.baseAddress! + (f * columns + t) * c, to: destination.baseAddress! + (t * rows + f) * c, count: c) }
        }
      }
    }
    var b = StemOps.transpose(xt, rows: c, columns: length)
    a = StemOps.layerNorm(a, tokens: tokens, channels: c, weight: w("crosstransformer.norm_in.weight"), bias: w("crosstransformer.norm_in.bias"))
    b = StemOps.layerNorm(b, tokens: length, channels: c, weight: w("crosstransformer.norm_in_t.weight"), bias: w("crosstransformer.norm_in_t.bias"))
    // Positional embeddings: 2D sin/cos for the spectrogram, 1D for the waveform.
    let embedding2D = StemOps.transpose(Self.sinEmbedding2D(channels: c, height: rows, width: columns), rows: c, columns: tokens)
    embedding2D.withUnsafeBufferPointer { source in
      a.withUnsafeMutableBufferPointer { destination in
        for f in 0..<rows {
          for t in 0..<columns {
            let to = destination.baseAddress! + (t * rows + f) * c
            vDSP_vadd(to, 1, source.baseAddress! + (f * columns + t) * c, 1, to, 1, vDSP_Length(c))
          }
        }
      }
    }
    let embedding1D = Self.sinEmbedding1D(channels: c, length: length)
    vDSP_vadd(b, 1, embedding1D, 1, &b, 1, vDSP_Length(b.count))
    for index in 0..<transformerLayers {
      if index % 2 == 0 {
        a = selfAttentionLayer("crosstransformer.layers.\(index)", a, tokens: tokens)
        b = selfAttentionLayer("crosstransformer.layers_t.\(index)", b, tokens: length)
      } else {
        let previous = a
        a = crossAttentionLayer("crosstransformer.layers.\(index)", a, queries: tokens, memory: b, keys: length)
        b = crossAttentionLayer("crosstransformer.layers_t.\(index)", b, queries: length, memory: previous, keys: tokens)
      }
    }
    // Back to [C, rows, columns] and [C, length].
    var reordered = [Float](repeating: 0, count: tokens * c)
    a.withUnsafeBufferPointer { source in
      reordered.withUnsafeMutableBufferPointer { destination in
        for f in 0..<rows {
          for t in 0..<columns { StemOps.copy(source.baseAddress! + (t * rows + f) * c, to: destination.baseAddress! + (f * columns + t) * c, count: c) }
        }
      }
    }
    return (StemOps.transpose(reordered, rows: tokens, columns: c), StemOps.transpose(b, rows: length, columns: c))
  }

  /// Norm first: x + γ₁·attention(norm₁ x), then + γ₂·feed-forward(norm₂ x), then a group
  /// norm over every token and channel.
  private func selfAttentionLayer(_ prefix: String, _ x: [Float], tokens: Int) -> [Float] {
    let c = transformerChannels
    var x = x
    let normed = StemOps.layerNorm(x, tokens: tokens, channels: c, weight: w("\(prefix).norm1.weight"), bias: w("\(prefix).norm1.bias"))
    let attended = StemOps.attention(
      query: normed, queries: tokens, memory: normed, keys: tokens, channels: c, heads: heads, inWeight: w("\(prefix).self_attn.in_proj_weight"),
      inBias: w("\(prefix).self_attn.in_proj_bias"), outWeight: w("\(prefix).self_attn.out_proj.weight"),
      outBias: w("\(prefix).self_attn.out_proj.bias"))
    addScaled(&x, attended, scale: w("\(prefix).gamma_1.scale"), tokens: tokens)
    feedForward(prefix, &x, tokens: tokens, norm: "norm2")
    tokenGroupNorm(&x, tokens: tokens, weight: w("\(prefix).norm_out.weight"), bias: w("\(prefix).norm_out.bias"))
    return x
  }

  private func crossAttentionLayer(_ prefix: String, _ q: [Float], queries: Int, memory: [Float], keys: Int) -> [Float] {
    let c = transformerChannels
    var x = q
    let normedQ = StemOps.layerNorm(q, tokens: queries, channels: c, weight: w("\(prefix).norm1.weight"), bias: w("\(prefix).norm1.bias"))
    let normedK = StemOps.layerNorm(memory, tokens: keys, channels: c, weight: w("\(prefix).norm2.weight"), bias: w("\(prefix).norm2.bias"))
    let attended = StemOps.attention(
      query: normedQ, queries: queries, memory: normedK, keys: keys, channels: c, heads: heads,
      inWeight: w("\(prefix).cross_attn.in_proj_weight"), inBias: w("\(prefix).cross_attn.in_proj_bias"),
      outWeight: w("\(prefix).cross_attn.out_proj.weight"), outBias: w("\(prefix).cross_attn.out_proj.bias"))
    addScaled(&x, attended, scale: w("\(prefix).gamma_1.scale"), tokens: queries)
    feedForward(prefix, &x, tokens: queries, norm: "norm3")
    tokenGroupNorm(&x, tokens: queries, weight: w("\(prefix).norm_out.weight"), bias: w("\(prefix).norm_out.bias"))
    return x
  }

  private func feedForward(_ prefix: String, _ x: inout [Float], tokens: Int, norm: String) {
    let c = transformerChannels
    let hiddenSize = shape("\(prefix).linear1.weight")[0]
    let normed = StemOps.layerNorm(x, tokens: tokens, channels: c, weight: w("\(prefix).\(norm).weight"), bias: w("\(prefix).\(norm).bias"))
    var hidden = StemOps.linear(normed, tokens: tokens, inFeatures: c, weight: w("\(prefix).linear1.weight"), bias: w("\(prefix).linear1.bias"), outFeatures: hiddenSize)
    StemOps.gelu(&hidden)
    let out = StemOps.linear(hidden, tokens: tokens, inFeatures: hiddenSize, weight: w("\(prefix).linear2.weight"), bias: w("\(prefix).linear2.bias"), outFeatures: c)
    addScaled(&x, out, scale: w("\(prefix).gamma_2.scale"), tokens: tokens)
  }

  /// x += y · scale, the scale per channel (LayerScale).
  private func addScaled(_ x: inout [Float], _ y: [Float], scale: [Float], tokens: Int) {
    let c = transformerChannels
    x.withUnsafeMutableBufferPointer { out in
      y.withUnsafeBufferPointer { add in
        for t in 0..<tokens {
          let row = out.baseAddress! + t * c
          vDSP_vma(add.baseAddress! + t * c, 1, scale, 1, row, 1, row, 1, vDSP_Length(c))
        }
      }
    }
  }

  /// GroupNorm(1) over all of a sequence's tokens and channels, with per-channel affine.
  private func tokenGroupNorm(_ x: inout [Float], tokens: Int, weight: [Float], bias: [Float]) {
    let c = transformerChannels
    var mean: Float = 0, meanSquare: Float = 0
    vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
    vDSP_measqv(x, 1, &meanSquare, vDSP_Length(x.count))
    var inverse = 1 / (max(0, meanSquare - mean * mean) + 1e-5).squareRoot()
    var shift = -mean * inverse
    x.withUnsafeMutableBufferPointer { out in
      vDSP_vsmsa(out.baseAddress!, 1, &inverse, &shift, out.baseAddress!, 1, vDSP_Length(tokens * c))
      for t in 0..<tokens {
        let row = out.baseAddress! + t * c
        vDSP_vma(row, 1, weight, 1, bias, 1, row, 1, vDSP_Length(c))
      }
    }
  }

  // MARK: - Helpers

  /// Mean and (unbiased) standard deviation, as torch's `std` computes them.
  static func meanAndStd(_ x: [Float]) -> (Float, Float) {
    var mean: Float = 0
    vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
    var sum: Double = 0
    for value in x {
      let d = Double(value - mean)
      sum += d * d
    }
    return (mean, Float((sum / Double(max(1, x.count - 1))).squareRoot()))
  }

  static func padColumns(_ x: [Float], channels: Int, columns: Int, right: Int) -> [Float] {
    var output = [Float](repeating: 0, count: channels * (columns + right))
    for c in 0..<channels {
      output.replaceSubrange((c * (columns + right))..<(c * (columns + right) + columns), with: x[(c * columns)..<((c + 1) * columns)])
    }
    return output
  }

  /// `create_sin_embedding`, tokens `[length, channels]`: cosines in the first half, sines in
  /// the second.
  static func sinEmbedding1D(channels: Int, length: Int) -> [Float] {
    let half = channels / 2
    var output = [Float](repeating: 0, count: length * channels)
    for i in 0..<half {
      let period = pow(10_000, Double(i) / Double(half - 1))
      for t in 0..<length {
        let phase = Double(t) / period
        output[t * channels + i] = Float(cos(phase))
        output[t * channels + half + i] = Float(sin(phase))
      }
    }
    return output
  }

  /// `create_2d_sin_embedding`: [channels, height, width].
  static func sinEmbedding2D(channels: Int, height: Int, width: Int) -> [Float] {
    var pe = [Float](repeating: 0, count: channels * height * width)
    let half = channels / 2
    let terms = stride(from: 0, to: half, by: 2).map { exp(Double($0) * -(log(10_000.0) / Double(half))) }
    for (i, term) in terms.enumerated() {
      for h in 0..<height {
        for x in 0..<width {
          pe[((2 * i) * height + h) * width + x] = Float(sin(Double(x) * term))
          pe[((2 * i + 1) * height + h) * width + x] = Float(cos(Double(x) * term))
          pe[((half + 2 * i) * height + h) * width + x] = Float(sin(Double(h) * term))
          pe[((half + 2 * i + 1) * height + h) * width + x] = Float(cos(Double(h) * term))
        }
      }
    }
    return pe
  }
}
