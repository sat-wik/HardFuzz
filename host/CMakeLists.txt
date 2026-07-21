cmake_minimum_required(VERSION 3.12)
project(hardfuzz_host CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Header-only library.
add_library(hardfuzz INTERFACE)
target_include_directories(hardfuzz INTERFACE include)

# CLI.
add_executable(hardfuzz_cli src/hardfuzz_cli.cpp)
target_link_libraries(hardfuzz_cli PRIVATE hardfuzz)
set_target_properties(hardfuzz_cli PROPERTIES OUTPUT_NAME hardfuzz)

# Self-test (build+run against mocks; no hardware).
enable_testing()
add_executable(test_campaign test/test_campaign.cpp)
target_link_libraries(test_campaign PRIVATE hardfuzz)
add_test(NAME campaign COMMAND test_campaign)
