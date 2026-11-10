import 'bridge_ids.dart';

/// Server side status of a [ConnectionSession].
enum ConnectionSessionStatus {
  active,
  disconnected,
  revoked,
  unknown;

  /// Parse the wire value (`active` · `disconnected` · `revoked`).
  static ConnectionSessionStatus parse(dynamic value) {
    switch (value?.toString()) {
      case 'active':
        return ConnectionSessionStatus.active;
      case 'disconnected':
        return ConnectionSessionStatus.disconnected;
      case 'revoked':
        return ConnectionSessionStatus.revoked;
      default:
        return ConnectionSessionStatus.unknown;
    }
  }

  /// Wire value of this status.
  String get wireName =>
      this == ConnectionSessionStatus.unknown ? 'unknown' : name;
}

/// A live link between one device/app install and the server (CONNECTIONS.md §4.5).
class ConnectionSession {
  final String id;
  final String? appKey;

  /// Owner id (int or string, depending on the user model's key type).
  final Object? userId;
  final String? deviceId;
  final String? platform;
  final String? deviceName;
  final String? appVersion;
  final String? osVersion;
  final String? ipAddress;
  final String? userAgent;
  final ConnectionSessionStatus status;

  /// `status == active` and seen within the server timeout.
  final bool isOnline;

  /// Whether this session is the one making the request.
  final bool isCurrent;
  final DateTime? connectedAt;
  final DateTime? lastSeenAt;
  final DateTime? disconnectedAt;
  final DateTime? revokedAt;
  final Map<String, dynamic> metadata;

  const ConnectionSession({
    required this.id,
    this.appKey,
    this.userId,
    this.deviceId,
    this.platform,
    this.deviceName,
    this.appVersion,
    this.osVersion,
    this.ipAddress,
    this.userAgent,
    this.status = ConnectionSessionStatus.active,
    this.isOnline = false,
    this.isCurrent = false,
    this.connectedAt,
    this.lastSeenAt,
    this.disconnectedAt,
    this.revokedAt,
    this.metadata = const {},
  });

  bool get isActive => status == ConnectionSessionStatus.active;
  bool get isRevoked => status == ConnectionSessionStatus.revoked;

  factory ConnectionSession.fromJson(Map<String, dynamic> json) =>
      ConnectionSession(
        id: json['id'].toString(),
        appKey: json['app_key'] as String?,
        userId: json['user_id'],
        deviceId: json['device_id']?.toString(),
        platform: json['platform'] as String?,
        deviceName: json['device_name'] as String?,
        appVersion: json['app_version']?.toString(),
        osVersion: json['os_version']?.toString(),
        ipAddress: json['ip_address'] as String?,
        userAgent: json['user_agent'] as String?,
        status: ConnectionSessionStatus.parse(json['status']),
        isOnline: parseBridgeBool(json['is_online']) ?? false,
        isCurrent: parseBridgeBool(json['is_current']) ?? false,
        connectedAt: parseBridgeDate(json['connected_at']),
        lastSeenAt: parseBridgeDate(json['last_seen_at']),
        disconnectedAt: parseBridgeDate(json['disconnected_at']),
        revokedAt: parseBridgeDate(json['revoked_at']),
        metadata: parseBridgeMap(json['metadata']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'app_key': appKey,
        'user_id': userId,
        'device_id': deviceId,
        'platform': platform,
        'device_name': deviceName,
        'app_version': appVersion,
        'os_version': osVersion,
        'ip_address': ipAddress,
        'user_agent': userAgent,
        'status': status.wireName,
        'is_online': isOnline,
        'is_current': isCurrent,
        'connected_at': connectedAt?.toIso8601String(),
        'last_seen_at': lastSeenAt?.toIso8601String(),
        'disconnected_at': disconnectedAt?.toIso8601String(),
        'revoked_at': revokedAt?.toIso8601String(),
        'metadata': metadata,
      };

  ConnectionSession copyWith({
    ConnectionSessionStatus? status,
    bool? isOnline,
    bool? isCurrent,
    DateTime? lastSeenAt,
    DateTime? revokedAt,
    DateTime? disconnectedAt,
    Map<String, dynamic>? metadata,
  }) {
    return ConnectionSession(
      id: id,
      appKey: appKey,
      userId: userId,
      deviceId: deviceId,
      platform: platform,
      deviceName: deviceName,
      appVersion: appVersion,
      osVersion: osVersion,
      ipAddress: ipAddress,
      userAgent: userAgent,
      status: status ?? this.status,
      isOnline: isOnline ?? this.isOnline,
      isCurrent: isCurrent ?? this.isCurrent,
      connectedAt: connectedAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      disconnectedAt: disconnectedAt ?? this.disconnectedAt,
      revokedAt: revokedAt ?? this.revokedAt,
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  String toString() =>
      'ConnectionSession($id, ${status.wireName}, device: $deviceId)';
}
