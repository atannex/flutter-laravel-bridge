import 'package:flutter/foundation.dart';
import '../client/laravel_client.dart';
import '../connection/bridge_endpoints.dart';
import '../models/api_response.dart';

/// Manages device registration and push notification FCM token synchronization.
class DeviceManager {
  final LaravelClient client;

  DeviceManager(this.client);

  /// Register or update this device's metadata and FCM push token.
  Future<ApiResponse<Map<String, dynamic>>> registerDevice({
    required String deviceId,
    required String platform,
    String? fcmToken,
    String? deviceName,
    String? osVersion,
    String? appVersion,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      final response = await client.post<Map<String, dynamic>>(
        client.endpoint(BridgeEndpoints.devicesRegister),
        data: {
          'device_id': deviceId,
          'platform': platform,
          if (fcmToken != null) 'fcm_token': fcmToken,
          if (deviceName != null) 'device_name': deviceName,
          if (osVersion != null) 'os_version': osVersion,
          if (appVersion != null) 'app_version': appVersion,
          if (metadata != null) 'metadata': metadata,
        },
      );

      debugPrint('DeviceManager: Device $deviceId registered successfully');
      return response;
    } catch (e) {
      debugPrint('DeviceManager: Failed to register device: $e');
      rethrow;
    }
  }

  /// Unregister device upon logout or notification disable.
  Future<ApiResponse<Map<String, dynamic>>> unregisterDevice(
      String deviceId) async {
    try {
      final response = await client.delete<Map<String, dynamic>>(
        client.endpoint(
          BridgeEndpoints.devicesUnregister,
          params: {'device': deviceId},
        ),
      );
      debugPrint('DeviceManager: Device $deviceId unregistered');
      return response;
    } catch (e) {
      debugPrint('DeviceManager: Failed to unregister device: $e');
      rethrow;
    }
  }
}
