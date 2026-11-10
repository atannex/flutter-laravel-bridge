import 'package:dio/dio.dart';
import '../../exceptions/laravel_exception.dart';

/// Interceptor that translates standard Dio errors into typed Laravel exceptions,
/// branching on the protocol `meta.error_code` (CONNECTIONS.md §3).
class ErrorInterceptor extends Interceptor {
  /// Invoked for every translated exception (used by the connection manager to
  /// react to `connection_revoked`, `upgrade_required`, app key errors…).
  final void Function(LaravelException exception, RequestOptions request)?
      onException;

  /// Clock used to interpret HTTP-date `Retry-After` values.
  final DateTime Function() clock;

  ErrorInterceptor({this.onException, DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    // Already translated (e.g. an error re-surfacing from a retried request).
    if (err.error is LaravelException) {
      return handler.next(err);
    }

    final exception = translate(err, clock: clock);

    try {
      onException?.call(exception, err.requestOptions);
    } catch (_) {
      // Observers must never break the request pipeline.
    }

    // Wrap into a custom DioException with the typed LaravelException
    handler.reject(
      DioException(
        requestOptions: err.requestOptions,
        response: err.response,
        type: err.type,
        error: exception,
        stackTrace: err.stackTrace,
        message: exception.message,
      ),
    );
  }

  /// Extract `meta.error_code` from a response body.
  static String? errorCodeOf(dynamic body) {
    if (body is Map) {
      final meta = body['meta'];
      if (meta is Map && meta['error_code'] != null) {
        return meta['error_code'].toString();
      }
      // Tolerate servers that put the code at the top level.
      if (body['error_code'] != null) return body['error_code'].toString();
    }
    return null;
  }

  /// Translate a raw [DioException] into the matching [LaravelException].
  static LaravelException translate(DioException err,
      {DateTime Function()? clock}) {
    final response = err.response;
    final statusCode = response?.statusCode;
    final data = response?.data;
    final code = errorCodeOf(data);
    final errors = data is Map ? data['errors'] : null;

    String extractMessage(String fallback) {
      if (data is Map &&
          data['message'] is String &&
          (data['message'] as String).isNotEmpty) {
        return data['message'] as String;
      }
      return err.message ?? fallback;
    }

    Duration? retryAfter() => parseRetryAfter(
        response?.headers.value('retry-after'), clock ?? DateTime.now);

    if (response == null) {
      final isNetwork = err.type == DioExceptionType.connectionTimeout ||
          err.type == DioExceptionType.receiveTimeout ||
          err.type == DioExceptionType.sendTimeout ||
          err.type == DioExceptionType.connectionError ||
          (err.type == DioExceptionType.unknown && err.error is Exception);
      if (isNetwork) {
        return const LaravelNetworkException(
          message:
              'Could not connect to server. Please verify your connection.',
        );
      }
      return LaravelException(
        message: err.type == DioExceptionType.cancel
            ? 'Request cancelled.'
            : (err.message ??
                err.error?.toString() ??
                'An unexpected network error occurred'),
      );
    }

    if (statusCode == 426 || code == LaravelErrorCode.upgradeRequired) {
      final details = errors is Map ? errors : const {};
      return LaravelUpgradeRequiredException(
        message: extractMessage('A newer version of the app is required.'),
        statusCode: statusCode,
        responseData: data,
        minVersion: details['min_version']?.toString(),
        latestVersion: details['latest_version']?.toString(),
        updateUrl: details['update_url']?.toString(),
        currentVersion: details['current_version']?.toString(),
      );
    }

    Map<String, List<String>> fieldErrorsOf() {
      final fieldErrors = <String, List<String>>{};
      if (errors is Map) {
        errors.forEach((key, value) {
          if (value is List) {
            fieldErrors[key.toString()] =
                value.map((e) => e.toString()).toList();
          } else if (value != null) {
            fieldErrors[key.toString()] = [value.toString()];
          }
        });
      }
      return fieldErrors;
    }

    // Fortify over the bridge (FORTIFY.md §2): emailed codes / reset tokens.
    final codeKind = LaravelCodeException.kindOf(code);
    if (codeKind != null) {
      return LaravelCodeException(
        message: extractMessage(switch (codeKind) {
          LaravelCodeErrorKind.invalid => 'The code is invalid.',
          LaravelCodeErrorKind.expired => 'The code has expired.',
          LaravelCodeErrorKind.locked =>
            'Too many attempts. Request a new code.',
        }),
        kind: codeKind,
        fieldErrors: fieldErrorsOf(),
        statusCode: statusCode,
        responseData: data,
        errorCode: code,
      );
    }

    if (code == LaravelErrorCode.passwordConfirmationRequired ||
        (statusCode == 423 && code == null)) {
      return LaravelPasswordConfirmationRequiredException(
        message: extractMessage('Please confirm your password to continue.'),
        statusCode: statusCode,
        responseData: data,
      );
    }

    if (code == LaravelErrorCode.alreadyVerified) {
      return LaravelAlreadyVerifiedException(
        message: extractMessage('Your email address is already verified.'),
        statusCode: statusCode,
        responseData: data,
      );
    }

    // 404 only: a 403 `feature_disabled` (bridge feature switched off) keeps
    // its LaravelPermissionException mapping.
    if (code == LaravelErrorCode.featureDisabled && statusCode == 404) {
      final feature = errors is Map ? errors['feature'] : null;
      return LaravelFeatureDisabledException(
        message: extractMessage('This feature is not available.'),
        statusCode: statusCode,
        responseData: data,
        feature: feature is List
            ? (feature.isEmpty ? null : feature.first?.toString())
            : feature?.toString(),
      );
    }

    if (statusCode == 422 && data is Map) {
      final fieldErrors = fieldErrorsOf();
      final payload = data['data'];
      final twoFactorFlag = payload is Map && payload['two_factor'] == true;
      if (LaravelErrorCode.isTwoFactorChallenge(code) ||
          (code == null && twoFactorFlag)) {
        final invalid = code == LaravelErrorCode.twoFactorInvalid;
        return LaravelTwoFactorRequiredException(
          message: extractMessage(invalid
              ? 'The two-factor code is invalid.'
              : 'Enter the code from your authenticator app.'),
          fieldErrors: fieldErrors,
          responseData: data,
          invalid: invalid,
        );
      }
      return LaravelValidationError(
        message: extractMessage('The given data was invalid.'),
        fieldErrors: fieldErrors,
        responseData: data,
        errorCode: code,
      );
    }

    switch (statusCode) {
      case 401:
        return LaravelAuthenticationException(
          message: extractMessage('Unauthenticated. Invalid or expired token.'),
          responseData: data,
          errorCode: code,
        );
      case 403:
        if (code == LaravelErrorCode.connectionRevoked) {
          final reason = errors is Map ? errors['reason']?.toString() : null;
          return LaravelConnectionRevokedException(
            message: extractMessage('This session has been revoked.'),
            responseData: data,
            reason: reason,
          );
        }
        if (LaravelErrorCode.isAppKeyError(code)) {
          return LaravelAppKeyException(
            message: extractMessage(
                'The application key was rejected by the server.'),
            responseData: data,
            errorCode: code,
          );
        }
        return LaravelPermissionException(
          message: extractMessage(
              'Forbidden. You do not have permission to perform this action.'),
          responseData: data,
          errorCode: code,
        );
      case 404:
        if (code == LaravelErrorCode.connectionNotFound) {
          return LaravelConnectionNotFoundException(
            message: extractMessage('Connection session not found.'),
            responseData: data,
          );
        }
        return LaravelNotFoundException(
          message: extractMessage('Resource not found.'),
          responseData: data,
          errorCode: code,
        );
      case 429:
        return LaravelRateLimitException(
          message: extractMessage('Too many requests. Please slow down.'),
          responseData: data,
          retryAfter: retryAfter(),
        );
      case 503:
        return LaravelMaintenanceException(
          message: extractMessage(
              'The service is under maintenance. Please try again later.'),
          responseData: data,
          errorCode: code ?? LaravelErrorCode.maintenance,
          retryAfter: retryAfter(),
        );
    }

    if (statusCode != null && statusCode >= 500) {
      return LaravelServerException(
        message: extractMessage('Internal server error occurred.'),
        statusCode: statusCode,
        responseData: data,
        errorCode: code,
      );
    }

    return LaravelException(
      message: extractMessage('An unexpected error occurred'),
      statusCode: statusCode,
      responseData: data,
      errorCode: code,
    );
  }

  /// Parse a `Retry-After` header: delta-seconds or an IMF-fixdate
  /// (`Wed, 21 Oct 2015 07:28:00 GMT`).
  static Duration? parseRetryAfter(String? value,
      [DateTime Function()? clock]) {
    if (value == null) return null;
    final trimmed = value.trim();
    final seconds = int.tryParse(trimmed);
    if (seconds != null) return Duration(seconds: seconds < 0 ? 0 : seconds);

    final match = RegExp(
      r'^[A-Za-z]{3},\s+(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT$',
    ).firstMatch(trimmed);
    if (match == null) return null;

    const months = [
      'jan',
      'feb',
      'mar',
      'apr',
      'may',
      'jun',
      'jul',
      'aug',
      'sep',
      'oct',
      'nov',
      'dec'
    ];
    final month = months.indexOf(match.group(2)!.toLowerCase()) + 1;
    if (month == 0) return null;

    final date = DateTime.utc(
      int.parse(match.group(3)!),
      month,
      int.parse(match.group(1)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
    );
    final delta = date.difference((clock ?? DateTime.now)().toUtc());
    return delta.isNegative ? Duration.zero : delta;
  }
}
