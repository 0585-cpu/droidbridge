cmake_minimum_required(VERSION 3.22.1)
project(droidbridge_socket_options C)
add_library(droidbridge_socket_options SHARED socket_options.c)
target_compile_options(droidbridge_socket_options PRIVATE -Wall -Wextra -Werror)
