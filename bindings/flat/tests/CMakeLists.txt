# The flat C API (licd_flat.c) over the C ABI stand-in
# (bindings/julia/test/stub/licd_stub.c), all compiled into one executable; no
# dongle and no native library needed.
#
#     cmake -S bindings/flat/tests -B build-flat-standin
#     cmake --build build-flat-standin
#     ctest --test-dir build-flat-standin
cmake_minimum_required(VERSION 3.16)
project(keynub_flat_standin_test C)

get_filename_component(KEYNUB_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
if(EXISTS "${KEYNUB_ROOT}/core/include/licdongle.h")
    set(KEYNUB_INCLUDE "${KEYNUB_ROOT}/core/include")
else()
    set(KEYNUB_INCLUDE "${KEYNUB_ROOT}/include")
endif()

add_executable(standin_test
    standin_test.c
    "${KEYNUB_ROOT}/bindings/flat/licd_flat.c"
    "${KEYNUB_ROOT}/bindings/julia/test/stub/licd_stub.c")
set_property(TARGET standin_test PROPERTY C_STANDARD 99)
target_compile_definitions(standin_test PRIVATE LICD_BUILD_SHARED LICDF_BUILD_SHARED)
target_include_directories(standin_test PRIVATE "${KEYNUB_INCLUDE}" "${KEYNUB_ROOT}/bindings/flat")

enable_testing()
add_test(NAME flat_standin_test COMMAND standin_test)
