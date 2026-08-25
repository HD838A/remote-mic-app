cmake_minimum_required(VERSION 3.25)

project(RemoteMicWindows VERSION 0.1.0 LANGUAGES CXX)

option(REMOTEMIC_BUILD_TESTS "Build hardware-free tests" ON)

add_library(remotemic_core STATIC
    src/app/application.cpp
    src/platform/runtime_paths.cpp
    src/logging/file_logger.cpp
)

target_include_directories(remotemic_core
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)

target_compile_features(remotemic_core PUBLIC cxx_std_20)
target_compile_definitions(remotemic_core
    PUBLIC
        REMOTEMIC_VERSION="${PROJECT_VERSION}"
)

if(MSVC)
    target_compile_options(remotemic_core PRIVATE /W4 /permissive- /EHsc /utf-8)
else()
    target_compile_options(remotemic_core PRIVATE -Wall -Wextra -Wpedantic)
endif()
add_executable(remotemic apps/cli/main.cpp)
target_link_libraries(remotemic PRIVATE remotemic_core)

if(MSVC)
    target_compile_options(remotemic PRIVATE /W4 /permissive- /EHsc /utf-8)
else()
    target_compile_options(remotemic PRIVATE -Wall -Wextra -Wpedantic)
endif()

include(GNUInstallDirs)
install(TARGETS remotemic RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

if(REMOTEMIC_BUILD_TESTS)
    enable_testing()
    add_executable(remotemic_unit_tests tests/unit/core_tests.cpp)
    target_link_libraries(remotemic_unit_tests PRIVATE remotemic_core)
    if(MSVC)
        target_compile_options(remotemic_unit_tests PRIVATE /W4 /permissive- /EHsc /utf-8)
    else()
        target_compile_options(remotemic_unit_tests PRIVATE -Wall -Wextra -Wpedantic)
    endif()
    add_test(NAME remotemic_unit_tests COMMAND remotemic_unit_tests)
endif()
