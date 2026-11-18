# app_network

The HTTP transport: a configured `Dio` with the bearer token, `accept-language`,
error conversion, silent token renewal on 401, safe retries, and a
connectivity gate that also reports how requests end.

```dart
final dio = DioManager.createDio(
  config: NetworkConfig(
    baseUrl: 'https://api.example.com',
    connectTimeout: NetworkConfig.recommendedConnectTimeout, // optional: 10 s
    retryPolicy: const RetryPolicy(),   // optional: retry safe methods
  ),
  tokenStore: tokenStore,             // where the access token is read from
  errorConverter: errorConverter,     // DioException -> your error type
  localeProvider: localeProvider,     // optional: accept-language
  sessionRefresher: sessionRefresher, // optional: renew and retry on 401
  networkStatus: networkStatus,       // optional: fail fast with no network
  reachabilityObserver: observer,     // optional: told how requests ended
  serviceObserver: serviceObserver,   // optional: told of 5xx answers
);
```

No dependency on any other package of this template; `app_core` implements
the ports.

## Ports

| Port | Asked for | Contract |
|---|---|---|
| `TokenStore` | the access token, on every request and resend | null or empty sends no `Authorization` (a resend drops the one it had) |
| `LocaleProvider` | the `accept-language` tag | null sends none |
| `NetworkErrorConverter` | your error type for a failure | placed on `DioException.error` |
| `SessionRefresher` | a new token after a 401 | null ends the session; a throw keeps it |
| `NetworkStatus` | "is there a network at all?" before each request | answer fast, never throw, true when unsure |
| `ReachabilityObserver` | each request's final transport outcome | `onReachable` (any HTTP status) or `onUnreachable` (no answer), once per request |
| `ServiceObserver` | whether the server could serve each request it answered | `onServiceUnavailable` (a 5xx) or `onServiceAvailable` (any other status), once per request; nothing when there was no answer |

## Interceptor order

**Auth → RefreshToken → Retry → Connectivity → ErrorHandler → Log**

| Interceptor | Added when | Does |
|---|---|---|
| `AuthInterceptor` | always | bearer token and `accept-language` |
| `RefreshTokenInterceptor` | `sessionRefresher` given | renews on 401 and resends once |
| `RetryInterceptor` | `config.retryPolicy.isEnabled` | resends a transient failure (below) |
| `ConnectivityInterceptor` | `networkStatus`, `reachabilityObserver` or `serviceObserver` given | refuses a request when there is no network; reports each request's outcome |
| `ErrorHandlerInterceptor` | always | puts the converter's output on `DioException.error` |
| `LogInterceptor` | `config.enableLogging` | logs every attempt |

The order matters. A 401 is renewed, not retried. Retry sees a failure
before it is converted, so a request it recovers never reaches the converter.
Connectivity's error handler sees only a request's final outcome: one verdict
per request, after any retries, so a blip a retry fixes is never reported. Every
resend (renewal or retry) goes through the same client and passes the gate
again, except a probe's (below).

## Retries

`RetryPolicy.none` is the default: a client opts in with `RetryPolicy()`.

* **Retried:** `GET`, `HEAD` and `OPTIONS`, on `connectionError` or a
  502/503/504 response.
* **How often:** at most 2 retries, after about 0.5 s and 1 s (±25 % jitter).
  No retry starts more than 10 s after the first send. A numeric
  `Retry-After` on a 503 is the wait; one above 4 s means no retry. The
  HTTP-date form is ignored. Cancelling the request's `CancelToken` ends the
  wait without a resend.
* **Never retried:** timeouts of any kind, a 500, any 4xx, `unknown` (TLS
  failures included), `badCertificate`, `cancel`, a request the gate refused,
  and `FormData` or stream bodies.
* **Writes** (`POST`, `PUT`, `PATCH`, `DELETE`) are never retried, because a
  "connection error" can arrive after the server already acted. The one
  exception: set `RetryPolicy.idempotencyHeader` (null by default) and a
  write carrying a non-blank string value of that header is retried. Set it only once the backend
  de-duplicates by that key.

## The connectivity gate

Fail-open: the gate refuses a request only when `NetworkStatus` says "no
network". An error, or no answer within 1 s, means "send". While the answer
stays "no", one request every 10 s is sent anyway, so a wrong platform
reading cannot block traffic for good; its real outcome corrects the reading.
That probe's own retries and renewal are sent too, so the caller and the
verdict get its final outcome, not a refusal.

A refused request fails with a `connectionError` carrying
`NoNetworkException`, and goes through every error interceptor
(`reject(err, true)`), so your converter classifies it like any other
connection failure.

Verdicts: any HTTP response, error statuses included, is reachable; a
`connectionError` or `connectionTimeout` is unreachable, and so is a
connection lost after the request was sent (an `unknown` carrying a
`SocketException` or an `HttpException`). A receive, send or transform
timeout, any other `unknown` (TLS failures included), `cancel`,
`badCertificate`, or a refusal gives no verdict.

Service verdicts go to `ServiceObserver`, at the same point: a 5xx as the
request's final answer (after its retries) is unavailable, any other status
is available. A request that got no answer gives none, so a lost connection
never reads as a failing server, and neither does a 5xx to a request marked
`ConnectivityInterceptor.quietServiceKey`.

## `extra` keys

Set on a request's `Options.extra`:

| Key | Effect |
|---|---|
| `RetryInterceptor.disableKey` | never resend it, for a `GET` with side effects (one that sends an OTP, say) |
| `ConnectivityInterceptor.skipKey` | send it even when there is no network |
| `ConnectivityInterceptor.quietServiceKey` | a 5xx answer to it gives no service verdict, for a call whose 5xx is a state the screen shows itself; any other answer still reports available |

Set by the interceptors, readable in your own: `RefreshTokenInterceptor.retriedKey`
(a renewed resend), `RetryInterceptor.retryingKey` (a retry is in progress),
`RetryInterceptor.startedAtKey` (when the request was first sent, a
`DateTime`), and `ConnectivityInterceptor.noNetworkKey` (the gate refused it).
Every resend reuses the same `RequestOptions`, so these flags hold across all
the attempts of one request.

## Defaults

`NetworkConfig` keeps 30 s connect and receive timeouts and
`RetryPolicy.none`. An app client should use
`NetworkConfig.recommendedConnectTimeout` (10 s): opening the connection is
the phase that hangs on Wi-Fi without internet, and the gate cannot see that
case.
