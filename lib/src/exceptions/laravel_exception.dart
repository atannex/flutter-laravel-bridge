/// Protocol-level error codes sent by the server in `meta.error_code`
/// (CONNECTIONS.md §3). Clients must branch on the code, not on the message.
class LaravelErrorCode {
  LaravelErrorCode._();

  static const String unauthenticated = 'unauthenticated';
  static const String invalidRefreshToken = 'invalid_refresh_token';
  static const String refreshTokenReused = 'refresh_token_reused';
  static const String appKeyRequired = 'app_key_required';
  static const String invalidAppKey = 'invalid_app_key';
  static const String appSuspended = 'app_suspended';
  static const String connectionRevoked = 'connection_revoked';
  static const String connectionNotFound = 'connection_not_found';
  static const String validationFailed = 'validation_failed';
  static const String upgradeRequired = 'upgrade_required';
  static const String tooManyRequests = 'too_many_requests';
  static const String maintenance = 'maintenance';

  /// Login needs an authenticator-app code (or a recovery code).
  static const String twoFactorRequired = 'two_factor_required';

  /// The authenticator-app code or recovery code sent with login was wrong.
  static const String twoFactorInvalid = 'two_factor_invalid';

  /// Whether [code] is one of the two-step sign-in challenge codes.
  static bool isTwoFactorChallenge(String? code) =>
      code == twoFactorRequired || code == twoFactorInvalid;

  /// Codes that must never trigger an access-token refresh.
  static const Set<String> noRefresh = {
    invalidRefreshToken,
    refreshTokenReused,
    connectionRevoked,
    appKeyRequired,
    invalidAppKey,
    appSuspended,
  };

  /// Whether [code] is one of the app key related codes.
  static bool isAppKeyError(String? code) =>
      code == appKeyRequired || code == invalidAppKey || code == appSuspended;
}

/// Base class for all Laravel-related exceptions.
class LaravelException implements Exception {
  final String message;
  final int? statusCode;
  final dynamic responseData;

  /// Protocol error code from `meta.error_code`, when the server sent one.
  final String? errorCode;

  const LaravelException({
    required this.message,
    this.statusCode,
    this.responseData,
    this.errorCode,
  });

  @override
  String toString() =>
      'LaravelException [$statusCode${errorCode != null ? ' $errorCode' : ''}]: $message';
}

/// Thrown when Laravel returns a 422 Unprocessable Entity with validation errors.
class LaravelValidationError extends LaravelException {
  final Map<String, List<String>> fieldErrors;

  LaravelValidationError({
    required super.message,
    required this.fieldErrors,
    super.statusCode = 422,
    super.responseData,
    super.errorCode,
  });

  /// Check if a specific field has validation errors.
  bool has(String field) =>
      fieldErrors.containsKey(field) && fieldErrors[field]!.isNotEmpty;

  /// Get the first validation error message for a specific field, or null.
  String? first(String field) {
    final errors = fieldErrors[field];
    if (errors != null && errors.isNotEmpty) {
      return errors.first;
    }
    return null;
  }

  /// Get all error messages flattened across all fields.
  List<String> get allMessages {
    return fieldErrors.values.expand((element) => element).toList();
  }

  @override
  String toString() =>
      'LaravelValidationError: $message (Fields: ${fieldErrors.keys.join(', ')})';
}

/// Thrown when login needs an authenticator-app code (422 `two_factor_required`)
/// or the code that was sent is wrong (422 `two_factor_invalid`).
///
/// It extends [LaravelValidationError], so existing `on LaravelValidationError`
/// handlers keep working; the message for the code field is in `first('code')`.
/// Ask the user for the code, then call `login` again with `code:` (or
/// `recoveryCode:`).
class LaravelTwoFactorRequiredException extends LaravelValidationError {
  /// `true` when a code was sent but rejected (`two_factor_invalid`), `false`
  /// when the server is asking for one (`two_factor_required`).
  final bool invalid;

  LaravelTwoFactorRequiredException({
    super.message = 'Enter the code from your authenticator app.',
    super.fieldErrors = const {},
    super.statusCode = 422,
    super.responseData,
    this.invalid = false,
    String? errorCode,
  }) : super(
          errorCode: errorCode ??
              (invalid
                  ? LaravelErrorCode.twoFactorInvalid
                  : LaravelErrorCode.twoFactorRequired),
        );

  @override
  String toString() =>
      'LaravelTwoFactorRequiredException: $message (invalid: $invalid)';
}

/// Thrown when an unauthenticated request is rejected (HTTP 401).
class LaravelAuthenticationException extends LaravelException {
  const LaravelAuthenticationException({
    super.message = 'Unauthenticated. Invalid or expired token.',
    super.statusCode = 401,
    super.responseData,
    super.errorCode,
  });

  /// Whether the refresh token itself was rejected (no retry possible).
  bool get isRefreshTokenInvalid =>
      errorCode == LaravelErrorCode.invalidRefreshToken ||
      errorCode == LaravelErrorCode.refreshTokenReused;
}

/// Thrown when an unauthorized action is rejected (HTTP 403 Forbidden).
class LaravelPermissionException extends LaravelException {
  const LaravelPermissionException({
    super.message =
        'Forbidden. You do not have permission to perform this action.',
    super.statusCode = 403,
    super.responseData,
    super.errorCode,
  });
}

/// Thrown when the current connection session was revoked (403 `connection_revoked`).
class LaravelConnectionRevokedException extends LaravelPermissionException {
  /// Optional reason supplied by the server.
  final String? reason;

  const LaravelConnectionRevokedException({
    super.message = 'This session has been revoked.',
    super.statusCode = 403,
    super.responseData,
    super.errorCode = LaravelErrorCode.connectionRevoked,
    this.reason,
  });
}

/// Thrown when the app key is missing, unknown or the app is suspended (403 `app_*`).
class LaravelAppKeyException extends LaravelPermissionException {
  const LaravelAppKeyException({
    super.message = 'The application key was rejected by the server.',
    super.statusCode = 403,
    super.responseData,
    super.errorCode = LaravelErrorCode.invalidAppKey,
  });

  /// The app exists but is suspended.
  bool get isSuspended => errorCode == LaravelErrorCode.appSuspended;

  /// The server requires an app key and none was sent.
  bool get isMissing => errorCode == LaravelErrorCode.appKeyRequired;
}

/// Thrown when a requested resource is not found (HTTP 404).
class LaravelNotFoundException extends LaravelException {
  const LaravelNotFoundException({
    super.message = 'Resource not found.',
    super.statusCode = 404,
    super.responseData,
    super.errorCode,
  });
}

/// Thrown when the connection session id is unknown to the server (404 `connection_not_found`).
class LaravelConnectionNotFoundException extends LaravelNotFoundException {
  const LaravelConnectionNotFoundException({
    super.message = 'Connection session not found.',
    super.statusCode = 404,
    super.responseData,
    super.errorCode = LaravelErrorCode.connectionNotFound,
  });
}

/// Thrown when the app version is below the server's minimum version (HTTP 426).
class LaravelUpgradeRequiredException extends LaravelException {
  /// Minimum supported version.
  final String? minVersion;

  /// Latest available version.
  final String? latestVersion;

  /// Store / download URL for the update.
  final String? updateUrl;

  /// Version the client reported.
  final String? currentVersion;

  const LaravelUpgradeRequiredException({
    super.message = 'A newer version of the app is required.',
    super.statusCode = 426,
    super.responseData,
    super.errorCode = LaravelErrorCode.upgradeRequired,
    this.minVersion,
    this.latestVersion,
    this.updateUrl,
    this.currentVersion,
  });

  @override
  String toString() =>
      'LaravelUpgradeRequiredException: $message (current: $currentVersion, min: $minVersion)';
}

/// Thrown when the client is throttled (HTTP 429).
class LaravelRateLimitException extends LaravelException {
  /// Delay requested by the `Retry-After` header.
  final Duration? retryAfter;

  const LaravelRateLimitException({
    super.message = 'Too many requests. Please slow down.',
    super.statusCode = 429,
    super.responseData,
    super.errorCode = LaravelErrorCode.tooManyRequests,
    this.retryAfter,
  });
}

/// Thrown when an internal server error occurs (HTTP 500+).
class LaravelServerException extends LaravelException {
  const LaravelServerException({
    super.message = 'Internal server error occurred.',
    super.statusCode = 500,
    super.responseData,
    super.errorCode,
  });
}

/// Thrown when the server (or app) is in maintenance mode (HTTP 503).
class LaravelMaintenanceException extends LaravelServerException {
  /// Delay requested by the `Retry-After` header.
  final Duration? retryAfter;

  const LaravelMaintenanceException({
    super.message = 'The service is under maintenance. Please try again later.',
    super.statusCode = 503,
    super.responseData,
    super.errorCode = LaravelErrorCode.maintenance,
    this.retryAfter,
  });
}

/// Thrown when network connectivity fails or a request times out.
class LaravelNetworkException extends LaravelException {
  const LaravelNetworkException({
    super.message =
        'Network connection failed. Please check your internet connection.',
    super.statusCode,
    super.responseData,
    super.errorCode,
  });
}
