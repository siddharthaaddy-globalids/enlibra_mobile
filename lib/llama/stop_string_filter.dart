/// Suppresses stop strings from a streamed token feed.
///
/// A stop string rarely arrives as one token. `<|im_end|>` might come
/// through as `<|`, `im`, `_end`, `|>`, so naively emitting each token puts
/// half a stop marker on screen before anything notices. This holds back
/// any tail that could still grow into a stop string and releases it once
/// it cannot.
///
/// Most correctly-converted GGUFs mark their stop tokens as end-of-
/// generation, so llama.cpp halts on its own and this never fires. It
/// exists for the models where that metadata is wrong or missing.
class StopStringFilter {
  StopStringFilter(List<String> stopStrings)
    : _stops = stopStrings.where((s) => s.isNotEmpty).toList(growable: false);

  final List<String> _stops;
  final StringBuffer _pending = StringBuffer();

  bool _stopped = false;
  bool get stopped => _stopped;

  /// Feeds one token's text in and returns the portion safe to display.
  String add(String text) {
    if (_stopped) return '';
    if (_stops.isEmpty) return text;

    _pending.write(text);
    final buffer = _pending.toString();

    for (final stop in _stops) {
      final at = buffer.indexOf(stop);
      if (at >= 0) {
        _stopped = true;
        _pending.clear();
        return buffer.substring(0, at);
      }
    }

    // Hold back the longest suffix that is a prefix of some stop string;
    // it may yet complete on the next token.
    final hold = _longestPartialSuffix(buffer);
    final safe = buffer.substring(0, buffer.length - hold);
    _pending
      ..clear()
      ..write(buffer.substring(buffer.length - hold));
    return safe;
  }

  /// Releases anything still held back. Called when generation ends without
  /// a stop string, so a partial match that never completed is not lost.
  String flush() {
    final remaining = _stopped ? '' : _pending.toString();
    _pending.clear();
    return remaining;
  }

  int _longestPartialSuffix(String buffer) {
    var longest = 0;
    for (final stop in _stops) {
      final max = stop.length - 1 < buffer.length
          ? stop.length - 1
          : buffer.length;
      for (var len = max; len > longest; len--) {
        if (buffer.endsWith(stop.substring(0, len))) {
          longest = len;
          break;
        }
      }
    }
    return longest;
  }
}
