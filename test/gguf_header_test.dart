import 'dart:convert';
import 'dart:typed_data';

import 'package:enlibra_mobile/models/gguf_header.dart';
import 'package:flutter_test/flutter_test.dart';

/// Writes the GGUF header format, so the parser can be tested without a
/// multi-gigabyte fixture in the repository.
class _GgufWriter {
  final _out = BytesBuilder();

  Uint8List take() => _out.takeBytes();

  void magic({int version = 3}) {
    _out.add(ascii.encode('GGUF'));
    u32(version);
  }

  void u32(int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.little);
    _out.add(b.buffer.asUint8List());
  }

  void u64(int v) {
    final b = ByteData(8)..setUint64(0, v, Endian.little);
    _out.add(b.buffer.asUint8List());
  }

  void str(String s) {
    final bytes = utf8.encode(s);
    u64(bytes.length);
    _out.add(bytes);
  }

  void kvString(String key, String value) {
    str(key);
    u32(8);
    str(value);
  }

  void kvU32(String key, int value) {
    str(key);
    u32(4);
    u32(value);
  }

  /// An array of strings, which is what `tokenizer.ggml.tokens` is and the one
  /// thing in a real header big enough to matter.
  void kvStringArray(String key, List<String> values) {
    str(key);
    u32(9);
    u32(8);
    u64(values.length);
    for (final v in values) {
      str(v);
    }
  }

  void tensor(String name, List<int> dims, {int type = 15, int offset = 0}) {
    str(name);
    u32(dims.length);
    for (final d in dims) {
      u64(d);
    }
    u32(type);
    u64(offset);
  }
}

/// A plausible 4B-parameter GQA model: 36 layers, 20 query heads over 4 KV
/// heads, 2560-wide.
Uint8List _sampleModel() {
  final w = _GgufWriter()..magic();
  w.u64(2); // tensor count
  w.u64(10); // metadata kv count
  w.kvString('general.architecture', 'qwen2');
  w.kvString('general.name', 'enlibraQ3 14B to 4B');
  w.kvU32('general.file_type', 15); // Q4_K_M
  w.kvU32('qwen2.block_count', 36);
  w.kvU32('qwen2.attention.head_count', 20);
  w.kvU32('qwen2.attention.head_count_kv', 4);
  w.kvU32('qwen2.embedding_length', 2560);
  w.kvU32('qwen2.context_length', 32768);
  w.kvStringArray('tokenizer.ggml.tokens', [
    '<|im_start|>',
    '<|im_end|>',
    'hi',
  ]);
  w.kvString('tokenizer.chat_template', '{% for m in messages %}...');
  w.tensor('token_embd.weight', [2560, 151936]);
  w.tensor('blk.0.attn_q.weight', [2560, 2560]);
  return w.take();
}

void main() {
  group('GgufHeader.parse', () {
    test('reads the shape needed to size a model', () {
      final header = GgufHeader.parse(_sampleModel());

      expect(header.architecture, 'qwen2');
      expect(header.name, 'enlibraQ3 14B to 4B');
      expect(header.layerCount, 36);
      expect(header.kvHeadCount, 4);
      expect(header.headDim, 128); // 2560 / 20
      expect(header.contextLength, 32768);
      expect(header.quantization, 'Q4_K_M');
      expect(header.chatTemplate, startsWith('{% for m in messages %}'));
      expect(header.paramCount, 2560 * 151936 + 2560 * 2560);
    });

    test('walks past a token array without needing its contents', () {
      // The array is skipped, not materialised, but everything after it must
      // still land on the right offset -- which the tensor section proves.
      final header = GgufHeader.parse(_sampleModel());
      expect(header.paramCount, greaterThan(0));
      expect(header.headerBytes, _sampleModel().length);
    });

    test('asks for more bytes when the header is cut short', () {
      final full = _sampleModel();
      final truncated = Uint8List.sublistView(full, 0, full.length ~/ 2);

      expect(
        () => GgufHeader.parse(truncated),
        throwsA(
          isA<GgufNeedsMoreBytes>().having(
            (e) => e.atLeast,
            'atLeast',
            greaterThan(truncated.length),
          ),
        ),
      );
    });

    test('rejects a file that is not GGUF at all', () {
      final notGguf = Uint8List.fromList(utf8.encode('<!doctype html><html>'));
      expect(
        () => GgufHeader.parse(notGguf),
        throwsA(isA<GgufFormatException>()),
      );
    });

    test('rejects a GGUF version it cannot read', () {
      final w = _GgufWriter()..magic(version: 99);
      w.u64(0);
      w.u64(0);
      expect(
        () => GgufHeader.parse(w.take()),
        throwsA(isA<GgufFormatException>()),
      );
    });

    test('rejects metadata with no architecture to namespace under', () {
      final w = _GgufWriter()..magic();
      w.u64(0);
      w.u64(1);
      w.kvString('general.name', 'nameless');
      expect(
        () => GgufHeader.parse(w.take()),
        throwsA(isA<GgufFormatException>()),
      );
    });

    test('falls back to head_count when head_count_kv is absent', () {
      // Pre-GQA architectures omit the key entirely; treating that as "no KV
      // heads" would divide the cache estimate by nothing.
      final w = _GgufWriter()..magic();
      w.u64(0);
      w.u64(4);
      w.kvString('general.architecture', 'llama');
      w.kvU32('llama.block_count', 32);
      w.kvU32('llama.attention.head_count', 32);
      w.kvU32('llama.embedding_length', 4096);

      final header = GgufHeader.parse(w.take());
      expect(header.kvHeadCount, 32);
      expect(header.headDim, 128);
      expect(header.contextLength, 4096); // default when unstated
    });

    test('prefers an explicit key_length over embedding / heads', () {
      final w = _GgufWriter()..magic();
      w.u64(0);
      w.u64(6);
      w.kvString('general.architecture', 'gemma3');
      w.kvU32('gemma3.block_count', 26);
      w.kvU32('gemma3.attention.head_count', 8);
      w.kvU32('gemma3.attention.head_count_kv', 4);
      w.kvU32('gemma3.embedding_length', 2304);
      // 2304/8 = 288, which is not the real head dim.
      w.str('gemma3.attention.key_length');
      w.u32(4);
      w.u32(256);

      final header = GgufHeader.parse(w.take());
      expect(header.headDim, 256);
    });
  });
}
