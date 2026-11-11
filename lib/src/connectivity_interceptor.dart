import 'package:dio/dio.dart';

import 'ports.dart';
import 'retry_interceptor.dart';

/// Carried on the connectionError of a request this client did not send
/// because the device has no network. ErrorHandlerInterceptor replaces it
/// with the converter's output (FailureType.network).
class NoNetworkException implements Exception {
  const NoNetworkException();

  @override
  String toString() =>
      'NoNetworkException: the device has no network connection.';
}

/// Fails a request at once when the device has no network, and tells
/// [observer] how each request finally ended.
///
/// Fail-open: an unanswered or failing [status] means "send". While the
/// device keeps reporting no network, one request per [probeInterval] is
/// sent anyway, so a wrong platform reading cannot block traffic forever;
/// the real outcome then corrects the reading. The probe's own resends (a
/// retry, a renewed 401) pass too, so that outcome is its final one.
///
/// Sits after [RetryInterceptor], so its onError sees only a request's final
/// outcome, and before `ErrorHandlerInterceptor`, which converts a refusal
/// like any other connection error.
class ConnectivityInterceptor extends Interceptor {
  ConnectivityInterceptor({
    this.status,
    this.observer,
    this.probeInterval = const Duration(seconds: 10),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final NetworkStatus? status;
  final ReachabilityObserver? observer;
  final Duration probeInterval;

  final DateTime Function() _clock;

  /// true on a request's `extra`: send it even when there is no network.
  static const String skipKey = 'connectivitySkip';

  /// Set on a request this gate refused.
  static const String noNetworkKey = 'connectivityRefused';

  /// Set once a request's outcome was reported: one verdict per request.
  static const String _reportedKey = 'connectivityReported';

  /// Set on the request a probe let through. Its resends reuse the same
  /// options, so they pass without using up the next window: refusing them
  /// would replace the probe's real answer with "no network".
  static const String _probeKey = 'connectivityProbe';

  /// How long [status] may take; no answer by then counts as "send".
  static const Duration _checkTimeout = Duration(seconds: 1);

  DateTime? _nextProbeAt;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra[skipKey] == true || options.extra[_probeKey] == true) {
      return handler.next(options);
    }

    if (await _hasNetwork()) {
      options.extra.remove(noNetworkKey);
      _nextProbeAt = null;
      return handler.next(options);
    }

    final now = _clock();
    final probeAt = _nextProbeAt;
    if (probeAt != null && !now.isBefore(probeAt)) {
      // The probe: only a real request can prove the reading wrong.
      _nextProbeAt = now.add(probeInterval);
      options.extra.remove(noNetworkKey);
      options.extra[_probeKey] = true;
      return handler.next(options);
    }

    _nextProbeAt ??= now.add(probeInterval);
    options.extra[noNetworkKey] = true;
    // `true` is required: on a plain request-phase reject dio skips every
    // error interceptor, and the error handler would never convert this.
    handler.reject(
      DioException.connectionError(
        requestOptions: options,
        reason: 'The device has no network connection.',
        error: const NoNetworkException(),
      ),
      true,
    );
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final extra = response.requestOptions.extra;
    if (extra[_reportedKey] != true) {
      extra[_reportedKey] = true;
      _report((observer) => observer.onReachable());
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final extra = err.requestOptions.extra;
    if (extra[noNetworkKey] != true &&
        extra[RetryInterceptor.retryingKey] != true &&
        extra[_reportedKey] != true) {
      if (err.response != null) {
        extra[_reportedKey] = true;
        _report((observer) => observer.onReachable());
      } else if (err.type == DioExceptionType.connectionError ||
          err.type == DioExceptionType.connectionTimeout) {
        extra[_reportedKey] = true;
        _report((observer) => observer.onUnreachable());
      }
      // Anything else says nothing about reachability: a receive, send or
      // transform timeout, `unknown` (TLS included), cancel, bad certificate.
    }
    handler.next(err);
  }

  Future<bool> _hasNetwork() async {
    final status = this.status;
    if (status == null) return true;
    try {
      return await status.hasNetwork().timeout(
        _checkTimeout,
        onTimeout: () => true,
      );
    } catch (_) {
      return true;
    }
  }

  /// The verdict is advisory: an observer that throws must not turn the
  /// request's own outcome into a different failure.
  void _report(void Function(ReachabilityObserver observer) verdict) {
    final observer = this.observer;
    if (observer == null) return;
    try {
      verdict(observer);
    } catch (_) {
      // Ignored: a missed verdict is corrected by the next request.
    }
  }
}
