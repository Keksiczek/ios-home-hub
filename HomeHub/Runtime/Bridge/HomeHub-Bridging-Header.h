//
//  HomeHub-Bridging-Header.h
//  HomeHub
//
//  Bridging header for llama.cpp C API.
//  Only active when HOMEHUB_REAL_RUNTIME is set in build settings.
//

#ifndef HomeHub_Bridging_Header_h
#define HomeHub_Bridging_Header_h

#ifdef HOMEHUB_REAL_RUNTIME
#include <llama.h>
#include <ggml.h>
#endif

#endif /* HomeHub_Bridging_Header_h */
