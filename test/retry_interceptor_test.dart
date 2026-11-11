import 'dart:async';
import 'dart:convert';

import 'package:app_network/app_network.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

const _connectionError = DioExceptionType.connectionError;

/// A sleep that returns at once and remembers how long it was asked to wait.
Future<void> Function(Duration) _recordInto(List<Duration> sleeps) =>
    (delay) async => sleeps.add(delay);

void main() {
  group('RetryPolicy', () {
    test('none is off; the default is on', () {
      expect(RetryPolicy.none.isEnabled, isFalse);
      expect(const RetryPolicy().isEnabled, isTrue);
    });

    test('delays double from the base and stop at maxDelay', () {
      const policy = RetryPolicy();
      const middle = FixedRandom();
      expect(
        [
          for (var retry = 1; retry <= 5; retry++)
            policy.delayFor(retry, middle),
        ],
        const [
          Duration(milliseconds: 500),
          Duration(seconds: 1),
          Duration(seconds: 2),
          Duration(seconds: 4),
          Duration(seconds: 4),
        ],
      );
    });

    test('jitter spreads a delay by at most ±25%', () {
      const policy = RetryPolicy();
      expect(
        policy.delayFor(2, const FixedRandom(0)),
        const Duration(milliseconds: 750),
      );
      expect(
        policy.delayFor(2, const FixedRandom(1)),
        const Duration(milliseconds: 1250),
      );
    });
  });

  group('safe methods', () {
    test('a GET that cannot connect twice, then succeeds: the caller only '
        'sees the 200', () async {
      final server = ScriptedServer([
        failWith(_connectionError),
        failWith(_connectionError),
        status(200),
      ]);
      final sleeps = <Duration>[];

      final response = await client(
        server,
        sleep: _recordInto(sleeps),
      ).get<void>('/x');

      expect(response.statusCode, 200);
      expect(server.calls, 3);
      expect(sleeps, const [Duration(milliseconds: 500), Duration(seconds: 1)]);
      expect(
        response.requestOptions.extra,
        isNot(contains(RetryInterceptor.retryingKey)),
      );
    });

    test('a GET that never connects: 3 attempts, then the converted '
        'failure', () async {
      final server = ScriptedServer([failWith(_connectionError)]);

      final error = await failureOf(client(server).get<void>('/x'));

      expect(server.calls, 3);
      expect(error.type, _connectionError);
      expect(error.error, isA<Converted>());
      expect(
        error.requestOptions.extra,
        isNot(contains(RetryInterceptor.retryingKey)),
      );
    });

    for (final method in ['HEAD', 'OPTIONS']) {
      test('$method is retried', () async {
        final server = ScriptedServer([failWith(_connectionError)]);

        await failureOf(
          client(server).request<void>('/x', options: Options(method: method)),
        );

        expect(server.calls, 3);
      });
    }

    test('retryDisabled on a GET: sent once', () async {
      final server = ScriptedServer([failWith(_connectionError)]);

      await failureOf(
        client(server).get<void>(
          '/x',
          options: Options(extra: {RetryInterceptor.disableKey: true}),
        ),
      );

      expect(server.calls, 1);
    });
  });

  group('writes', () {
    for (final method in ['POST', 'PUT', 'PATCH', 'DELETE']) {
      test('$method is never retried', () async {
        final server = ScriptedServer([failWith(_connectionError)]);

        await failureOf(
          client(server).request<void>(
            '/x',
            data: {'amount': 10},
            options: Options(method: method),
          ),
        );

        expect(server.calls, 1);
      });
    }

    group('with an idempotency header configured', () {
      const policy = RetryPolicy(idempotencyHeader: 'Idempotency-Key');

      test('a POST without the header: sent once', () async {
        final server = ScriptedServer([failWith(_connectionError)]);

        await failureOf(
          client(server, policy: policy).post<void>('/x', data: {'a': 1}),
        );

        expect(server.calls, 1);
      });

      test('a POST carrying the header (any case) is retried', () async {
        final server = ScriptedServer([
          failWith(_connectionError),
          status(201),
        ]);

        final response = await client(server, policy: policy).post<void>(
          '/x',
          data: {'a': 1},
          options: Options(headers: {'idempotency-key': 'k-1'}),
        );

        expect(response.statusCode, 201);
        expect(server.calls, 2);
      });

      for (final (label, value) in [
        ('null', null),
        ('empty', ''),
        ('blank', '  '),
      ]) {
        test('a POST whose header is $label: sent once', () async {
          // dio drops a null header, and an empty one gives the backend no
          // key to de-duplicate on.
          final server = ScriptedServer([
            failWith(_connectionError),
            status(201),
          ]);

          await failureOf(
            client(server, policy: policy).post<void>(
              '/x',
              data: {'a': 1},
              options: Options(headers: {'Idempotency-Key': value}),
            ),
          );

          expect(server.calls, 1);
        });
      }

      test('a FormData body is never retried', () async {
        final server = ScriptedServer([failWith(_connectionError)]);

        final error = await failureOf(
          client(server, policy: policy).post<void>(
            '/x',
            data: FormData.fromMap({'a': '1'}),
            options: Options(headers: {'Idempotency-Key': 'k-1'}),
          ),
        );

        // A resend would fail inside dio (a FormData is finalised once)
        // before reaching the server, and replace this connection error.
        expect(server.calls, 1);
        expect(error.type, _connectionError);
      });

      test('a stream body is never retried', () async {
        final server = ScriptedServer([failWith(_connectionError)]);
        final body = utf8.encode('{"a":1}');

        await failureOf(
          client(server, policy: policy).post<void>(
            '/x',
            data: Stream<List<int>>.value(body),
            options: Options(
              headers: {
                'Idempotency-Key': 'k-1',
                Headers.contentLengthHeader: body.length,
              },
            ),
          ),
        );

        expect(server.calls, 1);
      });
    });
  });

  group('which failures', () {
    for (final code in [502, 503, 504]) {
      test('$code is retried', () async {
        final server = ScriptedServer([status(code)]);

        final error = await failureOf(client(server).get<void>('/x'));

        expect(server.calls, 3);
        expect(error.response?.statusCode, code);
      });
    }

    for (final code in [500, 400, 404, 429]) {
      test('$code is not retried', () async {
        final server = ScriptedServer([status(code)]);

        await failureOf(client(server).get<void>('/x'));

        expect(server.calls, 1);
      });
    }

    for (final type in [
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.badCertificate,
      DioExceptionType.unknown,
    ]) {
      test('${type.name} is not retried', () async {
        final server = ScriptedServer([failWith(type)]);

        final error = await failureOf(client(server).get<void>('/x'));

        expect(server.calls, 1);
        expect(error.type, type);
      });
    }

    test('a retry that gets a non-retried failure stops there', () async {
      final server = ScriptedServer([status(503), status(500), status(200)]);

      final error = await failureOf(client(server).get<void>('/x'));

      expect(server.calls, 2);
      expect(error.response?.statusCode, 500);
    });
  });

  group('Retry-After on a 503', () {
    test('a number within maxDelay is the wait', () async {
      final server = ScriptedServer([
        status(
          503,
          headers: {
            'Retry-After': ['1'],
          },
        ),
        status(200),
      ]);
      final sleeps = <Duration>[];

      final response = await client(
        server,
        sleep: _recordInto(sleeps),
      ).get<void>('/x');

      expect(response.statusCode, 200);
      expect(sleeps, const [Duration(seconds: 1)]);
    });

    test('a number above maxDelay means no retry', () async {
      final server = ScriptedServer([
        status(
          503,
          headers: {
            'Retry-After': ['120'],
          },
        ),
        status(200),
      ]);
      final sleeps = <Duration>[];

      final error = await failureOf(
        client(server, sleep: _recordInto(sleeps)).get<void>('/x'),
      );

      expect(server.calls, 1);
      expect(sleeps, isEmpty);
      expect(error.response?.statusCode, 503);
    });

    test('above maxDelay but within the budget still means no retry', () async {
      final server = ScriptedServer([
        status(
          503,
          headers: {
            'Retry-After': ['5'],
          },
        ),
        status(200),
      ]);

      await failureOf(client(server).get<void>('/x'));

      expect(server.calls, 1);
    });

    test('an HTTP date is ignored: the policy delay applies', () async {
      final server = ScriptedServer([
        status(
          503,
          headers: {
            'Retry-After': ['Wed, 21 Oct 2026 07:28:00 GMT'],
          },
        ),
        status(200),
      ]);
      final sleeps = <Duration>[];

      await client(server, sleep: _recordInto(sleeps)).get<void>('/x');

      expect(sleeps, const [Duration(milliseconds: 500)]);
    });
  });

  group('limits', () {
    test('a clock already past maxElapsed: no further attempt', () async {
      final clock = FakeClock();
      final server = ScriptedServer([failWith(_connectionError)])
        ..onFetch = () => clock.advance(const Duration(seconds: 11));

      await failureOf(client(server, clock: clock.call).get<void>('/x'));

      expect(server.calls, 1);
    });

    test('a retry that would start past maxElapsed is not made', () async {
      final clock = FakeClock();
      // Each attempt takes 6 s: the first retry starts at 6.5 s, the second
      // would start at 13 s.
      final server = ScriptedServer([failWith(_connectionError)])
        ..onFetch = () => clock.advance(const Duration(seconds: 6));

      await failureOf(client(server, clock: clock.call).get<void>('/x'));

      expect(server.calls, 2);
    });

    test('a request cancelled during the wait is not sent again', () async {
      final server = ScriptedServer([failWith(_connectionError)]);
      final waiting = Completer<void>();
      final wake = Completer<void>();
      final token = CancelToken();
      final dio = client(
        server,
        sleep: (_) {
          if (!waiting.isCompleted) waiting.complete();
          return wake.future;
        },
      );

      final request = failureOf(dio.get<void>('/x', cancelToken: token));
      await waiting.future;
      token.cancel('left the screen');
      final error = await request;
      await pumpEventQueue();

      expect(error.type, DioExceptionType.cancel);
      // The wait ended with the cancel, not with the sleep.
      expect(
        server.lastRequest!.extra,
        isNot(contains(RetryInterceptor.retryingKey)),
      );

      wake.complete();
      await pumpEventQueue();
      expect(server.calls, 1);
    });
  });

  group('the token on a resend', () {
    test('a sign-out during the wait: the resend carries no token', () async {
      final tokens = Tokens('old');
      final server = ScriptedServer([failWith(_connectionError), status(200)]);

      await client(
        server,
        tokens: tokens,
        sleep: (_) async => tokens.token = null,
      ).get<void>('/x');

      expect(server.sentTokens, ['Bearer old', null]);
    });

    test('a caller\'s own Authorization is resent unchanged', () async {
      final server = ScriptedServer([failWith(_connectionError), status(200)]);

      await client(server, tokens: Tokens(null)).get<void>(
        '/x',
        options: Options(headers: {'Authorization': 'Basic abc'}),
      );

      expect(server.sentTokens, ['Basic abc', 'Basic abc']);
    });
  });

  group('with token renewal', () {
    test('a renewed 401 whose resend cannot connect is retried in one loop '
        'only', () async {
      final tokens = Tokens('old');
      final refresher = Refresher(() async => tokens.token = 'new');
      final server = ScriptedServer([status(401), failWith(_connectionError)]);

      final error = await failureOf(
        client(server, tokens: tokens, refresher: refresher).get<void>('/x'),
      );

      expect(error.type, _connectionError);
      // The 401, the renewed resend, and that resend's two retries.
      expect(server.calls, 1 + 1 + 2);
      expect(server.sentTokens, [
        'Bearer old',
        'Bearer new',
        'Bearer new',
        'Bearer new',
      ]);
      expect(refresher.calls, 1);
    });

    test('503, then 401 (renewed once), then 200: the caller gets the '
        '200', () async {
      final tokens = Tokens('old');
      final refresher = Refresher(() async => tokens.token = 'new');
      final server = ScriptedServer([status(503), status(401), status(200)]);

      final response = await client(
        server,
        tokens: tokens,
        refresher: refresher,
      ).get<void>('/x');

      expect(response.statusCode, 200);
      expect(server.calls, 3);
      expect(refresher.calls, 1);
    });
  });
}
