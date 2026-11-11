import 'retry_policy.dart';

/// Everything a client needs to know about the host it talks to.
class NetworkConfig {
  const NetworkConfig({
    required this.baseUrl,
    this.headers = const {},
    this.enableLogging = false,
    this.connectTimeout = defaultTimeout,
    this.receiveTimeout = defaultTimeout,
    this.retryPolicy = RetryPolicy.none,
  });

  static const Duration defaultTimeout = Duration(seconds: 30);

  /// The connect timeout an app client should use. Opening the connection is
  /// the phase that hangs when Wi-Fi is up but has no internet; ten seconds
  /// fails that case three times sooner than [defaultTimeout] while leaving
  /// slow links room. [defaultTimeout] stays the package default.
  static const Duration recommendedConnectTimeout = Duration(seconds: 10);

  final String baseUrl;
  final Map<String, String> headers;
  final bool enableLogging;
  final Duration connectTimeout;
  final Duration receiveTimeout;

  /// Which failed requests are sent again. [RetryPolicy.none] by default:
  /// retrying is a decision each client makes.
  final RetryPolicy retryPolicy;
}
