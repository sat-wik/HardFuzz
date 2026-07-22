idf_component_register(
    SRCS "main.cpp" "ble_service.cpp"
    INCLUDE_DIRS "." "../../../host/include"      # reuse the header-only campaign engine
    REQUIRES driver bt nvs_flash)

# the engine headers are C++17
target_compile_options(${COMPONENT_LIB} PRIVATE -std=gnu++17)
