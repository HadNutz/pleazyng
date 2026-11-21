// Model the installed webOS embedder asking for pixels after unregister returns.
#include <cassert>

#include "../../../shared/tv_mpv/tv_mpv_plugin.h"

int main() {
  using namespace pleazyng_tv;
  auto first = std::make_shared<PictureSlot>();
  first->picture = std::make_shared<Picture>(8, 4);
  auto first_id = WebosPictureSlots::add(first);
  auto* first_context = reinterpret_cast<void*>(first_id);
  auto* lease = WebosPictureSlots::copy(8, 4, first_context);
  assert(lease && lease->width == 8);
  WebosPictureSlots::remove(first_id);
  first.reset();

  auto next = std::make_shared<PictureSlot>();
  next->picture = std::make_shared<Picture>(16, 4);
  auto next_id = WebosPictureSlots::add(next);
  assert(WebosPictureSlots::copy(0, 0, first_context) == nullptr);
  assert(WebosPictureSlots::copy(8, 4, first_context) == nullptr);
  assert(lease->width == 8 && lease->buffer);
  lease->release_callback(lease->release_context);
  auto* current = WebosPictureSlots::copy(16, 4, reinterpret_cast<void*>(next_id));
  assert(current && current->width == 16);
  current->release_callback(current->release_context);
  WebosPictureSlots::remove(next_id);
}
