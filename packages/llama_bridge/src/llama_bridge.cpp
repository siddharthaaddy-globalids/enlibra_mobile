#include "llama_bridge.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <string>
#include <vector>

#include "llama.h"

namespace {

ggml_type kv_type_from_name(const char* name) {
  if (name == nullptr) return GGML_TYPE_Q8_0;
  if (std::strcmp(name, "f16") == 0) return GGML_TYPE_F16;
  if (std::strcmp(name, "q4_0") == 0) return GGML_TYPE_Q4_0;
  return GGML_TYPE_Q8_0;
}

void set_error(char* err, int32_t err_len, const std::string& message) {
  if (err == nullptr || err_len <= 0) return;
  const auto n = std::min<size_t>(message.size(), static_cast<size_t>(err_len - 1));
  std::memcpy(err, message.data(), n);
  err[n] = '\0';
}

}  // namespace

struct lb_context {
  llama_model* model = nullptr;
  llama_context* ctx = nullptr;
  const llama_vocab* vocab = nullptr;
  llama_sampler* sampler = nullptr;

  // Tokens currently resident in the KV cache, in order. This is what makes
  // prefix reuse possible across turns: we diff the next prompt against it
  // rather than reprocessing from scratch.
  std::vector<llama_token> cached;

  bool generating = false;
  int32_t max_tokens = 0;
  int32_t emitted = 0;
  std::atomic<bool> cancel{false};

  int64_t prefill_us = 0;
  int32_t prompt_tokens = 0;
  int32_t cached_tokens = 0;
};

// --- lifecycle -------------------------------------------------------------

void lb_backend_init(void) {
  static bool done = false;
  if (done) return;
  llama_backend_init();
  done = true;
}

void lb_backend_free(void) { llama_backend_free(); }

lb_context* lb_load(const lb_model_params* params, char* err, int32_t err_len) {
  if (params == nullptr || params->model_path == nullptr) {
    set_error(err, err_len, "null params");
    return nullptr;
  }

  lb_backend_init();

  auto mparams = llama_model_default_params();
  mparams.n_gpu_layers = params->n_gpu_layers;
  // mmap lets the OS evict weight pages under pressure instead of killing
  // the process. On a memory-constrained phone this is not an optimisation,
  // it is what keeps the app alive, so never mlock: pinning two gigabytes
  // of weights is the fastest way to get jetsammed.
  mparams.load_mode =
      params->use_mmap ? LLAMA_LOAD_MODE_MMAP : LLAMA_LOAD_MODE_NONE;

  llama_model* model = llama_model_load_from_file(params->model_path, mparams);
  if (model == nullptr) {
    set_error(err, err_len, std::string("failed to load model: ") + params->model_path);
    return nullptr;
  }

  auto cparams = llama_context_default_params();
  cparams.n_ctx = static_cast<uint32_t>(params->n_ctx);
  cparams.n_batch = static_cast<uint32_t>(params->n_batch > 0 ? params->n_batch : 512);
  cparams.n_threads = params->n_threads;
  cparams.n_threads_batch = params->n_threads;
  cparams.type_k = kv_type_from_name(params->kv_type);
  cparams.type_v = kv_type_from_name(params->kv_type);
  cparams.no_perf = true;

  llama_context* ctx = llama_init_from_model(model, cparams);
  if (ctx == nullptr) {
    llama_model_free(model);
    set_error(err, err_len, "failed to create context (likely out of memory)");
    return nullptr;
  }

  auto* out = new lb_context();
  out->model = model;
  out->ctx = ctx;
  out->vocab = llama_model_get_vocab(model);
  return out;
}

void lb_free(lb_context* c) {
  if (c == nullptr) return;
  if (c->sampler != nullptr) llama_sampler_free(c->sampler);
  if (c->ctx != nullptr) llama_free(c->ctx);
  if (c->model != nullptr) llama_model_free(c->model);
  delete c;
}

// --- introspection ---------------------------------------------------------

int32_t lb_n_ctx(lb_context* c) {
  if (c == nullptr) return 0;
  return static_cast<int32_t>(llama_n_ctx(c->ctx));
}

int32_t lb_count_tokens(lb_context* c, const char* text, bool add_special) {
  if (c == nullptr || text == nullptr) return 0;
  const auto len = static_cast<int32_t>(std::strlen(text));
  // A negative return is the negated required capacity.
  const int32_t n = llama_tokenize(c->vocab, text, len, nullptr, 0, add_special, true);
  return n < 0 ? -n : n;
}

// --- chat templating -------------------------------------------------------

int32_t lb_format_prompt(lb_context* c, const char** roles, const char** contents,
                         int32_t n_messages, bool add_assistant, char* buf,
                         int32_t buf_len) {
  if (c == nullptr || roles == nullptr || contents == nullptr) return LB_ERR_GENERIC;

  std::vector<llama_chat_message> messages;
  messages.reserve(static_cast<size_t>(n_messages));
  for (int32_t i = 0; i < n_messages; ++i) {
    messages.push_back({roles[i], contents[i]});
  }

  // NULL asks for the template the GGUF was converted with.
  const char* tmpl = llama_model_chat_template(c->model, nullptr);
  if (tmpl == nullptr) {
    // No baked-in template. Falling back to a guess here would produce
    // subtly wrong output, so make the caller deal with it explicitly.
    return LB_ERR_GENERIC;
  }

  const int32_t needed = llama_chat_apply_template(
      tmpl, messages.data(), messages.size(), add_assistant, nullptr, 0);
  if (needed < 0) return LB_ERR_GENERIC;
  if (buf == nullptr || buf_len < needed + 1) return -(needed + 1);

  const int32_t written = llama_chat_apply_template(
      tmpl, messages.data(), messages.size(), add_assistant, buf, buf_len);
  if (written < 0) return LB_ERR_GENERIC;
  buf[written] = '\0';
  return written;
}

// --- generation ------------------------------------------------------------

namespace {

llama_sampler* build_sampler(const lb_context* c, const lb_sampling_params& p) {
  auto params = llama_sampler_chain_default_params();
  params.no_perf = true;
  llama_sampler* chain = llama_sampler_chain_init(params);

  if (p.repeat_penalty != 1.0f && p.repeat_last_n > 0) {
    llama_sampler_chain_add(
        chain, llama_sampler_init_penalties(0, p.repeat_last_n, p.repeat_penalty, 0.0f, 0.0f));
  }

  if (p.temperature <= 0.0f) {
    // Greedy. Ordering matters: temperature 0 means "always the argmax",
    // so truncation samplers before it would be pointless work.
    llama_sampler_chain_add(chain, llama_sampler_init_greedy());
    return chain;
  }

  if (p.top_k > 0) llama_sampler_chain_add(chain, llama_sampler_init_top_k(p.top_k));
  if (p.top_p < 1.0f) llama_sampler_chain_add(chain, llama_sampler_init_top_p(p.top_p, 1));
  llama_sampler_chain_add(chain, llama_sampler_init_temp(p.temperature));
  llama_sampler_chain_add(chain, llama_sampler_init_dist(p.seed));
  (void)c;
  return chain;
}

// Decodes [from, tokens.size()) in n_batch-sized chunks.
int32_t decode_range(lb_context* c, const std::vector<llama_token>& tokens, int32_t from) {
  const auto n_batch = static_cast<int32_t>(llama_n_batch(c->ctx));
  const auto total = static_cast<int32_t>(tokens.size());

  for (int32_t i = from; i < total; i += n_batch) {
    if (c->cancel.load(std::memory_order_relaxed)) return LB_DONE_CANCELLED;
    const int32_t n = std::min(n_batch, total - i);
    llama_batch batch =
        llama_batch_get_one(const_cast<llama_token*>(tokens.data()) + i, n);
    const int32_t rc = llama_decode(c->ctx, batch);
    if (rc == 1) return LB_ERR_CONTEXT_FULL;
    if (rc != 0) return LB_ERR_DECODE;
  }
  return LB_OK;
}

}  // namespace

int32_t lb_generate_begin(lb_context* c, const char* prompt,
                          const lb_sampling_params* sampling, int32_t max_tokens) {
  if (c == nullptr || prompt == nullptr || sampling == nullptr) return LB_ERR_GENERIC;

  c->cancel.store(false, std::memory_order_relaxed);
  c->emitted = 0;
  c->max_tokens = max_tokens;

  const auto len = static_cast<int32_t>(std::strlen(prompt));
  int32_t n_tokens = llama_tokenize(c->vocab, prompt, len, nullptr, 0, true, true);
  if (n_tokens < 0) n_tokens = -n_tokens;

  std::vector<llama_token> tokens(static_cast<size_t>(n_tokens));
  if (llama_tokenize(c->vocab, prompt, len, tokens.data(), n_tokens, true, true) < 0) {
    return LB_ERR_GENERIC;
  }

  if (n_tokens >= lb_n_ctx(c)) return LB_ERR_CONTEXT_FULL;

  // How much of the cache still matches the new prompt.
  int32_t common = 0;
  const auto cached_n = static_cast<int32_t>(c->cached.size());
  while (common < cached_n && common < n_tokens && c->cached[common] == tokens[common]) {
    ++common;
  }
  // Always leave at least one token to decode, otherwise there are no
  // logits to sample the first reply token from.
  if (common >= n_tokens) common = n_tokens - 1;
  if (common < 0) common = 0;

  // Drop everything after the shared prefix.
  llama_memory_t mem = llama_get_memory(c->ctx);
  llama_memory_seq_rm(mem, 0, common, -1);
  c->cached.resize(static_cast<size_t>(common));

  const auto started = std::chrono::steady_clock::now();
  const int32_t rc = decode_range(c, tokens, common);
  const auto finished = std::chrono::steady_clock::now();

  c->prefill_us =
      std::chrono::duration_cast<std::chrono::microseconds>(finished - started).count();
  c->prompt_tokens = n_tokens;
  c->cached_tokens = common;

  if (rc != LB_OK) return rc;

  c->cached.assign(tokens.begin(), tokens.end());

  if (c->sampler != nullptr) llama_sampler_free(c->sampler);
  c->sampler = build_sampler(c, *sampling);
  c->generating = true;
  return LB_OK;
}

int32_t lb_generate_next(lb_context* c, char* buf, int32_t buf_len) {
  if (c == nullptr || buf == nullptr || buf_len <= 0) return LB_ERR_GENERIC;
  if (!c->generating) return LB_ERR_NOT_GENERATING;

  if (c->cancel.load(std::memory_order_relaxed)) {
    c->generating = false;
    return LB_DONE_CANCELLED;
  }
  if (c->emitted >= c->max_tokens) {
    c->generating = false;
    return LB_DONE_MAX_TOKENS;
  }
  if (static_cast<int32_t>(c->cached.size()) >= lb_n_ctx(c)) {
    c->generating = false;
    return LB_ERR_CONTEXT_FULL;
  }

  const llama_token token = llama_sampler_sample(c->sampler, c->ctx, -1);
  llama_sampler_accept(c->sampler, token);

  if (llama_vocab_is_eog(c->vocab, token)) {
    c->generating = false;
    return LB_DONE_EOS;
  }

  int32_t n = llama_token_to_piece(c->vocab, token, buf, buf_len, 0, true);
  if (n < 0) return -n;  // caller retries with a larger buffer
  if (n < buf_len) buf[n] = '\0';

  // Feed the sampled token back in so the next call has fresh logits.
  c->cached.push_back(token);
  llama_batch batch = llama_batch_get_one(&c->cached.back(), 1);
  const int32_t rc = llama_decode(c->ctx, batch);
  if (rc != 0) {
    c->generating = false;
    return rc == 1 ? LB_ERR_CONTEXT_FULL : LB_ERR_DECODE;
  }

  ++c->emitted;
  return n;
}

void lb_generate_cancel(lb_context* c) {
  if (c == nullptr) return;
  c->cancel.store(true, std::memory_order_relaxed);
}

int64_t lb_last_prefill_us(lb_context* c) { return c == nullptr ? 0 : c->prefill_us; }
int32_t lb_last_prompt_tokens(lb_context* c) { return c == nullptr ? 0 : c->prompt_tokens; }
int32_t lb_last_cached_tokens(lb_context* c) { return c == nullptr ? 0 : c->cached_tokens; }

// --- session persistence ---------------------------------------------------

bool lb_session_save(lb_context* c, const char* path) {
  if (c == nullptr || path == nullptr) return false;
  return llama_state_seq_save_file(c->ctx, path, 0, c->cached.data(), c->cached.size()) > 0;
}

bool lb_session_load(lb_context* c, const char* path) {
  if (c == nullptr || path == nullptr) return false;

  std::vector<llama_token> tokens(static_cast<size_t>(lb_n_ctx(c)));
  size_t n_out = 0;
  const size_t read = llama_state_seq_load_file(c->ctx, path, 0, tokens.data(),
                                                tokens.size(), &n_out);
  if (read == 0) return false;

  tokens.resize(n_out);
  c->cached = std::move(tokens);
  return true;
}
