#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace system_video {

// The compatibility surface is an sRGB Flutter texture. Decode PQ/HLG before
// compressing luminance, then convert linear BT.2020 to the display primaries.
struct TransferTables {
  std::array<float, 1024> pq{}, hlg{};
  std::array<uint8_t, 4096> srgb{};
  TransferTables() {
    for (size_t i = 0; i < pq.size(); ++i) {
      const double v = i / 1023.0;
      const double p = std::pow(v, 32.0 / 2523.0);
      pq[i] = static_cast<float>(
          10000 * std::pow(std::max(0., p - 3424. / 4096.) / (2413. / 128. - 2392. / 128. * p), 16384. / 2610.));
      hlg[i] = static_cast<float>(v <= .5 ? v * v / 3 : (std::exp((v - .55991073) / .17883277) + .28466892) / 12);
    }
    for (size_t i = 0; i < srgb.size(); ++i) {
      const double v = i / 4095.;
      srgb[i] =
          static_cast<uint8_t>(std::lround(255 * (v <= .0031308 ? 12.92 * v : 1.055 * std::pow(v, 1 / 2.4) - .055)));
    }
  }
  uint8_t encode(float linear) const { return srgb[std::lround(std::clamp(linear, 0.f, 1.f) * 4095)]; }
};

inline void toSdr(uint32_t rgb, bool pq, bool hlg, bool bt2020, uint8_t* dst) {
  const unsigned r = rgb & 1023, g = (rgb >> 10) & 1023, b = (rgb >> 20) & 1023;
  dst[3] = 255;
  if (!pq && !hlg) {
    dst[0] = (r * 255 + 511) / 1023;
    dst[1] = (g * 255 + 511) / 1023;
    dst[2] = (b * 255 + 511) / 1023;
    return;
  }
  static const TransferTables tables;
  const auto& curve = pq ? tables.pq : tables.hlg;
  float red = curve[r], green = curve[g], blue = curve[b];
  const float y =
      bt2020 ? .2627f * red + .6780f * green + .0593f * blue : .2126f * red + .7152f * green + .0722f * blue;
  // Reference 1000-nit HLG display with system gamma 1.2, 203-nit diffuse white.
  const float units = (pq ? 1.f : 1000.f * std::pow(y, .2f)) / 203.f;
  const float scale = units / (1.f + y * units);
  red *= scale;
  green *= scale;
  blue *= scale;
  dst[0] = tables.encode(bt2020 ? 1.66049f * red - .58764f * green - .07285f * blue : red);
  dst[1] = tables.encode(bt2020 ? -.12455f * red + 1.13290f * green - .00835f * blue : green);
  dst[2] = tables.encode(bt2020 ? -.01815f * red - .10058f * green + 1.11873f * blue : blue);
}
}  // namespace system_video
