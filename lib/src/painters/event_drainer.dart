/// Default per-call cap for [drainPolls]. The matching C++-side
/// `riveThreadedPollEvents` binding truncates at this same limit per call;
/// the drain loop keeps polling until a non-full batch arrives so any
/// queue depth surfaces in full.
const int kDefaultPollCap = 128;

/// Repeatedly invokes [poll] with [maxEvents] until a batch shorter than
/// [maxEvents] arrives, accumulating every returned event.
///
/// The poll callback is expected to return at most [maxEvents] entries per
/// call; a return of exactly [maxEvents] is treated as "more may be queued"
/// and triggers another call.
///
/// Pure-Dart helper with no FFI dependency so it can be exercised in a
/// `flutter_test` unit test without loading the native library.
List<T> drainPolls<T>({
  required List<T> Function(int maxEvents) poll,
  int maxEvents = kDefaultPollCap,
}) {
  final all = <T>[];
  while (true) {
    final batch = poll(maxEvents);
    all.addAll(batch);
    if (batch.length < maxEvents) break;
  }
  return all;
}
