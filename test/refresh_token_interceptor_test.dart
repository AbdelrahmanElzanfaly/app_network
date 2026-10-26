import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:app_network/app_network.dart';
import 'package:test/test.dart';

/// A server that accepts exactly one token, and records what it was sent.
class _FakeServer implements HttpClientAdapter {
  _FakeServer({required this.validToken, this.status});

  String validToken;

  /// Forces this status for every request, whatever the token.
  int? status;

  final List<String?> sentTokens = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final auth = options.headers['Authorization'] as String?;
    sentTokens.add(auth);
    final code = status ?? (auth == 'Bearer $validToken' ? 200 : 401);
    return ResponseBody.fromString(
      jsonEncode({'ok': code == 200}),
      code,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Hands out queued tokens one read at a time, then repeats the last.
class _Tokens implements TokenStore {
  _Tokens(this._queue);

  final List<String?> _queue;

  @override
  Future<String?> readAccessToken() async =>
      _queue.length > 1 ? _queue.removeAt(0) : _queue.first;

  void set(String token) => _queue
    ..clear()
    ..add(token);
}

class _Refresher implements SessionRefresher {
  _Refresher(this.onRefresh);

  final Future<String?> Function() onRefresh;
  int calls = 0;

  @override
  Future<String?> refreshAccessToken() {
    calls++;
    return onRefresh();
  }
}

class _Converted {
  const _Converted(this.statusCode, this.cause);

  final int? statusCode;
  final Object? cause;
}

class _Converter implements NetworkErrorConverter {
  @override
  Object convert(DioException error) =>
      _Converted(error.response?.statusCode, error.error);
}

Dio _client(_FakeServer server, _Tokens tokens, _Refresher refresher) =>
    DioManager.createDio(
        config: const NetworkConfig(baseUrl: 'https://api.test'),
        tokenStore: tokens,
        errorConverter: _Converter(),
        sessionRefresher: refresher,
      )
      ..httpClientAdapter = server;

void main() {
  test('401 renews, retries, and the caller only sees the 200', () async {
    final server = _FakeServer(validToken: 'new');
    final tokens = _Tokens(['old']);
    final refresher = _Refresher(() async {
      tokens.set('new');
      return 'new';
    });

    final response = await _client(server, tokens, refresher).get<void>('/x');

    expect(response.statusCode, 200);
    expect(refresher.calls, 1);
    expect(server.sentTokens, ['Bearer old', 'Bearer new']);
  });

  test('session ended: the original 401 reaches the caller', () async {
    final server = _FakeServer(validToken: 'new');
    final refresher = _Refresher(() async => null);

    final error = await _client(
      server,
      _Tokens(['old']),
      refresher,
    ).get<void>('/x').then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<DioException>());
    final converted = (error! as DioException).error! as _Converted;
    expect(converted.statusCode, 401);
    expect(server.sentTokens, hasLength(1));
  });

  test('renewal failed but session kept: the caller gets that failure, '
      'not the 401', () async {
    final server = _FakeServer(validToken: 'new');
    const offline = 'no connection';
    final refresher = _Refresher(() async => throw offline);

    final error = await _client(
      server,
      _Tokens(['old']),
      refresher,
    ).get<void>('/x').then<Object?>((_) => null, onError: (Object e) => e);

    final converted = (error! as DioException).error! as _Converted;
    expect(converted.statusCode, isNull);
    expect(converted.cause, offline);
  });

  test('a 401 on the retry is passed on, with no second renewal', () async {
    final server = _FakeServer(validToken: 'never-issued');
    final tokens = _Tokens(['old']);
    final refresher = _Refresher(() async {
      tokens.set('new');
      return 'new';
    });

    await expectLater(
      _client(server, tokens, refresher).get<void>('/x'),
      throwsA(isA<DioException>()),
    );
    expect(refresher.calls, 1);
    expect(server.sentTokens, ['Bearer old', 'Bearer new']);
  });

  test('a token renewed meanwhile by another request is reused, '
      'not renewed again', () async {
    final server = _FakeServer(validToken: 'new');
    // Sent with 'old'; by the time the 401 is handled, the store has 'new'.
    final tokens = _Tokens(['old', 'new']);
    final refresher = _Refresher(() async => fail('should not renew'));

    final response = await _client(server, tokens, refresher).get<void>('/x');

    expect(response.statusCode, 200);
    expect(refresher.calls, 0);
  });

  test('other failures do not renew', () async {
    final server = _FakeServer(validToken: 'old', status: 500);
    final refresher = _Refresher(() async => fail('should not renew'));

    await expectLater(
      _client(server, _Tokens(['old']), refresher).get<void>('/x'),
      throwsA(isA<DioException>()),
    );
    expect(refresher.calls, 0);
  });
}
