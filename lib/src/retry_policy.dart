import 'dart:math';

/// Which failed requests are sent again, how often, and after how long.
///
/// Conservative on purpose: in a banking API a write can move money, and a
/// "connection error" can arrive after the server already acted. So only
/// safe methods are retried, and only for failures that say nothing about
/// the request itself.
class RetryPolicy {
  const RetryPolicy({
    this.maxRetries = 2,
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 4),
    this.maxElapsed = const Duration(seconds: 10),
    this.jitter = 0.25,
    this.methods = const {'GET', 'HEAD', 'OPTIONS'},
    this.statuses = const {502, 503, 504},
    this.idempotencyHeader,
  }) : assert(maxRetries >= 0),
       assert(jitter >= 0 && jitter <= 1);

  /// Never retries. The package default: a client opts in.
  static const RetryPolicy none = RetryPolicy(maxRetries: 0);

  /// Resends after the first attempt; 0 turns retrying off.
  final int maxRetries;

  /// The wait before the first resend; each later one doubles it.
  final Duration baseDelay;

  /// Also the longest `Retry-After` honoured; a longer one means "do not retry".
  final Duration maxDelay;

  /// No retry starts later than this after the first send, so a spinner
  /// cannot grow without bound.
  final Duration maxElapsed;

  /// ±fraction applied to each delay, so clients do not retry in lockstep.
  final double jitter;

  /// The safe methods, in upper case: sending them twice changes nothing.
  final Set<String> methods;

  /// Gateway answers meaning "briefly unavailable, the request was not
  /// handled". A plain 500 is left out: the server may have acted on it.
  final Set<int> statuses;

  /// A request whose method is not in [methods] is retried only when it
  /// carries a non-blank string value of this header — the backend's
  /// idempotency key. Null (default):
  /// writes are never retried. Set it only once the backend de-duplicates
  /// by that header.
  final String? idempotencyHeader;

  bool get isEnabled => maxRetries > 0;

  /// baseDelay * 2^(retry-1), capped at [maxDelay], spread by ±[jitter].
  Duration delayFor(int retry, Random random) {
    final base = baseDelay * pow(2, retry - 1).toDouble();
    final capped = base > maxDelay ? maxDelay : base;
    final factor = 1 + jitter * (random.nextDouble() * 2 - 1);
    return capped * factor;
  }
}
