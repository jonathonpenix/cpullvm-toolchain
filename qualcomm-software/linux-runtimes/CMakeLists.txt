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

# CMake build for a library variant, combining musl with compiler-rt and
# libcx/libcxxabi/libunwind. When building for Linux, the situation is a bit
# more fiddly than embedded as builtins have Linux and C library dependencies
# and we ultimately want to build *all* of compiler-rt, not just the builtins.
# We do the following to bootstrap everything:
# - Install Linux user-space headers (and in a separate location so they aren't
#   accidentally redistributed)
# - Install C headers
# - Build compiler-rt builtins
# - Build C libraries
# - Build libcxx/libcxxabi/libunwind
# - Build compiler-rt

cmake_minimum_required(VERSION 3.20)

project(linux-runtimes)

# Root directory of the CMake scrpts.
set(TOOLCHAIN_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/..)
# Root directory of the llvm-project source.
set(llvmproject_src_dir ${TOOLCHAIN_SOURCE_DIR}/..)


# CMake arguments are loaded from the JSON file depending on which C
# library is used, so this must be set before the JSON is processed.
# Given our situation of using musl-embedded or musl depending on the
# target but otherwise building the same way, it's easiest to just
# call everything musl for now and we'll switch between the sources
# internally.
set(C_LIBRARY "musl")

set(VARIANT_JSON "" CACHE STRING "JSON file to load args from.")
if(VARIANT_JSON)
    file(READ ${VARIANT_JSON} variant_json_read)
    # Load arguments common to all libraries.
    string(JSON json_args GET ${variant_json_read} "args" "common")
    string(JSON json_args_len LENGTH ${json_args})
    math(EXPR json_args_len_dec "${json_args_len} - 1")
    foreach(json_idx RANGE ${json_args_len_dec})
        string(JSON json_param MEMBER ${json_args} ${json_idx})
        string(JSON json_val GET ${json_args} ${json_param})
        string(JSON json_val_type TYPE ${json_args} ${json_param})
        set(${json_param}_def ${json_val})
    endforeach()
    # Load arguments specific to the chosen library, overwriting any existing values.
    string(JSON json_args GET ${variant_json_read} "args" ${C_LIBRARY})
    string(JSON json_args_len LENGTH ${json_args})
    math(EXPR json_args_len_dec "${json_args_len} - 1")
    foreach(json_idx RANGE ${json_args_len_dec})
        string(JSON json_param MEMBER ${json_args} ${json_idx})
        string(JSON json_val GET ${json_args} ${json_param})
        string(JSON json_val_type TYPE ${json_args} ${json_param})
        set(${json_param}_def ${json_val})
    endforeach()
endif()

# Default values will be populated by the json above.
# Any user specified options will override the default.
set(TARGET_ARCH ${TARGET_ARCH_def} CACHE STRING "Architecture being targetted.")
set(VARIANT ${VARIANT_def} CACHE STRING "Name for the variant, usually architecture + suffix.")
set(COMPILE_FLAGS ${COMPILE_FLAGS_def} CACHE STRING "Flags required to build the variant.")

set(SUPPORTED_LIBRARY_BUILD_TYPES minsizerelease release releasewithdebuginfo)
if(NOT LIBRARY_BUILD_TYPE_def IN_LIST SUPPORTED_LIBRARY_BUILD_TYPES)
    string(REPLACE ";" ", " SUPPORTED_LIBRARY_BUILD_TYPES_STR "${SUPPORTED_LIBRARY_BUILD_TYPES}")
    message(FATAL_ERROR "Unsupported LIBRARY_BUILD_TYPE value. Supported values are: ${SUPPORTED_LIBRARY_BUILD_TYPES_STR}")
endif()
set(LIBRARY_BUILD_TYPE ${LIBRARY_BUILD_TYPE_def} CACHE STRING "Build type to use in library builds.")
set_property(CACHE LIBRARY_BUILD_TYPE PROPERTY STRINGS ${SUPPORTED_LIBRARY_BUILD_TYPES})

set(ENABLE_CXX_LIBS ${ENABLE_CXX_LIBS_def} CACHE BOOL "Build CXX libs")
set(LLVM_BINARY_DIR "" CACHE PATH "Path to LLVM toolchain root to build libraries with")

# Set up a few arbitrary pass-through flags for musl-embedded. This probably
# isn't the best idea, but historically, our flag usage is such that it is a
# bit unclear how to do this in a more princicpled way. This should be
# revisited and probably cleaned up, but for now just mirror what we used to do.
set(EXTRA_MUSL-EMBEDDED_CONFIG_FLAGS ${EXTRA_MUSL-EMBEDDED_CONFIG_FLAGS_def} CACHE BOOL "Extra configure options for musl-embedded.")
set(EXTRA_MUSL-EMBEDDED_CFLAGS ${EXTRA_MUSL-EMBEDDED_CFLAGS_def} CACHE BOOL "Extra flags to be used when compiling musl-embedded.")

set(PROJECT_PREFIX "subproj" CACHE STRING "Directory to build subprojects in.")
set(VARIANT_BUILD_ID "${VARIANT}" CACHE STRING "Name to use to identify build directories." )

# Temporary location to collect the libraries as they are built.
set(TEMP_LIB_DIR "${CMAKE_CURRENT_BINARY_DIR}/tmp_install")

find_package(Python3 REQUIRED COMPONENTS Interpreter)

include(ExternalProject)

# If a compiler launcher such as ccache has been set, it should be
# passed down to each subproject build.
set(compiler_launcher_cmake_args "")
if(CMAKE_C_COMPILER_LAUNCHER)
    list(APPEND compiler_launcher_cmake_args "-DCMAKE_C_COMPILER_LAUNCHER=${CMAKE_C_COMPILER_LAUNCHER}")
endif()
if(CMAKE_CXX_COMPILER_LAUNCHER)
    list(APPEND compiler_launcher_cmake_args "-DCMAKE_CXX_COMPILER_LAUNCHER=${CMAKE_CXX_COMPILER_LAUNCHER}")
endif()

if(TARGET_ARCH MATCHES "^aarch64")
    set(target_triple "aarch64-linux-gnu")
elseif(TARGET_ARCH MATCHES "^riscv32")
    set(target_triple "riscv32-linux-gnu")
elseif(TARGET_ARCH MATCHES "^riscv64")
    set(target_triple "riscv64-linux-gnu")
else()
    # Choose the target triple so that compiler-rt will do the
    # right thing. We can't always put the exact target
    # architecture in the triple, because compiler-rt's cmake
    # system doesn't recognize every possible Arm architecture
    # version. So mostly we just say 'arm' and control the arch
    # version via -march=armv7m (or whatever).
    # Exceptions are architectures pre-armv7, which compiler-rt expects to
    # see in the triple because that's where it looks to decide whether to
    # use specific assembly sources.
    if(TARGET_ARCH MATCHES "^armv[4-6]")
        set(target_triple "${TARGET_ARCH}-linux-gnueabi")
    else()
        set(target_triple "arm-linux-gnueabi")
    endif()
    if(COMPILE_FLAGS MATCHES "-mfloat-abi=hard")
        # Also, compiler-rt looks in the ABI component of the
        # triple to decide whether to use the hard float ABI.
        set(target_triple "${target_triple}hf")
    endif()
endif()

set(compile_arch_flags "--target=${target_triple} ${COMPILE_FLAGS} --sysroot ${TEMP_LIB_DIR}")
# Compiling the libraries benefits from some extra optimization
# flags, and requires a sysroot.
set(lib_compile_flags "${compile_arch_flags} -ffunction-sections -fdata-sections")

# Generic target names for the C library.
# Declare these now, since compiler-rt requires the 'install' dependency.
# FIXME: this isn't correct now
add_custom_target(clib-configure)
add_custom_target(clib-build)
add_custom_target(clib-install)

# At this point it's been asserted that LIBRARY_BUILD_TYPE value is valid.
if(LIBRARY_BUILD_TYPE STREQUAL minsizerelease)
    set(LIBRARY_CMAKE_BUILD_TYPE MinSizeRel)
elseif(LIBRARY_BUILD_TYPE STREQUAL release)
    set(LIBRARY_CMAKE_BUILD_TYPE Release)
elseif(LIBRARY_BUILD_TYPE STREQUAL releasewithdebuginfo)
    set(LIBRARY_CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

###############################################################################
# Linux headers
###############################################################################
include(${TOOLCHAIN_SOURCE_DIR}/cmake/fetch_linux.cmake)
# Place these in a separate folder so we can filter them out as part of the
# install.
set(linux_header_install_dir ${TEMP_LIB_DIR}/linux_headers)

ExternalProject_Add(
    linux-headers
    STAMP_DIR ${PROJECT_PREFIX}/linux-headers/${VARIANT_BUILD_ID}/stamp
    BINARY_DIR ${PROJECT_PREFIX}/linux-headers/${VARIANT_BUILD_ID}/build
    DOWNLOAD_DIR ${PROJECT_PREFIX}/linux-headers/${VARIANT_BUILD_ID}/dl
    TMP_DIR ${PROJECT_PREFIX}/linux-headers/${VARIANT_BUILD_ID}/tmp
    SOURCE_DIR ${linux_SOURCE_DIR}
    INSTALL_DIR ${linux_header_install_dir}
    CONFIGURE_COMMAND ""
    BUILD_COMMAND
        make -C <SOURCE_DIR> ${make_flags}
    INSTALL_COMMAND
        make install
    USES_TERMINAL_CONFIGURE TRUE
    USES_TERMINAL_BUILD TRUE
    USES_TERMINAL_INSTALL TRUE
    # Always run the build command so that incremental builds are correct.
    CONFIGURE_HANDLED_BY_BUILD TRUE
    TEST_EXCLUDE_FROM_MAIN TRUE
    STEP_TARGETS configure build install
)

###############################################################################
# musl headers
###############################################################################
if(TARGET_ARCH MATCHES "^riscv")
    include(${TOOLCHAIN_SOURCE_DIR}/cmake/fetch_musl.cmake)
else()
    include(${TOOLCHAIN_SOURCE_DIR}/cmake/fetch_musl-embedded.cmake)
endif()


###############################################################################
# compiler-rt builtins
###############################################################################

if(target_triple MATCHES "^riscv")
    string(REPLACE "-linux-" "-unknown-linux-" normalized_target_triple ${target_triple})
else()
    string(REPLACE "-linux-" "-unknown-linux-" normalized_target_triple ${target_triple})
endif()

ExternalProject_Add(
    compiler_rt
    STAMP_DIR ${PROJECT_PREFIX}/compiler_rt/${VARIANT_BUILD_ID}/stamp
    BINARY_DIR ${PROJECT_PREFIX}/compiler_rt/${VARIANT_BUILD_ID}/build
    DOWNLOAD_DIR ${PROJECT_PREFIX}/compiler_rt/${VARIANT_BUILD_ID}/dl
    TMP_DIR ${PROJECT_PREFIX}/compiler_rt/${VARIANT_BUILD_ID}/tmp
    SOURCE_DIR ${llvmproject_src_dir}/runtimes
    INSTALL_DIR compiler-rt/install
    CMAKE_ARGS
    ${compiler_launcher_cmake_args}
    -DCMAKE_AR=${LLVM_BINARY_DIR}/bin/llvm-ar${CMAKE_EXECUTABLE_SUFFIX}
    -DCMAKE_ASM_COMPILER_TARGET=${target_triple}
    -DCMAKE_ASM_FLAGS=${lib_compile_flags}
    -DCMAKE_BUILD_TYPE=${LIBRARY_CMAKE_BUILD_TYPE}
    -DCMAKE_CXX_COMPILER=${LLVM_BINARY_DIR}/bin/clang++${CMAKE_EXECUTABLE_SUFFIX}
    -DCMAKE_CXX_COMPILER_TARGET=${target_triple}
    -DCMAKE_CXX_FLAGS=${lib_compile_flags}
    -DCMAKE_C_COMPILER=${LLVM_BINARY_DIR}/bin/clang${CMAKE_EXECUTABLE_SUFFIX}
    -DCMAKE_C_COMPILER_TARGET=${target_triple}
    -DCMAKE_C_FLAGS=${lib_compile_flags}
    -DCMAKE_INSTALL_MESSAGE=${CMAKE_INSTALL_MESSAGE}
    -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
    -DCMAKE_NM=${LLVM_BINARY_DIR}/bin/llvm-nm${CMAKE_EXECUTABLE_SUFFIX}
    -DCMAKE_RANLIB=${LLVM_BINARY_DIR}/bin/llvm-ranlib${CMAKE_EXECUTABLE_SUFFIX}
    -DCMAKE_SYSTEM_NAME=Linux
    # We have no other libraries at the moment so test links won't end well.
    # And, we're only building the builtins.
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    -DCOMPILER_RT_BUILD_BUILTINS=ON
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF
    -DCOMPILER_RT_BUILD_PROFILE=OFF
    -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF
    -DCOMPILER_RT_BUILD_MEMPROF=OFF
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF
    -DCOMPILER_RT_BUILD_XRAY=OFF
    -DCOMPILER_RT_BUILD_ORC=OFF
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
    -DLLVM_ENABLE_RUNTIMES=compiler-rt
    -DRUNTIME_VARIANT_NAME=${VARIANT}
    -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=ON
    STEP_TARGETS configure build install
    USES_TERMINAL_CONFIGURE TRUE
    USES_TERMINAL_BUILD TRUE
    USES_TERMINAL_INSTALL TRUE
    LIST_SEPARATOR ,
    CONFIGURE_HANDLED_BY_BUILD TRUE
    INSTALL_COMMAND ${CMAKE_COMMAND} --install .
    # Copy compiler-rt lib directory, moving libraries out of their
    # target-specific subdirectory.
    COMMAND
        ${CMAKE_COMMAND}
        -E copy_directory
        <INSTALL_DIR>/lib/${normalized_target_triple}
        "${TEMP_LIB_DIR}/resource-dir/lib"
    # FIXME: also copy in include so that we can use it as a resource dir
)

###############################################################################
# musl
###############################################################################

include(ProcessorCount)
set(make_flags)
ProcessorCount(nproc)
if(NOT nproc EQUAL 0)
    set(make_flags -j${nproc})
endif()

if(LIBRARY_BUILD_TYPE STREQUAL minsizerelease)
    set(musl_opt_flags "-Os")
elseif((LIBRARY_BUILD_TYPE STREQUAL release) OR (LIBRARY_BUILD_TYPE STREQUAL releasewithdebuginfo))
    set(musl_opt_flags "-O3")
endif()

set(musl_embedded_flags
    --disable-wrapper
    ${EXTRA_MUSL-EMBEDDED_CONFIG_FLAGS}
    "CROSS_COMPILE=${LLVM_BINARY_DIR}/bin/llvm-"
    "CC=${LLVM_BINARY_DIR}/bin/clang --target=${target_triple} -fuse-ld=eld"
    "CFLAGS=${lib_compile_flags} ${musl_opt_flags} ${EXTRA_MUSL-EMBEDDED_CFLAGS}"
    "LIBCC=${TEMP_LIB_DIR}/resource-dir/lib/${normalized_target_triple}/libclang_rt.builtins.a")

ExternalProject_Add(
    ${C_LIBRARY}
    STAMP_DIR ${PROJECT_PREFIX}/${C_LIBRARY}/${VARIANT_BUILD_ID}/stamp
    BINARY_DIR ${PROJECT_PREFIX}/${C_LIBRARY}/${VARIANT_BUILD_ID}/build
    DOWNLOAD_DIR ${PROJECT_PREFIX}/${C_LIBRARY}/${VARIANT_BUILD_ID}/dl
    TMP_DIR ${PROJECT_PREFIX}/${C_LIBRARY}/${VARIANT_BUILD_ID}/tmp
    SOURCE_DIR ${musl-embedded_SOURCE_DIR}
    INSTALL_DIR ${TEMP_LIB_DIR}
    DEPENDS compiler_rt-install
    CONFIGURE_COMMAND
        <SOURCE_DIR>/configure
        --prefix=${TEMP_LIB_DIR}
        ${musl_embedded_flags}
    BUILD_COMMAND
        make ${make_flags}
    INSTALL_COMMAND
        make install
    USES_TERMINAL_CONFIGURE TRUE
    USES_TERMINAL_BUILD TRUE
    USES_TERMINAL_INSTALL TRUE
    # Always run the build command so that incremental builds are correct.
    CONFIGURE_HANDLED_BY_BUILD TRUE
    TEST_EXCLUDE_FROM_MAIN TRUE
    STEP_TARGETS configure build install
)

add_dependencies(clib-configure ${C_LIBRARY}-configure)
add_dependencies(clib-build ${C_LIBRARY}-build)
add_dependencies(clib-install ${C_LIBRARY}-install)

###############################################################################
# runtimes (libcxx, libcxxabi, libunwind)
###############################################################################

if(ENABLE_CXX_LIBS)
    ExternalProject_Add(
        cxxlibs
        STAMP_DIR ${PROJECT_PREFIX}/cxxlibs/${VARIANT_BUILD_ID}/stamp
        BINARY_DIR ${PROJECT_PREFIX}/cxxlibs/${VARIANT_BUILD_ID}/build
        DOWNLOAD_DIR ${PROJECT_PREFIX}/cxxlibs/${VARIANT_BUILD_ID}/dl
        TMP_DIR ${PROJECT_PREFIX}/cxxlibs/${VARIANT_BUILD_ID}/tmp
        SOURCE_DIR ${llvmproject_src_dir}/runtimes
        INSTALL_DIR ${TEMP_LIB_DIR}
        DEPENDS compiler_rt-install clib-install
        CMAKE_ARGS
        ${compiler_launcher_cmake_args}
        -DCMAKE_AR=${LLVM_BINARY_DIR}/bin/llvm-ar${CMAKE_EXECUTABLE_SUFFIX}
        -DCMAKE_ASM_FLAGS=${lib_compile_flags}
        -DCMAKE_BUILD_TYPE=${LIBRARY_CMAKE_BUILD_TYPE}
        -DCMAKE_CXX_COMPILER=${LLVM_BINARY_DIR}/bin/clang++${CMAKE_EXECUTABLE_SUFFIX}
        -DCMAKE_CXX_COMPILER_TARGET=${target_triple}
        -DCMAKE_CXX_FLAGS=${lib_compile_flags}
        -DCMAKE_C_COMPILER=${LLVM_BINARY_DIR}/bin/clang${CMAKE_EXECUTABLE_SUFFIX}
        -DCMAKE_C_COMPILER_TARGET=${target_triple}
        -DCMAKE_C_FLAGS=${lib_compile_flags}
        -DCMAKE_INSTALL_MESSAGE=${CMAKE_INSTALL_MESSAGE}
        -DCMAKE_INSTALL_PREFIX=${TEMP_LIB_DIR}
        -DCMAKE_NM=${LLVM_BINARY_DIR}/bin/llvm-nm${CMAKE_EXECUTABLE_SUFFIX}
        -DCMAKE_RANLIB=${LLVM_BINARY_DIR}/bin/llvm-ranlib${CMAKE_EXECUTABLE_SUFFIX}
        # Let CMake know we're cross-compiling
        -DCMAKE_SYSTEM_NAME=Generic
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
        -DLIBCXXABI_BAREMETAL=ON
        -DLIBCXXABI_ENABLE_ASSERTIONS=OFF
        -DLIBCXXABI_ENABLE_SHARED=OFF
        -DLIBCXXABI_ENABLE_STATIC=ON
        -DLIBCXXABI_USE_COMPILER_RT=ON
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON
        -DLIBCXXABI_SHARED_OUTPUT_NAME="c++abi-shared"
        -DLIBCXX_CXX_ABI=libcxxabi
        -DLIBCXX_ENABLE_FILESYSTEM=OFF
        -DLIBCXX_ENABLE_SHARED=OFF
        -DLIBCXX_ENABLE_STATIC=ON
        -DLIBCXX_INCLUDE_BENCHMARKS=OFF
        -DLIBCXX_SHARED_OUTPUT_NAME="c++-shared"
        -DLIBUNWIND_ENABLE_ASSERTIONS=OFF
        -DLIBUNWIND_ENABLE_SHARED=OFF
        -DLIBUNWIND_ENABLE_STATIC=ON
        -DLIBUNWIND_IS_BAREMETAL=ON
        -DLIBUNWIND_REMEMBER_HEAP_ALLOC=ON
        -DLIBUNWIND_USE_COMPILER_RT=ON
        -DLIBUNWIND_SHARED_OUTPUT_NAME="unwind-shared"
        -DLLVM_LIT_ARGS=${LLVM_LIT_ARGS}
        -DLLVM_ENABLE_RUNTIMES=libcxxabi,libcxx,libunwind
        -DRUNTIME_VARIANT_NAME=${VARIANT}
        ${cxxlibs_extra_cmake_options}
        ${cxxlibs_test_cmake_options}
        STEP_TARGETS configure build install
        USES_TERMINAL_CONFIGURE TRUE
        USES_TERMINAL_BUILD TRUE
        USES_TERMINAL_INSTALL TRUE
        LIST_SEPARATOR ,
        CONFIGURE_HANDLED_BY_BUILD TRUE
    )
else() # if not ENABLE_CXX_LIBS

    # The parent embedded-multilib cmake script will still want to invoke
    # build targets like 'cxxlibs-configure', whether we actually have
    # C++ libraries or not. So we should define them, even if they
    # don't do anything.
    add_custom_target(cxxlibs-configure)
    add_custom_target(cxxlibs-build)
endif()

###############################################################################
# compiler-rt
###############################################################################


install(
    DIRECTORY ${TEMP_LIB_DIR}/
    DESTINATION .
)
