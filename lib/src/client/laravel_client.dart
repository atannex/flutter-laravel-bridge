import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../auth/token_storage.dart';
import '../cache/cache_policy.dart';
import '../connection/bridge_ids.dart';
import '../connection/server_info.dart';
import '../exceptions/laravel_exception.dart';
import '../models/api_response.dart';
import '../offline/mutation_record.dart';
import '../offline/offline_queue.dart';
import '../pagination/paginated_response.dart';
import '../query/laravel_query.dart';
import 'interceptors/auth_interceptor.dart';
import 'interceptors/connection_interceptor.dart';
import 'interceptors/error_interceptor.dart';
import 'interceptors/logging_interceptor.dart';
import 'interceptors/telemetry_interceptor.dart';
import 'laravel_options.dart';

/// The primary enterprise HTTP client communicating with Laravel backend.
class LaravelClient {
  final LaravelOptions options;
  final TokenStorage tokenStorage;
  final Dio _dio;
  final CacheManager _cacheManager;
  final OfflineQueue _offlineQueue;
  late final ConnectionInterceptor _connectionInterceptor;
  late final AuthInterceptor _authInterceptor;

  final ValueNotifier<ServerInfo?> _serverInfo;

  /// Latest handshake of the server this client talks to. Set by
  /// [LaravelConnectionManager]; used to resolve endpoint paths.
  ServerInfo? get serverInfo => _serverInfo.value;
  set serverInfo(ServerInfo? info) => _serverInfo.value = info;

  /// Notifies whenever [serverInfo] is replaced (a new handshake).
  ValueListenable<ServerInfo?> get serverInfoListenable => _serverInfo;

  Dio get rawDio => _dio;
  OfflineQueue get offlineQueue => _offlineQueue;
  CacheManager get cacheManager => _cacheManager;

  /// Interceptor attaching the bridge protocol headers.
  ConnectionInterceptor get connectionInterceptor => _connectionInterceptor;

  /// Interceptor handling bearer tokens and refresh rotation.
  AuthInterceptor get authInterceptor => _authInterceptor;

  /// Difference between the server clock and the local clock, from `X-Flutter-Server-Time`.
  Duration? get serverClockOffset => _connectionInterceptor.serverClockOffset;

  /// Current time on the server, estimated from [serverClockOffset].
  DateTime serverNow() => _connectionInterceptor.serverNow();

  LaravelClient({
    required this.options,
    TokenStorage? tokenStorage,
    Future<String?> Function()? onRefreshToken,
    void Function()? onSessionExpired,
    Dio? customDio,
    String? Function()? connectionIdProvider,
    void Function(LaravelException exception, RequestOptions request)?
        onException,
    DateTime Function()? clock,
    ServerInfo? serverInfo,
    OfflineQueue? offlineQueue,
    CacheManager? cacheManager,
  })  : tokenStorage = tokenStorage ?? InMemoryTokenStorage(),
        _dio = customDio ?? Dio(buildBaseOptions(options)),
        _serverInfo = ValueNotifier<ServerInfo?>(serverInfo),
        _offlineQueue = offlineQueue ?? OfflineQueue(),
        _cacheManager = cacheManager ?? CacheManager() {
    _setupInterceptors(
      onRefreshToken,
      onSessionExpired,
      connectionIdProvider,
      onException,
      clock,
    );
  }

  /// Build the Dio [BaseOptions] matching [options]. The base URL always ends
  /// with a slash so relative endpoint paths (`api/flutter/ping`) join correctly.
  static BaseOptions buildBaseOptions(LaravelOptions options) {
    return BaseOptions(
      baseUrl: normalizeBaseUrl(options.baseUrl),
      connectTimeout: options.connectTimeout,
      receiveTimeout: options.receiveTimeout,
      sendTimeout: options.sendTimeout,
      headers: Map<String, dynamic>.of(options.headers),
    );
  }

  /// Ensure [baseUrl] ends with exactly one `/`.
  static String normalizeBaseUrl(String baseUrl) {
    var url = baseUrl.trim();
    if (url.isEmpty) return url;
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return '$url/';
  }

  /// Resolve a protocol endpoint path ([BridgeEndpoints] key), preferring the
  /// server advertised table and falling back to [LaravelOptions] prefixes.
  String endpoint(String key, {Map<String, Object> params = const {}}) {
    final info = serverInfo;
    if (info != null) return info.endpoint(key, params: params);
    return options.defaultEndpoint(key, params: params);
  }

  void _setupInterceptors(
    Future<String?> Function()? onRefreshToken,
    void Function()? onSessionExpired,
    String? Function()? connectionIdProvider,
    void Function(LaravelException exception, RequestOptions request)?
        onException,
    DateTime Function()? clock,
  ) {
    _connectionInterceptor = ConnectionInterceptor(
      appKey: options.appKey,
      connectionIdProvider: connectionIdProvider,
      clock: clock,
    );
    _authInterceptor = AuthInterceptor(
      tokenStorage: tokenStorage,
      dio: _dio,
      onRefreshToken: onRefreshToken,
      onSessionExpired: onSessionExpired,
    );
    _dio.interceptors.addAll([
      TelemetryInterceptor(options),
      _connectionInterceptor,
      _authInterceptor,
      LaravelLoggingInterceptor(enabled: options.enableLogging),
      ErrorInterceptor(onException: onException, clock: clock),
    ]);
  }

  /// Release the underlying HTTP resources. Pending requests are cancelled.
  void close({bool force = true}) {
    _dio.close(force: force);
    _offlineQueue.dispose();
  }

  /// Perform a GET request with optional caching policy and query builder.
  ///
  /// The body may be the bridge envelope or plain JSON (an object or a list),
  /// see [ApiResponse.fromBody].
  Future<ApiResponse<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    LaravelQuery? query,
    CachePolicy cachePolicy = CachePolicy.networkOnly,
    Duration cacheTtl = const Duration(minutes: 5),
    T Function(dynamic json)? fromJson,
    Options? requestOptions,
  }) async {
    final body = await _getBody(
      path,
      queryParameters: queryParameters,
      query: query,
      cachePolicy: cachePolicy,
      cacheTtl: cacheTtl,
      requestOptions: requestOptions,
    );
    return ApiResponse<T>.fromBody(body, fromJson);
  }

  /// GET a plain JSON object and return the decoded body as is (no envelope
  /// unwrapping). Meant for ordinary Laravel endpoints that return raw JSON.
  /// Honours [cachePolicy] exactly like [get].
  ///
  /// Throws a [LaravelException] when the body is not a JSON object.
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, dynamic>? queryParameters,
    LaravelQuery? query,
    CachePolicy cachePolicy = CachePolicy.networkOnly,
    Duration cacheTtl = const Duration(minutes: 5),
    Options? requestOptions,
  }) async {
    final body = await _getBody(
      path,
      queryParameters: queryParameters,
      query: query,
      cachePolicy: cachePolicy,
      cacheTtl: cacheTtl,
      requestOptions: requestOptions,
    );
    if (body is Map<String, dynamic>) return body;
    if (body is Map) return parseBridgeMap(body);
    throw LaravelException(
        message: 'Expected a JSON object from $path, got ${body.runtimeType}.');
  }

  /// GET [path] and return the decoded body, applying [cachePolicy].
  Future<dynamic> _getBody(
    String path, {
    Map<String, dynamic>? queryParameters,
    LaravelQuery? query,
    required CachePolicy cachePolicy,
    required Duration cacheTtl,
    Options? requestOptions,
  }) async {
    final mergedParams = <String, dynamic>{
      if (queryParameters != null) ...queryParameters,
      if (query != null) ...query.toMap(),
    };

    final cacheKey = '$path:${mergedParams.toString()}';
    if (cachePolicy != CachePolicy.networkOnly) {
      // Load persisted entries on first use.
      await _cacheManager.restore();
    }

    // 1. Check cache first if requested
    if (cachePolicy == CachePolicy.cacheFirst ||
        cachePolicy == CachePolicy.cacheOnly) {
      final cached = _cacheManager.get(cacheKey);
      if (cached != null) return cached;
      if (cachePolicy == CachePolicy.cacheOnly) {
        throw const LaravelException(
            message: 'Cached data not found for requested resource.');
      }
    }

    try {
      final response = await _dio.get<dynamic>(
        path,
        queryParameters: mergedParams.isEmpty ? null : mergedParams,
        options: requestOptions,
      );

      final rawData = response.data ?? <String, dynamic>{};

      // Store in cache if enabled
      if (cachePolicy != CachePolicy.networkOnly) {
        _cacheManager.put(cacheKey, rawData, cacheTtl);
      }

      return rawData;
    } on DioException catch (e) {
      // 2. If network request failed but networkFirst was requested, fallback to cache
      if (e.error is LaravelNetworkException &&
          cachePolicy == CachePolicy.networkFirst) {
        final cached = _cacheManager.get(cacheKey);
        if (cached != null) return cached;
      }
      _throwTyped(e);
    }
  }

  /// Perform a POST request. Optionally queues into [OfflineQueue] when offline.
  Future<ApiResponse<T>> post<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    T Function(dynamic json)? fromJson,
    bool queueIfOffline = false,
    Options? requestOptions,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: requestOptions,
      );

      return ApiResponse<T>.fromBody(response.data, fromJson);
    } on DioException catch (e) {
      if (queueIfOffline && e.error is LaravelNetworkException) {
        _enqueueMutation('POST', path, data, queryParameters);
      }
      _throwTyped(e);
    }
  }

  /// Perform a PUT request.
  Future<ApiResponse<T>> put<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    T Function(dynamic json)? fromJson,
    bool queueIfOffline = false,
    Options? requestOptions,
  }) async {
    try {
      final response = await _dio.put<dynamic>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: requestOptions,
      );

      return ApiResponse<T>.fromBody(response.data, fromJson);
    } on DioException catch (e) {
      if (queueIfOffline && e.error is LaravelNetworkException) {
        _enqueueMutation('PUT', path, data, queryParameters);
      }
      _throwTyped(e);
    }
  }

  /// Perform a PATCH request.
  Future<ApiResponse<T>> patch<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    T Function(dynamic json)? fromJson,
    bool queueIfOffline = false,
    Options? requestOptions,
  }) async {
    try {
      final response = await _dio.patch<dynamic>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: requestOptions,
      );

      return ApiResponse<T>.fromBody(response.data, fromJson);
    } on DioException catch (e) {
      if (queueIfOffline && e.error is LaravelNetworkException) {
        _enqueueMutation('PATCH', path, data, queryParameters);
      }
      _throwTyped(e);
    }
  }

  /// Perform a DELETE request.
  Future<ApiResponse<T>> delete<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    T Function(dynamic json)? fromJson,
    bool queueIfOffline = false,
    Options? requestOptions,
  }) async {
    try {
      final response = await _dio.delete<dynamic>(
        path,
        data: data,
        queryParameters: queryParameters,
        options: requestOptions,
      );

      return ApiResponse<T>.fromBody(response.data, fromJson);
    } on DioException catch (e) {
      if (queueIfOffline && e.error is LaravelNetworkException) {
        _enqueueMutation('DELETE', path, data, queryParameters);
      }
      _throwTyped(e);
    }
  }

  /// Perform a paginated GET request returning a typed [PaginatedResponse<T>].
  Future<PaginatedResponse<T>> paginate<T>(
    String path, {
    int page = 1,
    int? perPage,
    Map<String, dynamic>? queryParameters,
    LaravelQuery? query,
    required T Function(dynamic item) itemParser,
  }) async {
    final params = Map<String, dynamic>.from(queryParameters ?? {});
    if (query != null) {
      params.addAll(query.toMap());
    }

    params['page'] = page;
    if (perPage != null) {
      params['per_page'] = perPage;
    }

    try {
      final response = await _dio.get<Map<String, dynamic>>(
        path,
        queryParameters: params,
      );

      final rawData = response.data ?? <String, dynamic>{};
      return PaginatedResponse<T>.fromJson(rawData, itemParser);
    } on DioException catch (e) {
      _throwTyped(e);
    }
  }

  /// Replay pending mutations queued in [OfflineQueue].
  Future<int> flushOfflineQueue() async {
    return _offlineQueue.flush((record) async {
      final response = await _dio.request<dynamic>(
        record.path,
        data: record.data,
        queryParameters: record.queryParameters,
        options: Options(method: record.method),
      );
      final statusCode = response.statusCode ?? 500;
      return statusCode >= 200 && statusCode < 300;
    });
  }

  /// Re-throw the typed [LaravelException] carried by [e], or [e] itself.
  Never _throwTyped(DioException e) {
    final error = e.error;
    if (error is LaravelException) {
      Error.throwWithStackTrace(error, e.stackTrace);
    }
    Error.throwWithStackTrace(e, e.stackTrace);
  }

  void _enqueueMutation(
    String method,
    String path,
    dynamic data,
    Map<String, dynamic>? queryParameters,
  ) {
    final record = MutationRecord(
      id: BridgeIds.uuid(),
      method: method,
      path: path,
      data: data,
      queryParameters: queryParameters,
    );
    _offlineQueue.enqueue(record);
  }
}
