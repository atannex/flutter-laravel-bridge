import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../client/interceptors/auth_interceptor.dart';
import '../client/laravel_client.dart';
import '../connection/bridge_endpoints.dart';
import '../connection/bridge_ids.dart';
import '../exceptions/laravel_exception.dart';
import 'auth_state.dart';
import 'token_storage.dart';

/// Reactive authentication manager handling logins, token rotation, and user sessions.
class AuthManager<TUser> {
  final LaravelClient client;
  final TokenStorage tokenStorage;
  final TUser Function(Map<String, dynamic> json) userParser;

  /// Called once when the session can no longer be refreshed (refresh token
  /// rejected / missing) and the local session has been cleared.
  void Function()? onSessionExpired;

  /// Refresh the access token shortly before `expires_in` elapses.
  final bool proactiveRefresh;

  /// Margin before expiry at which the proactive refresh fires.
  final Duration refreshMargin;

  final DateTime Function() _clock;

  final _stateController = StreamController<AuthState>.broadcast();
  AuthState _currentState = const Unauthenticated();
  TUser? _currentUser;
  DateTime? _accessTokenExpiresAt;
  DateTime? _refreshTokenExpiresAt;
  Future<String?>? _refreshFuture;
  Timer? _refreshTimer;
  bool _disposed = false;

  /// Current authentication state.
  AuthState get currentState => _currentState;

  /// Stream of authentication state transitions.
  Stream<AuthState> get stateStream => _stateController.stream;

  /// Currently authenticated user instance, if any.
  TUser? get currentUser => _currentUser;

  /// Whether a user is currently authenticated.
  bool get isAuthenticated =>
      _currentState is Authenticated || _currentUser != null;

  /// Expiry of the current access token, from `expires_in` / `expires_at`.
  DateTime? get accessTokenExpiresAt => _accessTokenExpiresAt;

  /// Expiry of the current refresh token, from `refresh_expires_at`.
  DateTime? get refreshTokenExpiresAt => _refreshTokenExpiresAt;

  /// Whether the access token is known to be expired.
  bool get isAccessTokenExpired {
    final expiry = _accessTokenExpiresAt;
    return expiry != null && !_clock().isBefore(expiry);
  }

  AuthManager({
    required this.client,
    TokenStorage? tokenStorage,
    required this.userParser,
    this.onSessionExpired,
    this.proactiveRefresh = true,
    this.refreshMargin = const Duration(seconds: 60),
    DateTime Function()? clock,
  })  : tokenStorage = tokenStorage ?? client.tokenStorage,
        _clock = clock ?? DateTime.now {
    _stateController.add(_currentState);
  }

  static Options _publicAuthOptions({bool sendBearer = false}) => Options(
        extra: {
          AuthInterceptor.skipAuthRefreshExtra: true,
          if (!sendBearer) AuthInterceptor.skipAuthHeaderExtra: true,
        },
      );

  /// Initialize session from persisted tokens on application startup.
  ///
  /// Tokens are only discarded when the server rejects them; network failures
  /// keep them so the session can be restored once the server is reachable.
  Future<TUser?> initialize() async {
    final token = await tokenStorage.getAccessToken();
    if (token == null || token.isEmpty) {
      _currentUser = null;
      _setState(const Unauthenticated());
      return null;
    }

    try {
      final user = await fetchUserProfile();
      if (user != null) {
        _currentUser = user;
        final current = await tokenStorage.getAccessToken() ?? token;
        _setState(Authenticated<TUser>(user: user, accessToken: current));
        return user;
      }
      _setState(const Unauthenticated());
    } on LaravelAuthenticationException catch (e) {
      debugPrint('AuthManager session restoration rejected: ${e.message}');
      await clearSession();
    } on LaravelConnectionRevokedException catch (e) {
      debugPrint('AuthManager session revoked: ${e.message}');
      await clearSession();
    } catch (e) {
      debugPrint('AuthManager session restoration failed: $e');
      // Keep the tokens: the server may simply be unreachable.
      if (_currentUser == null) _setState(const Unauthenticated());
    }
    return null;
  }

  /// Authenticate with email and password.
  ///
  /// When the account uses an authenticator app, the first attempt throws a
  /// [LaravelTwoFactorRequiredException] (state goes back to
  /// [Unauthenticated]); call [login] again with the same credentials plus
  /// [code] (or [recoveryCode]). A wrong code throws the same exception with
  /// `invalid == true`. [extra] fields are sent too (explicit fields win).
  Future<TUser> login({
    required String email,
    required String password,
    String? deviceName,
    String? fcmToken,
    String? code,
    String? recoveryCode,
    Map<String, dynamic>? extra,
  }) {
    return _authenticate(
      client.endpoint(BridgeEndpoints.authLogin),
      {
        if (extra != null) ...extra,
        'email': email,
        'password': password,
        if (deviceName != null) 'device_name': deviceName,
        if (client.options.deviceId != null)
          'device_id': client.options.deviceId,
        if (fcmToken != null) 'fcm_token': fcmToken,
        if (client.options.platform != null)
          'platform': client.options.platform,
        if (code != null) 'code': code,
        if (recoveryCode != null) 'recovery_code': recoveryCode,
      },
    );
  }

  /// Register a new user account.
  Future<TUser> register({
    required String name,
    required String email,
    required String password,
    String? deviceName,
    Map<String, dynamic>? extra,
  }) {
    return _authenticate(
      client.endpoint(BridgeEndpoints.authRegister),
      {
        if (extra != null) ...extra,
        'name': name,
        'email': email,
        'password': password,
        if (deviceName != null) 'device_name': deviceName,
        if (client.options.deviceId != null)
          'device_id': client.options.deviceId,
        if (client.options.platform != null)
          'platform': client.options.platform,
      },
      requireToken: false,
    );
  }

  /// Authenticate using third-party mobile OAuth credentials (Apple, Google, GitHub).
  ///
  /// Supports the same two-step challenge as [login] via [code] /
  /// [recoveryCode].
  Future<TUser> loginWithSocial({
    required String provider,
    required String token,
    String? email,
    String? name,
    String? deviceName,
    String? code,
    String? recoveryCode,
  }) {
    return _authenticate(
      client.endpoint(BridgeEndpoints.authSocial),
      {
        'provider': provider,
        'token': token,
        if (email != null) 'email': email,
        if (name != null) 'name': name,
        if (deviceName != null) 'device_name': deviceName,
        if (client.options.deviceId != null)
          'device_id': client.options.deviceId,
        if (client.options.platform != null)
          'platform': client.options.platform,
        if (code != null) 'code': code,
        if (recoveryCode != null) 'recovery_code': recoveryCode,
      },
    );
  }

  /// Request a Two-Factor Authentication OTP code to be sent.
  Future<String> sendTwoFactorOtp(String email) async {
    final response = await client.post<Map<String, dynamic>>(
      client.endpoint(BridgeEndpoints.authTwoFactorSend),
      data: {'email': email},
      requestOptions: _publicAuthOptions(),
    );
    return response.data?['two_factor_token'] as String;
  }

  /// Complete login by verifying a 6-digit Two-Factor code.
  Future<TUser> verifyTwoFactor({
    required String twoFactorToken,
    required String code,
  }) {
    return _authenticate(
      client.endpoint(BridgeEndpoints.authTwoFactorVerify),
      {
        'two_factor_token': twoFactorToken,
        'code': code,
        if (client.options.deviceId != null)
          'device_id': client.options.deviceId,
      },
    );
  }

  Future<TUser> _authenticate(
    String path,
    Map<String, dynamic> body, {
    bool requireToken = true,
  }) async {
    _setState(const Authenticating());

    try {
      final response = await client.post<Map<String, dynamic>>(
        path,
        data: body,
        requestOptions: _publicAuthOptions(),
      );

      final payload = response.data ?? const <String, dynamic>{};
      final rawUser = payload['user'];
      if (rawUser is! Map) {
        throw const LaravelException(
            message: 'Authentication response did not include a user.');
      }
      final user = userParser(parseBridgeMap(rawUser));
      final accessToken = await _persistAuthorization(payload['authorization']);

      if (accessToken == null) {
        if (requireToken) {
          throw const LaravelException(
            message: 'Authentication response did not include an access token.',
          );
        }
        _setState(const Unauthenticated());
        return user;
      }

      _currentUser = user;
      _setState(Authenticated<TUser>(user: user, accessToken: accessToken));
      return user;
    } on LaravelTwoFactorRequiredException {
      // Not an error: the server wants a code. Nothing was persisted (the
      // challenge arrives before any token); go back to Unauthenticated so the
      // UI can ask for the code and call login again.
      _setState(const Unauthenticated());
      rethrow;
    } catch (e) {
      _setState(AuthError(
          message: e is LaravelException ? e.message : e.toString(), cause: e));
      rethrow;
    }
  }

  /// Persist an `authorization` object (§6). Returns the access token, if any.
  Future<String?> _persistAuthorization(dynamic rawAuthorization) async {
    final auth = parseBridgeMap(rawAuthorization);
    final accessToken = auth['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) return null;

    await tokenStorage.saveAccessToken(accessToken);
    final refreshToken = auth['refresh_token'] as String?;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await tokenStorage.saveRefreshToken(refreshToken);
    }

    final expiresIn = parseBridgeInt(auth['expires_in']);
    _accessTokenExpiresAt = expiresIn != null
        ? _clock().add(Duration(seconds: expiresIn))
        : parseBridgeDate(auth['expires_at']);
    _refreshTokenExpiresAt = parseBridgeDate(auth['refresh_expires_at']);
    _scheduleProactiveRefresh();
    return accessToken;
  }

  void _scheduleProactiveRefresh() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    final expiry = _accessTokenExpiresAt;
    if (!proactiveRefresh || expiry == null || _disposed) return;

    var delay = expiry.subtract(refreshMargin).difference(_clock());
    if (delay.isNegative) delay = Duration.zero;
    _refreshTimer = Timer(delay, () {
      if (!_disposed) {
        refreshToken().catchError((Object e) {
          debugPrint('AuthManager proactive refresh failed: $e');
          return null;
        });
      }
    });
  }

  /// Refresh the access token if it is expired or about to expire.
  Future<String?> ensureFreshToken() async {
    final expiry = _accessTokenExpiresAt;
    if (expiry != null && !_clock().add(refreshMargin).isBefore(expiry)) {
      return refreshToken();
    }
    return tokenStorage.getAccessToken();
  }

  /// Fetch the current user profile from `/auth/me`.
  Future<TUser?> fetchUserProfile() async {
    final response = await client.get<Map<String, dynamic>>(
      client.endpoint(BridgeEndpoints.authMe),
    );
    final userMap = response.data?['user'];
    if (userMap is Map) {
      return userParser(parseBridgeMap(userMap));
    }
    return null;
  }

  /// Refresh the access token using the stored refresh token (rotation).
  ///
  /// The refresh endpoint is public: no (stale) bearer token is sent and the
  /// request never triggers the interceptor's refresh logic. Concurrent calls
  /// share one request. When the server rejects the refresh the session is
  /// cleared **locally** (no network logout, which would dead-lock on a 401),
  /// [onSessionExpired] fires and `null` is returned. Network failures keep the
  /// session and rethrow the [LaravelNetworkException].
  Future<String?> refreshToken() {
    return _refreshFuture ??=
        _doRefresh().whenComplete(() => _refreshFuture = null);
  }

  Future<String?> _doRefresh() async {
    final currentRefreshToken = await tokenStorage.getRefreshToken();
    if (currentRefreshToken == null || currentRefreshToken.isEmpty) {
      await expireSession();
      return null;
    }

    final previousState = _currentState;
    if (previousState is Authenticated) _setState(const RefreshingToken());

    try {
      final response = await client.post<Map<String, dynamic>>(
        client.endpoint(BridgeEndpoints.authRefresh),
        data: {
          'refresh_token': currentRefreshToken,
          if (client.options.deviceId != null)
            'device_id': client.options.deviceId,
        },
        requestOptions: _publicAuthOptions(),
      );

      final newAccessToken =
          await _persistAuthorization(response.data?['authorization']);
      if (newAccessToken != null) {
        final user = _currentUser;
        if (user != null) {
          _setState(
              Authenticated<TUser>(user: user, accessToken: newAccessToken));
        } else if (_currentState is RefreshingToken) {
          _setState(previousState);
        }
        return newAccessToken;
      }
      debugPrint(
          'AuthManager refresh response did not include an access token');
    } on LaravelNetworkException catch (e) {
      // Transient: keep the session, the next request will retry.
      debugPrint('AuthManager refresh token failed (network): ${e.message}');
      if (_currentState is RefreshingToken) _setState(previousState);
      rethrow;
    } catch (e) {
      debugPrint('AuthManager refresh token failed: $e');
    }

    await expireSession();
    return null;
  }

  /// Clear the local session and notify [onSessionExpired] (once per session).
  Future<void> expireSession() async {
    final hadSession = _currentUser != null || await _hasStoredToken();
    await clearSession();
    if (hadSession) {
      try {
        onSessionExpired?.call();
      } catch (e) {
        debugPrint('AuthManager onSessionExpired callback threw: $e');
      }
    }
  }

  /// Forget tokens and user locally without contacting the server.
  Future<void> clearSession() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _accessTokenExpiresAt = null;
    _refreshTokenExpiresAt = null;
    try {
      await tokenStorage.clear();
    } catch (e) {
      debugPrint('AuthManager failed to clear token storage: $e');
    }
    _currentUser = null;
    _setState(const Unauthenticated());
  }

  Future<bool> _hasStoredToken() async {
    try {
      final access = await tokenStorage.getAccessToken();
      final refresh = await tokenStorage.getRefreshToken();
      return (access != null && access.isNotEmpty) ||
          (refresh != null && refresh.isNotEmpty);
    } catch (_) {
      return false;
    }
  }

  /// Revoke tokens and terminate local user session.
  Future<void> logout() async {
    try {
      final token = await tokenStorage.getAccessToken();
      if (token != null && token.isNotEmpty) {
        await client.post<dynamic>(
          client.endpoint(BridgeEndpoints.authLogout),
          requestOptions: _publicAuthOptions(sendBearer: true),
        );
      }
    } catch (_) {
      // Ignore network failures on logout
    } finally {
      await clearSession();
    }
  }

  void _setState(AuthState state) {
    _currentState = state;
    if (!_stateController.isClosed) _stateController.add(state);
  }

  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    _stateController.close();
  }
}
