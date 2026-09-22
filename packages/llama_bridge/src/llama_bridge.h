// A deliberately narrow C ABI over llama.cpp.
//
// Dart binds to *this* header, not to llama.h. That matters: llama.h's
// structs change shape between releases, and any Dart mirror of them would
// silently corrupt memory when they do. Everything here is opaque pointers
// and flat POD, so a llama.cpp bump can break the C++ build (loud) but can
// never produce a misaligned struct at runtime (silent).

#ifndef LLAMA_BRIDGE_H
#define LLAMA_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#if defined(_WIN32)
#define LB_EXPORT __declspec(dllexport)
#else
#define LB_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lb_context lb_context;

// Status codes. Negative values are returned in place of a byte count.
enum {
  LB_OK = 0,
  LB_DONE_EOS = -1,       // model emitted end-of-generation
  LB_DONE_MAX_TOKENS = -2,
  LB_DONE_CANCELLED = -3,
  LB_ERR_GENERIC = -10,
  LB_ERR_NOT_GENERATING = -11,
  LB_ERR_DECODE = -12,
  LB_ERR_CONTEXT_FULL = -13,
};

typedef struct {
  const char* model_path;
  int32_t n_ctx;
  int32_t n_batch;
  int32_t n_threads;
  // 0 keeps everything on CPU. Negative offloads every layer. On Android,
  // treat anything above 0 as opportunistic: GPU support is a vendor
  // lottery and CPU is the dependable baseline.
  int32_t n_gpu_layers;
  // "f16", "q8_0" or "q4_0". q8_0 roughly halves KV cache memory for very
  // little quality cost, which on a phone is often the difference between
  // running and being killed by the OS.
  const char* kv_type;
  bool use_mmap;
} lb_model_params;

typedef struct {
  float temperature;
  float top_p;
  int32_t top_k;
  float repeat_penalty;
  int32_t repeat_last_n;
  uint32_t seed;  // UINT32_MAX for a random seed
} lb_sampling_params;

// --- lifecycle -------------------------------------------------------------

// Idempotent; safe to call more than once.
LB_EXPORT void lb_backend_init(void);
LB_EXPORT void lb_backend_free(void);

// Returns NULL on failure and writes a message into err.
LB_EXPORT lb_context* lb_load(const lb_model_params* params, char* err,
                              int32_t err_len);
LB_EXPORT void lb_free(lb_context* ctx);

// --- introspection ---------------------------------------------------------

LB_EXPORT int32_t lb_n_ctx(lb_context* ctx);

// Token count using the model's own tokenizer. A character heuristic is
// wrong by enough to blow the context window, so the context budget must
// use this.
LB_EXPORT int32_t lb_count_tokens(lb_context* ctx, const char* text,
                                  bool add_special);

// --- chat templating -------------------------------------------------------

// Formats messages using the chat template baked into the GGUF. Wrong
// templating is the most common cause of a model producing garbage, and it
// does not look like a formatting bug from the outside, so prefer this over
// assembling the prompt in Dart.
//
// Writes into buf and returns the number of bytes written. If buf is too
// small, returns the negative of the required size and writes nothing.
LB_EXPORT int32_t lb_format_prompt(lb_context* ctx, const char** roles,
                                   const char** contents, int32_t n_messages,
                                   bool add_assistant, char* buf,
                                   int32_t buf_len);

// --- generation ------------------------------------------------------------

// Tokenizes the prompt, reuses whatever KV cache prefix still matches, and
// decodes the remainder. Blocking: prefill is the dominant cost on mobile
// (25-60s for a long history on a mid-range Android CPU), so call this on a
// background isolate.
LB_EXPORT int32_t lb_generate_begin(lb_context* ctx, const char* prompt,
                                    const lb_sampling_params* sampling,
                                    int32_t max_tokens);

// Decodes exactly one token and writes its UTF-8 piece into buf.
// Returns the byte count, or one of the LB_DONE_*/LB_ERR_* codes.
LB_EXPORT int32_t lb_generate_next(lb_context* ctx, char* buf,
                                   int32_t buf_len);

// Safe to call from another thread while lb_generate_next is blocked; the
// flag it sets is atomic. This is how the UI's stop button reaches the
// decode loop.
LB_EXPORT void lb_generate_cancel(lb_context* ctx);

// Stats for the most recent lb_generate_begin. cached_tokens is the part of
// the prompt served from the existing KV cache; when it approaches
// prompt_tokens, prefix reuse is doing its job.
LB_EXPORT int64_t lb_last_prefill_us(lb_context* ctx);
LB_EXPORT int32_t lb_last_prompt_tokens(lb_context* ctx);
LB_EXPORT int32_t lb_last_cached_tokens(lb_context* ctx);

// --- session persistence ---------------------------------------------------

// Serialises the KV cache so a reopened conversation skips prefill entirely.
LB_EXPORT bool lb_session_save(lb_context* ctx, const char* path);
LB_EXPORT bool lb_session_load(lb_context* ctx, const char* path);

#ifdef __cplusplus
}
#endif

#endif  // LLAMA_BRIDGE_H
