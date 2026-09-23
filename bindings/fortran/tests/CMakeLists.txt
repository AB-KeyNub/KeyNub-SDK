# The Fortran binding over the flat C API (licd_flat.c) and the C ABI stand-in
# (bindings/julia/test/stub/licd_stub.c), all linked into one program; no dongle
# and no native library needed. Needs a Fortran compiler (gfortran) and a C
# compiler.
#
#     cmake -S bindings/fortran/tests -B build-fortran-standin
#     cmake --build build-fortran-standin
#     ctest --test-dir build-fortran-standin
cmake_minimum_required(VERSION 3.16)
project(keynub_fortran_standin_test C Fortran)

get_filename_component(KEYNUB_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
if(EXISTS "${KEYNUB_ROOT}/core/include/licdongle.h")
    set(KEYNUB_INCLUDE "${KEYNUB_ROOT}/core/include")
else()
    set(KEYNUB_INCLUDE "${KEYNUB_ROOT}/include")
endif()

add_executable(standin_test
    "${KEYNUB_ROOT}/bindings/fortran/keynub_licdongle.f90"
    standin_test.f90
    "${KEYNUB_ROOT}/bindings/flat/licd_flat.c"
    "${KEYNUB_ROOT}/bindings/julia/test/stub/licd_stub.c")
target_compile_definitions(standin_test PRIVATE LICD_BUILD_SHARED LICDF_BUILD_SHARED)
target_include_directories(standin_test PRIVATE "${KEYNUB_INCLUDE}" "${KEYNUB_ROOT}/bindings/flat")

enable_testing()
add_test(NAME fortran_standin_test COMMAND standin_test)
