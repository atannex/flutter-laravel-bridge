import 'package:dio/dio.dart';
import '../laravel_options.dart';

/// Interceptor that attaches client telemetry and platform headers.
class TelemetryInterceptor extends Interceptor {
  final LaravelOptions options;

  TelemetryInterceptor(this.options);

  @override
  void onRequest(
      RequestOptions requestOptions, RequestInterceptorHandler handler) {
    requestOptions.headers['Accept'] = 'application/json';

    if (options.platform != null) {
      requestOptions.headers['X-Flutter-Platform'] = options.platform;
    }

    if (options.appVersion != null) {
      requestOptions.headers['X-Flutter-App-Version'] = options.appVersion;
    }

    if (options.deviceId != null) {
      requestOptions.headers['X-Flutter-Device-Id'] = options.deviceId;
    }

    handler.next(requestOptions);
  }
}
