import 'package:dio/dio.dart';
import '../client/laravel_client.dart';
import '../models/api_response.dart';

/// Helper for uploading single or multiple files with progress tracking.
class LaravelUploader {
  final LaravelClient client;

  const LaravelUploader(this.client);

  /// Upload a single file with optional progress callback and extra form fields.
  Future<ApiResponse<T>> uploadFile<T>({
    required String path,
    required String fileKey,
    required String filePath,
    String? filename,
    Map<String, dynamic>? extraData,
    void Function(int count, int total)? onProgress,
    T Function(dynamic json)? fromJson,
  }) async {
    final multipartFile = await MultipartFile.fromFile(
      filePath,
      filename: filename,
    );

    final formData = FormData.fromMap({
      fileKey: multipartFile,
      if (extraData != null) ...extraData,
    });

    try {
      final response = await client.rawDio.post<Map<String, dynamic>>(
        path,
        data: formData,
        onSendProgress: onProgress,
      );

      return ApiResponse<T>.fromJson(
          response.data ?? <String, dynamic>{}, fromJson);
    } on DioException catch (e) {
      if (e.error != null) {
        throw e.error!;
      }
      rethrow;
    }
  }

  /// Upload multiple files with progress callback.
  Future<ApiResponse<T>> uploadMultipleFiles<T>({
    required String path,
    required String fileKey,
    required List<String> filePaths,
    Map<String, dynamic>? extraData,
    void Function(int count, int total)? onProgress,
    T Function(dynamic json)? fromJson,
  }) async {
    final List<MultipartFile> files = [];
    for (final filePath in filePaths) {
      files.add(await MultipartFile.fromFile(filePath));
    }

    final formData = FormData.fromMap({
      fileKey: files,
      if (extraData != null) ...extraData,
    });

    try {
      final response = await client.rawDio.post<Map<String, dynamic>>(
        path,
        data: formData,
        onSendProgress: onProgress,
      );

      return ApiResponse<T>.fromJson(
          response.data ?? <String, dynamic>{}, fromJson);
    } on DioException catch (e) {
      if (e.error != null) {
        throw e.error!;
      }
      rethrow;
    }
  }
}
