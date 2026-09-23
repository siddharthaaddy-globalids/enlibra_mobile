/// Reads the metadata block at the front of a GGUF file.
///
/// This exists so a model can be added by URL alone. The backend path hands
/// the app a manifest describing the model's shape; a pasted pre-signed URL
/// hands it nothing, and without a shape the app cannot say whether the model
/// fits in RAM or what context length to load it with. Everything needed is
/// already in the file's header, and the header sits at byte zero -- so a few
/// megabytes of HTTP Range request answers it, rather than the 2.5GB the file
/// actually weighs.
///
/// Format (little-endian throughout):
///   magic u32 'GGUF' | version u32 | tensor_count u64 | kv_count u64
///   kv_count x (key string, value_type u32, value)
///   tensor_count x (name string, n_dims u32, dims u64[], type u32, offset u64)
library;

import 'dart:convert';
import 'dart:typed_data';

/// Thrown when the buffer ran out mid-structure. [atLeast] is what the reader
/// should fetch before trying again -- an estimate, not a promise.
class GgufNeedsMoreBytes implements Exception {
  GgufNeedsMoreBytes(this.atLeast);
  final int atLeast;
  @override
  String toString() => 'GgufNeedsMoreBytes(atLeast: $atLeast)';
}

class GgufFormatException implements Exception {
  GgufFormatException(this.message);
  final String message;
  @override
  String toString() => 'GgufFormatException: $message';
}

/// `general.file_type`, which is llama.cpp's `LLAMA_FTYPE` enum.
///
/// Only a label: sizing uses the file's real byte count, so an unrecognised
/// value costs a nicer string and nothing else.
const Map<int, String> _fileTypeNames = {
  0: 'F32',
  1: 'F16',
  2: 'Q4_0',
  3: 'Q4_1',
  7: 'Q8_0',
  8: 'Q5_0',
  9: 'Q5_1',
  10: 'Q2_K',
  11: 'Q3_K_S',
  12: 'Q3_K_M',
  13: 'Q3_K_L',
  14: 'Q4_K_S',
  15: 'Q4_K_M',
  16: 'Q5_K_S',
  17: 'Q5_K_M',
  18: 'Q6_K',
  19: 'IQ2_XXS',
  20: 'IQ2_XS',
  21: 'Q2_K_S',
  22: 'IQ3_XS',
  23: 'IQ3_XXS',
  24: 'IQ1_S',
  25: 'IQ4_NL',
  26: 'IQ3_S',
  27: 'IQ3_M',
  28: 'IQ2_S',
  29: 'IQ2_M',
  30: 'IQ4_XS',
  31: 'IQ1_M',
  32: 'BF16',
  36: 'TQ1_0',
  37: 'TQ2_0',
};

class GgufHeader {
  const GgufHeader({
    required this.architecture,
    required this.layerCount,
    required this.kvHeadCount,
    required this.headDim,
    required this.contextLength,
    required this.paramCount,
    required this.headerBytes,
    this.name,
    this.quantization,
    this.chatTemplate,
    this.eosTokenId,
  });

  /// `llama`, `qwen2`, `gemma3`, ... Everything else in the metadata is
  /// namespaced under it.
  final String architecture;

  final String? name;
  final int layerCount;

  /// Grouped-query attention: usually a fraction of the attention head count,
  /// and the number that actually sizes the KV cache.
  final int kvHeadCount;

  final int headDim;

  /// What the model was trained for. The device may still load it with less.
  final int contextLength;

  /// Summed over every tensor in the file, so it includes embeddings and the
  /// output head rather than just the transformer body.
  final int paramCount;

  /// Label from `general.file_type`. Null when the file uses a quantisation
  /// this build does not have a name for.
  final String? quantization;

  final String? chatTemplate;
  final int? eosTokenId;

  /// How many bytes of the file the parse consumed. Useful for logging how
  /// close the prefetch came to being too small.
  final int headerBytes;

  @override
  String toString() =>
      'GgufHeader($architecture, ${paramCount ~/ 1000000}M params, '
      'layers=$layerCount, kvHeads=$kvHeadCount, headDim=$headDim, '
      'ctx=$contextLength, ${quantization ?? "unknown quant"})';

  /// Parses as much of [bytes] as the header occupies.
  ///
  /// Throws [GgufNeedsMoreBytes] when [bytes] is a prefix that stops inside the
  /// header, which is the expected outcome of the first Range request.
  static GgufHeader parse(Uint8List bytes) {
    final r = _Reader(bytes);

    if (r.u32() != 0x46554747) {
      throw GgufFormatException('not a GGUF file (bad magic)');
    }
    final version = r.u32();
    if (version < 2 || version > 3) {
      throw GgufFormatException('unsupported GGUF version $version');
    }

    final tensorCount = r.u64();
    final kvCount = r.u64();
    if (kvCount > 1 << 20 || tensorCount > 1 << 22) {
      throw GgufFormatException('implausible header counts; file is corrupt');
    }

    final kv = <String, Object?>{};
    for (var i = 0; i < kvCount; i++) {
      final key = r.string();
      kv[key] = r.value();
    }

    final arch = kv['general.architecture'] as String?;
    if (arch == null) {
      throw GgufFormatException('metadata has no general.architecture');
    }

    // Tensor dimensions are the only place the true parameter count lives --
    // no metadata key carries it -- so the whole tensor index gets walked.
    var params = 0;
    for (var i = 0; i < tensorCount; i++) {
      r.string(); // tensor name
      final dimCount = r.u32();
      if (dimCount > 4) {
        throw GgufFormatException('tensor $i has $dimCount dimensions');
      }
      var elements = 1;
      for (var d = 0; d < dimCount; d++) {
        elements *= r.u64();
      }
      r.u32(); // ggml type
      r.u64(); // offset into the tensor data block
      params += elements;
    }

    final headCount = _int(kv['$arch.attention.head_count']);
    final embedding = _int(kv['$arch.embedding_length']);

    // Most architectures state the head dimension only implicitly. Gemma and
    // friends set key_length explicitly and it does *not* equal
    // embedding/heads, so that key wins where it exists.
    final headDim =
        _int(kv['$arch.attention.key_length']) ??
        (embedding != null && headCount != null && headCount > 0
            ? embedding ~/ headCount
            : null);

    final layerCount = _int(kv['$arch.block_count']);
    final kvHeads = _int(kv['$arch.attention.head_count_kv']) ?? headCount;
    final context = _int(kv['$arch.context_length']);

    if (layerCount == null || kvHeads == null || headDim == null) {
      throw GgufFormatException(
        'metadata is missing the shape keys needed to size this model '
        '(block_count / head_count_kv / key_length for "$arch")',
      );
    }

    return GgufHeader(
      architecture: arch,
      name: kv['general.name'] as String?,
      layerCount: layerCount,
      kvHeadCount: kvHeads,
      headDim: headDim,
      // A model with no declared context still has to be given one. 4096 is
      // the conservative floor every modern architecture supports.
      contextLength: context ?? 4096,
      paramCount: params,
      quantization: _fileTypeNames[_int(kv['general.file_type']) ?? -1],
      chatTemplate: kv['tokenizer.chat_template'] as String?,
      eosTokenId: _int(kv['tokenizer.ggml.eos_token_id']),
      headerBytes: r.offset,
    );
  }
}

int? _int(Object? value) => value is int ? value : null;

/// Cursor over the prefix we have, which asks for more rather than reading
/// past the end.
class _Reader {
  _Reader(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;
  int offset = 0;

  void _need(int count) {
    if (offset + count > bytes.length) {
      // Ask for double what we have, or for the exact shortfall when that is
      // larger. What is missing is usually the tokenizer's token list or the
      // tensor index, both large relative to what has been read so far, so
      // creeping forward by the shortfall alone would cost a dozen round trips.
      final doubled = bytes.length * 2;
      final needed = offset + count;
      throw GgufNeedsMoreBytes(needed > doubled ? needed : doubled);
    }
  }

  int u8() {
    _need(1);
    return bytes[offset++];
  }

  int u32() {
    _need(4);
    final v = data.getUint32(offset, Endian.little);
    offset += 4;
    return v;
  }

  int i32() {
    _need(4);
    final v = data.getInt32(offset, Endian.little);
    offset += 4;
    return v;
  }

  /// Read as two 32-bit halves rather than `getUint64`, which is unimplemented
  /// on the web target. Values above 2^53 cannot be real here (they would be
  /// string lengths or tensor dimensions) so they are rejected as corruption
  /// instead of silently losing precision.
  int u64() {
    _need(8);
    final lo = data.getUint32(offset, Endian.little);
    final hi = data.getUint32(offset + 4, Endian.little);
    offset += 8;
    if (hi > 0x1FFFFF) {
      throw GgufFormatException('64-bit value too large to be meaningful');
    }
    return (hi << 32) | lo;
  }

  double f32() {
    _need(4);
    final v = data.getFloat32(offset, Endian.little);
    offset += 4;
    return v;
  }

  double f64() {
    _need(8);
    final v = data.getFloat64(offset, Endian.little);
    offset += 8;
    return v;
  }

  String string() {
    final length = u64();
    if (length > 1 << 26) {
      throw GgufFormatException('metadata string of $length bytes');
    }
    _need(length);
    final s = utf8.decode(
      bytes.sublist(offset, offset + length),
      allowMalformed: true,
    );
    offset += length;
    return s;
  }

  /// A metadata value. Arrays are walked but not materialised: the only large
  /// one is `tokenizer.ggml.tokens`, which can be several megabytes of strings
  /// this app has no use for -- llama.cpp reads the tokenizer from the file
  /// itself at load time.
  Object? value() {
    final type = u32();
    switch (type) {
      case 0:
        return u8();
      case 1:
        final raw = u8();
        return raw >= 128 ? raw - 256 : raw;
      case 2:
        _need(2);
        final v = data.getUint16(offset, Endian.little);
        offset += 2;
        return v;
      case 3:
        _need(2);
        final v = data.getInt16(offset, Endian.little);
        offset += 2;
        return v;
      case 4:
        return u32();
      case 5:
        return i32();
      case 6:
        return f32();
      case 7:
        return u8() != 0;
      case 8:
        return string();
      case 9:
        final elementType = u32();
        final count = u64();
        for (var i = 0; i < count; i++) {
          _skip(elementType);
        }
        return _GgufArray(elementType, count);
      case 10:
        return u64();
      case 11:
        return u64(); // int64; values that matter here are never negative
      case 12:
        return f64();
      default:
        throw GgufFormatException('unknown metadata value type $type');
    }
  }

  void _skip(int type) {
    switch (type) {
      case 0:
      case 1:
      case 7:
        _need(1);
        offset += 1;
      case 2:
      case 3:
        _need(2);
        offset += 2;
      case 4:
      case 5:
      case 6:
        _need(4);
        offset += 4;
      case 10:
      case 11:
      case 12:
        _need(8);
        offset += 8;
      case 8:
        string();
      case 9:
        // Nested arrays are legal in the format and absent in practice.
        final elementType = u32();
        final count = u64();
        for (var i = 0; i < count; i++) {
          _skip(elementType);
        }
      default:
        throw GgufFormatException('unknown array element type $type');
    }
  }
}

class _GgufArray {
  const _GgufArray(this.elementType, this.length);
  final int elementType;
  final int length;
  @override
  String toString() => 'array<$elementType>[$length]';
}
