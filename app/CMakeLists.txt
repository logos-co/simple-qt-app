cmake_minimum_required(VERSION 3.16)
project(HelloWorld LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_INCLUDE_CURRENT_DIR ON)

# RPATH settings for macOS
set(CMAKE_SKIP_BUILD_RPATH FALSE)
set(CMAKE_BUILD_WITH_INSTALL_RPATH TRUE)
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH TRUE)
if(APPLE)
    set(CMAKE_INSTALL_RPATH "@executable_path/../lib")
else()
    set(CMAKE_INSTALL_RPATH "\$ORIGIN/../lib:\$ORIGIN/lib")
endif()

find_package(Qt6 COMPONENTS Widgets REQUIRED)

set(PROJECT_SOURCES
    main.cpp
)

qt_add_executable(HelloWorld
    ${PROJECT_SOURCES}
)

target_link_libraries(HelloWorld PRIVATE 
    Qt6::Widgets
)
