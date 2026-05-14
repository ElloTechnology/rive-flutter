import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:rive/src/painters/event_drainer.dart';

/// Regression test for the silent-drop in `riveThreadedPollEvents`.
///
/// The pre-Phase-5 wrapper polled with `maxEvents: 32` once per frame; any
/// queue depth past 32 was truncated by the C++-side `std::min(events.size(),
/// maxEvents)` and never surfaced to Dart. The fix is to (a) bump the per-call
/// cap to 128 and (b) drain in a loop until a non-full batch arrives. Both
/// pieces are required — the cap alone leaves a silent-drop window at exactly
/// the cap boundary.
void main() {
  group('drainPolls', () {
    test('returns all events when queue fits in a single batch', () {
      final queue = List<int>.generate(50, (i) => i);
      final all = drainPolls<int>(
        poll: (n) {
          final batch = queue.take(n).toList();
          queue.removeRange(0, batch.length);
          return batch;
        },
        maxEvents: 128,
      );
      expect(all.length, 50);
      expect(all.first, 0);
      expect(all.last, 49);
    });

    test('drains all events when queue exceeds the per-call cap', () {
      // 300 events > 128 cap forces the loop to call poll three times
      // (128 + 128 + 44).
      final queue = List<int>.generate(300, (i) => i);
      var callCount = 0;
      final all = drainPolls<int>(
        poll: (n) {
          callCount++;
          final batch = queue.take(n).toList();
          queue.removeRange(0, batch.length);
          return batch;
        },
        maxEvents: 128,
      );
      expect(callCount, 3);
      expect(all.length, 300);
      expect(all.first, 0);
      expect(all.last, 299);
    });

    test('forces an extra poll when a batch lands exactly at the cap', () {
      // Exactly 128 events: first poll returns a full batch, drainer must
      // call again to confirm the queue is empty. This is the boundary the
      // pre-Phase-5 caller silently corrupted.
      final queue = List<int>.generate(128, (i) => i);
      var callCount = 0;
      final all = drainPolls<int>(
        poll: (n) {
          callCount++;
          final batch = queue.take(n).toList();
          queue.removeRange(0, batch.length);
          return batch;
        },
        maxEvents: 128,
      );
      expect(callCount, 2);
      expect(all.length, 128);
    });

    test('returns empty when the queue is empty on first poll', () {
      var callCount = 0;
      final all = drainPolls<int>(
        poll: (n) {
          callCount++;
          return const <int>[];
        },
        maxEvents: 128,
      );
      expect(callCount, 1);
      expect(all, isEmpty);
    });

    test('uses kDefaultPollCap when maxEvents is omitted', () {
      var seenCap = -1;
      drainPolls<int>(poll: (n) {
        seenCap = n;
        return const <int>[];
      });
      expect(seenCap, kDefaultPollCap);
      expect(kDefaultPollCap, 128);
    });

    test('honours maxIterations and fires onCapHit', () {
      // poll always returns a full batch of `n` → drainer would loop forever
      // without the iteration cap. Assert the cap stops it and the callback
      // surfaces the saturation.
      var pollCount = 0;
      var capHitWith = -1;
      drainPolls<int>(
        poll: (n) {
          pollCount++;
          return List<int>.generate(n, (i) => i);
        },
        maxEvents: 4,
        maxIterations: 3,
        onCapHit: (n) => capHitWith = n,
      );
      expect(pollCount, 3);
      expect(capHitWith, 4);
    });

    test('does not fire onCapHit if drain completes within maxIterations', () {
      var capHits = 0;
      drainPolls<int>(
        poll: (n) {
          // returns less-than-cap on first call → loop exits naturally
          return const [1, 2, 3];
        },
        maxEvents: 128,
        onCapHit: (_) => capHits++,
      );
      expect(capHits, 0);
    });
  });
}
