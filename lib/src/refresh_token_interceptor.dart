import 'package:dio/dio.dart';

import 'ports.dart';

/// Turns a 401 into a renewal and a silent retry.
///
/// The failed request is held — its caller keeps waiting, so a loading
/// indicator stays up — while [SessionRefresher] renews the session. Then:
///
/// * renewed: the same request is sent again with the new token, and the
///   caller receives that response as if nothing had happened;
/// * session ended: the original 401 is passed on, and the router guard
///   takes the user to login;
/// * renewal failed but the session was kept: the request fails with the
///   renewal's error (no connection, say) instead of the 401.
///
/// Must sit before `ErrorHandlerInterceptor`, so it sees the raw 401 and a
/// successful retry never reaches the error converter.
class RefreshTokenInterceptor extends Interceptor {
  RefreshTokenInterceptor({
    required this.dio,
    required this.tokenStore,
    required this.sessionRefresher,
  });

  /// The client to resend through — the same one, so the retry gets every
  /// interceptor again, including the fresh `Authorization` header.
  final Dio dio;
  final TokenStore tokenStore;
  final SessionRefresher sessionRefresher;

  /// Set on a resent request, so a second 401 is passed on instead of
  /// renewing again in a loop.
  static const String retriedKey = 'tokenRefreshRetried';

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final request = err.requestOptions;
    if (err.response?.statusCode != 401 || request.extra[retriedKey] == true) {
      return handler.next(err);
    }

    // Another request may have renewed the session while this one was in
    // flight. Then the token it was sent with is already stale, and retrying
    // with the current one is enough — no second renewal.
    final current = await tokenStore.readAccessToken();
    final sentWith = request.headers['Authorization'];
    final String? token;
    try {
      token = current != null && sentWith != 'Bearer $current'
          ? current
          : await sessionRefresher.refreshAccessToken();
    } catch (renewalError) {
      return handler.next(
        DioException(
          requestOptions: request,
          error: renewalError,
          message: 'The session could not be renewed.',
        ),
      );
    }

    if (token == null) return handler.next(err);

    try {
      final retry = request
        ..headers['Authorization'] = 'Bearer $token'
        ..extra[retriedKey] = true;
      handler.resolve(await dio.fetch<dynamic>(retry));
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }
}
