# To avoid duplicating the FetchContent code, this file can be
# included by either the top-level toolchain cmake, or the
# runtimes sub-project.
# FETCHCONTENT_SOURCE_DIR_LINUX should be passed down from the
# top level to any library builds to prevent repeated checkouts.
#
# Note that we do *not* support patches on top of linux--we only
# care about being able to build against the user-space headers.
# If there are any issues, we'll source a newer version, not
# make any modifications.

include(FetchContent)
include(${CMAKE_CURRENT_LIST_DIR}/patch_repo.cmake)

if(NOT VERSIONS_JSON)
    include(${CMAKE_CURRENT_LIST_DIR}/read_versions.cmake)
endif()
read_repo_version(linux linux)

FetchContent_Declare(linux
    GIT_REPOSITORY "${linux_URL}"
    GIT_TAG "${linux_TAG}"
    GIT_SHALLOW "${linux_SHALLOW}"
    GIT_PROGRESS TRUE
    # We only want to download the content, not configure it at this
    # stage. Linux headers will be built in many configurations using
    # ExternalProject_Add using the sources that are checked out here.
    SOURCE_SUBDIR do_not_add_linux_subdir
)
FetchContent_MakeAvailable(linux)
FetchContent_GetProperties(linux SOURCE_DIR FETCHCONTENT_SOURCE_DIR_LINUX)
