import 'dart:convert';

import 'package:enlibra_mobile/models/model_link.dart';
import 'package:flutter_test/flutter_test.dart';

/// The real shape of what the script prints: an S3 key under a dated run
/// directory, plus a SigV4 query.
const _key =
    'dss/dev/runs/20260818_215840_neuroscience_8f33eb7cf609/outputs/gkd/runs/'
    'enlibraQ3-14B-to-4B-2026-09-22-1209/gguf/'
    'enlibraQ3-14B-to-4B-2026-09-22-1209-Q4_K_M.gguf';

Uri _presigned({String signedAt = '20260923T120000Z', int expiresIn = 604800}) {
  return Uri.parse(
    'https://enlibra.s3.us-east-1.amazonaws.com/$_key'
    '?X-Amz-Algorithm=AWS4-HMAC-SHA256'
    '&X-Amz-Date=$signedAt'
    '&X-Amz-Expires=$expiresIn'
    '&X-Amz-SignedHeaders=host'
    '&X-Amz-Signature=abc123',
  );
}

void main() {
  group('ModelLink.parse', () {
    test('takes a bare pre-signed URL', () {
      final link = ModelLink.parse(_presigned().toString());
      expect(link.files, hasLength(1));
      expect(link.weights.role, 'weights');
      expect(link.manifest, isNull);
    });

    test('tolerates a URL copied with surrounding quotes', () {
      final link = ModelLink.parse('  "${_presigned()}"  ');
      expect(link.weights.url.path, endsWith('-Q4_K_M.gguf'));
    });

    test('rejects an s3:// address with advice rather than a bare failure', () {
      expect(
        () => ModelLink.parse('s3://enlibra/$_key'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('presign-model.mjs'),
          ),
        ),
      );
    });

    test('rejects empty input', () {
      expect(() => ModelLink.parse('   '), throwsA(isA<FormatException>()));
    });

    test('reads the script\'s --manifest JSON', () {
      final json = jsonEncode({
        'kind': 'enlibra-model-source',
        'version': 1,
        'id': 'enlibraq3-14b-to-4b-2026-09-22-1209',
        'displayName': 'enlibraQ3-14B-to-4B-2026-09-22-1209',
        'source': 's3://enlibra/dss/dev/runs/.../gguf/',
        'expiresAt': '2026-09-30T12:00:00.000Z',
        'files': [
          {
            'role': 'weights',
            'fileName': 'enlibraQ3-14B-to-4B-2026-09-22-1209-Q4_K_M.gguf',
            'sizeBytes': 2469606195,
            'sha256': 'A' * 64,
            'url': _presigned().toString(),
          },
        ],
      });

      final link = ModelLink.parse(json);
      expect(link.id, 'enlibraq3-14b-to-4b-2026-09-22-1209');
      expect(link.source, startsWith('s3://enlibra/'));
      expect(link.weights.sizeBytes, 2469606195);
      expect(link.weights.sha256, 'a' * 64); // normalised
    });

    test('rejects JSON of an unrecognised kind', () {
      final json = jsonEncode({'kind': 'something-else', 'files': []});
      expect(() => ModelLink.parse(json), throwsA(isA<FormatException>()));
    });

    test('rejects a files entry with no url', () {
      final json = jsonEncode({
        'kind': 'enlibra-model-source',
        'files': [
          {'fileName': 'model.gguf', 'sizeBytes': 1},
        ],
      });
      expect(() => ModelLink.parse(json), throwsA(isA<FormatException>()));
    });
  });

  group('signatureExpiry', () {
    test('derives the deadline from the SigV4 stamps', () {
      final expiry = ModelLink.signatureExpiry(
        _presigned(signedAt: '20260923T120000Z', expiresIn: 3600),
      );
      expect(expiry, DateTime.utc(2026, 9, 23, 13, 0, 0));
    });

    test('reads a CloudFront / SigV2 absolute epoch', () {
      final url = Uri.parse(
        'https://cdn.example.com/m.gguf?Expires=1790000000',
      );
      expect(
        ModelLink.signatureExpiry(url),
        DateTime.fromMillisecondsSinceEpoch(1790000000 * 1000, isUtc: true),
      );
    });

    test('is null for a URL that carries no signature', () {
      expect(
        ModelLink.signatureExpiry(Uri.parse('https://example.com/m.gguf')),
        isNull,
      );
    });

    test('surfaces an already-expired link', () {
      final link = ModelLink.parse(
        _presigned(signedAt: '20200101T000000Z', expiresIn: 60).toString(),
      );
      expect(link.earliestExpiry!.isBefore(DateTime.now().toUtc()), isTrue);
    });
  });

  group('idFromUrl', () {
    test('names the model after its run directory, not the file', () {
      // Every quantisation run writes a `model-q4_k_m.gguf`, so the file name
      // would collide across models and share one on-disk directory.
      expect(
        ModelLink.idFromUrl(_presigned()),
        'enlibraq3-14b-to-4b-2026-09-22-1209',
      );
    });

    test('is stable across re-signing the same object', () {
      expect(
        ModelLink.idFromUrl(_presigned(signedAt: '20260923T120000Z')),
        ModelLink.idFromUrl(_presigned(signedAt: '20260924T090000Z')),
      );
    });

    test('ignores a format directory, so gguf/ and quantized/ agree', () {
      // The same build is published twice: the checkpoint under quantized/
      // and the converted weights under gguf/. Neither directory names the
      // model, and taking the tail would call this one "gguf".
      const run =
          'dss/dev/runs/20260818_215840_neuroscience_8f33eb7cf609/outputs/gkd/'
          'runs/enlibraQ3-14B-to-4B-2026-09-22-1209';

      final fromGguf = Uri.parse(
        'https://enlibra.s3.us-east-1.amazonaws.com/$run/gguf/'
        'enlibraQ3-14B-to-4B-2026-09-22-1209-Q4_K_M.gguf',
      );
      final fromQuantized = Uri.parse(
        'https://enlibra.s3.us-east-1.amazonaws.com/$run/quantized/model.gguf',
      );

      expect(
        ModelLink.idFromUrl(fromGguf),
        'enlibraq3-14b-to-4b-2026-09-22-1209',
      );
      expect(ModelLink.idFromUrl(fromQuantized), ModelLink.idFromUrl(fromGguf));
    });

    test('falls back to the file name when there is no directory to use', () {
      expect(
        ModelLink.idFromUrl(Uri.parse('https://example.com/Tiny-Model.gguf')),
        'tiny-model',
      );
    });
  });
}
