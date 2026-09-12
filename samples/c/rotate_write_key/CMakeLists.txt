# Build and run (two P-256 private keys in PKCS#8 DER: the current one, yours):
#   cmake -S . -B build && cmake --build build
#   ./build/rotate_write_key ../../../keys/keynub-shipping-writeauth.key.der my-key.der
cmake_minimum_required(VERSION 3.15)
project(keynub_sample_rotate_write_key C)

find_package(keynub_licdongle CONFIG REQUIRED PATHS "${CMAKE_CURRENT_SOURCE_DIR}/../../..")

add_executable(rotate_write_key rotate_write_key.c)
target_link_libraries(rotate_write_key PRIVATE keynub::licdongle)
keynub_copy_runtime(rotate_write_key)
