import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/key_value_store.dart';

/// Cache handling strategy for HTTP queries.
enum CachePolicy {
  /// Always bypass cache and request fresh data from server.
  networkOnly,

  /// Return cached response if valid; fetch from network only if missing/expired.
  cacheFirst,

  /// Try network first; fallback to cached data if network request fails.
  networkFirst,

  /// Only return cached response. If not cached, throw [LaravelException].
  cacheOnly,
}

/// Cached response entry with expiration.
class CacheEntry {
  final dynamic data;
  final DateTime expiresAt;

  CacheEntry({
    required this.data,
    required this.expiresAt,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Whether the entry is expired at [now].
  bool isExpiredAt(DateTime now) => now.isAfter(expiresAt);

  Map<String, dynamic> toJson() => {
        'data': data,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      };

  factory CacheEntry.fromJson(Map<String, dynamic> json) => CacheEntry(
        data: json['data'],
        expiresAt: DateTime.parse(json['expiresAt'] as String),
      );
}

/// Cache manager for GET responses with least-recently-used eviction.
///
/// With a [store] entries are written through on every change (under
/// [storageKey]) and loaded back lazily by [restore]; expired entries are
/// skipped on load. Values that are not JSON-encodable stay in memory only.
class CacheManager {
  /// Base key used in the [store]; profiles append `:<profileId>`.
  static const String baseStorageKey = 'flutter_laravel_cache';

  /// Key used for the cache of connection profile [profileId].
  static String storageKeyFor(String? profileId) =>
      profileId == null || profileId.isEmpty
          ? baseStorageKey
          : '$baseStorageKey:$profileId';

  /// Optional persistent backing store.
  final BridgeKeyValueStore? store;

  /// Key under which the cache is saved in [store].
  final String storageKey;

  /// Maximum number of entries; the least recently used ones are evicted.
  final int maxEntries;

  final DateTime Function() _clock;

  // Insertion order == recency order (oldest first).
  final LinkedHashMap<String, CacheEntry> _store =
      LinkedHashMap<String, CacheEntry>();
  Future<void> _writes = Future<void>.value();
  Future<void>? _restoreFuture;

  CacheManager({
    this.store,
    String? storageKey,
    this.maxEntries = 200,
    DateTime Function()? clock,
  })  : storageKey = storageKey ?? baseStorageKey,
        _clock = clock ?? DateTime.now;

  /// Number of entries currently held (expired ones included until touched).
  int get length => _store.length;

  /// Cached keys, least recently used first.
  Iterable<String> get keys => List.unmodifiable(_store.keys);

  /// Whether [restore] has completed.
  bool get isRestored => store == null || _restored;
  bool _restored = false;

  /// Completes once every pending write to [store] has finished.
  Future<void> whenPersisted() => _writes;

  /// Load the persisted entries (once; later calls return the same future).
  /// Entries cached in memory meanwhile take precedence.
  Future<void> restore() => _restoreFuture ??= _restore();

  Future<void> _restore() async {
    final store = this.store;
    if (store == null) return;
    try {
      final raw = await store.read(storageKey);
      if (raw == null || raw.isEmpty) return;
      final now = _clock();
      var pruned = false;
      final loaded = <String, CacheEntry>{};
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) throw const FormatException('not a map');
        decoded.forEach((key, value) {
          try {
            final entry =
                CacheEntry.fromJson(Map<String, dynamic>.from(value as Map));
            if (entry.isExpiredAt(now)) {
              pruned = true;
            } else {
              loaded[key.toString()] = entry;
            }
          } catch (_) {
            pruned = true;
          }
        });
      } on FormatException catch (e) {
        debugPrint('CacheManager: dropping corrupt data under $storageKey: $e');
        pruned = true;
      }

      // Memory entries are newer: keep them last (most recently used).
      final current = Map.of(_store);
      _store
        ..clear()
        ..addAll(loaded)
        ..addAll(current);
      if (_evict() || pruned) _persist();
    } catch (e) {
      debugPrint('CacheManager: failed to restore $storageKey: $e');
    } finally {
      _restored = true;
    }
  }

  /// Retrieve cached data if present and not expired.
  ///
  /// Only reads memory; call (and await) [restore] first to include persisted
  /// entries — [LaravelClient] does this automatically. The first call also
  /// starts restoring in the background.
  dynamic get(String key) {
    if (store != null && _restoreFuture == null) unawaited(restore());
    final entry = _store.remove(key);
    if (entry == null) return null;
    if (entry.isExpiredAt(_clock())) {
      _persist();
      return null;
    }
    _store[key] = entry; // mark as most recently used
    return entry.data;
  }

  /// Store response data with a specified time-to-live.
  void put(String key, dynamic data, Duration ttl) {
    _store.remove(key);
    _store[key] = CacheEntry(
      data: data,
      expiresAt: _clock().add(ttl),
    );
    _evict();
    _persist();
  }

  /// Invalidate cache for a specific key.
  void invalidate(String key) {
    if (_store.remove(key) != null) _persist();
  }

  /// Invalidate every key starting with [prefix] (e.g. `api/posts`).
  /// Returns the number of removed entries.
  int invalidatePrefix(String prefix) {
    final keys = _store.keys.where((k) => k.startsWith(prefix)).toList();
    for (final key in keys) {
      _store.remove(key);
    }
    if (keys.isNotEmpty) _persist();
    return keys.length;
  }

  /// Clear all cached data.
  void clear() {
    _store.clear();
    _persist();
  }

  /// Evict least recently used entries above [maxEntries]. Returns true when
  /// anything was removed.
  bool _evict() {
    var evicted = false;
    while (_store.length > maxEntries && _store.isNotEmpty) {
      _store.remove(_store.keys.first);
      evicted = true;
    }
    return evicted;
  }

  void _persist() {
    final store = this.store;
    if (store == null) return;
    _writes = _writes.then((_) async {
      // Never overwrite saved entries that were not loaded yet.
      await restore();
      final now = _clock();
      final encoded = <String, Object?>{};
      _store.forEach((key, entry) {
        if (entry.isExpiredAt(now)) return;
        try {
          encoded[key] = jsonDecode(jsonEncode(entry.toJson()));
        } catch (_) {
          // Not JSON-encodable: memory only.
        }
      });
      try {
        await store.write(storageKey, jsonEncode(encoded));
      } catch (e) {
        debugPrint('CacheManager: failed to persist $storageKey: $e');
      }
    });
  }
}
