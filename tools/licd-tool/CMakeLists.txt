# licd-tool over the prebuilt static core from the repository's natives/ folder:
#
#   cmake -S tools/licd-tool -B build-licd-tool
#   cmake --build build-licd-tool --config Release
#
# The executable carries the core and needs no KeyNub library beside it.
cmake_minimum_required(VERSION 3.16)
project(licd_tool C)

find_package(keynub_licdongle CONFIG REQUIRED
    PATHS "${CMAKE_CURRENT_SOURCE_DIR}/../.." NO_DEFAULT_PATH)
if(NOT TARGET keynub::licdongle_static)
    message(FATAL_ERROR "no static KeyNub library for this platform in ${keynub_licdongle_NATIVES_DIR}")
endif()

add_executable(licd_tool licd_tool.c)
target_link_libraries(licd_tool PRIVATE keynub::licdongle_static)
set_target_properties(licd_tool PROPERTIES OUTPUT_NAME licd-tool C_STANDARD 99)
