# Build and run:
#   cmake -S . -B build && cmake --build build && ./build/verify_and_read
cmake_minimum_required(VERSION 3.15)
project(keynub_sample_verify_and_read C)

find_package(keynub_licdongle CONFIG REQUIRED PATHS "${CMAKE_CURRENT_SOURCE_DIR}/../../..")

add_executable(verify_and_read verify_and_read.c)
target_link_libraries(verify_and_read PRIVATE keynub::licdongle)
keynub_copy_runtime(verify_and_read)
