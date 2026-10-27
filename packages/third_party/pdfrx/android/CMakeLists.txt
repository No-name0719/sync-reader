cmake_minimum_required(VERSION 3.18.1)

# Project-level configuration.
set(PROJECT_NAME "pdfrx")
project(${PROJECT_NAME} LANGUAGES CXX)

# Invoke the build for native code shared with the other target platforms.
# This can be changed to accommodate different builds.
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

set(PDFIUM_RELEASE chromium%2F7202)
set(PDFIUM_DIR ${CMAKE_BINARY_DIR}/pdfium)
set(PDFIUM_RELEASE_DIR ${PDFIUM_DIR}/${PDFIUM_RELEASE})

file(MAKE_DIRECTORY ${PDFIUM_RELEASE_DIR})

set(PDFIUM_PLATFORM "android")
set(PDFIUM_LIB_FILENAME "libpdfium.so")
set(PDFIUM_LIB_DIR "lib")

set(PDFIUM_ABI2SUF_arm64-v8a "android-arm64")
set(PDFIUM_ABI2SUF_armeabi-v7a "android-arm")
set(PDFIUM_ABI2SUF_x86 "android-x86")
set(PDFIUM_ABI2SUF_x86_64 "android-x64")

set(PDFIUM_ARCHIVE_NAME pdfium-${PDFIUM_ABI2SUF_${ANDROID_ABI}})
set(PDFIUM_SRC_LIB_FILENAME ${PDFIUM_RELEASE_DIR}/${PDFIUM_LIB_DIR}/${PDFIUM_LIB_FILENAME})

set(PDFIUM_LIBS_DIR ${CMAKE_SOURCE_DIR}/.lib/${PDFIUM_RELEASE})
set(PDFIUM_LIBS_ARCH_DIR ${PDFIUM_LIBS_DIR}/${ANDROID_ABI})
set(PDFIUM_DEST_LIB_FILENAME ${PDFIUM_LIBS_ARCH_DIR}/${PDFIUM_LIB_FILENAME})

set(PDFIUM_LATEST_DIR ${CMAKE_SOURCE_DIR}/.lib/latest)
set(PDFIUM_LATEST_LIBS_ARCH_DIR ${PDFIUM_LATEST_DIR}/${ANDROID_ABI})
set(PDFIUM_LATEST_LIB_FILENAME ${PDFIUM_LATEST_LIBS_ARCH_DIR}/${PDFIUM_LIB_FILENAME})

# SyncReader patch (2026-10-26): AGP wipes the per-configure .cxx directory
# on every build, so ${PDFIUM_DEST_LIB_FILENAME} under the shared .lib/ tree
# is the only durable pre-seed point (machines where GitHub downloads stall —
# see docs/08 §6.3.1). Treat .lib as a valid cache before downloading.
if(NOT EXISTS ${PDFIUM_SRC_LIB_FILENAME} AND NOT EXISTS ${PDFIUM_DEST_LIB_FILENAME})
    message(STATUS "Download precompiled PDFium...")
    file(DOWNLOAD https://github.com/bblanchon/pdfium-binaries/releases/download/${PDFIUM_RELEASE}/${PDFIUM_ARCHIVE_NAME}.tgz ${PDFIUM_RELEASE_DIR}/${PDFIUM_ARCHIVE_NAME}.tgz)
    execute_process(
        COMMAND ${CMAKE_COMMAND} -E tar zxf ${PDFIUM_RELEASE_DIR}/${PDFIUM_ARCHIVE_NAME}.tgz
        WORKING_DIRECTORY ${PDFIUM_RELEASE_DIR}
        RESULT_VARIABLE STATUS
        ERROR_QUIET
    )
    if(STATUS AND NOT STATUS EQUAL 0)
        message(FATAL_ERROR "Could not obtain PDFium binary for ${ANDROID_ABI}: ${STATUS}")
    endif()
else()
    message(STATUS "Use existing precompiled PDFium." )
endif()

if (NOT EXISTS ${PDFIUM_DEST_LIB_FILENAME})
    file(MAKE_DIRECTORY ${PDFIUM_LIBS_ARCH_DIR})
    file(COPY ${PDFIUM_SRC_LIB_FILENAME} DESTINATION ${PDFIUM_LIBS_ARCH_DIR})
endif()

# also copy header files for dev use
if (NOT EXISTS ${PDFIUM_LIBS_DIR}/include)
    file(COPY ${PDFIUM_RELEASE_DIR}/include DESTINATION ${PDFIUM_LIBS_DIR})
endif()

file(REMOVE ${PDFIUM_LATEST_DIR})
# SyncReader patch (2026-10-26): Windows hosts without Developer Mode cannot
# create symbolic links. Fall back to a directory junction (mklink /J, no
# privilege required), then to a plain directory copy; keep symbolic links
# on other host platforms. NOTE: WIN32 reflects the TARGET system, which is
# Android when cross-compiling — use CMAKE_HOST_WIN32 for the host OS.
if(CMAKE_HOST_WIN32)
    find_program(CMD_EXE NAMES cmd.exe)
    file(TO_NATIVE_PATH "${PDFIUM_LATEST_DIR}" PDFIUM_LATEST_DIR_NATIVE)
    file(TO_NATIVE_PATH "${PDFIUM_LIBS_DIR}" PDFIUM_LIBS_DIR_NATIVE)
    execute_process(
        COMMAND ${CMD_EXE} /c mklink /J "${PDFIUM_LATEST_DIR_NATIVE}" "${PDFIUM_LIBS_DIR_NATIVE}"
        RESULT_VARIABLE PDFIUM_JUNCTION_RESULT
        ERROR_QUIET
        OUTPUT_QUIET
    )
    if(NOT PDFIUM_JUNCTION_RESULT EQUAL 0 OR NOT EXISTS ${PDFIUM_LATEST_DIR})
        # trailing slash copies directory contents
        file(COPY "${PDFIUM_LIBS_DIR}/" DESTINATION "${PDFIUM_LATEST_DIR}")
    endif()
else()
    file(CREATE_LINK ${PDFIUM_LIBS_DIR} ${PDFIUM_LATEST_DIR} SYMBOLIC)
endif()

set(pdfrx_bundled_libraries
  # Defined in ../src/CMakeLists.txt.
  # This can be changed to accommodate different builds.
  $<TARGET_FILE:pdfrx>
  ${PDFIUM_LATEST_LIB_FILENAME}
  PARENT_SCOPE
)

target_include_directories(pdfrx PRIVATE ${PDFIUM_LATEST_DIR}/include)
# Support 16KB page size (#365)
target_link_options(pdfrx PRIVATE "-Wl,-z,max-page-size=16384")
target_link_libraries(pdfrx PRIVATE ${PDFIUM_LATEST_LIB_FILENAME})
