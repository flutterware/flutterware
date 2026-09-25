cmake_minimum_required(VERSION 3.16)

project(flutterware_embedder_host C)

# OBJC is macOS's alone — `surface.m` is the only file that needs it, and
# demanding an Objective-C compiler on a host that has none fails configuration
# before anything is built. Enabled here rather than listed in `project()`
# above because `APPLE` is not set until `project()` has run, so a condition up
# there is always false and this whole file would silently be the Linux one.
if(APPLE)
  enable_language(OBJC)
endif()

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(NOT FLUTTER_ENGINE_DIR)
  message(FATAL_ERROR
    "Pass -DFLUTTER_ENGINE_DIR=<dir holding the embedder engine>")
endif()

if(APPLE)
  add_executable(host host.c surface.m clipboard.m ipc.c input.c)
  # The Objective-C files use ARC: surface.m for its Metal object lifetimes,
  # clipboard.m for the pasteboard's.
  set_source_files_properties(surface.m clipboard.m
    PROPERTIES COMPILE_FLAGS "-fobjc-arc")
  target_link_options(host PRIVATE "-F${FLUTTER_ENGINE_DIR}")
  target_link_libraries(host PRIVATE
    "-framework FlutterEmbedder"
    "-framework IOSurface"
    "-framework CoreFoundation"
    "-framework Foundation"
    "-framework AppKit"
    "-framework Metal")
else()
  add_executable(host host.c surface_gl.c clipboard_none.c ipc.c input.c)
  # The engine ships as a plain shared object next to its header, so the engine
  # directory is both an include path and a link path.
  target_link_directories(host PRIVATE "${FLUTTER_ENGINE_DIR}")
  target_link_libraries(host PRIVATE flutter_engine EGL GLESv2 pthread)
  # shm_open moved into libc in glibc 2.34; older glibc keeps it in librt, and
  # linking a library that is not there is the error, not linking one whose
  # symbols have already been found.
  find_library(RT_LIBRARY rt)
  if(RT_LIBRARY)
    target_link_libraries(host PRIVATE ${RT_LIBRARY})
  endif()
endif()

target_include_directories(host PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
set_target_properties(host PROPERTIES
  BUILD_WITH_INSTALL_RPATH TRUE
  INSTALL_RPATH "${FLUTTER_ENGINE_DIR}")
