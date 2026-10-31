//
//  DelayLine.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <cmath>
#include <vector>

namespace ongaku {

/// A delay line read at fractional positions (for modulation and gliding sizes).
class DelayLine {
public:
  void allocate(int maximumDelay) {
    // A power of two, so wrapping is a mask.
    int size = 1;
    while (size < maximumDelay + 4) size <<= 1;
    mBuffer.assign(size_t(size), 0);
    mMask = size - 1;
    mWrite = 0;
  }

  void clear() { std::fill(mBuffer.begin(), mBuffer.end(), 0.0f); }

  void write(float sample) {
    mBuffer[size_t(mWrite)] = sample;
    mWrite = (mWrite + 1) & mMask;
  }

  /// The sample written `delay` samples ago (at least 1), interpolated linearly.
  float read(float delay) const {
    float position = float(mWrite) - delay;
    int whole = int(std::floor(position));
    float fraction = position - float(whole);
    float a = mBuffer[size_t(whole & mMask)];
    float b = mBuffer[size_t((whole + 1) & mMask)];
    return a + (b - a) * fraction;
  }

  float read(int delay) const { return mBuffer[size_t((mWrite - delay) & mMask)]; }

private:
  std::vector<float> mBuffer {0, 0, 0, 0};
  int mMask = 3;
  int mWrite = 0;
};

}  // namespace ongaku
