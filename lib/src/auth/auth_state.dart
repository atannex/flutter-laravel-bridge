/// Represents the current lifecycle state of user authentication.
sealed class AuthState {
  const AuthState();
}

/// User is not logged in.
class Unauthenticated extends AuthState {
  const Unauthenticated();
}

/// Authentication attempt is currently in progress.
class Authenticating extends AuthState {
  const Authenticating();
}

/// User is successfully authenticated.
class Authenticated<T> extends AuthState {
  final T user;
  final String accessToken;

  const Authenticated({
    required this.user,
    required this.accessToken,
  });
}

/// Token is being refreshed in the background.
class RefreshingToken extends AuthState {
  const RefreshingToken();
}

/// Authentication failure occurred.
class AuthError extends AuthState {
  final String message;
  final dynamic cause;

  const AuthError({
    required this.message,
    this.cause,
  });
}
