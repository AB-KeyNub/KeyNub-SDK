# CMake package for the KeyNub License Dongle SDK.
#
# From a clone, a FetchContent checkout or an installed prefix:
#
#   find_package(keynub_licdongle CONFIG REQUIRED PATHS <clone>)
#   target_link_libraries(myapp PRIVATE keynub::licdongle)
#   keynub_copy_runtime(myapp)      # Windows: puts the DLL next to the executable
#
# Targets
#   keynub::licdongle        the core library, shared, with include/licdongle.h
#   keynub::licdongle_flat   the flat companion API, shared, with licd_flat.h
#   keynub::licdongle_static the core library as one self-contained static
#                            archive, linking the system libraries it needs
#   keynub::licdongle_cpp    the header-only C++11 wrapper, licdongle.hpp,
#                            linking keynub::licdongle
#
# Variables
#   keynub_licdongle_VERSION      the SDK version
#   keynub_licdongle_NATIVES_DIR  the directory the libraries were taken from

if(TARGET keynub::licdongle)
    return()
endif()

set(keynub_licdongle_VERSION "1.1.1")

# --- which prebuilt library: the platform folder for the target ---------------
if(WIN32)
    if(CMAKE_GENERATOR_PLATFORM MATCHES "^[Aa][Rr][Mm]64$"
       OR CMAKE_SYSTEM_PROCESSOR MATCHES "^([Aa][Rr][Mm]64|aarch64)$")
        set(_keynub_rid "win-arm64")
    elseif(CMAKE_GENERATOR_PLATFORM MATCHES "^[Ww]in32$" OR CMAKE_SIZEOF_VOID_P EQUAL 4)
        set(_keynub_rid "win-x86")
    else()
        set(_keynub_rid "win-x64")
    endif()
    set(_keynub_shared "keynub_licdongle.dll")
    set(_keynub_shared_flat "keynub_licdongle_flat.dll")
    set(_keynub_implib "keynub_licdongle.lib")
    set(_keynub_implib_flat "keynub_licdongle_flat.lib")
elseif(APPLE)
    # One universal binary serves both architectures; the folders hold the same file.
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm64|aarch64)$"
       OR CMAKE_OSX_ARCHITECTURES MATCHES "arm64")
        set(_keynub_rid "osx-arm64")
    else()
        set(_keynub_rid "osx-x64")
    endif()
    set(_keynub_shared "libkeynub_licdongle.dylib")
    set(_keynub_shared_flat "libkeynub_licdongle_flat.dylib")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64)$")
        set(_keynub_rid "linux-arm64")
    elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
        set(_keynub_rid "linux-x64")
    else()
        message(FATAL_ERROR "keynub_licdongle: no prebuilt library for Linux on "
                            "${CMAKE_SYSTEM_PROCESSOR}; see NATIVES.md")
    endif()
    set(_keynub_shared "libkeynub_licdongle.so")
    set(_keynub_shared_flat "libkeynub_licdongle_flat.so")
else()
    message(FATAL_ERROR "keynub_licdongle: no prebuilt library for ${CMAKE_SYSTEM_NAME}; "
                        "see NATIVES.md")
endif()

# --- where the files are: a source tree, or an installed prefix ---------------
get_filename_component(_keynub_here "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)
if(EXISTS "${_keynub_here}/natives/${_keynub_rid}")
    # Repository layout (a clone, FetchContent, add_subdirectory).
    set(keynub_licdongle_NATIVES_DIR "${_keynub_here}/natives/${_keynub_rid}")
    set(_keynub_lib_dir "${keynub_licdongle_NATIVES_DIR}")
    set(_keynub_bin_dir "${keynub_licdongle_NATIVES_DIR}")
    set(_keynub_inc_core "${_keynub_here}/include")
    set(_keynub_inc_flat "${_keynub_here}/bindings/flat")
    set(_keynub_inc_cpp "${_keynub_here}/bindings/cpp")
else()
    # Installed layout: <prefix>/lib/cmake/keynub_licdongle/<this file>, or
    # <prefix>/share/keynub_licdongle/<this file> as vcpkg lays it out.
    get_filename_component(_keynub_prefix "${_keynub_here}/../../.." ABSOLUTE)
    if(NOT EXISTS "${_keynub_prefix}/include/licdongle.h")
        get_filename_component(_keynub_prefix "${_keynub_here}/../.." ABSOLUTE)
    endif()
    set(keynub_licdongle_NATIVES_DIR "${_keynub_prefix}/lib")
    set(_keynub_lib_dir "${_keynub_prefix}/lib")
    if(WIN32)
        set(_keynub_bin_dir "${_keynub_prefix}/bin")
    else()
        set(_keynub_bin_dir "${_keynub_prefix}/lib")
    endif()
    set(_keynub_inc_core "${_keynub_prefix}/include")
    set(_keynub_inc_flat "${_keynub_prefix}/include")
    set(_keynub_inc_cpp "${_keynub_prefix}/include")
endif()

foreach(_f "${_keynub_bin_dir}/${_keynub_shared}" "${_keynub_inc_core}/licdongle.h")
    if(NOT EXISTS "${_f}")
        message(FATAL_ERROR "keynub_licdongle: ${_f} is missing")
    endif()
endforeach()

# --- the targets ----------------------------------------------------------------
# GLOBAL, so they are visible to a parent project that add_subdirectory()s or
# FetchContent_MakeAvailable()s this tree, not only in this directory.
add_library(keynub::licdongle SHARED IMPORTED GLOBAL)
set_target_properties(keynub::licdongle PROPERTIES
    IMPORTED_LOCATION "${_keynub_bin_dir}/${_keynub_shared}"
    INTERFACE_INCLUDE_DIRECTORIES "${_keynub_inc_core}")

add_library(keynub::licdongle_flat SHARED IMPORTED GLOBAL)
set_target_properties(keynub::licdongle_flat PROPERTIES
    IMPORTED_LOCATION "${_keynub_bin_dir}/${_keynub_shared_flat}"
    INTERFACE_INCLUDE_DIRECTORIES "${_keynub_inc_flat}")

if(WIN32)
    set_target_properties(keynub::licdongle PROPERTIES
        IMPORTED_IMPLIB "${_keynub_lib_dir}/${_keynub_implib}")
    set_target_properties(keynub::licdongle_flat PROPERTIES
        IMPORTED_IMPLIB "${_keynub_lib_dir}/${_keynub_implib_flat}")
endif()

# The static library carries Mbed TLS and hidapi; what it still needs from the
# system is named here, so a consumer links the one target.
if(WIN32)
    set(_keynub_static "${_keynub_lib_dir}/keynub_licdongle_static.lib")
    set(_keynub_static_deps setupapi hid advapi32 bcrypt)
elseif(APPLE)
    set(_keynub_static "${_keynub_lib_dir}/libkeynub_licdongle_static.a")
    set(_keynub_static_deps "-framework IOKit" "-framework CoreFoundation" pthread)
else()
    set(_keynub_static "${_keynub_lib_dir}/libkeynub_licdongle_static.a")
    set(_keynub_static_deps udev pthread)
endif()
if(EXISTS "${_keynub_static}")
    add_library(keynub::licdongle_static STATIC IMPORTED GLOBAL)
    set_target_properties(keynub::licdongle_static PROPERTIES
        IMPORTED_LOCATION "${_keynub_static}"
        INTERFACE_INCLUDE_DIRECTORIES "${_keynub_inc_core}"
        INTERFACE_LINK_LIBRARIES "${_keynub_static_deps}")
endif()

add_library(keynub::licdongle_cpp INTERFACE IMPORTED GLOBAL)
set_target_properties(keynub::licdongle_cpp PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${_keynub_inc_cpp}"
    INTERFACE_LINK_LIBRARIES keynub::licdongle
    INTERFACE_COMPILE_FEATURES cxx_std_11)

# Copies the shared library next to a target's executable after each build, so
# it runs from the build tree without touching PATH. The library is loaded by
# name at start-up on every platform; on Linux and macOS the loader also finds
# it through LD_LIBRARY_PATH / DYLD_LIBRARY_PATH or an rpath.
function(keynub_copy_runtime target)
    add_custom_command(TARGET ${target} POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "$<TARGET_FILE:keynub::licdongle>" "$<TARGET_FILE_DIR:${target}>"
        VERBATIM)
endfunction()

unset(_keynub_f)
unset(_keynub_here)
unset(_keynub_prefix)
