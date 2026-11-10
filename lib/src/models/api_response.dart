/// Standardized enterprise API response envelope from Laravel.
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

  /// Parse response JSON into typed [ApiResponse<T>].
  factory ApiResponse.fromJson(
    Map<String, dynamic> json, [
    T Function(dynamic json)? fromJsonT,
  ]) {
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

  /// Check if metadata contains a specific key.
  dynamic metaValue(String key) => meta?[key];
}
