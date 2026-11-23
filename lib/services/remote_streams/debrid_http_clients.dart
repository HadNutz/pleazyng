import 'package:http/http.dart' as http;

import '../../utils/bounded_http_response.dart';
import 'remote_stream_models.dart';

http.Client realDebridJsonClient(http.Client? client) => ResponseSizeLimitClient(
  client ?? http.Client(),
  4 * 1024 * 1024,
  const RealDebridException(RealDebridFailure.invalidResponse),
);

class RealDebridException implements Exception {
  const RealDebridException(this.reason);
  final RealDebridFailure reason;
}

enum RealDebridFailure {
  authentication,
  unavailable,
  invalidResponse,
  unsupported,
  preparationFailed,
  timeout,
  cancelled,
}

http.Client debridJsonClient(http.Client? client) => ResponseSizeLimitClient(
  client ?? http.Client(),
  2 * 1024 * 1024,
  const RemoteProviderException(RemoteProviderFailure.unavailable),
);

http.Client torBoxAuthJsonClient(http.Client? client) => ResponseSizeLimitClient(
  client ?? http.Client(),
  64 * 1024,
  const RemoteProviderException(RemoteProviderFailure.invalidResponse),
);
