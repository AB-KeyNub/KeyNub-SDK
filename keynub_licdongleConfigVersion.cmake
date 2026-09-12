# Version file for find_package(keynub_licdongle <version>). Compatible within
# the same major version; the API is a stable C ABI across minor releases.
set(PACKAGE_VERSION "1.1.1")

if(PACKAGE_FIND_VERSION VERSION_GREATER PACKAGE_VERSION)
    set(PACKAGE_VERSION_COMPATIBLE FALSE)
elseif(PACKAGE_FIND_VERSION_MAJOR STREQUAL "1" OR NOT PACKAGE_FIND_VERSION)
    set(PACKAGE_VERSION_COMPATIBLE TRUE)
    if(PACKAGE_FIND_VERSION STREQUAL PACKAGE_VERSION)
        set(PACKAGE_VERSION_EXACT TRUE)
    endif()
else()
    set(PACKAGE_VERSION_COMPATIBLE FALSE)
endif()
