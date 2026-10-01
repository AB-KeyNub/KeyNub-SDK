# The foreign module of the keynub_licdongle pack (c/keynub_licdongle4pl.c).
#
# `swipl pack install` runs configure, build, install and ctest here and
# passes -DSWIPL=<the swipl that installs the pack>. Built on its own, the
# swipl on the PATH is used:
#
#     cmake -S . -B build && cmake --build build && cmake --install build
#
# The install step puts the module into lib/<arch>/, where the pack loads it
# from. The module does not link against the KeyNub library.
cmake_minimum_required(VERSION 3.10)
project(keynub_licdongle4pl C)

if(NOT SWIPL)
  find_program(SWIPL NAMES swipl)
endif()
if(NOT SWIPL)
  message(FATAL_ERROR "swipl was not found; pass -DSWIPL=<path to swipl>")
endif()

execute_process(COMMAND "${SWIPL}" --dump-runtime-variables
                OUTPUT_VARIABLE swipl_variables
                RESULT_VARIABLE swipl_result)
if(NOT swipl_result EQUAL 0)
  message(FATAL_ERROR "${SWIPL} --dump-runtime-variables failed")
endif()
foreach(name PLBASE PLARCH PLSOEXT PLLIBDIR)
  if(swipl_variables MATCHES "(^|\n)${name}=\"([^\"]*)\"")
    set(${name} "${CMAKE_MATCH_2}")
  else()
    message(FATAL_ERROR "${SWIPL} does not report ${name}")
  endif()
endforeach()
message(STATUS "SWI-Prolog ${PLBASE} (${PLARCH})")

add_library(keynub_licdongle4pl MODULE c/keynub_licdongle4pl.c)
target_include_directories(keynub_licdongle4pl PRIVATE "${PLBASE}/include")
set_target_properties(keynub_licdongle4pl PROPERTIES
  PREFIX ""
  SUFFIX ".${PLSOEXT}"
  C_STANDARD 99
  C_VISIBILITY_PRESET hidden)

if(WIN32)
  # Windows resolves the SWI-Prolog API at link time, against libswipl.
  if(MSVC)
    find_file(swipl_import_library libswipl.lib PATHS "${PLLIBDIR}" "${PLBASE}/lib" NO_DEFAULT_PATH)
  else()
    find_file(swipl_import_library NAMES libswipl.dll.a libswipl.lib
              PATHS "${PLLIBDIR}" "${PLBASE}/lib" NO_DEFAULT_PATH)
  endif()
  if(NOT swipl_import_library)
    message(FATAL_ERROR "no libswipl import library under ${PLLIBDIR}")
  endif()
  target_link_libraries(keynub_licdongle4pl PRIVATE "${swipl_import_library}")
elseif(APPLE)
  # macOS resolves the SWI-Prolog API from the process that loads the module.
  set_target_properties(keynub_licdongle4pl PROPERTIES LINK_FLAGS "-undefined dynamic_lookup")
else()
  target_link_libraries(keynub_licdongle4pl PRIVATE ${CMAKE_DL_LIBS})
endif()

install(TARGETS keynub_licdongle4pl
        LIBRARY DESTINATION "${CMAKE_CURRENT_SOURCE_DIR}/lib/${PLARCH}")

# The unit tests, which need no KeyNub library and no dongle.
enable_testing()
add_test(NAME unit
         COMMAND "${SWIPL}" -p "foreign=$<TARGET_FILE_DIR:keynub_licdongle4pl>"
                 "${CMAKE_CURRENT_SOURCE_DIR}/test/unit_test.pl"
         WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}")
