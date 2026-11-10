import 'dart:async';
import 'package:dio/dio.dart';
import '../../auth/token_storage.dart';
import '../../exceptions/laravel_exception.dart';
import 'error_interceptor.dart';

/// Interceptor that manages token injection, 401 interception, and auto-refresh token rotation.
///
/// * Concurrent 401s share a single in-flight refresh.
/// * Requests flagged with `extra: {'skipAuthRefresh': true}` (all bridge auth
///   calls) and the public auth endpoints never trigger a refresh, which makes
///   the refresh → logout → 401 → refresh dead-lock impossible.
/// * Error codes `invalid_refresh_token`, `refresh_token_reused`,
///   `connection_revoked` and `app_*` never trigger a refresh.
/// * Failed requests are retried once with a cloned [RequestOptions].
class AuthInterceptor extends Interceptor {
  /// Request `extra` flag: never attempt a token refresh for this request.
  static const String skipAuthRefreshExtra = 'skipAuthRefresh';

  /// Request `extra` flag: do not attach the stored bearer token.
  static const String skipAuthHeaderExtra = 'skipAuthHeader';

  static const String _retriedExtra = 'authRetried';

  /// Path fragments of public auth endpoints that must never trigger a refresh.
  static final RegExp _publicAuthPath = RegExp(
    r'(^|/)auth/(login|register|refresh|logout|social|2fa)(/|$|\?)',
  );

  final TokenStorage tokenStorage;
  final Dio dio;
  final Future<String?> Function()? onRefreshToken;
  final void Function()? onSessionExpired;

  Future<String?>? _refreshFuture;

  AuthInterceptor({
    required this.tokenStorage,
    required this.dio,
    this.onRefreshToken,
    this.onSessionExpired,
  });

  /// Whether a refresh is currently in flight.
  bool get isRefreshing => _refreshFuture != null;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // If request already explicitly specified an Authorization header, respect it
    if (options.extra[skipAuthHeaderExtra] != true &&
        !options.headers.containsKey('Authorization')) {
      try {
        final token = await tokenStorage.getAccessToken();
        if (token != null && token.isNotEmpty) {
          options.headers['Authorization'] = 'Bearer $token';
        }
      } catch (_) {
        // A failing storage must not block the request; it goes out unauthenticated.
      }
    }

    handler.next(options);
  }

  @override
  Future<void> onError(
      DioException err, ErrorInterceptorHandler handler) async {
    final response = err.response;

    // Only intercept 401 Unauthorized
    if (response?.statusCode != 401) {
      return handler.next(err);
    }

    final request = err.requestOptions;
    final code = ErrorInterceptor.errorCodeOf(response?.data);

    if (request.extra[skipAuthRefreshExtra] == true ||
        _publicAuthPath.hasMatch(request.path)) {
      return handler.next(err);
    }

    if (code != null && LaravelErrorCode.noRefresh.contains(code)) {
      if (code == LaravelErrorCode.invalidRefreshToken ||
          code == LaravelErrorCode.refreshTokenReused) {
        _notifyExpired();
      }
      return handler.next(err);
    }

    if (onRefreshToken == null || request.extra[_retriedExtra] == true) {
      _notifyExpired();
      return handler.next(err);
    }

    final sentToken = _bearerOf(request);
    final String? newToken;
    try {
      newToken = await _refreshOnce(sentToken);
    } catch (_) {
      // Transient refresh failure (e.g. offline): keep the session, surface the 401.
      return handler.next(err);
    }

    if (newToken == null || newToken.isEmpty) {
      return handler.next(err);
    }

    final retryOptions = request.copyWith(
      headers: {
        ...request.headers,
        'Authorization': 'Bearer $newToken',
      },
      extra: {
        ...request.extra,
        _retriedExtra: true,
      },
    );

    try {
      final retryResponse = await dio.fetch<dynamic>(retryOptions);
      return handler.resolve(retryResponse);
    } on DioException catch (retryError) {
      return handler.next(retryError);
    } catch (e, stack) {
      return handler.next(
        DioException(requestOptions: retryOptions, error: e, stackTrace: stack),
      );
    }
  }

  /// Run (or join) a single refresh. Returns the new token, or `null` when the
  /// refresh was rejected — in which case [onSessionExpired] has been called once.
  /// Throws when the refresh failed transiently (network), without expiring.
  Future<String?> _refreshOnce(String? sentToken) async {
    // A refresh already completed after this request was sent: reuse its token.
    if (_refreshFuture == null && sentToken != null) {
      final current = await tokenStorage.getAccessToken();
      if (current != null && current.isNotEmpty && current != sentToken) {
        return current;
      }
    }

    final inFlight = _refreshFuture;
    if (inFlight != null) return inFlight;

    final completer = Completer<String?>();
    // Waiters must not surface an unhandled error if nobody else is listening.
    completer.future.ignore();
    _refreshFuture = completer.future;

    try {
      final token = await onRefreshToken!();
      _refreshFuture = null;
      completer.complete(token);
      if (token == null || token.isEmpty) {
        _notifyExpired();
      }
      return token;
    } on LaravelNetworkException catch (e, stack) {
      _refreshFuture = null;
      completer.completeError(e, stack);
      rethrow;
    } catch (_) {
      _refreshFuture = null;
      completer.complete(null);
      _notifyExpired();
      return null;
    }
  }

  void _notifyExpired() {
    try {
      onSessionExpired?.call();
    } catch (_) {
      // Callbacks must not break the interceptor chain.
    }
  }

  static String? _bearerOf(RequestOptions request) {
    final header = request.headers['Authorization']?.toString();
    if (header == null || !header.startsWith('Bearer ')) return null;
    return header.substring(7);
  }
}
