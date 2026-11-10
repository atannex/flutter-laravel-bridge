import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Clean logging interceptor for Laravel HTTP requests and responses.
class LaravelLoggingInterceptor extends Interceptor {
  final bool enabled;

  const LaravelLoggingInterceptor({this.enabled = true});

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (enabled && kDebugMode) {
      debugPrint(
          '┌── [HTTP REQUEST] ${options.method.toUpperCase()} ${options.uri}');
      if (options.data != null) {
        debugPrint('│ Body: ${options.data}');
      }
      debugPrint('└──');
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (enabled && kDebugMode) {
      debugPrint(
          '┌── [HTTP RESPONSE] ${response.statusCode} ${response.requestOptions.uri}');
      debugPrint('│ Body: ${response.data}');
      debugPrint('└──');
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (enabled && kDebugMode) {
      debugPrint(
          '┌── [HTTP ERROR] ${err.response?.statusCode ?? 'N/A'} ${err.requestOptions.uri}');
      debugPrint('│ Error: ${err.error ?? err.message}');
      debugPrint('└──');
    }
    handler.next(err);
  }
}
