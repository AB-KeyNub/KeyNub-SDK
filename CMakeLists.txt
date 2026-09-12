# The KeyNub License Dongle SDK as a CMake project.
#
# As a subproject, from a clone or through FetchContent:
#
#   include(FetchContent)
#   FetchContent_Declare(keynub_licdongle
#       GIT_REPOSITORY https://github.com/AB-KeyNub/KeyNub-SDK.git
#       GIT_TAG        v1.1.1)
#   FetchContent_MakeAvailable(keynub_licdongle)
#   target_link_libraries(myapp PRIVATE keynub::licdongle)
#
# Installed, for find_package(keynub_licdongle) from any project:
#
#   cmake -S KeyNub-SDK -B build && cmake --install build --prefix <prefix>
#
# Either way the targets come from keynub_licdongleConfig.cmake, which also
# documents them. The libraries are prebuilt, per platform, under natives/.
cmake_minimum_required(VERSION 3.15)
project(keynub_licdongle VERSION 1.1.1 LANGUAGES C)

include("${CMAKE_CURRENT_SOURCE_DIR}/keynub_licdongleConfig.cmake")

# --- install: the current platform's libraries, the headers, this package ------
include(GNUInstallDirs)

install(FILES
    include/licdongle.h
    bindings/flat/licd_flat.h
    bindings/labview/licd_labview.h
    bindings/cpp/licdongle.hpp
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}")

if(WIN32)
    install(FILES
        "${keynub_licdongle_NATIVES_DIR}/keynub_licdongle.dll"
        "${keynub_licdongle_NATIVES_DIR}/keynub_licdongle_flat.dll"
        "${keynub_licdongle_NATIVES_DIR}/KeyNub.dll"
        DESTINATION "${CMAKE_INSTALL_BINDIR}")
    install(FILES
        "${keynub_licdongle_NATIVES_DIR}/keynub_licdongle.lib"
        "${keynub_licdongle_NATIVES_DIR}/keynub_licdongle_flat.lib"
        "${keynub_licdongle_NATIVES_DIR}/keynub_licdongle_static.lib"
        "${keynub_licdongle_NATIVES_DIR}/KeyNub.lib"
        DESTINATION "${CMAKE_INSTALL_LIBDIR}")
else()
    file(GLOB _keynub_libs
        "${keynub_licdongle_NATIVES_DIR}/libkeynub_licdongle.*"
        "${keynub_licdongle_NATIVES_DIR}/libkeynub_licdongle_flat.*"
        "${keynub_licdongle_NATIVES_DIR}/libkeynub_licdongle_static.a")
    install(FILES ${_keynub_libs} DESTINATION "${CMAKE_INSTALL_LIBDIR}")
endif()

install(FILES
    keynub_licdongleConfig.cmake
    keynub_licdongleConfigVersion.cmake
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/keynub_licdongle")

install(FILES LICENSE BINARY-LICENSE.txt NOTICE THIRD-PARTY-NOTICES.txt
    DESTINATION "${CMAKE_INSTALL_DATADIR}/licenses/keynub_licdongle")
