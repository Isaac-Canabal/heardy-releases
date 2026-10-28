# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(heardy LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "heardy")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# libmpv para el ecualizador. El de media_kit_libs_windows_audio (mpv 0.36,
# FFmpeg 6.0 mínimo) sólo trae el filtro `equalizer`, falla al encadenar dos
# `lavfi` y su `af-command` no acepta destino, así que no permite 10 bandas
# ajustables en vivo. Se reemplaza por el libmpv que media_kit publica para
# media_kit_libs_windows_video (mpv 0.39, FFmpeg con avfilter), LGPL: FFmpeg
# con --disable-gpl --enable-version3 y mpv con -Dgpl=false (ver
# packages/ffmpeg.cmake y packages/mpv.cmake de media-kit/libmpv-win32-video-cmake
# en el commit ed01efd). El .7z se trata como no confiable: se verifica por
# SHA-256 y sólo se extrae libmpv-2.dll en su propio directorio. Sin él la
# cadena de 10 bandas deja mudo al reproductor, por eso falla el build en vez
# de seguir con la DLL vieja. tool/mpv_eq_probe.py comprueba la DLL resultante.
set(LIBMPV_EQ_TAG "20241021")
set(LIBMPV_EQ_ARCHIVE_NAME "mpv-dev-x86_64-20241021-git-0f78584.7z")
set(LIBMPV_EQ_SHA256 "e23701df0adc1fe57c8ede3ff313513b0b80519870058c2d35ff02754284a007")
set(LIBMPV_EQ_DLL_SHA256 "56f9a69200863c2dcd2fb6367427ffedc35550d26f947d6c36eab37bd2a65fd5")
set(LIBMPV_EQ_ARCHIVE "${CMAKE_BINARY_DIR}/libmpv-eq-dl/${LIBMPV_EQ_ARCHIVE_NAME}")
set(LIBMPV_EQ_DIR "${CMAKE_BINARY_DIR}/libmpv-eq-${LIBMPV_EQ_TAG}")
set(LIBMPV_EQ_DLL "${LIBMPV_EQ_DIR}/libmpv-2.dll")
if(EXISTS "${LIBMPV_EQ_DLL}")
  file(SHA256 "${LIBMPV_EQ_DLL}" LIBMPV_EQ_HAVE)
  if(NOT LIBMPV_EQ_HAVE STREQUAL LIBMPV_EQ_DLL_SHA256)
    file(REMOVE_RECURSE "${LIBMPV_EQ_DIR}")
  endif()
endif()
if(NOT EXISTS "${LIBMPV_EQ_DLL}")
  file(DOWNLOAD
    "https://github.com/media-kit/libmpv-win32-video-cmake/releases/download/${LIBMPV_EQ_TAG}/${LIBMPV_EQ_ARCHIVE_NAME}"
    "${LIBMPV_EQ_ARCHIVE}"
    EXPECTED_HASH SHA256=${LIBMPV_EQ_SHA256}
    STATUS LIBMPV_EQ_DL_STATUS)
  list(GET LIBMPV_EQ_DL_STATUS 0 LIBMPV_EQ_DL_CODE)
  if(NOT LIBMPV_EQ_DL_CODE EQUAL 0)
    file(REMOVE "${LIBMPV_EQ_ARCHIVE}")
    message(FATAL_ERROR "No se pudo descargar ${LIBMPV_EQ_ARCHIVE_NAME}: ${LIBMPV_EQ_DL_STATUS}")
  endif()
  file(MAKE_DIRECTORY "${LIBMPV_EQ_DIR}")
  execute_process(
    COMMAND ${CMAKE_COMMAND} -E tar xf "${LIBMPV_EQ_ARCHIVE}" -- libmpv-2.dll
    WORKING_DIRECTORY "${LIBMPV_EQ_DIR}"
    RESULT_VARIABLE LIBMPV_EQ_EXTRACT_RESULT)
  if(EXISTS "${LIBMPV_EQ_DLL}")
    file(SHA256 "${LIBMPV_EQ_DLL}" LIBMPV_EQ_HAVE)
  endif()
  if(NOT LIBMPV_EQ_EXTRACT_RESULT EQUAL 0 OR NOT LIBMPV_EQ_HAVE STREQUAL LIBMPV_EQ_DLL_SHA256)
    file(REMOVE_RECURSE "${LIBMPV_EQ_DIR}")
    message(FATAL_ERROR "libmpv-2.dll de ${LIBMPV_EQ_ARCHIVE_NAME} no coincide con el hash fijado")
  endif()
endif()
# Se cambia la entrada de media_kit en la lista en vez de instalar encima, para
# que no dependa del orden de los install().
list(FILTER PLUGIN_BUNDLED_LIBRARIES EXCLUDE REGEX "/libmpv-2\\.dll$")
list(APPEND PLUGIN_BUNDLED_LIBRARIES "${LIBMPV_EQ_DLL}")


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# yt-dlp.exe para "Escuchar" en Windows (streaming resuelto en el cliente).
# Se descarga fijado por versión y verificado por SHA-256 (no se versiona el
# binario); la app lo busca en <exe>/yt-dlp/yt-dlp.exe y lo mantiene al día.
set(YTDLP_VERSION "2026.08.19")
set(YTDLP_SHA256 "66674953fe251b89f4d08c5f0e35e0728679bd67ab3d7d05c0562af101dd3e7a")
set(YTDLP_LOCAL "${CMAKE_BINARY_DIR}/yt-dlp/yt-dlp.exe")
if(NOT EXISTS "${YTDLP_LOCAL}")
  file(DOWNLOAD
    "https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp.exe"
    "${YTDLP_LOCAL}"
    EXPECTED_HASH SHA256=${YTDLP_SHA256}
    STATUS YTDLP_DL_STATUS)
  list(GET YTDLP_DL_STATUS 0 YTDLP_DL_CODE)
  if(NOT YTDLP_DL_CODE EQUAL 0)
    file(REMOVE "${YTDLP_LOCAL}")
    message(WARNING "No se pudo descargar yt-dlp.exe: Escuchar quedara desactivado en Windows")
  endif()
endif()
if(EXISTS "${YTDLP_LOCAL}")
  install(FILES "${YTDLP_LOCAL}" DESTINATION "${CMAKE_INSTALL_PREFIX}/yt-dlp"
    COMPONENT Runtime)
endif()

# ffmpeg.exe (build LGPL, no GPL) para la onda del seek bar en Windows: las
# descargas son M4A fragmentado y Media Foundation no lo lee. Se descarga fijado
# a un autobuild de BtbN/FFmpeg-Builds (n8.1.3, "win64-lgpl-shared") y verificado
# por SHA-256; no se versiona. BtbN borra sus autobuilds a las pocas semanas:
# cuando pase, subir FFMPEG_TAG/FFMPEG_DIRNAME al más reciente y copiar su hash
# de checksums.sha256 del mismo release. El hash se comprueba aparte y no con
# EXPECTED_HASH, porque con EXPECTED_HASH una descarga fallida (404) aborta todo
# el build en vez de sólo dejar la onda desactivada. En CI (variable CI) sí se
# aborta: un release sin ffmpeg pierde la onda y el nivelador de Windows sin
# que nadie se entere. El .zip es lo que se descarga (~81 MB); se trata como no
# confiable: se extrae en su propio directorio nuevo y solo se copian
# ffmpeg.exe, sus DLL y LICENSE.txt. La app lo busca en <exe>/ffmpeg/ffmpeg.exe;
# sin el, la onda cae al Slider.
set(FFMPEG_TAG "autobuild-2026-10-28-19-47")
set(FFMPEG_DIRNAME "ffmpeg-n8.1.3-25-g611cec792a-win64-lgpl-shared-8.1")
set(FFMPEG_SHA256 "0448c3f3b9bdc724cc0189d5ce6e6bfa5b8937e7ec408e1e97fb08719bdb3b92")
set(FFMPEG_ZIP "${CMAKE_BINARY_DIR}/ffmpeg-dl/${FFMPEG_DIRNAME}.zip")
set(FFMPEG_EXTRACT_DIR "${CMAKE_BINARY_DIR}/ffmpeg-extract-${FFMPEG_TAG}")
set(FFMPEG_FILES
  ffmpeg.exe avcodec-62.dll avdevice-62.dll avfilter-11.dll avformat-62.dll
  avutil-60.dll swresample-6.dll swscale-9.dll)
if(NOT EXISTS "${FFMPEG_EXTRACT_DIR}/${FFMPEG_DIRNAME}/bin/ffmpeg.exe")
  file(DOWNLOAD
    "https://github.com/BtbN/FFmpeg-Builds/releases/download/${FFMPEG_TAG}/${FFMPEG_DIRNAME}.zip"
    "${FFMPEG_ZIP}"
    STATUS FFMPEG_DL_STATUS)
  list(GET FFMPEG_DL_STATUS 0 FFMPEG_DL_CODE)
  set(FFMPEG_ZIP_OK FALSE)
  if(FFMPEG_DL_CODE EQUAL 0)
    file(SHA256 "${FFMPEG_ZIP}" FFMPEG_ZIP_HASH)
    if(FFMPEG_ZIP_HASH STREQUAL FFMPEG_SHA256)
      set(FFMPEG_ZIP_OK TRUE)
    else()
      message(WARNING "ffmpeg: el hash del .zip no coincide (${FFMPEG_ZIP_HASH})")
    endif()
  else()
    message(WARNING "ffmpeg: no se pudo descargar ${FFMPEG_TAG} (${FFMPEG_DL_STATUS})")
  endif()
  if(FFMPEG_ZIP_OK)
    file(REMOVE_RECURSE "${FFMPEG_EXTRACT_DIR}")
    file(MAKE_DIRECTORY "${FFMPEG_EXTRACT_DIR}")
    set(FFMPEG_MEMBERS "${FFMPEG_DIRNAME}/LICENSE.txt")
    foreach(f ${FFMPEG_FILES})
      list(APPEND FFMPEG_MEMBERS "${FFMPEG_DIRNAME}/bin/${f}")
    endforeach()
    execute_process(
      COMMAND ${CMAKE_COMMAND} -E tar xf "${FFMPEG_ZIP}" -- ${FFMPEG_MEMBERS}
      WORKING_DIRECTORY "${FFMPEG_EXTRACT_DIR}"
      RESULT_VARIABLE FFMPEG_EXTRACT_RESULT)
    if(NOT FFMPEG_EXTRACT_RESULT EQUAL 0)
      file(REMOVE_RECURSE "${FFMPEG_EXTRACT_DIR}")
    endif()
  else()
    file(REMOVE "${FFMPEG_ZIP}")
  endif()
  if(NOT EXISTS "${FFMPEG_EXTRACT_DIR}/${FFMPEG_DIRNAME}/bin/ffmpeg.exe")
    if(DEFINED ENV{CI})
      message(FATAL_ERROR "No se pudo preparar ffmpeg.exe (${FFMPEG_TAG}): actualizar el autobuild de BtbN en windows/CMakeLists.txt")
    endif()
    message(WARNING "No se pudo preparar ffmpeg.exe: la onda del seek bar quedara desactivada en Windows")
  endif()
endif()
if(EXISTS "${FFMPEG_EXTRACT_DIR}/${FFMPEG_DIRNAME}/bin/ffmpeg.exe")
  foreach(f ${FFMPEG_FILES})
    install(FILES "${FFMPEG_EXTRACT_DIR}/${FFMPEG_DIRNAME}/bin/${f}"
      DESTINATION "${CMAKE_INSTALL_PREFIX}/ffmpeg" COMPONENT Runtime)
  endforeach()
  install(FILES "${FFMPEG_EXTRACT_DIR}/${FFMPEG_DIRNAME}/LICENSE.txt"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/ffmpeg" COMPONENT Runtime)
endif()
