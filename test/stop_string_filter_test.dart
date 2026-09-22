import 'package:enlibra_mobile/llama/stop_string_filter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feeds tokens through the filter and returns what a UI would have shown.
String run(StopStringFilter filter, List<String> tokens) {
  final out = StringBuffer();
  for (final t in tokens) {
    out.write(filter.add(t));
    if (filter.stopped) break;
  }
  out.write(filter.flush());
  return out.toString();
}

void main() {
  test('passes text through when there are no stop strings', () {
    final f = StopStringFilter([]);
    expect(run(f, ['Hello', ' ', 'world']), 'Hello world');
    expect(f.stopped, isFalse);
  });

  test('cuts at a stop string that arrives in one token', () {
    final f = StopStringFilter(['<|im_end|>']);
    expect(run(f, ['Hi there', '<|im_end|>', ' ignored']), 'Hi there');
    expect(f.stopped, isTrue);
  });

  test('cuts a stop string split across several tokens', () {
    // The case that makes this class necessary: a naive implementation
    // shows "<|" and "im" on screen before noticing.
    final f = StopStringFilter(['<|im_end|>']);
    expect(run(f, ['Done', '<|', 'im', '_end', '|>', ' after']), 'Done');
    expect(f.stopped, isTrue);
  });

  test('releases a partial match that turns out not to be one', () {
    final f = StopStringFilter(['<|im_end|>']);
    // "<|" looks like the start of the stop string, then resolves to
    // ordinary text and must not be swallowed.
    expect(run(f, ['a', '<|', 'b']), 'a<|b');
    expect(f.stopped, isFalse);
  });

  test('flush releases a dangling partial match at end of generation', () {
    final f = StopStringFilter(['<|im_end|>']);
    expect(run(f, ['text', '<|im']), 'text<|im');
    expect(f.stopped, isFalse);
  });

  test('handles several stop strings of different lengths', () {
    final f = StopStringFilter(['<|eot_id|>', '</s>']);
    expect(run(f, ['reply', '</', 's', '>', ' tail']), 'reply');
    expect(f.stopped, isTrue);
  });

  test('keeps text preceding a stop string inside the same token', () {
    final f = StopStringFilter(['<|im_end|>']);
    expect(run(f, ['answer<|im_end|>trailing']), 'answer');
    expect(f.stopped, isTrue);
  });

  test('emits nothing further once stopped', () {
    final f = StopStringFilter(['STOP']);
    f.add('before STOP');
    expect(f.stopped, isTrue);
    expect(f.add('more'), isEmpty);
    expect(f.flush(), isEmpty);
  });
}
