#include "fold_panels.h"

std::vector<RECT> EmbeddedDisplayPanels() {
  UINT32 paths_count = 0, modes_count = 0;
  for (int attempt = 0; attempt < 3; ++attempt) {
    if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &paths_count, &modes_count) != ERROR_SUCCESS) break;
    std::vector<DISPLAYCONFIG_PATH_INFO> paths(paths_count);
    std::vector<DISPLAYCONFIG_MODE_INFO> modes(modes_count);
    const LONG status =
        QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &paths_count, paths.data(), &modes_count, modes.data(), nullptr);
    if (status == ERROR_INSUFFICIENT_BUFFER) continue;
    if (status != ERROR_SUCCESS) break;
    std::vector<RECT> panels;
    for (UINT32 index = 0; index < paths_count; ++index) {
      const auto& path = paths[index];
      switch (path.targetInfo.outputTechnology) {
        case DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL:
        case DISPLAYCONFIG_OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED:
        case DISPLAYCONFIG_OUTPUT_TECHNOLOGY_UDI_EMBEDDED:
        case DISPLAYCONFIG_OUTPUT_TECHNOLOGY_LVDS:
          break;
        default:
          continue;
      }
      if (path.sourceInfo.modeInfoIdx >= modes_count) continue;
      const auto& mode = modes[path.sourceInfo.modeInfoIdx];
      if (mode.infoType != DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE) continue;
      const auto& source = mode.sourceMode;
      RECT rect{
          source.position.x, source.position.y, source.position.x + static_cast<LONG>(source.width),
          source.position.y + static_cast<LONG>(source.height)};
      bool clone = false;
      for (const RECT& existing : panels) clone |= EqualRect(&rect, &existing) != FALSE;
      if (!clone && !IsRectEmpty(&rect)) panels.push_back(rect);
    }
    return panels;
  }
  return {};
}
