//
//  Biquad.hpp
//  OngakuEffects
//

#pragma once

#include <cmath>
#include <complex>

namespace ongaku {

/// The coefficients of one second-order filter section, from Robert Bristow-Johnson's
/// Audio EQ Cookbook, normalised so a0 is 1. First-order sections leave b2 and a2 at zero.
struct BiquadCoefficients {
  double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;

  static BiquadCoefficients normalised(double b0, double b1, double b2, double a0, double a1, double a2) {
    return {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
  }

  static BiquadCoefficients bell(double frequency, double gainDB, double q, double sampleRate) {
    double a = std::pow(10.0, gainDB / 40);
    double w = 2 * M_PI * frequency / sampleRate;
    double alpha = std::sin(w) / (2 * q);
    double cosW = std::cos(w);
    return normalised(1 + alpha * a, -2 * cosW, 1 - alpha * a, 1 + alpha / a, -2 * cosW, 1 - alpha / a);
  }

  static BiquadCoefficients lowShelf(double frequency, double gainDB, double q, double sampleRate) {
    double a = std::pow(10.0, gainDB / 40);
    double w = 2 * M_PI * frequency / sampleRate;
    double alpha = std::sin(w) / (2 * q);
    double cosW = std::cos(w);
    double root = 2 * std::sqrt(a) * alpha;
    return normalised(
      a * ((a + 1) - (a - 1) * cosW + root), 2 * a * ((a - 1) - (a + 1) * cosW), a * ((a + 1) - (a - 1) * cosW - root),
      (a + 1) + (a - 1) * cosW + root, -2 * ((a - 1) + (a + 1) * cosW), (a + 1) + (a - 1) * cosW - root);
  }

  static BiquadCoefficients highShelf(double frequency, double gainDB, double q, double sampleRate) {
    double a = std::pow(10.0, gainDB / 40);
    double w = 2 * M_PI * frequency / sampleRate;
    double alpha = std::sin(w) / (2 * q);
    double cosW = std::cos(w);
    double root = 2 * std::sqrt(a) * alpha;
    return normalised(
      a * ((a + 1) + (a - 1) * cosW + root), -2 * a * ((a - 1) + (a + 1) * cosW), a * ((a + 1) + (a - 1) * cosW - root),
      (a + 1) - (a - 1) * cosW + root, 2 * ((a - 1) - (a + 1) * cosW), (a + 1) - (a - 1) * cosW - root);
  }

  static BiquadCoefficients lowPass(double frequency, double q, double sampleRate) {
    double w = 2 * M_PI * frequency / sampleRate;
    double alpha = std::sin(w) / (2 * q);
    double cosW = std::cos(w);
    return normalised((1 - cosW) / 2, 1 - cosW, (1 - cosW) / 2, 1 + alpha, -2 * cosW, 1 - alpha);
  }

  static BiquadCoefficients highPass(double frequency, double q, double sampleRate) {
    double w = 2 * M_PI * frequency / sampleRate;
    double alpha = std::sin(w) / (2 * q);
    double cosW = std::cos(w);
    return normalised((1 + cosW) / 2, -(1 + cosW), (1 + cosW) / 2, 1 + alpha, -2 * cosW, 1 - alpha);
  }

  /// A band around `frequency`, 0 dB at its peak; Q 1.41 is about an octave wide.
  static BiquadCoefficients bandPass(double frequency, double q, double sampleRate) {
    double w = 2 * M_PI * frequency / sampleRate;
    double alpha = std::sin(w) / (2 * q);
    return normalised(alpha, 0, -alpha, 1 + alpha, -2 * std::cos(w), 1 - alpha);
  }

  /// Passes every frequency at the same level, turning the phase through 360° around the
  /// frequency. At Q 0.71 it's what a Linkwitz-Riley low-pass and high-pass at the same
  /// frequency add up to.
  static BiquadCoefficients allPass(double frequency, double q, double sampleRate) {
    double w = 2 * M_PI * frequency / sampleRate;
    double alpha = std::sin(w) / (2 * q);
    double cosW = std::cos(w);
    return normalised(1 - alpha, -2 * cosW, 1 + alpha, 1 + alpha, -2 * cosW, 1 - alpha);
  }

  /// A first-order (6 dB per octave) low-pass, by the bilinear transform.
  static BiquadCoefficients firstOrderLowPass(double frequency, double sampleRate) {
    double k = std::tan(M_PI * frequency / sampleRate);
    return {k / (1 + k), k / (1 + k), 0, (k - 1) / (k + 1), 0};
  }

  static BiquadCoefficients firstOrderHighPass(double frequency, double sampleRate) {
    double k = std::tan(M_PI * frequency / sampleRate);
    return {1 / (1 + k), -1 / (1 + k), 0, (k - 1) / (k + 1), 0};
  }

  /// The section's gain at `frequency`, in decibels.
  double magnitudeDB(double frequency, double sampleRate) const {
    std::complex<double> z1 = std::polar(1.0, -2 * M_PI * frequency / sampleRate);
    std::complex<double> z2 = z1 * z1;
    double magnitude = std::abs(b0 + b1 * z1 + b2 * z2) / std::abs(1.0 + a1 * z1 + a2 * z2);
    return 20 * std::log10(std::max(magnitude, 1e-12));
  }
};

/// One channel's memory of a section (transposed direct form II, in double precision so
/// low, steep filters stay stable and quiet).
struct BiquadState {
  double z1 = 0, z2 = 0;

  inline float process(float input, BiquadCoefficients const &c) {
    double output = c.b0 * input + z1;
    z1 = c.b1 * input - c.a1 * output + z2;
    z2 = c.b2 * input - c.a2 * output;
    return float(output);
  }

  void reset() { z1 = z2 = 0; }

  /// Clears values too small to hear, so a filter ringing out doesn't fall into slow
  /// denormal arithmetic.
  void flushDenormals() {
    if (std::abs(z1) < 1e-20) z1 = 0;
    if (std::abs(z2) < 1e-20) z2 = 0;
  }
};

}  // namespace ongaku
