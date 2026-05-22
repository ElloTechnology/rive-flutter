/// Default per-call cap for [drainPolls]. The matching C++-side
/// `riveThreadedPollEvents` binding truncates at this same limit per call;
/// the drain loop keeps polling until a non-full batch arrives so any
/// queue depth surfaces in full.
const int kDefaultPollCap = 128;

/// Upper bound on drain iterations. With [kDefaultPollCap] = 128 this caps
/// any single drain at 128 × 8 = 1024 events / frame — well beyond plausible
/// state-machine output and below the threshold where the spin would freeze
/// the UI. Hitting it indicates a pathological event-production rate or a
/// stuck queue; [onCapHit] surfaces it to the caller for logging.
const int kMaxDrainIterations = 8;

/// Repeatedly invokes [poll] with [maxEvents] until a batch shorter than
/// [maxEvents] arrives, accumulating every returned event.
///
/// The poll callback is expected to return at most [maxEvents] entries per
/// call; a return of exactly [maxEvents] is treated as "more may be queued"
/// and triggers another call.
///
/// Bounded by [maxIterations] full batches (defaults to [kMaxDrainIterations])
/// to guarantee the loop terminates even under pathological event-production
/// rates. When the cap is hit, [onCapHit] is invoked with [maxEvents] so the
/// caller can log; the function still returns the accumulated batches.
///
/// Pure-Dart helper with no FFI dependency so it can be exercised in a
/// `flutter_test` unit test without loading the native library.
List<T> drainPolls<T>({
  required List<T> Function(int maxEvents) poll,
  int maxEvents = kDefaultPollCap,
  int maxIterations = kMaxDrainIterations,
  void Function(int maxEvents)? onCapHit,
}) {
  final all = <T>[];
  for (var i = 0; i < maxIterations; i++) {
    final batch = poll(maxEvents);
    all.addAll(batch);
    if (batch.length < maxEvents) return all;
  }
  onCapHit?.call(maxEvents);
  return all;
}
