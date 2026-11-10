import 'dart:convert';

import '../storage/key_value_store.dart';
import 'laravel_connection.dart';

/// Persistence contract for connection profiles and the active profile id.
abstract class ConnectionStore {
  /// Load every saved profile (in display order).
  Future<List<LaravelConnection>> loadConnections();

  /// Replace the saved profiles.
  Future<void> saveConnections(List<LaravelConnection> connections);

  /// Load the id of the active profile.
  Future<String?> loadActiveId();

  /// Save (or clear, with `null`) the id of the active profile.
  Future<void> saveActiveId(String? id);

  /// Load the generated install/device id (used when `LaravelOptions.deviceId` is not set).
  ///
  /// Stores that cannot persist it return `null`, in which case a new id is
  /// generated per app launch.
  Future<String?> loadDeviceId() async => null;

  /// Persist the generated install/device id.
  Future<void> saveDeviceId(String deviceId) async {}
}

/// Non-persistent [ConnectionStore], ideal for tests and as the default store.
class InMemoryConnectionStore extends ConnectionStore {
  final List<LaravelConnection> _connections;
  String? _activeId;
  String? _deviceId;

  InMemoryConnectionStore({
    List<LaravelConnection> connections = const [],
    String? activeId,
    String? deviceId,
  })  : _connections = List.of(connections),
        _activeId = activeId,
        _deviceId = deviceId;

  @override
  Future<List<LaravelConnection>> loadConnections() async =>
      List.unmodifiable(_connections);

  @override
  Future<void> saveConnections(List<LaravelConnection> connections) async {
    _connections
      ..clear()
      ..addAll(connections);
  }

  @override
  Future<String?> loadActiveId() async => _activeId;

  @override
  Future<void> saveActiveId(String? id) async => _activeId = id;

  @override
  Future<String?> loadDeviceId() async => _deviceId;

  @override
  Future<void> saveDeviceId(String deviceId) async => _deviceId = deviceId;
}

/// [ConnectionStore] adapter over any string key-value store
/// (SharedPreferences, FlutterSecureStorage, Hive…). Profiles are stored as JSON.
class DelegateConnectionStore extends ConnectionStore {
  final Future<String?> Function(String key) onRead;
  final Future<void> Function(String key, String value) onWrite;
  final Future<void> Function(String key) onDelete;

  /// Prefix prepended to every key (useful to share one store between apps/flavors).
  final String keyPrefix;

  static const String connectionsKey = 'flutter_laravel_connections';
  static const String activeIdKey = 'flutter_laravel_active_connection';
  static const String deviceIdKey = 'flutter_laravel_device_id';

  DelegateConnectionStore({
    required this.onRead,
    required this.onWrite,
    required this.onDelete,
    this.keyPrefix = '',
  });

  /// Persist profiles in a [BridgeKeyValueStore].
  DelegateConnectionStore.fromStore(
    BridgeKeyValueStore store, {
    String keyPrefix = '',
  }) : this(
          onRead: store.read,
          onWrite: store.write,
          onDelete: store.delete,
          keyPrefix: keyPrefix,
        );

  String _key(String key) => '$keyPrefix$key';

  @override
  Future<List<LaravelConnection>> loadConnections() async {
    final raw = await onRead(_key(connectionsKey));
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((e) => LaravelConnection.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    } on FormatException {
      return const [];
    }
  }

  @override
  Future<void> saveConnections(List<LaravelConnection> connections) {
    return onWrite(
      _key(connectionsKey),
      jsonEncode(connections.map((c) => c.toJson()).toList()),
    );
  }

  @override
  Future<String?> loadActiveId() => onRead(_key(activeIdKey));

  @override
  Future<void> saveActiveId(String? id) {
    if (id == null) return onDelete(_key(activeIdKey));
    return onWrite(_key(activeIdKey), id);
  }

  @override
  Future<String?> loadDeviceId() => onRead(_key(deviceIdKey));

  @override
  Future<void> saveDeviceId(String deviceId) =>
      onWrite(_key(deviceIdKey), deviceId);
}
