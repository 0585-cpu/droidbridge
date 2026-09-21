cmake_minimum_required(VERSION 3.28)
project(droidbridge_core VERSION 0.1.0 LANGUAGES C)
set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
include(CTest)
add_library(droidbridge_protocol STATIC src/dbp_codec.c src/destination_policy.c
    src/ipv4_packet.c src/tcp_packet.c src/checksum.c src/flow_table.c src/tcp_rewrite.c)
target_include_directories(droidbridge_protocol PUBLIC include)
if(BUILD_TESTING)
  add_subdirectory(tests)
endif()

# --- lwIP NO_SYS data-plane library ---
option(DROIDBRIDGE_BUILD_LWIP "Build the lwIP data-plane adapter (requires the submodule)" ON)
if(DROIDBRIDGE_BUILD_LWIP AND EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lwip/src/Filelists.cmake)
  set(LWIP_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lwip)
  set(LWIP_INCLUDE_DIRS
      ${CMAKE_CURRENT_SOURCE_DIR}/ports
      ${LWIP_DIR}/src/include)
  include(${LWIP_DIR}/src/Filelists.cmake)
  add_library(droidbridge_lwip STATIC
      ${lwipcore_SRCS} ${lwipcore4_SRCS} ${lwipnetif_SRCS}
      ports/lwip_port.c src/lwip_adapter.c src/packet_engine.c src/dns_bridge.c src/dns_packet.c)
  target_include_directories(droidbridge_lwip PUBLIC ${LWIP_INCLUDE_DIRS} include)
  # lwIP 2.2 has minor sign-conversion/unused warnings; keep our own code warned but not lwIP.
  target_compile_options(droidbridge_lwip PRIVATE -Wno-everything)
endif()

option(DROIDBRIDGE_BUILD_FUZZERS "Build libFuzzer targets (requires an LLVM clang with libFuzzer)" OFF)
if(DROIDBRIDGE_BUILD_FUZZERS)
  set(fuzz_flags -fsanitize=fuzzer,address,undefined -fno-omit-frame-pointer)
  foreach(target fuzz_dbp_header fuzz_open_tcp)
    add_executable(${target} fuzz/${target}.c)
    target_link_libraries(${target} PRIVATE droidbridge_protocol)
    target_compile_options(${target} PRIVATE ${fuzz_flags})
    target_link_options(${target} PRIVATE ${fuzz_flags})
  endforeach()
  # the library itself must be instrumented too
  target_compile_options(droidbridge_protocol PRIVATE ${fuzz_flags})
endif()
