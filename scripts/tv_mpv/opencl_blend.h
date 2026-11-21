// Optional OpenCL 1.1 for the FFmpeg framerate filter on TV. Resolve the
// Linux OpenCL ABI at runtime so the same binary works on TVs without it.
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "opencl_devices.h"

typedef struct TvBlend {
  int attempted;
  const char* provider;
  void *library, *context, *queue, *program, *kernel, *buffers[3];
  size_t capacity;
  int (*get_devices)(void*, uint64_t, unsigned, void**, unsigned*);
  void* (*create_context)(
      const intptr_t*, unsigned, void* const*, void (*)(const char*, const void*, size_t, void*), void*, int*);
  void* (*create_queue)(void*, void*, uint64_t, int*);
  void* (*create_program)(void*, unsigned, const char**, const size_t*, int*);
  int (*build_program)(void*, unsigned, void* const*, const char*, void (*)(void*, void*), void*);
  void* (*create_kernel)(void*, const char*, int*);
  void* (*create_buffer)(void*, uint64_t, size_t, void*, int*);
  int (*set_arg)(void*, unsigned, size_t, const void*);
  int (*write_rect)(
      void*, void*, unsigned, const size_t*, const size_t*, const size_t*, size_t, size_t, size_t, size_t, const void*,
      unsigned, void* const*, void**);
  int (*read_rect)(
      void*, void*, unsigned, const size_t*, const size_t*, const size_t*, size_t, size_t, size_t, size_t, void*,
      unsigned, void* const*, void**);
  int (*enqueue)(void*, void*, unsigned, const size_t*, const size_t*, const size_t*, unsigned, void* const*, void**);
  int (*finish)(void*);
  int (*release_buffer)(void*);
  int (*release_kernel)(void*);
  int (*release_program)(void*);
  int (*release_queue)(void*);
  int (*release_context)(void*);
} TvBlend;

static void tv_blend_close(TvBlend* b) {
  if (b->queue) b->finish(b->queue);
  for (int i = 0; i < 3; ++i)
    if (b->buffers[i]) b->release_buffer(b->buffers[i]);
  if (b->kernel) b->release_kernel(b->kernel);
  if (b->program) b->release_program(b->program);
  if (b->queue) b->release_queue(b->queue);
  if (b->context) b->release_context(b->context);
  if (b->library) dlclose(b->library);
  memset(b, 0, sizeof(*b));
  b->attempted = 1;
}

static int tv_blend_open(TvBlend* b) {
  static const char* source =
      "__kernel void blend(__global const uchar *a,__global const uchar *b,"
      "__global uchar *out,int weight) {size_t i=get_global_id(0);"
      "out[i]=(a[i]*(128-weight)+b[i]*weight+64)>>7;}";
  b->attempted = 1;
  void* platforms[TV_CL_LIMIT];
  unsigned count = 0;
  b->library = tv_opencl_platforms(platforms, &count);
  if (!b->library) return 0;
#define LOAD(field, symbol) \
  if (!(b->field = dlsym(b->library, symbol))) goto fail
  LOAD(get_devices, "clGetDeviceIDs");
  LOAD(create_context, "clCreateContext");
  LOAD(create_queue, "clCreateCommandQueue");
  LOAD(create_program, "clCreateProgramWithSource");
  LOAD(build_program, "clBuildProgram");
  LOAD(create_kernel, "clCreateKernel");
  LOAD(create_buffer, "clCreateBuffer");
  LOAD(set_arg, "clSetKernelArg");
  LOAD(write_rect, "clEnqueueWriteBufferRect");
  LOAD(read_rect, "clEnqueueReadBufferRect");
  LOAD(enqueue, "clEnqueueNDRangeKernel");
  LOAD(finish, "clFinish");
  LOAD(release_buffer, "clReleaseMemObject");
  LOAD(release_kernel, "clReleaseKernel");
  LOAD(release_program, "clReleaseProgram");
  LOAD(release_queue, "clReleaseCommandQueue");
  LOAD(release_context, "clReleaseContext");
#undef LOAD
  // Some embedded drivers also expose DSPs or other compute accelerators.
  // Device type alone cannot identify one as an NPU.
  const uint64_t device_types[] = {TV_CL_ACCELERATOR, TV_CL_GPU};
  for (unsigned t = 0; t < 2; ++t) {
    for (unsigned i = 0; i < count; ++i) {
      void* devices[16];
      unsigned n = 0;
      if (b->get_devices(platforms[i], device_types[t], 16, devices, &n)) continue;
      for (unsigned j = 0; j < n && j < 16; ++j) {
        void* device = devices[j];
        b->context = b->create_context(NULL, 1, &device, NULL, NULL, NULL);
        if (!b->context) continue;
        b->queue = b->create_queue(b->context, device, 0, NULL);
        b->program = b->create_program(b->context, 1, &source, NULL, NULL);
        if (b->queue && b->program && !b->build_program(b->program, 1, &device, NULL, NULL, NULL))
          b->kernel = b->create_kernel(b->program, "blend", NULL);
        if (b->kernel) {
          b->provider = t == 0 ? "OpenCL accelerator" : "OpenCL GPU";
          return 1;
        }
        if (b->program) b->release_program(b->program);
        if (b->queue) b->release_queue(b->queue);
        b->release_context(b->context);
        b->context = b->program = b->queue = NULL;
      }
    }
  }
fail:
  tv_blend_close(b);
  return 0;
}

static int tv_blend_plane(
    TvBlend* b, const uint8_t* a, int a_pitch, const uint8_t* c, int c_pitch, uint8_t* dst, int dst_pitch, int width,
    int height, int weight) {
  const size_t origin[3] = {0, 0, 0};
  if (width <= 0 || height <= 0 || width > a_pitch || width > c_pitch || width > dst_pitch ||
      (size_t)width > SIZE_MAX / (size_t)height)
    return 0;
  if (!b->kernel && (b->attempted || !tv_blend_open(b))) return 0;
  const size_t region[3] = {(size_t)width, (size_t)height, 1};
  const size_t bytes = region[0] * region[1];
  if (bytes > b->capacity) {
    for (int i = 0; i < 3; ++i) {
      if (b->buffers[i]) b->release_buffer(b->buffers[i]);
      b->buffers[i] = b->create_buffer(b->context, 1 /* CL_MEM_READ_WRITE */, bytes, NULL, NULL);
      if (!b->buffers[i] || b->set_arg(b->kernel, i, sizeof(void*), &b->buffers[i])) goto fail;
    }
    b->capacity = bytes;
  }
  if (b->write_rect(b->queue, b->buffers[0], 0, origin, origin, region, 0, 0, a_pitch, 0, a, 0, NULL, NULL) ||
      b->write_rect(b->queue, b->buffers[1], 0, origin, origin, region, 0, 0, c_pitch, 0, c, 0, NULL, NULL) ||
      b->set_arg(b->kernel, 3, sizeof(weight), &weight) ||
      b->enqueue(b->queue, b->kernel, 1, NULL, &bytes, NULL, 0, NULL, NULL) ||
      b->read_rect(b->queue, b->buffers[2], 1, origin, origin, region, 0, 0, dst_pitch, 0, dst, 0, NULL, NULL))
    goto fail;
  return 1;
fail:
  tv_blend_close(b);
  return 0;
}
