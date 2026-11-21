//
//  StemTensorOps.swift
//  OngakuEngine
//

import Accelerate
import Foundation

/// The arithmetic HTDemucs needs, on the CPU with Accelerate (BLAS matrix multiplies run on
/// the Apple silicon matrix units). Tensors are plain row-major `[Float]` arrays; shapes are
/// passed alongside. A "plane" is `[channels, rows, columns]`: the frequency branch's
/// `[C, F, T]`, or the time branch's `[C, 1, T]`. Every inner loop is a vDSP or BLAS call,
/// so it's fast in debug builds too.
enum StemOps {
  /// `C = A × B`, with A `[m, k]` and B `[k, n]` (either may be transposed in memory), and
  /// optional leading dimensions for working on slices in place.
  static func matmul(
    _ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ c: UnsafeMutablePointer<Float>, m: Int, n: Int, k: Int,
    transposeA: Bool = false, transposeB: Bool = false, accumulate: Bool = false, lda: Int? = nil, ldb: Int? = nil, ldc: Int? = nil
  ) {
    cblas_sgemm(
      CblasRowMajor, transposeA ? CblasTrans : CblasNoTrans, transposeB ? CblasTrans : CblasNoTrans, Int32(m), Int32(n), Int32(k), 1,
      a, Int32(lda ?? (transposeA ? m : k)), b, Int32(ldb ?? (transposeB ? k : n)), accumulate ? 1 : 0, c, Int32(ldc ?? n))
  }

  /// Copies `count` floats `from` (every `stride`th) `to`.
  @inline(__always)
  static func copy(_ from: UnsafePointer<Float>, stride: Int = 1, to: UnsafeMutablePointer<Float>, count: Int) {
    guard count > 0 else { return }
    cblas_scopy(Int32(count), from, Int32(stride), to, 1)
  }

  @inline(__always)
  static func zero(_ pointer: UnsafeMutablePointer<Float>, count: Int) {
    guard count > 0 else { return }
    vDSP_vclr(pointer, 1, vDSP_Length(count))
  }

  /// Adds each output channel's bias to its block of `count` positions in `result` and
  /// stores them at `start` in `output` (whose channels are `positions` long).
  static func storeBlock(
    _ result: UnsafePointer<Float>, count: Int, into output: UnsafeMutablePointer<Float>, start: Int, positions: Int,
    outChannels: Int, bias: [Float]?
  ) {
    for o in 0..<outChannels {
      var b = bias?[o] ?? 0
      vDSP_vsadd(result + o * count, 1, &b, output + o * positions + start, 1, vDSP_Length(count))
    }
  }

  // MARK: - Convolutions

  /// A convolution along a plane's columns (time), rows independent: weights
  /// `[out, in, kernel]`. Returns `[out, rows, outColumns]`.
  static func convColumns(
    _ x: [Float], channels: Int, rows: Int, columns: Int, weight: [Float], bias: [Float]?, outChannels: Int, kernel: Int,
    stride: Int = 1, padding: Int = 0, dilation: Int = 1
  ) -> (values: [Float], columns: Int) {
    let outColumns = (columns + 2 * padding - dilation * (kernel - 1) - 1) / stride + 1
    let positions = rows * outColumns
    var output = [Float](repeating: 0, count: outChannels * positions)
    let depth = channels * kernel
    // Whole rows at a time, so the unfolded input stays small.
    let rowsPerBlock = max(1, min(rows, 4_000_000 / max(1, depth * outColumns)))
    let block = rowsPerBlock * outColumns
    var unfolded = [Float](repeating: 0, count: depth * block)
    var result = [Float](repeating: 0, count: outChannels * block)
    x.withUnsafeBufferPointer { input in
      output.withUnsafeMutableBufferPointer { out in
        unfolded.withUnsafeMutableBufferPointer { cols in
          result.withUnsafeMutableBufferPointer { res in
            weight.withUnsafeBufferPointer { w in
              var firstRow = 0
              while firstRow < rows {
                let blockRows = min(rowsPerBlock, rows - firstRow)
                let count = blockRows * outColumns
                // One row of the unfolded matrix per (channel, tap): the input row, shifted
                // by the tap and stepped by the stride, zeros past either end.
                for c in 0..<channels {
                  for k in 0..<kernel {
                    let shift = k * dilation - padding
                    // Output columns whose source is inside the row.
                    let first = shift >= 0 ? 0 : (-shift + stride - 1) / stride
                    let last = min(outColumns, (columns - 1 - shift) / stride + 1)
                    for r in 0..<blockRows {
                      let destination = cols.baseAddress! + (c * kernel + k) * count + r * outColumns
                      let source = input.baseAddress! + (c * rows + firstRow + r) * columns
                      if last <= first {
                        zero(destination, count: outColumns)
                        continue
                      }
                      zero(destination, count: first)
                      copy(source + first * stride + shift, stride: stride, to: destination + first, count: last - first)
                      zero(destination + last, count: outColumns - last)
                    }
                  }
                }
                matmul(w.baseAddress!, cols.baseAddress!, res.baseAddress!, m: outChannels, n: count, k: depth)
                storeBlock(
                  res.baseAddress!, count: count, into: out.baseAddress!, start: firstRow * outColumns, positions: positions,
                  outChannels: outChannels, bias: bias)
                firstRow += blockRows
              }
            }
          }
        }
      }
    }
    return (output, outColumns)
  }

  /// A convolution along a plane's rows (frequency), columns independent: weights
  /// `[out, in, kernel, 1]`. Returns `[out, outRows, columns]`.
  static func convRows(
    _ x: [Float], channels: Int, rows: Int, columns: Int, weight: [Float], bias: [Float]?, outChannels: Int, kernel: Int,
    stride: Int, padding: Int
  ) -> (values: [Float], rows: Int) {
    let outRows = (rows + 2 * padding - kernel) / stride + 1
    let positions = outRows * columns
    var output = [Float](repeating: 0, count: outChannels * positions)
    let depth = channels * kernel
    let rowsPerBlock = max(1, min(outRows, 4_000_000 / max(1, depth * columns)))
    let block = rowsPerBlock * columns
    var unfolded = [Float](repeating: 0, count: depth * block)
    var result = [Float](repeating: 0, count: outChannels * block)
    x.withUnsafeBufferPointer { input in
      output.withUnsafeMutableBufferPointer { out in
        unfolded.withUnsafeMutableBufferPointer { cols in
          result.withUnsafeMutableBufferPointer { res in
            weight.withUnsafeBufferPointer { w in
              var firstRow = 0
              while firstRow < outRows {
                let blockRows = min(rowsPerBlock, outRows - firstRow)
                let count = blockRows * columns
                for c in 0..<channels {
                  for k in 0..<kernel {
                    for r in 0..<blockRows {
                      let destination = cols.baseAddress! + (c * kernel + k) * count + r * columns
                      let source = (firstRow + r) * stride + k - padding
                      if source >= 0 && source < rows {
                        copy(input.baseAddress! + (c * rows + source) * columns, to: destination, count: columns)
                      } else {
                        zero(destination, count: columns)
                      }
                    }
                  }
                }
                matmul(w.baseAddress!, cols.baseAddress!, res.baseAddress!, m: outChannels, n: count, k: depth)
                storeBlock(
                  res.baseAddress!, count: count, into: out.baseAddress!, start: firstRow * columns, positions: positions,
                  outChannels: outChannels, bias: bias)
                firstRow += blockRows
              }
            }
          }
        }
      }
    }
    return (output, outRows)
  }

  /// A 3×3 convolution over a whole plane (rows and columns), padding 1: weights
  /// `[out, in, 3, 3]`.
  static func conv3x3(_ x: [Float], channels: Int, rows: Int, columns: Int, weight: [Float], bias: [Float], outChannels: Int) -> [Float] {
    let positions = rows * columns
    var output = [Float](repeating: 0, count: outChannels * positions)
    let depth = channels * 9
    let rowsPerBlock = max(1, min(rows, 6_000_000 / max(1, depth * columns)))
    let block = rowsPerBlock * columns
    var unfolded = [Float](repeating: 0, count: depth * block)
    var result = [Float](repeating: 0, count: outChannels * block)
    x.withUnsafeBufferPointer { input in
      output.withUnsafeMutableBufferPointer { out in
        unfolded.withUnsafeMutableBufferPointer { cols in
          result.withUnsafeMutableBufferPointer { res in
            weight.withUnsafeBufferPointer { w in
              var firstRow = 0
              while firstRow < rows {
                let blockRows = min(rowsPerBlock, rows - firstRow)
                let count = blockRows * columns
                for c in 0..<channels {
                  for kr in 0..<3 {
                    for kc in 0..<3 {
                      let shift = kc - 1
                      for r in 0..<blockRows {
                        let destination = cols.baseAddress! + (c * 9 + kr * 3 + kc) * count + r * columns
                        let source = firstRow + r + kr - 1
                        guard source >= 0 && source < rows else {
                          zero(destination, count: columns)
                          continue
                        }
                        let row = input.baseAddress! + (c * rows + source) * columns
                        // Shifted by one column left or right, a zero coming in at the edge.
                        if shift < 0 {
                          destination[0] = 0
                          copy(row, to: destination + 1, count: columns - 1)
                        } else if shift > 0 {
                          copy(row + 1, to: destination, count: columns - 1)
                          destination[columns - 1] = 0
                        } else {
                          copy(row, to: destination, count: columns)
                        }
                      }
                    }
                  }
                }
                matmul(w.baseAddress!, cols.baseAddress!, res.baseAddress!, m: outChannels, n: count, k: depth)
                storeBlock(
                  res.baseAddress!, count: count, into: out.baseAddress!, start: firstRow * columns, positions: positions,
                  outChannels: outChannels, bias: bias)
                firstRow += blockRows
              }
            }
          }
        }
      }
    }
    return output
  }

  /// A 1×1 convolution (a linear map of channels at every position): weights `[out, in]`.
  static func pointwise(_ x: [Float], channels: Int, positions: Int, weight: [Float], bias: [Float]?, outChannels: Int) -> [Float] {
    var output = [Float](repeating: 0, count: outChannels * positions)
    weight.withUnsafeBufferPointer { w in
      x.withUnsafeBufferPointer { input in
        output.withUnsafeMutableBufferPointer { out in
          matmul(w.baseAddress!, input.baseAddress!, out.baseAddress!, m: outChannels, n: positions, k: channels)
          if let bias {
            for o in 0..<outChannels {
              var b = bias[o]
              vDSP_vsadd(out.baseAddress! + o * positions, 1, &b, out.baseAddress! + o * positions, 1, vDSP_Length(positions))
            }
          }
        }
      }
    }
    return output
  }

  /// A transposed convolution along columns (`alongRows == false`) or rows: weights
  /// `[in, out, kernel(, 1)]`, the input's positions spread `stride` apart and overlapped.
  /// Returns the full output (before any cropping).
  static func convTranspose(
    _ x: [Float], channels: Int, rows: Int, columns: Int, weight: [Float], bias: [Float], outChannels: Int, kernel: Int,
    stride: Int, alongRows: Bool
  ) -> (values: [Float], rows: Int, columns: Int) {
    let positions = rows * columns
    // Every output tap of every input position: [out × kernel, positions].
    var taps = [Float](repeating: 0, count: outChannels * kernel * positions)
    weight.withUnsafeBufferPointer { w in
      x.withUnsafeBufferPointer { input in
        taps.withUnsafeMutableBufferPointer { out in
          matmul(w.baseAddress!, input.baseAddress!, out.baseAddress!, m: outChannels * kernel, n: positions, k: channels, transposeA: true)
        }
      }
    }
    let outRows = alongRows ? (rows - 1) * stride + kernel : rows
    let outColumns = alongRows ? columns : (columns - 1) * stride + kernel
    let plane = outRows * outColumns
    var output = [Float](repeating: 0, count: outChannels * plane)
    taps.withUnsafeBufferPointer { tap in
      output.withUnsafeMutableBufferPointer { out in
        for o in 0..<outChannels {
          var b = bias[o]
          vDSP_vfill(&b, out.baseAddress! + o * plane, 1, vDSP_Length(plane))
          for k in 0..<kernel {
            let source = tap.baseAddress! + (o * kernel + k) * positions
            for r in 0..<rows {
              if alongRows {
                // Row r lands on output row r·stride + k.
                let destination = out.baseAddress! + o * plane + (r * stride + k) * outColumns
                vDSP_vadd(source + r * columns, 1, destination, 1, destination, 1, vDSP_Length(columns))
              } else {
                // Column t lands on output column t·stride + k.
                let destination = out.baseAddress! + o * plane + r * outColumns + k
                vDSP_vadd(source + r * columns, 1, destination, vDSP_Stride(stride), destination, vDSP_Stride(stride), vDSP_Length(columns))
              }
            }
          }
        }
      }
    }
    return (output, outRows, outColumns)
  }

  // MARK: - Activations and normalization

  /// The exact GELU, x·Φ(x) = x/2·(1 + erf(x/√2)), with erf from Abramowitz and Stegun
  /// 7.1.26 (within 1.5 × 10⁻⁷), all in vector operations.
  static func gelu(_ x: inout [Float]) {
    let n = x.count
    guard n > 0 else { return }
    let length = vDSP_Length(n)
    var z = [Float](repeating: 0, count: n), t = [Float](repeating: 0, count: n), e = [Float](repeating: 0, count: n)
    var invSqrt2 = Float(1 / 2.0.squareRoot())
    // z = |x|/√2
    vDSP_vabs(x, 1, &z, 1, length)
    vDSP_vsmul(z, 1, &invSqrt2, &z, 1, length)
    // t = 1/(1 + p·z)
    var p: Float = 0.3275911, one: Float = 1
    vDSP_vsmsa(z, 1, &p, &one, &t, 1, length)
    vDSP_svdiv(&one, t, 1, &t, 1, length)
    // poly(t)·t
    let a: [Float] = [1.061405429, -1.453152027, 1.421413741, -0.284496736, 0.254829592]
    var poly = [Float](repeating: a[0], count: n)
    for coefficient in a.dropFirst() {
      var c = coefficient
      vDSP_vmsa(poly, 1, t, 1, &c, &poly, 1, length)
    }
    vDSP_vmul(poly, 1, t, 1, &poly, 1, length)
    // e = exp(-z²)
    vDSP_vsq(z, 1, &e, 1, length)
    vDSP_vneg(e, 1, &e, 1, length)
    var count = Int32(n)
    vvexpf(&e, e, &count)
    // erf(|x|/√2) = 1 - poly·e; with the sign of x: Φ-part = 1 + sign·erf.
    vDSP_vmul(poly, 1, e, 1, &poly, 1, length)
    var minusOne: Float = -1
    vDSP_vsmsa(poly, 1, &minusOne, &one, &poly, 1, length)  // erf(|x|/√2)
    // sign(x)·erf, via copysign.
    var signs = [Float](repeating: 0, count: n)
    vvcopysignf(&signs, poly, x, &count)
    var half: Float = 0.5
    vDSP_vsadd(signs, 1, &one, &signs, 1, length)
    vDSP_vsmul(signs, 1, &half, &signs, 1, length)
    vDSP_vmul(x, 1, signs, 1, &x, 1, length)
  }

  /// The gated linear unit over channels: the first half times the sigmoid of the second.
  static func glu(_ x: [Float], channels: Int, positions: Int) -> [Float] {
    let half = channels / 2 * positions
    var gate = [Float](repeating: 0, count: half)
    var output = [Float](repeating: 0, count: half)
    x.withUnsafeBufferPointer { input in
      // sigmoid(g) = 1 / (1 + e^-g)
      vDSP_vneg(input.baseAddress! + half, 1, &gate, 1, vDSP_Length(half))
      var count = Int32(half)
      vvexpf(&gate, gate, &count)
      var one: Float = 1
      vDSP_vsadd(gate, 1, &one, &gate, 1, vDSP_Length(half))
      vDSP_vdiv(gate, 1, input.baseAddress!, 1, &output, 1, vDSP_Length(half))
    }
    return output
  }

  /// Group norm over `groups` groups of channels (Demucs uses one: everything), then the
  /// per-channel scale and shift.
  static func groupNorm(_ x: inout [Float], channels: Int, positions: Int, groups: Int = 1, weight: [Float], bias: [Float], eps: Float = 1e-5) {
    let perGroup = channels / groups * positions
    x.withUnsafeMutableBufferPointer { buffer in
      for g in 0..<groups {
        let base = buffer.baseAddress! + g * perGroup
        var mean: Float = 0, meanSquare: Float = 0
        vDSP_meanv(base, 1, &mean, vDSP_Length(perGroup))
        vDSP_measqv(base, 1, &meanSquare, vDSP_Length(perGroup))
        let inverse = 1 / (max(0, meanSquare - mean * mean) + eps).squareRoot()
        for c in (g * channels / groups)..<((g + 1) * channels / groups) {
          var scale = inverse * weight[c]
          var shift = bias[c] - mean * scale
          let row = buffer.baseAddress! + c * positions
          vDSP_vsmsa(row, 1, &scale, &shift, row, 1, vDSP_Length(positions))
        }
      }
    }
  }

  /// Layer norm over each token's channels: tokens `[count, channels]`.
  static func layerNorm(_ x: [Float], tokens: Int, channels: Int, weight: [Float], bias: [Float], eps: Float = 1e-5) -> [Float] {
    var output = [Float](repeating: 0, count: x.count)
    x.withUnsafeBufferPointer { input in
      output.withUnsafeMutableBufferPointer { out in
        for t in 0..<tokens {
          let row = input.baseAddress! + t * channels
          let destination = out.baseAddress! + t * channels
          var mean: Float = 0, meanSquare: Float = 0
          vDSP_meanv(row, 1, &mean, vDSP_Length(channels))
          vDSP_measqv(row, 1, &meanSquare, vDSP_Length(channels))
          var inverse = 1 / (max(0, meanSquare - mean * mean) + eps).squareRoot()
          var shift = -mean * inverse
          vDSP_vsmsa(row, 1, &inverse, &shift, destination, 1, vDSP_Length(channels))
          vDSP_vma(destination, 1, weight, 1, bias, 1, destination, 1, vDSP_Length(channels))
        }
      }
    }
    return output
  }

  /// A linear layer on tokens `[count, in]` with weights `[out, in]`.
  static func linear(_ x: [Float], tokens: Int, inFeatures: Int, weight: [Float], bias: [Float], outFeatures: Int) -> [Float] {
    x.withUnsafeBufferPointer { input in
      weight.withUnsafeBufferPointer { w in
        linear(input.baseAddress!, tokens: tokens, inFeatures: inFeatures, weight: w.baseAddress!, bias: bias, outFeatures: outFeatures)
      }
    }
  }

  static func linear(
    _ x: UnsafePointer<Float>, tokens: Int, inFeatures: Int, weight: UnsafePointer<Float>, bias: ArraySlice<Float>, outFeatures: Int
  ) -> [Float] {
    var output = [Float](repeating: 0, count: tokens * outFeatures)
    output.withUnsafeMutableBufferPointer { out in
      // Start from the bias in every row, then add x·Wᵀ.
      bias.withUnsafeBufferPointer { b in
        for t in 0..<tokens { copy(b.baseAddress!, to: out.baseAddress! + t * outFeatures, count: outFeatures) }
      }
      matmul(x, weight, out.baseAddress!, m: tokens, n: outFeatures, k: inFeatures, transposeB: true, accumulate: true)
    }
    return output
  }

  static func linear(
    _ x: UnsafePointer<Float>, tokens: Int, inFeatures: Int, weight: UnsafePointer<Float>, bias: [Float], outFeatures: Int
  ) -> [Float] {
    linear(x, tokens: tokens, inFeatures: inFeatures, weight: weight, bias: bias[...], outFeatures: outFeatures)
  }

  /// Multi-head attention (PyTorch's nn.MultiheadAttention): queries from `query`
  /// `[tq, C]`, keys and values from `memory` `[tk, C]`, packed input projection
  /// `[3C, C]`, output projection `[C, C]`.
  static func attention(
    query: [Float], queries: Int, memory: [Float], keys: Int, channels: Int, heads: Int, inWeight: [Float], inBias: [Float],
    outWeight: [Float], outBias: [Float]
  ) -> [Float] {
    let c = channels, d = channels / heads
    let (q, k, v) = inWeight.withUnsafeBufferPointer { w in
      query.withUnsafeBufferPointer { qx in
        memory.withUnsafeBufferPointer { mx in
          (
            linear(qx.baseAddress!, tokens: queries, inFeatures: c, weight: w.baseAddress!, bias: inBias[0..<c], outFeatures: c),
            linear(mx.baseAddress!, tokens: keys, inFeatures: c, weight: w.baseAddress! + c * c, bias: inBias[c..<(2 * c)], outFeatures: c),
            linear(mx.baseAddress!, tokens: keys, inFeatures: c, weight: w.baseAddress! + 2 * c * c, bias: inBias[(2 * c)..<(3 * c)], outFeatures: c)
          )
        }
      }
    }
    var context = [Float](repeating: 0, count: queries * c)
    var scores = [Float](repeating: 0, count: queries * keys)
    let scale = 1 / Float(d).squareRoot()
    q.withUnsafeBufferPointer { qp in
      k.withUnsafeBufferPointer { kp in
        v.withUnsafeBufferPointer { vp in
          context.withUnsafeMutableBufferPointer { cp in
            for h in 0..<heads {
              // Each head's slice of every token, read in place (leading dimension C).
              scores.withUnsafeMutableBufferPointer { sp in
                matmul(qp.baseAddress! + h * d, kp.baseAddress! + h * d, sp.baseAddress!, m: queries, n: keys, k: d, transposeB: true, lda: c, ldb: c)
                var s = scale
                vDSP_vsmul(sp.baseAddress!, 1, &s, sp.baseAddress!, 1, vDSP_Length(queries * keys))
              }
              softmaxRows(&scores, rows: queries, columns: keys)
              scores.withUnsafeBufferPointer { sp in
                matmul(sp.baseAddress!, vp.baseAddress! + h * d, cp.baseAddress! + h * d, m: queries, n: d, k: keys, ldb: c, ldc: c)
              }
            }
          }
        }
      }
    }
    return linear(context, tokens: queries, inFeatures: c, weight: outWeight, bias: outBias, outFeatures: c)
  }

  static func softmaxRows(_ x: inout [Float], rows: Int, columns: Int) {
    x.withUnsafeMutableBufferPointer { buffer in
      for r in 0..<rows {
        let row = buffer.baseAddress! + r * columns
        var maximum: Float = 0
        vDSP_maxv(row, 1, &maximum, vDSP_Length(columns))
        var negative = -maximum
        vDSP_vsadd(row, 1, &negative, row, 1, vDSP_Length(columns))
        var count = Int32(columns)
        vvexpf(row, row, &count)
        var sum: Float = 0
        vDSP_sve(row, 1, &sum, vDSP_Length(columns))
        var inverse = 1 / sum
        vDSP_vsmul(row, 1, &inverse, row, 1, vDSP_Length(columns))
      }
    }
  }

  /// `[a, b]` to `[b, a]`.
  static func transpose(_ x: [Float], rows: Int, columns: Int) -> [Float] {
    var output = [Float](repeating: 0, count: x.count)
    vDSP_mtrans(x, 1, &output, 1, vDSP_Length(columns), vDSP_Length(rows))
    return output
  }
}

// MARK: - STFT

/// PyTorch's `stft`/`istft` as Demucs calls them: a periodic Hann window, centred frames
/// (reflect padding), "normalized" (scaled by 1/√n), one-sided.
final class StemSTFT: @unchecked Sendable {
  let size: Int
  let hop: Int
  private let window: [Float]
  private let setup: vDSP_DFT_Setup
  private let inverseSetup: vDSP_DFT_Setup

  init(size: Int, hop: Int) {
    self.size = size
    self.hop = hop
    window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
    setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)!
    inverseSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .INVERSE)!
  }

  deinit {
    vDSP_DFT_DestroySetup(setup)
    vDSP_DFT_DestroySetup(inverseSetup)
  }

  /// The spectrum of a signal: `[frames][bins]` of (real, imaginary), bins 0…size/2.
  func forward(_ signal: [Float]) -> (real: [[Float]], imaginary: [[Float]]) {
    let pad = size / 2
    let padded = Self.reflect(signal, left: pad, right: pad)
    let frames = 1 + (padded.count - size) / hop
    var real = [[Float]](), imaginary = [[Float]]()
    real.reserveCapacity(frames)
    imaginary.reserveCapacity(frames)
    let half = size / 2
    var evens = [Float](repeating: 0, count: half), odds = [Float](repeating: 0, count: half)
    var outReal = [Float](repeating: 0, count: half), outImaginary = [Float](repeating: 0, count: half)
    let scale = 0.5 / Float(size).squareRoot()
    for frame in 0..<frames {
      let start = frame * hop
      for i in 0..<half {
        evens[i] = padded[start + 2 * i] * window[2 * i]
        odds[i] = padded[start + 2 * i + 1] * window[2 * i + 1]
      }
      vDSP_DFT_Execute(setup, evens, odds, &outReal, &outImaginary)
      // zrop packs the Nyquist bin into imaginary[0]; its output is twice the DFT.
      var re = [Float](repeating: 0, count: half + 1), im = [Float](repeating: 0, count: half + 1)
      re[0] = outReal[0] * scale
      re[half] = outImaginary[0] * scale
      for k in 1..<half {
        re[k] = outReal[k] * scale
        im[k] = outImaginary[k] * scale
      }
      real.append(re)
      imaginary.append(im)
    }
    return (real, imaginary)
  }

  /// A signal from its spectrum (the inverse of `forward`), `length` samples long.
  func inverse(real: [[Float]], imaginary: [[Float]], length: Int) -> [Float] {
    let frames = real.count
    let half = size / 2
    let total = size + hop * (frames - 1)
    var output = [Float](repeating: 0, count: total)
    var envelope = [Float](repeating: 0, count: total)
    var inReal = [Float](repeating: 0, count: half), inImaginary = [Float](repeating: 0, count: half)
    var evens = [Float](repeating: 0, count: half), odds = [Float](repeating: 0, count: half)
    // Undo the 1/√n, and zrop's inverse gives n times the signal (from a twice-scaled input).
    let scale = Float(size).squareRoot() / Float(size)
    for frame in 0..<frames {
      inReal[0] = real[frame][0]
      inImaginary[0] = real[frame][half]
      for k in 1..<half {
        inReal[k] = real[frame][k]
        inImaginary[k] = imaginary[frame][k]
      }
      vDSP_DFT_Execute(inverseSetup, inReal, inImaginary, &evens, &odds)
      let start = frame * hop
      for i in 0..<half {
        let a = evens[i] * scale, b = odds[i] * scale
        output[start + 2 * i] += a * window[2 * i]
        output[start + 2 * i + 1] += b * window[2 * i + 1]
        envelope[start + 2 * i] += window[2 * i] * window[2 * i]
        envelope[start + 2 * i + 1] += window[2 * i + 1] * window[2 * i + 1]
      }
    }
    let pad = size / 2
    var result = [Float](repeating: 0, count: length)
    for i in 0..<length where pad + i < total {
      let e = envelope[pad + i]
      result[i] = e > 1e-11 ? output[pad + i] / e : 0
    }
    return result
  }

  /// Reflect padding (as `F.pad(mode: "reflect")`, mirroring without repeating the edge),
  /// with zeros first when the signal is too short to reflect (as Demucs's `pad1d`).
  static func reflect(_ signal: [Float], left: Int, right: Int) -> [Float] {
    var x = signal
    var left = left, right = right
    let longest = max(left, right)
    if x.count <= longest {
      let extra = longest - x.count + 1
      let extraRight = min(right, extra)
      let extraLeft = extra - extraRight
      x = [Float](repeating: 0, count: extraLeft) + x + [Float](repeating: 0, count: extraRight)
      left -= extraLeft
      right -= extraRight
    }
    let n = x.count
    var output = [Float](repeating: 0, count: left + n + right)
    for i in 0..<left { output[i] = x[left - i] }
    for i in 0..<n { output[left + i] = x[i] }
    for i in 0..<right { output[left + n + i] = x[n - 2 - i] }
    return output
  }
}
