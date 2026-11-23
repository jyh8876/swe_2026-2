cmake_minimum_required(VERSION 3.22.1)
project("vinylo_llm" LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED true)

# arm64 phones: KleidiAI micro-kernels + runtime-selected CPU variants (GGML_CPU_ALL_VARIANTS).
set(GGML_SYSTEM_ARCH "ARM")
set(GGML_CPU_KLEIDIAI ON)

add_subdirectory(${LLAMA_SRC} build-llama)

# The core is shared with iOS, which builds it in the vinylo_llama Swift package.
set(VL_CORE ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../packages/vinylo_llama/ios/vinylo_llama/Sources/VinyloLlmCore)
add_library(vinylo_llm SHARED vinylo_llm.cpp ${VL_CORE}/vinylo_llm_core.cpp)
target_include_directories(vinylo_llm PRIVATE ${VL_CORE}/include ${LLAMA_SRC}/include ${LLAMA_SRC}/ggml/include)
target_link_libraries(vinylo_llm llama ggml android log)
