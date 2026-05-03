//
//  HomeHub-Bridging-Header.h
//  HomeHub
//
//  Bridging header for the llama.cpp C API.
//
//  llama.cpp is OPTIONAL since the MLX runtime became the primary backend.
//  Only include the C headers when the build explicitly opts in to llama.cpp
//  via the HOMEHUB_LLAMA_RUNTIME preprocessor flag. The flag must be set in
//  BOTH GCC_PREPROCESSOR_DEFINITIONS (visible here) AND
//  SWIFT_ACTIVE_COMPILATION_CONDITIONS (visible to the Swift sources that
//  wrap the llama_* calls); otherwise the Swift and C sides disagree on
//  whether the symbols are available.
//
//  Default builds do NOT need llama.xcframework on disk and compile cleanly
//  without it.
//

#ifndef HomeHub_Bridging_Header_h
#define HomeHub_Bridging_Header_h

#ifdef HOMEHUB_LLAMA_RUNTIME
#include <llama.h>
#include <ggml.h>
#endif /* HOMEHUB_LLAMA_RUNTIME */

#endif /* HomeHub_Bridging_Header_h */
