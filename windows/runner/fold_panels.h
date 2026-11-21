#pragma once
#include <windows.h>
#include <vector>

// Active embedded panel bounds in desktop physical pixels. External displays
// and cloned outputs must never be interpreted as the halves of a foldable.
std::vector<RECT> EmbeddedDisplayPanels();
