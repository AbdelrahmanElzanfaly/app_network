import 'package:dio/dio.dart';

/// Where the client reads the bearer token from.
///
/// Implemented by the app's session storage. Read on every request, so a
/// sign-out takes effect on the very next call.
abstract interface class TokenStore {
  Future<String?> readAccessToken();
}

/// The language tag sent as `accept-language`, or null to send none.
abstract interface class LocaleProvider {
  String? currentLanguageTag();
}

/// Turns a transport failure into the app's own error type.
///
/// The result is placed on [DioException.error], so a caller that catches the
/// `DioException` still finds the converted error there.
abstract interface class NetworkErrorConverter {
  Object convert(DioException error);
}

/// Renews the session after the server rejects a token with 401.
///
/// Implemented by the app's session owner, which decides how many attempts
/// to make and ends the session when it cannot be renewed.
abstract interface class SessionRefresher {
  /// A new access token, or null when the session could not be renewed and
  /// has been ended. Throws when renewal failed but the session was kept
  /// (no network, say): the request then fails with that error instead.
  ///
  /// Concurrent callers must share one renewal: refresh tokens are often
  /// single-use, and a second parallel renewal would invalidate the first.
  Future<String?> refreshAccessToken();
}
