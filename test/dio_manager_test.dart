import 'package:app_network/app_network.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

Dio _create({
  NetworkConfig config = const NetworkConfig(baseUrl: 'https://api.test'),
  SessionRefresher? sessionRefresher,
  NetworkStatus? networkStatus,
  ReachabilityObserver? reachabilityObserver,
}) => DioManager.createDio(
  config: config,
  tokenStore: Tokens('token'),
  errorConverter: const StubConverter(),
  sessionRefresher: sessionRefresher,
  networkStatus: networkStatus,
  reachabilityObserver: reachabilityObserver,
);

/// The interceptors this package adds, in order; dio's own built-in ones
/// come first and are left out.
List<Type> _types(Dio dio) =>
    dio.interceptors
        .skipWhile((interceptor) => interceptor is! AuthInterceptor)
        .map((interceptor) => interceptor.runtimeType)
        .toList();

void main() {
  group('interceptor order', () {
    final refresher = Refresher(() async => 'new');
    final network = FakeNetworkStatus(() async => true);

    test('Auth, RefreshToken, Retry, Connectivity, ErrorHandler', () {
      final dio = _create(
        config: const NetworkConfig(
          baseUrl: 'https://api.test',
          retryPolicy: RetryPolicy(),
        ),
        sessionRefresher: refresher,
        networkStatus: network,
        reachabilityObserver: RecordingObserver(),
      );

      expect(_types(dio), [
        AuthInterceptor,
        RefreshTokenInterceptor,
        RetryInterceptor,
        ConnectivityInterceptor,
        ErrorHandlerInterceptor,
      ]);
    });

    test('logging comes last', () {
      final dio = _create(
        config: const NetworkConfig(
          baseUrl: 'https://api.test',
          enableLogging: true,
          retryPolicy: RetryPolicy(),
        ),
        sessionRefresher: refresher,
        networkStatus: network,
      );

      expect(_types(dio), [
        AuthInterceptor,
        RefreshTokenInterceptor,
        RetryInterceptor,
        ConnectivityInterceptor,
        ErrorHandlerInterceptor,
        LogInterceptor,
      ]);
    });

    test('RetryPolicy.none (the default) leaves out Retry', () {
      final dio = _create(networkStatus: network);

      expect(_types(dio), [
        AuthInterceptor,
        ConnectivityInterceptor,
        ErrorHandlerInterceptor,
      ]);
    });

    test('no status and no observer leave out Connectivity', () {
      final dio = _create(
        config: const NetworkConfig(
          baseUrl: 'https://api.test',
          retryPolicy: RetryPolicy(),
        ),
      );

      expect(_types(dio), [
        AuthInterceptor,
        RetryInterceptor,
        ErrorHandlerInterceptor,
      ]);
    });

    test('an observer alone adds Connectivity', () {
      final dio = _create(reachabilityObserver: RecordingObserver());

      expect(_types(dio), contains(ConnectivityInterceptor));
    });
  });

  group('NetworkConfig', () {
    test('the package defaults are unchanged', () {
      const config = NetworkConfig(baseUrl: 'https://api.test');

      expect(NetworkConfig.defaultTimeout, const Duration(seconds: 30));
      expect(config.connectTimeout, NetworkConfig.defaultTimeout);
      expect(config.receiveTimeout, NetworkConfig.defaultTimeout);
      expect(config.retryPolicy, same(RetryPolicy.none));
      expect(config.retryPolicy.isEnabled, isFalse);
    });

    test('the recommended connect timeout is 10 s, and the client uses the '
        'configured timeouts', () {
      final dio = _create(
        config: const NetworkConfig(
          baseUrl: 'https://api.test',
          connectTimeout: NetworkConfig.recommendedConnectTimeout,
        ),
      );

      expect(
        NetworkConfig.recommendedConnectTimeout,
        const Duration(seconds: 10),
      );
      expect(dio.options.connectTimeout, const Duration(seconds: 10));
      expect(dio.options.receiveTimeout, NetworkConfig.defaultTimeout);
    });
  });

  group('the built client', () {
    test('no network: refused, converted to a connection error, with no '
        'verdict and no send', () async {
      final server = ScriptedServer([status(200)]);
      final observer = RecordingObserver();
      final dio = _create(
        config: const NetworkConfig(
          baseUrl: 'https://api.test',
          retryPolicy: RetryPolicy(),
        ),
        networkStatus: FakeNetworkStatus(() async => false),
        reachabilityObserver: observer,
      )..httpClientAdapter = server;

      final error = await failureOf(dio.get<void>('/x'));

      expect(server.calls, 0);
      expect(error.type, DioExceptionType.connectionError);
      expect((error.error! as Converted).cause, isA<NoNetworkException>());
      expect(observer.verdicts, isEmpty);
    });

    test('a GET that never connects is retried, then reported '
        'unreachable once', () async {
      final server = ScriptedServer([
        failWith(DioExceptionType.connectionError),
      ]);
      final observer = RecordingObserver();
      final dio = _create(
        // No waiting between attempts, to keep the test fast.
        config: const NetworkConfig(
          baseUrl: 'https://api.test',
          retryPolicy: RetryPolicy(baseDelay: Duration.zero),
        ),
        networkStatus: FakeNetworkStatus(() async => true),
        reachabilityObserver: observer,
      )..httpClientAdapter = server;

      final error = await failureOf(dio.get<void>('/x'));

      expect(server.calls, 3);
      expect(error.error, isA<Converted>());
      expect(observer.verdicts, ['unreachable']);
    });
  });
}
