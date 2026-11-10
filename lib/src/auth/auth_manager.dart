import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../client/interceptors/auth_interceptor.dart';
import '../client/laravel_client.dart';
import '../connection/bridge_endpoints.dart';
import '../connection/bridge_ids.dart';
import '../exceptions/laravel_exception.dart';
import '../storage/key_value_store.dart';
import 'auth_state.dart';
import 'fortify_models.dart';
import 'passkey_manager.dart';
import 'token_storage.dart';
import 'two_factor_manager.dart';

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

  BridgeKeyValueStore? _userCache;
  String _userCacheKey = defaultUserCacheKey;

  /// Storage key of the cached user when [attachUserCache] is given no key.
  static const String defaultUserCacheKey = 'flutter_laravel_user';

  final _stateController = StreamController<AuthState>.broadcast();
  AuthState _currentState = const Unauthenticated();
  TUser? _currentUser;
  DateTime? _accessTokenExpiresAt;
  DateTime? _refreshTokenExpiresAt;
  Future<String?>? _refreshFuture;
  Timer? _refreshTimer;
  bool _disposed = false;
  FortifyFeatures? _fortifyOverride;
  PasswordConfirmation? _passwordConfirmation;
  late final TwoFactorManager<TUser> twoFactor = TwoFactorManager<TUser>(this);
  late final PasskeyManager passkeys = PasskeyManager(this);

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

  /// Remember the signed-in user in [store] under [key], so a session can be
  /// restored while the server is unreachable (e.g. the app starts offline).
  /// The cached user is written on every sign-in and profile fetch and
  /// removed with the session.
  void attachUserCache(BridgeKeyValueStore store,
      {String key = defaultUserCacheKey}) {
    _userCache = store;
    _userCacheKey = key;
  }

  Future<void> _cacheUser(Map<String, dynamic> raw) async {
    final cache = _userCache;
    if (cache == null) return;
    try {
      await cache.write(_userCacheKey, jsonEncode(raw));
    } catch (e) {
      debugPrint('AuthManager failed to cache the user: $e');
    }
  }

  Future<TUser?> _cachedUser() async {
    final cache = _userCache;
    if (cache == null) return null;
    try {
      final raw = await cache.read(_userCacheKey);
      if (raw == null || raw.isEmpty) return null;
      return userParser(parseBridgeMap(jsonDecode(raw)));
    } catch (e) {
      debugPrint('AuthManager ignored an unreadable cached user: $e');
      return null;
    }
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
      // Keep the tokens: the server may simply be unreachable. Restore the
      // last known user so the app stays signed in while offline.
      final cached = _currentUser ?? await _cachedUser();
      if (cached != null) {
        _currentUser = cached;
        _setState(Authenticated<TUser>(user: cached, accessToken: token));
        return cached;
      }
      _setState(const Unauthenticated());
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
  }) async {
    requireFortifyFeature('registration');
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
      final userJson = parseBridgeMap(rawUser);
      final user = userParser(userJson);
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
      await _cacheUser(userJson);
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
      final json = parseBridgeMap(userMap);
      final user = userParser(json);
      await _cacheUser(json);
      return user;
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
    try {
      await _userCache?.delete(_userCacheKey);
    } catch (e) {
      debugPrint('AuthManager failed to clear the cached user: $e');
    }
    _currentUser = null;
    _passwordConfirmation = null;
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

  // ---------------------------------------------------------------------------
  // Laravel Fortify over the bridge (FORTIFY.md)
  // ---------------------------------------------------------------------------

  /// Fortify features of the server (`features.fortify` of the handshake, or
  /// of `GET config` after [refreshFortifyFeatures]).
  FortifyFeatures get fortify =>
      _fortifyOverride ??
      client.serverInfo?.fortify ??
      FortifyFeatures.unavailable(
          registration: client.serverInfo?.features.registration ?? true);

  /// Replace the discovered [fortify] features (`null` goes back to the
  /// handshake of the client's server).
  set fortify(FortifyFeatures? features) => _fortifyOverride = features;

  /// Read `features.fortify` from `GET config` (useful without a
  /// [LaravelConnectionManager], which already reads it from the handshake).
  Future<FortifyFeatures> refreshFortifyFeatures() async {
    final response = await client.get<dynamic>(
      client.endpoint(BridgeEndpoints.config),
      requestOptions: _publicAuthOptions(sendBearer: true),
    );
    final data = parseBridgeMap(response.data);
    final features = parseBridgeMap(data['features']);
    final raw = features['fortify'] ?? data['fortify'];
    final parsed = FortifyFeatures.fromJson(raw,
        registrationFallback:
            parseBridgeBool(features['registration']) ?? fortify.registration);
    _fortifyOverride = parsed;
    return parsed;
  }

  /// Throw a [LaravelFeatureDisabledException] — without any request — when
  /// the server published `features.fortify` and [feature] is off in it.
  void requireFortifyFeature(String feature) {
    final features = fortify;
    if (!features.advertised) return;
    final enabled = switch (feature) {
      'registration' => features.registration,
      'reset_passwords' => features.resetPasswords,
      'email_verification' => features.emailVerification,
      'update_profile_information' => features.updateProfileInformation,
      'update_passwords' => features.updatePasswords,
      'two_factor_authentication' => features.twoFactorAuthentication,
      'passkeys' => features.passkeys,
      _ => features.has(feature),
    };
    if (!enabled) {
      throw LaravelFeatureDisabledException(
        message: 'The server does not offer $feature.',
        feature: feature,
      );
    }
  }

  /// Latest known password confirmation of this session (from
  /// [confirmPassword] / [confirmedPasswordStatus]); `null` when unknown.
  PasswordConfirmation? get passwordConfirmation => _passwordConfirmation;

  /// Whether the password was confirmed recently enough, judged locally from
  /// the last [confirmPassword] / [confirmedPasswordStatus] answer.
  bool get isPasswordConfirmed =>
      _passwordConfirmation?.isConfirmed(_clock()) ?? false;

  /// Ask the server to send a password reset (a 6-digit code by default).
  /// Always succeeds for a well-formed address: the server never reveals
  /// whether an account exists.
  Future<PasswordResetRequest> forgotPassword(String email) async {
    requireFortifyFeature('reset_passwords');
    final response = await client.post<dynamic>(
      client.endpoint(BridgeEndpoints.authForgotPassword),
      data: {'email': email},
      requestOptions: _publicAuthOptions(),
    );
    return PasswordResetRequest.fromJson(parseBridgeMap(response.data));
  }

  /// Exchange the emailed [code] for a short-lived, single-use reset token
  /// to pass to [resetPassword]. Throws [LaravelCodeException] when the code
  /// is invalid, expired or locked.
  Future<String> verifyPasswordResetCode({
    required String email,
    required String code,
  }) async {
    requireFortifyFeature('reset_passwords');
    final response = await client.post<dynamic>(
      client.endpoint(BridgeEndpoints.authResetPasswordVerifyCode),
      data: {'email': email, 'code': code},
      requestOptions: _publicAuthOptions(),
    );
    final token = parseBridgeMap(response.data)['reset_token']?.toString();
    if (token == null || token.isEmpty) {
      throw const LaravelException(
          message: 'The server did not return a reset token.');
    }
    return token;
  }

  /// Choose a new password with a [resetToken] (from
  /// [verifyPasswordResetCode]) or a Fortify broker [token] (from the email
  /// link). The server signs every device of the user out.
  Future<void> resetPassword({
    required String email,
    required String password,
    required String passwordConfirmation,
    String? resetToken,
    String? token,
  }) async {
    if ((resetToken == null || resetToken.isEmpty) &&
        (token == null || token.isEmpty)) {
      throw ArgumentError('Pass either resetToken or token.');
    }
    requireFortifyFeature('reset_passwords');
    await client.post<dynamic>(
      client.endpoint(BridgeEndpoints.authResetPassword),
      data: {
        'email': email,
        'password': password,
        'password_confirmation': passwordConfirmation,
        if (resetToken != null && resetToken.isNotEmpty)
          'reset_token': resetToken,
        if (token != null && token.isNotEmpty) 'token': token,
      },
      requestOptions: _publicAuthOptions(),
    );
  }

  /// Email a verification code to the signed-in user. Throws
  /// [LaravelAlreadyVerifiedException] when the address is already verified.
  Future<void> sendEmailVerification() async {
    requireFortifyFeature('email_verification');
    await client.post<dynamic>(
      client.endpoint(BridgeEndpoints.authEmailVerificationNotification),
    );
  }

  /// Verify the signed-in user's email address with the emailed [code].
  /// Updates [currentUser], the offline user cache and [stateStream].
  Future<TUser> verifyEmail(String code) async {
    requireFortifyFeature('email_verification');
    final response = await client.post<dynamic>(
      client.endpoint(BridgeEndpoints.authEmailVerify),
      data: {'code': code},
    );
    return await _userFromResponse(response.data);
  }

  /// Update the signed-in user's profile with the fields of Fortify's
  /// `UpdatesUserProfileInformation` (`name`, `email`, …). Updates
  /// [currentUser], the offline user cache and [stateStream].
  Future<TUser> updateProfile(Map<String, dynamic> fields) async {
    requireFortifyFeature('update_profile_information');
    final response = await client.put<dynamic>(
      client.endpoint(BridgeEndpoints.authProfileInformation),
      data: fields,
    );
    return await _userFromResponse(response.data);
  }

  /// Change the signed-in user's password. With [revokeOtherSessions] every
  /// other device is signed out; this one stays signed in.
  Future<void> updatePassword({
    required String currentPassword,
    required String password,
    required String passwordConfirmation,
    bool revokeOtherSessions = false,
  }) async {
    requireFortifyFeature('update_passwords');
    final response = await client.put<dynamic>(
      client.endpoint(BridgeEndpoints.authUserPassword),
      data: {
        'current_password': currentPassword,
        'password': password,
        'password_confirmation': passwordConfirmation,
        if (revokeOtherSessions) 'revoke_other_sessions': true,
      },
    );
    // Tolerate servers that rotate the current token on password change.
    final data = parseBridgeMap(response.data);
    if (data['authorization'] is Map) {
      final token = await _persistAuthorization(data['authorization']);
      final user = _currentUser;
      if (token != null && user != null) {
        _setState(Authenticated<TUser>(user: user, accessToken: token));
      }
    }
  }

  /// Confirm the signed-in user's [password] so sensitive actions (two-factor
  /// and passkey management) are allowed for `password_timeout`.
  /// A wrong password throws a [LaravelValidationError] (`password_invalid`).
  Future<PasswordConfirmation> confirmPassword(String password) async {
    final response = await client.post<dynamic>(
      client.endpoint(BridgeEndpoints.authConfirmPassword),
      data: {'password': password},
    );
    return _passwordConfirmation = PasswordConfirmation.fromJson(
      parseBridgeMap(response.data),
      now: _clock(),
      timeout: fortify.passwordTimeout,
      justConfirmed: true,
    );
  }

  /// Ask the server whether the password was confirmed recently enough.
  Future<PasswordConfirmation> confirmedPasswordStatus() async {
    final response = await client.get<dynamic>(
      client.endpoint(BridgeEndpoints.authConfirmedPasswordStatus),
    );
    return _passwordConfirmation = PasswordConfirmation.fromJson(
      parseBridgeMap(response.data),
      now: _clock(),
      timeout: fortify.passwordTimeout,
    );
  }

  /// Run [action]; when the server answers 423 `password_confirmation_required`
  /// ask the user for their password with [askPassword], confirm it and run
  /// [action] once more. When [askPassword] returns `null` (or an empty
  /// string) the original [LaravelPasswordConfirmationRequiredException] is
  /// rethrown; a wrong password throws the confirmation's validation error.
  Future<T> runWithPasswordConfirmation<T>(
    Future<T> Function() action,
    Future<String?> Function() askPassword,
  ) async {
    try {
      return await action();
    } on LaravelPasswordConfirmationRequiredException {
      _passwordConfirmation = null;
      final password = await askPassword();
      if (password == null || password.isEmpty) rethrow;
      await confirmPassword(password);
      return await action();
    }
  }

  /// Forget the known password confirmation (after a 423).
  void markPasswordUnconfirmed() => _passwordConfirmation = null;

  /// Re-read the user from `auth/me` and publish it (two-factor changes).
  Future<TUser?> reloadUser() async {
    final user = await fetchUserProfile();
    if (user != null) await _publishUser(user);
    return user;
  }

  /// Parse the user of a Fortify response (`{user: {...}}`, or the bare user
  /// object), cache it and publish it. Falls back to `auth/me`.
  Future<TUser> _userFromResponse(dynamic data) async {
    final map = parseBridgeMap(data);
    final rawUser =
        map['user'] is Map ? map['user'] : (map.containsKey('id') ? map : null);
    if (rawUser == null) {
      final user = await reloadUser();
      if (user == null) {
        throw const LaravelException(
            message: 'The server did not return the user.');
      }
      return user;
    }
    final json = parseBridgeMap(rawUser);
    final user = userParser(json);
    await _cacheUser(json);
    await _publishUser(user);
    return user;
  }

  /// Publish a user payload received from the server (`{user: {...}}` or the
  /// bare user; anything else re-reads `auth/me`): updates [currentUser], the
  /// offline user cache and [stateStream].
  Future<TUser> applyUserPayload(dynamic data) => _userFromResponse(data);

  Future<void> _publishUser(TUser user) async {
    _currentUser = user;
    final state = _currentState;
    String? token = state is Authenticated ? state.accessToken : null;
    token ??= await tokenStorage.getAccessToken();
    if (token != null && token.isNotEmpty) {
      _setState(Authenticated<TUser>(user: user, accessToken: token));
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
