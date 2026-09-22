import 'package:enlibra_mobile/core/memory_math.dart';
import 'package:flutter_test/flutter_test.dart';

// Shapes of the two models in assets/manifests/catalog.json.
const shape1b = ModelShape(
  paramCount: 1235814400,
  layerCount: 16,
  kvHeadCount: 8,
  headDim: 64,
);

const shape3b = ModelShape(
  paramCount: 3212749824,
  layerCount: 28,
  kvHeadCount: 8,
  headDim: 128,
);

const gb = 1024 * 1024 * 1024;

void main() {
  group('KV cache per token', () {
    test('1B at f16 is ~32KB/token', () {
      expect(shape1b.kvBytesPerToken('f16'), closeTo(32768, 1));
    });

    test('3B at f16 is ~112KB/token', () {
      expect(shape3b.kvBytesPerToken('f16'), closeTo(114688, 1));
    });

    test('q8_0 roughly halves the KV cache', () {
      final f16 = shape3b.kvBytesPerToken('f16');
      final q8 = shape3b.kvBytesPerToken('q8_0');
      expect(q8 / f16, closeTo(0.53, 0.02));
    });
  });

  group('device fit', () {
    // A 6GB Android at the 0.55 usable fraction.
    const budget6gb = 3.3 * gb;
    // An 8GB device at the same fraction.
    const budget8gb = 4.4 * gb;

    test('1B fits comfortably on a 6GB device at 4k context', () {
      final est = estimateMemory(
        shape: shape1b,
        quantization: 'Q4_K_M',
        contextLength: 4096,
      );
      expect(est.totalGb, lessThan(1.3));
      expect(est.totalBytes, lessThan(budget6gb));
    });

    test('3B at 4k with a q8_0 KV cache does fit the 6GB floor', () {
      final est = estimateMemory(
        shape: shape3b,
        quantization: 'Q4_K_M',
        contextLength: 4096,
      );
      // ~2.36GiB. Quantising the KV cache is what makes this work: the
      // same configuration at f16 costs another 230MiB and lands in the
      // no-headroom zone above.
      expect(est.totalGb, closeTo(2.36, 0.15));
      expect(est.totalBytes, lessThan(budget8gb));

      // Meaningful headroom even against the stricter iOS fraction.
      const budget6gbIos = 3.0 * gb;
      expect(1 - est.totalBytes / budget6gbIos, greaterThan(0.15));
    });

    // A 6GB iPhone at the 0.50 jetsam fraction.
    const budget6gbIos = 3.0 * gb;

    test(
      '3B at 8k with an f16 KV cache leaves no headroom on a 6GB iPhone',
      () {
        final est = estimateMemory(
          shape: shape3b,
          quantization: 'Q4_K_M',
          contextLength: 8192,
          kvType: 'f16',
        );
        // 2.93GiB against a 3.0GiB ceiling. Arithmetically it fits; in
        // practice a 2% margin is a crash, because the estimate cannot see
        // fragmentation or whatever else the OS wants back. This is why
        // fitsOn() requires real headroom rather than just a positive result.
        final headroom = 1 - est.totalBytes / budget6gbIos;
        expect(headroom, greaterThan(0));
        expect(headroom, lessThan(0.05));
      },
    );

    test('q8_0 buys back real headroom at the same context', () {
      final est = estimateMemory(
        shape: shape3b,
        quantization: 'Q4_K_M',
        contextLength: 8192,
      );
      final headroom = 1 - est.totalBytes / budget6gbIos;
      expect(headroom, greaterThan(0.15));
    });

    test('7B is not viable on any phone we support', () {
      const shape7b = ModelShape(
        paramCount: 7241732096,
        layerCount: 32,
        kvHeadCount: 8,
        headDim: 128,
      );
      final est = estimateMemory(
        shape: shape7b,
        quantization: 'Q4_K_M',
        contextLength: 4096,
      );
      expect(est.totalGb, greaterThan(4.5));
      expect(est.totalBytes, greaterThan(budget8gb.toInt()));
    });
  });

  group('maxContextForBudget', () {
    test('returns a multiple of 512', () {
      final ctx = maxContextForBudget(
        shape: shape3b,
        quantization: 'Q4_K_M',
        budgetBytes: (3.3 * gb).toInt(),
      );
      expect(ctx % 512, 0);
    });

    test('returns 0 when the weights alone do not fit', () {
      final ctx = maxContextForBudget(
        shape: shape3b,
        quantization: 'Q4_K_M',
        budgetBytes: 1 * gb,
      );
      expect(ctx, 0);
    });

    test('a 1B on a 6GB device gets far more context than a 3B', () {
      final ctx1b = maxContextForBudget(
        shape: shape1b,
        quantization: 'Q4_K_M',
        budgetBytes: (3.3 * gb).toInt(),
      );
      final ctx3b = maxContextForBudget(
        shape: shape3b,
        quantization: 'Q4_K_M',
        budgetBytes: (3.3 * gb).toInt(),
      );
      expect(ctx1b, greaterThan(ctx3b * 3));
    });
  });
}
