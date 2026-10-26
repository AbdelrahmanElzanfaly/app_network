/// Everything a client needs to know about the host it talks to.
class NetworkConfig {
  const NetworkConfig({
    required this.baseUrl,
    this.headers = const {},
    this.enableLogging = false,
    this.connectTimeout = defaultTimeout,
    this.receiveTimeout = defaultTimeout,
  });

  static const Duration defaultTimeout = Duration(seconds: 30);

  final String baseUrl;
  final Map<String, String> headers;
  final bool enableLogging;
  final Duration connectTimeout;
  final Duration receiveTimeout;
}
