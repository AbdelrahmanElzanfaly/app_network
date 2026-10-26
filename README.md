# app_network

The HTTP transport: a configured `Dio` with the bearer token, `accept-language`,
error conversion, and silent token renewal on 401.

```dart
final dio = DioManager.createDio(
  config: NetworkConfig(baseUrl: 'https://api.example.com'),
  tokenStore: tokenStore,             // where the access token is read from
  errorConverter: errorConverter,     // DioException -> your error type
  localeProvider: localeProvider,     // optional: accept-language
  sessionRefresher: sessionRefresher, // optional: renew and retry on 401
);
```

No dependency on any other package of this template; `app_core` implements
the ports (`TokenStore`, `LocaleProvider`, `NetworkErrorConverter`,
`SessionRefresher`).
