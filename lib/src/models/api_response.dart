/// Standardized enterprise API response envelope from Laravel.
///
/// Bodies that are not wrapped in the bridge envelope (plain JSON returned by
/// ordinary Laravel controllers or API resources) are accepted too: the whole
/// body becomes [data], [success] is `true` and [message] is empty.
class ApiResponse<T> {
  final bool success;
  final String message;
  final T? data;
  final dynamic errors;
  final Map<String, dynamic>? meta;

  const ApiResponse({
    required this.success,
    required this.message,
    this.data,
    this.errors,
    this.meta,
  });

  /// Whether [json] wraps its payload: it has a `success` key (the bridge
  /// envelope) or a `data` key (the bridge envelope, or a Laravel API
  /// resource such as `{"data": …, "links": …, "meta": …}`). Anything else is
  /// plain JSON and becomes the payload as a whole.
  static bool isEnvelope(Map<String, dynamic> json) =>
      json.containsKey('success') || json.containsKey('data');

  /// Parse response JSON into typed [ApiResponse<T>].
  ///
  /// A non-empty map that is not an envelope (see [isEnvelope]) is treated as
  /// the payload itself. An empty map (e.g. `204 No Content`) has no data.
  factory ApiResponse.fromJson(
    Map<String, dynamic> json, [
    T Function(dynamic json)? fromJsonT,
  ]) {
    if (json.isNotEmpty && !isEnvelope(json)) {
      return ApiResponse<T>.raw(json, fromJsonT);
    }

    final rawData = json['data'];
    T? parsedData;

    if (rawData != null && fromJsonT != null) {
      parsedData = fromJsonT(rawData);
    } else if (rawData != null) {
      parsedData = rawData as T?;
    }

    return ApiResponse<T>(
      success: json['success'] as bool? ?? true,
      message: json['message'] as String? ?? '',
      data: parsedData,
      errors: json['errors'],
      meta: json['meta'] as Map<String, dynamic>?,
    );
  }

  /// Wrap a plain (non-envelope) JSON [body] — a map, a list or a scalar —
  /// as a successful response whose [data] is the body.
  factory ApiResponse.raw(dynamic body, [T Function(dynamic json)? fromJsonT]) {
    T? parsedData;
    if (body != null && fromJsonT != null) {
      parsedData = fromJsonT(body);
    } else if (body != null) {
      parsedData = body as T?;
    }
    return ApiResponse<T>(success: true, message: '', data: parsedData);
  }

  /// Parse any decoded response body: maps go through [ApiResponse.fromJson]
  /// (envelope or plain), lists and scalars are wrapped as [data], and a
  /// `null` body yields an empty successful response.
  factory ApiResponse.fromBody(dynamic body,
      [T Function(dynamic json)? fromJsonT]) {
    if (body is Map<String, dynamic>) {
      return ApiResponse<T>.fromJson(body, fromJsonT);
    }
    if (body is Map) {
      return ApiResponse<T>.fromJson(
          body.map((key, value) => MapEntry(key.toString(), value)), fromJsonT);
    }
    if (body == null) {
      return ApiResponse<T>.fromJson(<String, dynamic>{}, fromJsonT);
    }
    return ApiResponse<T>.raw(body, fromJsonT);
  }

  /// Check if metadata contains a specific key.
  dynamic metaValue(String key) => meta?[key];
}
