// The webOS application jail can expose Mali's OpenCL implementation without
// installing the /etc/OpenCL/vendors entry used by the generic ICD loader.
#pragma once

#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef int (*TvClPlatforms)(unsigned, void**, unsigned*);
typedef int (*TvClDevices)(void*, uint64_t, unsigned, void**, unsigned*);
typedef int (*TvClInfo)(void*, unsigned, size_t, void*, size_t*);
enum { TV_CL_GPU = 1 << 2, TV_CL_ACCELERATOR = 1 << 3, TV_CL_LIMIT = 16 };

static inline void* tv_opencl_platforms(void** platforms, unsigned* count) {
  const char* libraries[] = {"libOpenCL.so.1", "libOpenCL.so", "libmali.so"};
  for (unsigned i = 0; i < sizeof(libraries) / sizeof(libraries[0]); ++i) {
    void* lib = dlopen(libraries[i], RTLD_NOW | RTLD_LOCAL);
    if (!lib) continue;
    TvClPlatforms query = (TvClPlatforms)dlsym(lib, "clGetPlatformIDs");
    TvClDevices devices = (TvClDevices)dlsym(lib, "clGetDeviceIDs");
    *count = 0;
    if (query && devices && !query(TV_CL_LIMIT, platforms, count)) {
      if (*count > TV_CL_LIMIT) *count = TV_CL_LIMIT;
      for (unsigned j = 0; j < *count; ++j) {
        unsigned n = 0;
        if (!devices(platforms[j], TV_CL_ACCELERATOR | TV_CL_GPU, 0, NULL, &n) && n) return lib;
      }
    }
    dlclose(lib);
  }
  return NULL;
}

static inline int tv_has_two_core_g510(void) {
  void* platforms[TV_CL_LIMIT];
  unsigned count = 0;
  void* lib = tv_opencl_platforms(platforms, &count);
  if (!lib) return 0;
  TvClDevices devices = (TvClDevices)dlsym(lib, "clGetDeviceIDs");
  TvClInfo info = (TvClInfo)dlsym(lib, "clGetDeviceInfo");
  int match = 0;
  for (unsigned i = 0; info && i < count && !match; ++i) {
    void* gpu = NULL;
    if (devices(platforms[i], TV_CL_GPU, 1, &gpu, NULL)) continue;
    char name[128] = {0};
    unsigned units = 0;
    if (!info(gpu, 0x102B /* CL_DEVICE_NAME */, sizeof(name), name, NULL) &&
        !info(gpu, 0x1002 /* CL_DEVICE_MAX_COMPUTE_UNITS */, sizeof(units), &units, NULL))
      match = units == 2 && strncmp(name, "Mali-G510", 9) == 0;
  }
  dlclose(lib);
  return match;
}
