import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:app_network/app_network.dart';
import 'package:dio/dio.dart';

/// What the fake server does with one request.
typedef Reply = ResponseBody Function(RequestOptions request);

/// Answers with [code] and, optionally, extra [headers].
Reply status(int code, {Map<String, List<String>> headers = const {}}) =>
    (_) => ResponseBody.fromString(
      jsonEncode({'status': code}),
      code,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...headers,
      },
    );

/// Fails at the transport level with [type]. A real adapter throws the
/// `DioException` itself; a raw exception would arrive as `unknown`.
Reply failWith(DioExceptionType type) =>
    (request) => throw DioException(requestOptions: request, type: type);

/// Plays [script] one reply per request, then repeats the last reply.
class ScriptedServer implements HttpClientAdapter {
  ScriptedServer(List<Reply> script) : _script = [...script];

  final List<Reply> _script;

  /// The `Authorization` header of each request, in the order received.
  /// Recorded as sent: a resend reuses, and changes, the same options.
  final List<Object?> sentTokens = [];

  /// Runs as each request arrives, before the reply (to move a clock, say).
  void Function()? onFetch;

  /// The options of the latest request: every resend shares them.
  RequestOptions? lastRequest;

  int get calls => sentTokens.length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    sentTokens.add(options.headers['Authorization']);
    lastRequest = options;
    onFetch?.call();
    final reply = _script.length > 1 ? _script.removeAt(0) : _script.first;
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

/// What [StubConverter] made of a failure.
class Converted {
  const Converted(this.type, this.statusCode, this.cause);

  final DioExceptionType type;
  final int? statusCode;
  final Object? cause;
}

class StubConverter implements NetworkErrorConverter {
  const StubConverter();

  @override
  Object convert(DioException error) =>
      Converted(error.type, error.response?.statusCode, error.error);
}

class Tokens implements TokenStore {
  Tokens(this.token);

  String? token;

  @override
  Future<String?> readAccessToken() async => token;
}

class Refresher implements SessionRefresher {
  Refresher(this.onRefresh);

  final Future<String?> Function() onRefresh;
  int calls = 0;

  @override
  Future<String?> refreshAccessToken() {
    calls++;
    return onRefresh();
  }
}

class FakeNetworkStatus implements NetworkStatus {
  FakeNetworkStatus(this.answer);

  Future<bool> Function() answer;
  int calls = 0;

  @override
  Future<bool> hasNetwork() {
    calls++;
    return answer();
  }
}

class RecordingObserver implements ReachabilityObserver {
  final List<String> verdicts = [];

  @override
  void onReachable() => verdicts.add('reachable');

  @override
  void onUnreachable() => verdicts.add('unreachable');
}

class RecordingServiceObserver implements ServiceObserver {
  final List<String> verdicts = [];

  @override
  void onServiceAvailable() => verdicts.add('available');

  @override
  void onServiceUnavailable() => verdicts.add('unavailable');
}

/// Always the middle of the jitter range: delays come out exact.
class FixedRandom implements Random {
  const FixedRandom([this.value = 0.5]);

  final double value;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;
}

class FakeClock {
  DateTime now = DateTime.utc(2026, 1, 1);

  DateTime call() => now;

  void advance(Duration by) => now = now.add(by);
}

/// A client in `DioManager`'s order, with every seam injectable. By default
/// retries do not wait: [sleep] returns at once.
Dio client(
  ScriptedServer server, {
  RetryPolicy policy = const RetryPolicy(),
  Future<void> Function(Duration)? sleep,
  DateTime Function()? clock,
  Random random = const FixedRandom(),
  Tokens? tokens,
  SessionRefresher? refresher,
  NetworkStatus? status,
  ReachabilityObserver? observer,
  ServiceObserver? serviceObserver,
}) {
  final tokenStore = tokens ?? Tokens('token');
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  dio.interceptors.addAll([
    AuthInterceptor(tokenStore: tokenStore),
    if (refresher != null)
      RefreshTokenInterceptor(
        dio: dio,
        tokenStore: tokenStore,
        sessionRefresher: refresher,
      ),
    if (policy.isEnabled)
      RetryInterceptor(
        dio: dio,
        policy: policy,
        sleep: sleep ?? (_) async {},
        clock: clock,
        random: random,
      ),
    if (status != null || observer != null || serviceObserver != null)
      ConnectivityInterceptor(
        status: status,
        observer: observer,
        serviceObserver: serviceObserver,
        clock: clock,
      ),
    ErrorHandlerInterceptor(const StubConverter()),
  ]);
  return dio..httpClientAdapter = server;
}

/// The `DioException` a request ended with; throws if it succeeded.
Future<DioException> failureOf(Future<Object?> request) async {
  try {
    await request;
  } on DioException catch (e) {
    return e;
  }
  throw StateError('The request succeeded.');
}
