import 'dart:async';

/// Minimal async string key-value contract the bridge persists to.
///
/// One app-provided store can back token storage, connection profiles, the
/// offline queue and the response cache (see `Laravel.initialize(storage:)`).
/// Adapt any backend (FlutterSecureStorage, SharedPreferences, Hive…) with
/// [DelegateKeyValueStore] — the package itself depends on none of them.
abstract class BridgeKeyValueStore {
  /// Read the value stored under [key] (`null` when missing).
  Future<String?> read(String key);

  /// Store [value] under [key].
  Future<void> write(String key, String value);

  /// Remove [key].
  Future<void> delete(String key);
}

/// Non-persistent [BridgeKeyValueStore], ideal for tests and as a default.
class InMemoryKeyValueStore implements BridgeKeyValueStore {
  final Map<String, String> _values;

  InMemoryKeyValueStore([Map<String, String>? initial])
      : _values = Map<String, String>.of(initial ?? const {});

  /// Snapshot of every stored entry (mainly for tests and debugging).
  Map<String, String> get values => Map.unmodifiable(_values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// [BridgeKeyValueStore] adapter over three callbacks.
///
/// ```dart
/// const secure = FlutterSecureStorage();
/// final storage = DelegateKeyValueStore(
///   read: (key) => secure.read(key: key),
///   write: (key, value) => secure.write(key: key, value: value),
///   delete: (key) => secure.delete(key: key),
/// );
/// ```
class DelegateKeyValueStore implements BridgeKeyValueStore {
  final Future<String?> Function(String key) onRead;
  final Future<void> Function(String key, String value) onWrite;
  final Future<void> Function(String key) onDelete;

  const DelegateKeyValueStore({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    required Future<void> Function(String key) delete,
  })  : onRead = read,
        onWrite = write,
        onDelete = delete;

  @override
  Future<String?> read(String key) => onRead(key);

  @override
  Future<void> write(String key, String value) => onWrite(key, value);

  @override
  Future<void> delete(String key) => onDelete(key);
}
