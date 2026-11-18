#include "system_tone_map.h"

#include <cstdio>
#include <cstdlib>

int main() {
  uint8_t rgba[4]{};
  auto grey = [&](uint32_t value, bool pq, bool hlg) {
    system_video::toSdr(value | (value << 10) | (value << 20), pq, hlg, true, rgba);
    if (rgba[0] != rgba[1] || rgba[1] != rgba[2] || rgba[3] != 255) std::abort();
    return rgba[0];
  };
  for (bool pq : {false, true}) {
    if (grey(0, pq, !pq) != 0) return 1;
    auto shadow = grey(128, pq, !pq);
    auto mid = grey(512, pq, !pq);
    auto peak = grey(1023, pq, !pq);
    if (shadow >= mid || mid >= peak || peak < 225) return 2;
  }
  system_video::toSdr(1023, false, false, false, rgba);
  if (rgba[0] != 255 || rgba[1] != 0 || rgba[2] != 0) return 3;
  return 0;
}
