import 'package:dio/dio.dart';

import 'network_config.dart';
import 'ports.dart';
import 'refresh_token_interceptor.dart';

/// Builds the one kind of client the app uses.
///
/// Pass [sessionRefresher] for a client that sends the user's token: a 401
/// then renews the session and retries. Leave it out for a client that must
/// never renew — the token endpoint itself.
abstract final class DioManager {
  static Dio createDio({
    required NetworkConfig config,
    required TokenStore tokenStore,
    required NetworkErrorConverter errorConverter,
    LocaleProvider? localeProvider,
    SessionRefresher? sessionRefresher,
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: config.baseUrl,
        connectTimeout: config.connectTimeout,
        receiveTimeout: config.receiveTimeout,
        headers: {'Accept': 'application/json', ...config.headers},
      ),
    );

    dio.interceptors.addAll([
      AuthInterceptor(tokenStore: tokenStore, localeProvider: localeProvider),
      // Before the error handler: it needs the raw 401, and a successful
      // retry must not be converted into an error.
      if (sessionRefresher != null)
        RefreshTokenInterceptor(
          dio: dio,
          tokenStore: tokenStore,
          sessionRefresher: sessionRefresher,
        ),
      ErrorHandlerInterceptor(errorConverter),
      if (config.enableLogging)
        LogInterceptor(requestBody: true, responseBody: true),
    ]);

    return dio;
  }
}

/// Attaches the bearer token and `accept-language`, each only when present.
class AuthInterceptor extends Interceptor {
  AuthInterceptor({required this.tokenStore, this.localeProvider});

  final TokenStore tokenStore;
  final LocaleProvider? localeProvider;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await tokenStore.readAccessToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }

    final language = localeProvider?.currentLanguageTag();
    if (language != null && language.isNotEmpty) {
      options.headers['accept-language'] = language;
    }

    handler.next(options);
  }
}

/// Puts the converted error on [DioException.error] and passes it on.
class ErrorHandlerInterceptor extends Interceptor {
  ErrorHandlerInterceptor(this.converter);

  final NetworkErrorConverter converter;

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) =>
      handler.next(err.copyWith(error: converter.convert(err)));
}
