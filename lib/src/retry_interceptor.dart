import 'dart:math';

import 'package:dio/dio.dart';

import 'connectivity_interceptor.dart';
import 'retry_policy.dart';

/// Sends a request again after a failure a second attempt can fix: the
/// connection could not be opened, or a gateway said the server is briefly
/// unavailable. See [RetryPolicy] for what is never retried.
///
/// Resends through the same client (as `RefreshTokenInterceptor` does), so a
/// resend passes the connectivity gate again (a probe's resend is let
/// through), reads the current token, and gets one 401 renewal. Sits after `RefreshTokenInterceptor` (a 401 is
/// renewed, not retried) and before [ConnectivityInterceptor] and
/// `ErrorHandlerInterceptor` (only a request's final outcome is reported and
/// converted).
class RetryInterceptor extends Interceptor {
  RetryInterceptor({
    required this.dio,
    required this.policy,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? clock,
    Random? random,
  }) : _sleep = sleep ?? _delay,
       _clock = clock ?? DateTime.now,
       _random = random ?? Random();

  /// The client to resend through — the same one, so a resend gets every
  /// interceptor again.
  final Dio dio;
  final RetryPolicy policy;

  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _clock;
  final Random _random;

  /// true on a request's `extra`: never resend it (a GET that sends an OTP).
  static const String disableKey = 'retryDisabled';

  /// Set while this interceptor resends, so the resend's own failure is left
  /// to the loop that sent it (not retried or reported twice).
  static const String retryingKey = 'retryInProgress';

  /// When the logical request was first sent; the budget counts from here.
  static const String startedAtKey = 'retryStartedAt';

  /// Set once a request has had its retries, so a later pass through
  /// onError for the same logical request (a renewed 401 whose resend
  /// failed) does not start a second loop.
  static const String _doneKey = 'retryDone';

  /// Only the delta-seconds form; the HTTP-date form is not honoured.
  static final RegExp _seconds = RegExp(r'^\d+$');

  static Future<void> _delay(Duration duration) =>
      Future<void>.delayed(duration);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // A resend reuses these options, so the first send's time is kept.
    options.extra.putIfAbsent(startedAtKey, _clock);
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final request = err.requestOptions;
    final extra = request.extra;
    if (extra[retryingKey] == true ||
        extra[_doneKey] == true ||
        !_eligible(err)) {
      return handler.next(err);
    }

    extra[retryingKey] = true;
    var last = err;
    try {
      for (var retry = 1; retry <= policy.maxRetries; retry++) {
        final delay = _delayBefore(retry, last);
        if (delay == null ||
            _clock().difference(_startedAt(request)) + delay >
                policy.maxElapsed) {
          break;
        }

        // A caller that gives up during the wait must not get a resend.
        final token = request.cancelToken;
        await Future.any<void>([
          _sleep(delay),
          if (token != null) token.whenCancel,
        ]);
        if (token?.isCancelled ?? false) break;

        try {
          return handler.resolve(await dio.fetch<dynamic>(request));
        } on DioException catch (e) {
          last = e;
          // A refusal by the gate is final: the device has no network, and
          // waiting a second here would not bring it back.
          if (!_transient(e) ||
              extra[ConnectivityInterceptor.noNetworkKey] == true) {
            break;
          }
        }
      }
    } finally {
      extra.remove(retryingKey);
      extra[_doneKey] = true;
    }
    handler.next(last);
  }

  bool _eligible(DioException err) {
    final request = err.requestOptions;
    final header = policy.idempotencyHeader;
    final data = request.data;
    return policy.isEnabled &&
        request.extra[disableKey] != true &&
        request.extra[ConnectivityInterceptor.noNetworkKey] != true &&
        (policy.methods.contains(request.method.toUpperCase()) ||
            (header != null && _isKey(request.headers[header]))) &&
        // Sent once: a FormData cannot be finalised twice, a stream not
        // replayed.
        data is! FormData &&
        data is! Stream &&
        _transient(err);
  }

  /// Only a value the backend can de-duplicate on: dio drops a null header,
  /// and a blank one is no key. Anything but a string is not trusted either.
  static bool _isKey(Object? value) =>
      value is String && value.trim().isNotEmpty;

  /// A failure that says nothing about the request itself. Every timeout is
  /// left out (the server may be acting on it, and a retry would multiply
  /// the wait), as are `unknown` (TLS failures included), `badCertificate`
  /// and `cancel`.
  bool _transient(DioException e) => switch (e.type) {
    DioExceptionType.connectionError => true,
    DioExceptionType.badResponse => policy.statuses.contains(
      e.response?.statusCode,
    ),
    _ => false,
  };

  /// The wait before [retry], or null when the server asked for a longer
  /// pause than [RetryPolicy.maxDelay].
  Duration? _delayBefore(int retry, DioException last) {
    final response = last.response;
    if (response?.statusCode == 503) {
      final values = response!.headers['retry-after'];
      final value =
          values != null && values.length == 1 ? values.single.trim() : null;
      if (value != null && _seconds.hasMatch(value)) {
        // Compared in whole seconds, so a huge value cannot overflow a
        // Duration; too many digits to parse is a very long pause too.
        final seconds = int.tryParse(value);
        if (seconds == null || seconds > policy.maxDelay.inSeconds) {
          return null;
        }
        return Duration(seconds: seconds);
      }
    }
    return policy.delayFor(retry, _random);
  }

  DateTime _startedAt(RequestOptions request) {
    final startedAt = request.extra[startedAtKey];
    return startedAt is DateTime ? startedAt : _clock();
  }
}
