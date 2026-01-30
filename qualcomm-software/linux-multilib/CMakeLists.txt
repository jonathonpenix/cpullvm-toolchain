#
# Copyright (c) 2024-2025, Arm Limited and affiliates.
#
# Part of the Arm Toolchain project, under the Apache License v2.0 with LLVM Exceptions.
# See https://llvm.org/LICENSE.txt for license information.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#
# ​​​​​Changes from Qualcomm Technologies, Inc. are provided under the following license:
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
#

# CMake build for a "multilib" layout of our Linux library variants. The name
# isn't entirely accurate--there is no multilib here, but this handles all the
# variants we need to build. Eventually, it'd be nice if we could do either
# per-variant config files or actual multilib here too.
#
# Another weird thing relative to embedded is that we only support ~one libc
# right now, so everything is assuming musl. But, we actually have two versions
# of musl that we use depending on the target. Hopefully this is only the case
# in the short term as we move away from musl and we can align closer towards
# embedded where we accommodate multiple different libcs.
#
# FIXME: Ideally, it would be nice if we could share a skeleton with
# embedded-multilib and only override the bits we care about, but that requires
# more changes than can be made right now. So for now, add only the bare minimum
# support we need to reach parity with our current build scripts (no testing,
# no parallel configures, etc.) and we'll come back to this later.

cmake_minimum_required(VERSION 3.20)

project(linux-multilib)

# Root directory of the CMake scripts.
set(TOOLCHAIN_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/..)
# Root directory of the llvm-project source.
set(llvmproject_src_dir ${TOOLCHAIN_SOURCE_DIR}/..)

# Cache variables to be set by user
set(MULTILIB_JSON "" CACHE STRING "JSON file to load library definitions from.")
set(ENABLE_VARIANTS "all" CACHE STRING "Semicolon separated list of variants to build, or \"all\". Must match entries in the json.")
set(PROJECT_PREFIX "${CMAKE_BINARY_DIR}/lib-builds" CACHE STRING "Directory to build subprojects in.")
option(
    NUMERICAL_BUILD_NAMES
    "Instead of using the full variant name to label build directories, use an index number. This may help shorten paths."
    OFF
)
set(LLVM_BINARY_DIR "" CACHE PATH "Path to LLVM toolchain build or install root.")

# If a compiler launcher such as ccache has been set, it should be
# passed down to each subproject build.
set(compiler_launcher_cmake_args "")
if(CMAKE_C_COMPILER_LAUNCHER)
    list(APPEND compiler_launcher_cmake_args "-DCMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER}")
endif()
if(CMAKE_CXX_COMPILER_LAUNCHER)
    list(APPEND compiler_launcher_cmake_args "-DCMAKE_CXX_COMPILER_LAUNCHER=${CMAKE_CXX_COMPILER_LAUNCHER}")
endif()

# Arguments to pass down to the library projects.
foreach(arg
    LLVM_BINARY_DIR
)
    if(${arg})
        list(APPEND passthrough_dirs "-D${arg}=${${arg}}")
    endif()
endforeach()

find_package(Python3 REQUIRED COMPONENTS Interpreter) # needed by fetch_*.cmake

include(ExternalProject)
include(${TOOLCHAIN_SOURCE_DIR}/cmake/fetch_musl-embedded.cmake)
list(APPEND passthrough_dirs "-DFETCHCONTENT_SOURCE_DIR_MUSL-EMBEDDED=${FETCHCONTENT_SOURCE_DIR_MUSL-EMBEDDED}")
include(${TOOLCHAIN_SOURCE_DIR}/cmake/fetch_musl.cmake)
list(APPEND passthrough_dirs "-DFETCHCONTENT_SOURCE_DIR_MUSL=${FETCHCONTENT_SOURCE_DIR_MUSL}")
include(${TOOLCHAIN_SOURCE_DIR}/cmake/fetch_linux.cmake)
list(APPEND passthrough_dirs "-DFETCHCONTENT_SOURCE_DIR_LINUX=${FETCHCONTENT_SOURCE_DIR_LINUX}")

# Target for any dependencies to build the runtimes project.
add_custom_target(runtimes-depends)

# Read the JSON file to load a multilib configuration.
file(READ ${MULTILIB_JSON} multilib_json_str)
string(JSON multilib_defs GET ${multilib_json_str} "libs")

string(JSON lib_count LENGTH ${multilib_defs})
math(EXPR lib_count_dec "${lib_count} - 1")

foreach(lib_idx RANGE ${lib_count_dec})
    string(JSON lib_def GET ${multilib_defs} ${lib_idx})
    string(JSON variant GET ${lib_def} "variant")
    set(additional_cmake_args "")

    if(variant IN_LIST ENABLE_VARIANTS OR ENABLE_VARIANTS STREQUAL "all")
        list(APPEND enabled_variants ${variant})
        string(JSON variant_multilib_flags GET ${lib_def} "flags")
        # Placeholder libraries won't have a json, so store the error in
        # a variable so a fatal error isn't generated.
        string(JSON variant_json ERROR_VARIABLE json_error GET ${lib_def} "json")

        if(NOT variant_json STREQUAL "json-NOTFOUND")
            # Sort by target triple
            if(variant MATCHES "^aarch64")
                set(parent_dir_name aarch64-unknown-linux-gnu)
            elseif(variant MATCHES "^riscv32")
                set(parent_dir_name riscv32-unknown-linux-gnu)
            elseif(variant MATCHES "^riscv64")
                set(parent_dir_name riscv64-unknown-linux-gnu)
            else()
                set(parent_dir_name arm-unknown-linux-gnueabi)
            endif()
            set(destination_directory "${CMAKE_CURRENT_BINARY_DIR}/multilib/${parent_dir_name}/${variant}")
            install(
                DIRECTORY ${destination_directory}
                DESTINATION ${parent_dir_name}
            )

            if(NUMERICAL_BUILD_NAMES)
                set(runtimes_id ${lib_idx})
                list(APPEND additional_cmake_args "-DVARIANT_BUILD_ID=${lib_idx}")
            else()
                set(runtimes_id ${variant})
            endif()

            ExternalProject_Add(
                runtimes-${variant}
                STAMP_DIR ${PROJECT_PREFIX}/runtimes/${runtimes_id}/stamp
                BINARY_DIR ${PROJECT_PREFIX}/runtimes/${runtimes_id}/build
                DOWNLOAD_DIR ${PROJECT_PREFIX}/runtimes/${runtimes_id}/dl
                TMP_DIR ${PROJECT_PREFIX}/runtimes/${runtimes_id}/tmp
                SOURCE_DIR ${TOOLCHAIN_SOURCE_DIR}/linux-runtimes
                INSTALL_DIR ${destination_directory}
                DEPENDS runtimes-depends
                CMAKE_ARGS
                ${compiler_launcher_cmake_args}
                ${passthrough_dirs}
                ${additional_cmake_args}
                -DVARIANT_JSON=${variant_json_file}
                -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
                -DPROJECT_PREFIX=${PROJECT_PREFIX}
                STEP_TARGETS build install
                USES_TERMINAL_CONFIGURE FALSE
                USES_TERMINAL_BUILD TRUE
                LIST_SEPARATOR ,
                CONFIGURE_HANDLED_BY_BUILD TRUE
                TEST_EXCLUDE_FROM_MAIN TRUE
            )
        endif()
    endif()

endforeach()

# Check that all variants that were configured to be enabled
# were actually enabled.
if(NOT ENABLE_VARIANTS STREQUAL "all")
    foreach(expected_variant ${ENABLE_VARIANTS})
        if(NOT expected_variant IN_LIST enabled_variants)
            message(FATAL_ERROR "Variant name ${expected_variant} not found in ${MULTILIB_JSON}")
        endif()
    endforeach()
endif()
