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

  /// Email + password did not match.
  static const String invalidCredentials = 'invalid_credentials';

  /// A sensitive action needs a recent password confirmation (423).
  static const String passwordConfirmationRequired =
      'password_confirmation_required';

  /// The password sent to `confirm-password` is wrong (422).
  static const String passwordInvalid = 'password_invalid';

  /// An emailed code is wrong (422).
  static const String codeInvalid = 'code_invalid';

  /// An emailed code is too old (422).
  static const String codeExpired = 'code_expired';

  /// Too many wrong attempts: the code no longer works (423).
  static const String codeLocked = 'code_locked';

  /// The password reset token is unknown, used or expired (422).
  static const String resetTokenInvalid = 'reset_token_invalid';

  /// The Fortify feature is disabled on the server (404).
  static const String featureDisabled = 'feature_disabled';

  /// The email address is already verified (409).
  static const String alreadyVerified = 'already_verified';

  /// Two-factor authentication is not enabled for the user (404).
  static const String twoFactorNotEnabled = 'two_factor_not_enabled';

  /// Codes about emailed one-time codes and reset tokens.
  static const Set<String> codeErrors = {
    codeInvalid,
    codeExpired,
    codeLocked,
    resetTokenInvalid,
  };

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

/// Why an emailed code (or reset token) was rejected.
enum LaravelCodeErrorKind {
  /// Wrong code, or unknown / used reset token.
  invalid,

  /// The code is too old: ask for a new one.
  expired,

  /// Too many wrong attempts: ask for a new one.
  locked,
}

/// Thrown when an emailed code or a password reset token is rejected:
/// 422 `code_invalid` / `code_expired` / `reset_token_invalid`,
/// 423 `code_locked` (FORTIFY.md §2).
///
/// It extends [LaravelValidationError] so generic 422 handlers keep working;
/// the message for the field is in `first('code')` (or `first('reset_token')`).
class LaravelCodeException extends LaravelValidationError {
  final LaravelCodeErrorKind kind;

  LaravelCodeException({
    required super.message,
    required this.kind,
    super.fieldErrors = const {},
    int? statusCode,
    super.responseData,
    String? errorCode,
  }) : super(
          statusCode:
              statusCode ?? (kind == LaravelCodeErrorKind.locked ? 423 : 422),
          errorCode: errorCode ?? _defaultCode(kind),
        );

  static String _defaultCode(LaravelCodeErrorKind kind) {
    switch (kind) {
      case LaravelCodeErrorKind.invalid:
        return LaravelErrorCode.codeInvalid;
      case LaravelCodeErrorKind.expired:
        return LaravelErrorCode.codeExpired;
      case LaravelCodeErrorKind.locked:
        return LaravelErrorCode.codeLocked;
    }
  }

  /// Kind matching a `meta.error_code`, or `null` for other codes.
  static LaravelCodeErrorKind? kindOf(String? code) {
    switch (code) {
      case LaravelErrorCode.codeInvalid:
      case LaravelErrorCode.resetTokenInvalid:
        return LaravelCodeErrorKind.invalid;
      case LaravelErrorCode.codeExpired:
        return LaravelCodeErrorKind.expired;
      case LaravelErrorCode.codeLocked:
        return LaravelCodeErrorKind.locked;
    }
    return null;
  }

  bool get isInvalid => kind == LaravelCodeErrorKind.invalid;
  bool get isExpired => kind == LaravelCodeErrorKind.expired;
  bool get isLocked => kind == LaravelCodeErrorKind.locked;

  /// The reset token (not a code) was rejected: start the reset again.
  bool get isResetToken => errorCode == LaravelErrorCode.resetTokenInvalid;

  /// Whether a new code must be requested (expired or locked).
  bool get needsNewCode => kind != LaravelCodeErrorKind.invalid;

  @override
  String toString() => 'LaravelCodeException [${kind.name}]: $message';
}

/// Thrown when a sensitive action needs a recent password confirmation
/// (423 `password_confirmation_required`). Confirm with
/// `auth.confirmPassword(password)` and retry, or wrap the call in
/// `auth.runWithPasswordConfirmation`.
class LaravelPasswordConfirmationRequiredException extends LaravelException {
  const LaravelPasswordConfirmationRequiredException({
    super.message = 'Please confirm your password to continue.',
    super.statusCode = 423,
    super.responseData,
    super.errorCode = LaravelErrorCode.passwordConfirmationRequired,
  });

  @override
  String toString() => 'LaravelPasswordConfirmationRequiredException: $message';
}

/// Thrown when the email address is already verified (409 `already_verified`).
class LaravelAlreadyVerifiedException extends LaravelException {
  const LaravelAlreadyVerifiedException({
    super.message = 'Your email address is already verified.',
    super.statusCode = 409,
    super.responseData,
    super.errorCode = LaravelErrorCode.alreadyVerified,
  });
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

/// Thrown when a Fortify feature is disabled on the server
/// (404 `feature_disabled`), or locally — without any request — when the
/// server's `features.fortify` says the feature is off.
class LaravelFeatureDisabledException extends LaravelNotFoundException {
  /// Feature name as published in `features.fortify` (`reset_passwords`,
  /// `passkeys`…), when known.
  final String? feature;

  const LaravelFeatureDisabledException({
    super.message = 'This feature is not available.',
    super.statusCode = 404,
    super.responseData,
    super.errorCode = LaravelErrorCode.featureDisabled,
    this.feature,
  });

  @override
  String toString() =>
      'LaravelFeatureDisabledException: $message${feature != null ? ' ($feature)' : ''}';
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
