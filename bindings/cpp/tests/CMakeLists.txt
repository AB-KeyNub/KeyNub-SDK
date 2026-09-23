# The C++ wrapper against the C ABI stand-in (bindings/julia/test/stub/licd_stub.c),
# both compiled into one executable; no dongle and no native library needed.
#
#     cmake -S bindings/cpp/tests -B build-standin
#     cmake --build build-standin
#     ctest --test-dir build-standin
cmake_minimum_required(VERSION 3.16)
project(keynub_cpp_standin_test C CXX)

get_filename_component(KEYNUB_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
if(EXISTS "${KEYNUB_ROOT}/core/include/licdongle.h")
    set(KEYNUB_INCLUDE "${KEYNUB_ROOT}/core/include")
else()
    set(KEYNUB_INCLUDE "${KEYNUB_ROOT}/include")
endif()

add_executable(standin_test
    standin_test.cpp
    "${KEYNUB_ROOT}/bindings/julia/test/stub/licd_stub.c")
target_compile_features(standin_test PRIVATE cxx_std_11)
target_compile_definitions(standin_test PRIVATE LICD_BUILD_SHARED)
target_include_directories(standin_test PRIVATE "${KEYNUB_INCLUDE}" "${KEYNUB_ROOT}/bindings/cpp")

enable_testing()
add_test(NAME cpp_standin_test COMMAND standin_test)
