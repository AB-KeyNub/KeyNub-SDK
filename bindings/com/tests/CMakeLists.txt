# The COM server (keynub_com.cpp) built from its own source over the flat API
# (licd_flat.c) and the C ABI stand-in (bindings/julia/test/stub/licd_stub.c),
# then driven through the vtable and IDispatch by standin_test.cpp. No dongle,
# no native library and no registration: the test activates the object through
# DllGetClassObject. Windows with Visual C++ (MIDL and the resource compiler come
# with the Windows SDK):
#
#     cmake -S bindings/com/tests -B build-com-standin -A x64      (or -A Win32)
#     cmake --build build-com-standin --config Release
#     ctest --test-dir build-com-standin -C Release
cmake_minimum_required(VERSION 3.16)
project(keynub_com_standin_test C CXX)

if(NOT WIN32 OR NOT MSVC)
    message(FATAL_ERROR "the COM stand-in test needs Windows and Visual C++")
endif()

get_filename_component(KEYNUB_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
if(EXISTS "${KEYNUB_ROOT}/core/include/licdongle.h")
    set(KEYNUB_INCLUDE "${KEYNUB_ROOT}/core/include")
else()
    set(KEYNUB_INCLUDE "${KEYNUB_ROOT}/include")
endif()
set(KEYNUB_COM "${KEYNUB_ROOT}/bindings/com")

# midl is on PATH only in a developer shell, so look in the Windows SDK too,
# newest kit first. The x64 host tool targets win32 through /env.
set(_midl_hints "")
foreach(_kitroot "$ENV{ProgramFiles\(x86\)}/Windows Kits/10" "$ENV{ProgramFiles}/Windows Kits/10")
    if(_kitroot)
        file(TO_CMAKE_PATH "${_kitroot}" _kitroot)
        file(GLOB _found "${_kitroot}/bin/*/x64/midl.exe")
        list(SORT _found)
        list(REVERSE _found)
        foreach(_f ${_found})
            get_filename_component(_d "${_f}" DIRECTORY)
            list(APPEND _midl_hints "${_d}")
        endforeach()
    endif()
endforeach()
find_program(KEYNUB_MIDL midl HINTS ${_midl_hints} REQUIRED)

if(CMAKE_GENERATOR_PLATFORM MATCHES "^([Aa][Rr][Mm]64)$")
    set(_midl_env arm64)
elseif(CMAKE_SIZEOF_VOID_P EQUAL 8)
    set(_midl_env x64)
else()
    set(_midl_env win32)
endif()

set(_gen "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${_gen}")
add_custom_command(
    OUTPUT "${_gen}/KeyNub.tlb" "${_gen}/KeyNub_h.h" "${_gen}/KeyNub_i.c"
    COMMAND "${KEYNUB_MIDL}" /nologo /W1 /char signed /env ${_midl_env}
            /tlb "${_gen}/KeyNub.tlb" /h "${_gen}/KeyNub_h.h" /iid "${_gen}/KeyNub_i.c"
            /proxy "${_gen}/KeyNub_p.c" /dlldata "${_gen}/KeyNub_dlldata.c"
            "${KEYNUB_COM}/KeyNub.idl"
    DEPENDS "${KEYNUB_COM}/KeyNub.idl"
    COMMENT "MIDL: KeyNub.idl (${_midl_env})"
    VERBATIM)

set(KEYNUB_TLB_PATH "${_gen}/KeyNub.tlb")
configure_file("${KEYNUB_COM}/keynub_com.rc.in" "${_gen}/keynub_com.rc" @ONLY)
set_source_files_properties("${_gen}/keynub_com.rc" PROPERTIES OBJECT_DEPENDS "${_gen}/KeyNub.tlb")

# The server, exactly as shipped apart from the stand-in underneath it.
add_library(keynub_com_standin SHARED
    "${KEYNUB_COM}/keynub_com.cpp"
    "${KEYNUB_COM}/keynub_com.def"
    "${_gen}/KeyNub_i.c"
    "${_gen}/keynub_com.rc"
    "${KEYNUB_ROOT}/bindings/flat/licd_flat.c"
    "${KEYNUB_ROOT}/bindings/julia/test/stub/licd_stub.c")
target_include_directories(keynub_com_standin PRIVATE "${KEYNUB_INCLUDE}" "${KEYNUB_ROOT}/bindings/flat" "${_gen}")
target_compile_features(keynub_com_standin PRIVATE cxx_std_14)
target_link_libraries(keynub_com_standin PRIVATE ole32 oleaut32 advapi32)

add_executable(standin_test standin_test.cpp "${_gen}/KeyNub_i.c")
target_include_directories(standin_test PRIVATE "${KEYNUB_INCLUDE}" "${_gen}")
target_link_libraries(standin_test PRIVATE ole32 oleaut32)
add_dependencies(standin_test keynub_com_standin)

enable_testing()
add_test(NAME com_standin_test COMMAND standin_test "$<TARGET_FILE:keynub_com_standin>")
