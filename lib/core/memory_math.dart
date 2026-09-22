/// Memory estimation for on-device llama.cpp inference.
///
/// Every number here is an estimate. The point is not precision, it is to
/// refuse a download that would OOM-kill the app on the user's device.
library;

/// Bits per weight for the quantisation formats we ship.
///
/// These are the *effective* averages llama.cpp achieves, including the
/// higher-precision tensors (embeddings, output head) that K-quants leave
/// at a larger type.
const Map<String, double> _bitsPerWeight = {
  'Q4_K_M': 4.83,
  'Q4_K_S': 4.56,
  'Q5_K_M': 5.67,
  'Q6_K': 6.56,
  'Q8_0': 8.50,
  'F16': 16.0,
};

/// Bytes per element for a KV cache entry of the given type.
const Map<String, double> _kvBytesPerElement = {
  'f16': 2.0,
  'q8_0': 1.0625, // 8-bit + per-block scale
  'q4_0': 0.5625,
};

class MemoryEstimate {
  const MemoryEstimate({
    required this.weightsBytes,
    required this.kvCacheBytes,
    required this.overheadBytes,
  });

  /// Model weights, memory-mapped from the GGUF file.
  final int weightsBytes;

  /// KV cache for the full configured context. Allocated up front.
  final int kvCacheBytes;

  /// Compute buffers, tokenizer, logits, plus the Flutter runtime itself.
  final int overheadBytes;

  int get totalBytes => weightsBytes + kvCacheBytes + overheadBytes;

  double get totalMb => totalBytes / (1024 * 1024);
  double get totalGb => totalBytes / (1024 * 1024 * 1024);

  @override
  String toString() =>
      'weights=${_mb(weightsBytes)}MB kv=${_mb(kvCacheBytes)}MB '
      'overhead=${_mb(overheadBytes)}MB total=${_mb(totalBytes)}MB';

  static int _mb(int b) => (b / (1024 * 1024)).round();
}

/// The architecture facts we need to size a model. Read these from the GGUF
/// metadata (`llama_model_*` getters) or carry them in the manifest.
class ModelShape {
  const ModelShape({
    required this.paramCount,
    required this.layerCount,
    required this.kvHeadCount,
    required this.headDim,
  });

  final int paramCount;
  final int layerCount;

  /// Grouped-query attention means this is usually far smaller than the
  /// number of attention heads. Using the attention head count here would
  /// overestimate the KV cache by 4-8x.
  final int kvHeadCount;
  final int headDim;

  /// Bytes of KV cache consumed per token of context.
  ///
  ///   2 (K and V) x layers x kv_heads x head_dim x bytes_per_element
  double kvBytesPerToken(String kvType) {
    final bytesPerElement = _kvBytesPerElement[kvType] ?? 2.0;
    return 2 * layerCount * kvHeadCount * headDim * bytesPerElement;
  }
}

/// Estimates peak resident memory for a model at a given context length.
///
/// [kvType] is the llama.cpp `type_k`/`type_v` setting. Quantising the KV
/// cache to `q8_0` roughly halves its footprint for very little quality
/// cost, and on a phone that is often the difference between running and
/// being killed.
MemoryEstimate estimateMemory({
  required ModelShape shape,
  required String quantization,
  required int contextLength,
  String kvType = 'q8_0',
}) {
  final bits = _bitsPerWeight[quantization] ?? 4.83;
  final weights = (shape.paramCount * bits / 8).round();
  final kv = (shape.kvBytesPerToken(kvType) * contextLength).round();

  // Compute buffers scale with batch size and vocab, not context. 256MB is a
  // deliberately generous flat allowance that also covers the Dart heap and
  // the Flutter engine, so the estimate errs toward refusing to load.
  const overhead = 256 * 1024 * 1024;

  return MemoryEstimate(
    weightsBytes: weights,
    kvCacheBytes: kv,
    overheadBytes: overhead,
  );
}

/// Largest context length that fits in [budgetBytes], rounded down to a
/// multiple of 512. Returns 0 if even the weights do not fit.
int maxContextForBudget({
  required ModelShape shape,
  required String quantization,
  required int budgetBytes,
  String kvType = 'q8_0',
}) {
  final base = estimateMemory(
    shape: shape,
    quantization: quantization,
    contextLength: 0,
    kvType: kvType,
  );
  final remaining = budgetBytes - base.totalBytes;
  if (remaining <= 0) return 0;

  final perToken = shape.kvBytesPerToken(kvType);
  final tokens = (remaining / perToken).floor();
  return (tokens ~/ 512) * 512;
}
