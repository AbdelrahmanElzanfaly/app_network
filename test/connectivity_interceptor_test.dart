import 'dart:async';
import 'dart:io';

import 'package:app_network/app_network.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

const _connectionError = DioExceptionType.connectionError;

class _ThrowingObserver implements ReachabilityObserver {
  @override
  void onReachable() => throw StateError('observer failed');

  @override
  void onUnreachable() => throw StateError('observer failed');
}

class _ThrowingServiceObserver implements ServiceObserver {
  @override
  void onServiceAvailable() => throw StateError('observer failed');

  @override
  void onServiceUnavailable() => throw StateError('observer failed');
}

void main() {
  group('the gate', () {
    test('no network: refused before sending, converted, not reported and '
        'not retried', () async {
      final server = ScriptedServer([status(200)]);
      final network = FakeNetworkStatus(() async => false);
      final observer = RecordingObserver();

      final error = await failureOf(
        client(server, status: network, observer: observer).get<void>('/x'),
      );

      expect(server.calls, 0);
      expect(error.type, _connectionError);
      // Converted, so the refusal went through every error interceptor:
      // only `reject(err, true)` does that from the request phase.
      final converted = error.error! as Converted;
      expect(converted.cause, isA<NoNetworkException>());
      expect(
        error.requestOptions.extra[ConnectivityInterceptor.noNetworkKey],
        isTrue,
      );
      expect(observer.verdicts, isEmpty);
      // A retry would have asked the gate again.
      expect(network.calls, 1);
    });

    test('a retry the gate refuses ends the retries', () async {
      final server = ScriptedServer([failWith(_connectionError)]);
      final observer = RecordingObserver();
      // The first send gets through; the network is gone before the retry.
      final answers = [true, false];
      final network = FakeNetworkStatus(() async => answers.removeAt(0));

      final error = await failureOf(
        client(server, status: network, observer: observer).get<void>('/x'),
      );

      expect(server.calls, 1);
      expect(network.calls, 2);
      expect(error.type, _connectionError);
      expect(
        error.requestOptions.extra[ConnectivityInterceptor.noNetworkKey],
        isTrue,
      );
      expect(observer.verdicts, isEmpty);
    });

    test('skipKey sends the request without asking', () async {
      final server = ScriptedServer([status(200)]);
      final network = FakeNetworkStatus(() async => false);

      final response = await client(server, status: network).get<void>(
        '/x',
        options: Options(extra: {ConnectivityInterceptor.skipKey: true}),
      );

      expect(response.statusCode, 200);
      expect(network.calls, 0);
    });

    test('while there is no network, one request per probe interval is '
        'sent anyway', () async {
      final clock = FakeClock();
      final server = ScriptedServer([status(200)]);
      final dio = client(
        server,
        status: FakeNetworkStatus(() async => false),
        clock: clock.call,
      );

      await failureOf(dio.get<void>('/x'));
      clock.advance(const Duration(seconds: 5));
      await failureOf(dio.get<void>('/x'));
      expect(server.calls, 0);

      clock.advance(const Duration(seconds: 5));
      final probe = await dio.get<void>('/x');
      final next = await failureOf(dio.get<void>('/x'));

      expect(probe.statusCode, 200);
      expect(next.error, isA<Converted>());
      expect(server.calls, 1);
    });

    for (final (name, first) in [
      ('a 503', status(503)),
      ('a connection error', failWith(_connectionError)),
    ]) {
      test('a probe whose first attempt gets $name is retried, and its real '
          'outcome is reported', () async {
        final clock = FakeClock();
        final server = ScriptedServer([first, status(200)]);
        final observer = RecordingObserver();
        final dio = client(
          server,
          status: FakeNetworkStatus(() async => false),
          observer: observer,
          clock: clock.call,
        );

        await failureOf(dio.get<void>('/x'));
        clock.advance(const Duration(seconds: 10));
        final probe = await dio.get<void>('/x');
        // The probe's pass is not inherited by the next request.
        await failureOf(dio.get<void>('/x'));

        expect(probe.statusCode, 200);
        expect(server.calls, 2);
        expect(observer.verdicts, ['reachable']);
      });
    }

    test('a probe that keeps getting a 503: the caller gets the 503, and the '
        'server is reachable', () async {
      final clock = FakeClock();
      final server = ScriptedServer([status(503)]);
      final observer = RecordingObserver();
      final dio = client(
        server,
        status: FakeNetworkStatus(() async => false),
        observer: observer,
        clock: clock.call,
      );

      await failureOf(dio.get<void>('/x'));
      clock.advance(const Duration(seconds: 10));
      final error = await failureOf(dio.get<void>('/x'));

      expect(server.calls, 3);
      expect(error.response?.statusCode, 503);
      expect(
        error.requestOptions.extra,
        isNot(contains(ConnectivityInterceptor.noNetworkKey)),
      );
      expect(observer.verdicts, ['reachable']);
    });

    test('a probe that gets a 401 is renewed and resent', () async {
      final clock = FakeClock();
      final tokens = Tokens('old');
      final server = ScriptedServer([status(401), status(200)]);
      final dio = client(
        server,
        tokens: tokens,
        refresher: Refresher(() async => tokens.token = 'new'),
        status: FakeNetworkStatus(() async => false),
        clock: clock.call,
      );

      await failureOf(dio.get<void>('/x'));
      clock.advance(const Duration(seconds: 10));
      final probe = await dio.get<void>('/x');

      expect(probe.statusCode, 200);
      expect(server.sentTokens, ['Bearer old', 'Bearer new']);
    });

    test('a network answer ends the probe window', () async {
      final clock = FakeClock();
      final server = ScriptedServer([status(200)]);
      final network = FakeNetworkStatus(() async => false);
      final dio = client(server, status: network, clock: clock.call);

      await failureOf(dio.get<void>('/x'));
      network.answer = () async => true;
      await dio.get<void>('/x');
      network.answer = () async => false;
      clock.advance(const Duration(seconds: 10));
      await failureOf(dio.get<void>('/x'));

      // The window restarted at the second "no": nothing is probed yet.
      expect(server.calls, 1);
    });

    test(
      'a status that throws counts as network: the request is sent',
      () async {
        final server = ScriptedServer([status(200)]);
        final network = FakeNetworkStatus(() => throw StateError('no plugin'));

        final response = await client(server, status: network).get<void>('/x');

        expect(response.statusCode, 200);
      },
    );

    test('a status that answers too late counts as network: the request is '
        'sent', () async {
      final server = ScriptedServer([status(200)]);
      final network = FakeNetworkStatus(() => Completer<bool>().future);

      final response = await client(server, status: network).get<void>('/x');

      expect(response.statusCode, 200);
    });
  });

  group('reachability verdicts', () {
    for (final code in [200, 404, 500]) {
      test('$code: reachable, once', () async {
        final observer = RecordingObserver();
        final server = ScriptedServer([status(code)]);

        await client(
          server,
          observer: observer,
        ).get<void>('/x').then<void>((_) {}, onError: (_) {});

        expect(observer.verdicts, ['reachable']);
      });
    }

    test(
      'a GET that never connects, retried twice: unreachable, once',
      () async {
        final observer = RecordingObserver();
        final server = ScriptedServer([failWith(_connectionError)]);

        await failureOf(client(server, observer: observer).get<void>('/x'));

        expect(server.calls, 3);
        expect(observer.verdicts, ['unreachable']);
      },
    );

    test('a connection timeout: unreachable', () async {
      final observer = RecordingObserver();
      final server = ScriptedServer([
        failWith(DioExceptionType.connectionTimeout),
      ]);

      await failureOf(client(server, observer: observer).get<void>('/x'));

      expect(observer.verdicts, ['unreachable']);
    });

    test('the verdict is the final outcome\'s: failed connections, then a '
        '503, is reachable', () async {
      final observer = RecordingObserver();
      final server = ScriptedServer([
        failWith(_connectionError),
        failWith(_connectionError),
        status(503),
      ]);

      await failureOf(client(server, observer: observer).get<void>('/x'));

      expect(server.calls, 3);
      expect(observer.verdicts, ['reachable']);
    });

    test('a failure that a retry fixes: reachable only', () async {
      final observer = RecordingObserver();
      final server = ScriptedServer([failWith(_connectionError), status(200)]);

      await client(server, observer: observer).get<void>('/x');

      expect(observer.verdicts, ['reachable']);
    });

    for (final policy in [const RetryPolicy(), RetryPolicy.none]) {
      test('a renewed 401 whose resend cannot connect: one verdict '
          '(retry ${policy.isEnabled ? 'on' : 'off'})', () async {
        final observer = RecordingObserver();
        final tokens = Tokens('old');
        final server = ScriptedServer([
          status(401),
          failWith(_connectionError),
        ]);

        await failureOf(
          client(
            server,
            policy: policy,
            tokens: tokens,
            refresher: Refresher(() async => tokens.token = 'new'),
            observer: observer,
          ).get<void>('/x'),
        );

        expect(observer.verdicts, ['unreachable']);
      });
    }

    for (final type in [
      DioExceptionType.receiveTimeout,
      DioExceptionType.unknown,
    ]) {
      test('${type.name}: no verdict', () async {
        final observer = RecordingObserver();
        final server = ScriptedServer([failWith(type)]);

        await failureOf(client(server, observer: observer).get<void>('/x'));

        expect(observer.verdicts, isEmpty);
      });
    }

    for (final lost in <Object>[
      const SocketException('Connection reset by peer'),
      const HttpException('Connection closed while receiving data'),
    ]) {
      test('a connection lost after the request was sent '
          '(${lost.runtimeType}): unreachable, and not sent again', () async {
        final observer = RecordingObserver();
        // What dio's IO adapter does then: the socket's own error, unwrapped.
        final server = ScriptedServer([(_) => throw lost]);

        final error = await failureOf(
          client(server, observer: observer).get<void>('/x'),
        );

        expect(error.type, DioExceptionType.unknown);
        expect(server.calls, 1, reason: 'the server may have acted on it');
        expect(observer.verdicts, ['unreachable']);
      });
    }

    test('a TLS failure: no verdict', () async {
      final observer = RecordingObserver();
      final server = ScriptedServer([
        (_) => throw const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
      ]);

      await failureOf(client(server, observer: observer).get<void>('/x'));

      expect(observer.verdicts, isEmpty);
    });

    test('an observer that throws does not change the outcome', () async {
      final server = ScriptedServer([status(200)]);

      final response = await client(
        server,
        observer: _ThrowingObserver(),
      ).get<void>('/x');

      expect(response.statusCode, 200);
    });
  });

  group('service verdicts', () {
    for (final code in [200, 204, 401, 404, 422]) {
      test('$code: available, once', () async {
        final service = RecordingServiceObserver();
        final server = ScriptedServer([status(code)]);

        await client(
          server,
          serviceObserver: service,
        ).get<void>('/x').then<void>((_) {}, onError: (_) {});

        expect(service.verdicts, ['available']);
      });
    }

    test('a 500, which is not retried: unavailable, once', () async {
      final service = RecordingServiceObserver();
      final server = ScriptedServer([status(500)]);

      final error = await failureOf(
        client(server, serviceObserver: service).get<void>('/x'),
      );

      expect(server.calls, 1);
      expect(error.response?.statusCode, 500);
      expect(service.verdicts, ['unavailable']);
    });

    test('a 503 that its retries do not fix: unavailable, once, after the '
        'last of them', () async {
      final service = RecordingServiceObserver();
      final observer = RecordingObserver();
      final server = ScriptedServer([status(503)]);

      await failureOf(
        client(
          server,
          observer: observer,
          serviceObserver: service,
        ).get<void>('/x'),
      );

      expect(server.calls, 3);
      expect(service.verdicts, ['unavailable']);
      // Reached all the same: the two verdicts are separate.
      expect(observer.verdicts, ['reachable']);
    });

    test('a 503 that a retry fixes: available only', () async {
      final service = RecordingServiceObserver();
      final server = ScriptedServer([status(503), status(200)]);

      await client(server, serviceObserver: service).get<void>('/x');

      expect(server.calls, 2);
      expect(service.verdicts, ['available']);
    });

    test('a write that gets a 503 is not resent: unavailable', () async {
      final service = RecordingServiceObserver();
      final server = ScriptedServer([status(503)]);

      await failureOf(
        client(server, serviceObserver: service).post<void>('/x'),
      );

      expect(server.calls, 1);
      expect(service.verdicts, ['unavailable']);
    });

    for (final type in [
      _connectionError,
      DioExceptionType.connectionTimeout,
      DioExceptionType.receiveTimeout,
    ]) {
      test('${type.name}: no answer, no verdict', () async {
        final service = RecordingServiceObserver();
        final server = ScriptedServer([failWith(type)]);

        await failureOf(
          client(server, serviceObserver: service).get<void>('/x'),
        );

        expect(service.verdicts, isEmpty);
      });
    }

    test('a request the gate refused gives no verdict', () async {
      final service = RecordingServiceObserver();
      final server = ScriptedServer([status(200)]);

      await failureOf(
        client(
          server,
          status: FakeNetworkStatus(() async => false),
          serviceObserver: service,
        ).get<void>('/x'),
      );

      expect(server.calls, 0);
      expect(service.verdicts, isEmpty);
    });

    test(
      'each request has its own verdict: unavailable, then available',
      () async {
        final service = RecordingServiceObserver();
        final server = ScriptedServer([status(500), status(200)]);
        final dio = client(server, serviceObserver: service);

        await failureOf(dio.get<void>('/x'));
        await dio.get<void>('/x');

        expect(service.verdicts, ['unavailable', 'available']);
      },
    );

    test('a renewed 401 reports the resend\'s answer, once', () async {
      final service = RecordingServiceObserver();
      final tokens = Tokens('old');
      final server = ScriptedServer([status(401), status(500)]);

      await failureOf(
        client(
          server,
          tokens: tokens,
          refresher: Refresher(() async => tokens.token = 'new'),
          serviceObserver: service,
        ).get<void>('/x'),
      );

      expect(service.verdicts, ['unavailable']);
    });

    test(
      'an observer that throws does not change the request\'s outcome',
      () async {
        final ok = ScriptedServer([status(200)]);
        final failing = ScriptedServer([status(500)]);

        final response = await client(
          ok,
          serviceObserver: _ThrowingServiceObserver(),
        ).get<void>('/x');
        final error = await failureOf(
          client(
            failing,
            serviceObserver: _ThrowingServiceObserver(),
          ).get<void>('/x'),
        );

        expect(response.statusCode, 200);
        expect(error.response?.statusCode, 500);
        expect(error.error, isA<Converted>());
      },
    );
  });
}
