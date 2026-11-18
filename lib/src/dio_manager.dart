import 'package:dio/dio.dart';

import 'connectivity_interceptor.dart';
import 'network_config.dart';
import 'ports.dart';
import 'refresh_token_interceptor.dart';
import 'retry_interceptor.dart';

/// Builds the one kind of client the app uses.
///
/// Pass [sessionRefresher] for a client that sends the user's token: a 401
/// then renews the session and retries. Leave it out for a client that must
/// never renew — the token endpoint itself.
///
/// Pass [networkStatus] to fail requests at once while the device has no
/// network, [reachabilityObserver] to be told how each request finally
/// ended, and [serviceObserver] to be told when the server answers that it
/// cannot serve (a 5xx). `NetworkConfig.retryPolicy` decides which failures
/// are resent.
///
/// Interceptor order: Auth → RefreshToken → Retry → Connectivity →
/// ErrorHandler → Log.
abstract final class DioManager {
  static Dio createDio({
    required NetworkConfig config,
    required TokenStore tokenStore,
    required NetworkErrorConverter errorConverter,
    LocaleProvider? localeProvider,
    SessionRefresher? sessionRefresher,
    NetworkStatus? networkStatus,
    ReachabilityObserver? reachabilityObserver,
    ServiceObserver? serviceObserver,
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
      // After renewal: a 401 is renewed, not retried. Before the error
      // handler: a recovered request is never converted.
      if (config.retryPolicy.isEnabled)
        RetryInterceptor(dio: dio, policy: config.retryPolicy),
      // After Retry: its onError sees only a request's final outcome. Before
      // the error handler: a refusal is converted like any connection error.
      if (networkStatus != null ||
          reachabilityObserver != null ||
          serviceObserver != null)
        ConnectivityInterceptor(
          status: networkStatus,
          observer: reachabilityObserver,
          serviceObserver: serviceObserver,
        ),
      ErrorHandlerInterceptor(errorConverter),
      if (config.enableLogging)
        LogInterceptor(requestBody: true, responseBody: true),
    ]);

    return dio;
  }
}

/// Attaches the bearer token and `accept-language`, each only when present.
///
/// A resend reuses the first send's headers, so a token this interceptor
/// attached is removed once the store has none: a retry after sign-out must
/// not go out as the signed-out user. A caller's own `Authorization` is
/// left alone.
class AuthInterceptor extends Interceptor {
  AuthInterceptor({required this.tokenStore, this.localeProvider});

  final TokenStore tokenStore;
  final LocaleProvider? localeProvider;

  /// Set while the `Authorization` header is this interceptor's bearer.
  static const String _attachedKey = 'authTokenAttached';

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await tokenStore.readAccessToken();
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
      options.extra[_attachedKey] = true;
    } else if (options.extra.remove(_attachedKey) == true) {
      options.headers.remove('Authorization');
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
