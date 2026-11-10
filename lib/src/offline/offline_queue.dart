import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../exceptions/laravel_exception.dart';
import '../storage/key_value_store.dart';
import 'mutation_record.dart';

/// Why a queued mutation was dropped.
enum OfflineMutationFailureReason {
  /// The server rejected it permanently (4xx other than 408 / 429).
  rejected,

  /// It failed [OfflineQueue.maxRetries] times.
  maxRetriesExceeded,
}

/// A mutation dropped from the [OfflineQueue], emitted on [OfflineQueue.failures].
class OfflineMutationFailure {
  final MutationRecord record;
  final OfflineMutationFailureReason reason;

  /// Last error (exception thrown by the executor), when any.
  final Object? error;

  const OfflineMutationFailure({
    required this.record,
    required this.reason,
    this.error,
  });

  /// HTTP status of the last attempt, when known.
  int? get statusCode => OfflineQueue.statusCodeOf(error);

  @override
  String toString() =>
      'OfflineMutationFailure(${reason.name}, [${record.method}] ${record.path}, $error)';
}

/// Resilient FIFO queue for capturing and replaying offline requests.
///
/// With a [store] the queue survives app restarts: it is saved after every
/// change under [storageKey] and loaded back with [restore]. Records whose
/// payload is not JSON-encodable (`FormData`, streams…) stay in memory only.
class OfflineQueue {
  /// Base key used in the [store]; profiles append `:<profileId>`.
  static const String baseStorageKey = 'flutter_laravel_offline_queue';

  /// Key used for the queue of connection profile [profileId].
  static String storageKeyFor(String? profileId) =>
      profileId == null || profileId.isEmpty
          ? baseStorageKey
          : '$baseStorageKey:$profileId';

  /// Optional persistent backing store.
  final BridgeKeyValueStore? store;

  /// Key under which the queue is saved in [store].
  final String storageKey;

  /// Attempts after which a transiently failing record is dropped.
  final int maxRetries;

  final List<MutationRecord> _queue = [];
  final _queueController = StreamController<List<MutationRecord>>.broadcast();
  final _failuresController =
      StreamController<OfflineMutationFailure>.broadcast();
  Future<void> _writes = Future<void>.value();
  Future<void>? _restoreFuture;
  Future<int>? _flushFuture;

  OfflineQueue({
    this.store,
    String? storageKey,
    this.maxRetries = 5,
  }) : storageKey = storageKey ?? baseStorageKey;

  /// Stream emitting the queue whenever mutations are added, removed, or processed.
  Stream<List<MutationRecord>> get queueStream => _queueController.stream;

  /// Mutations dropped permanently (rejected by the server or out of retries).
  Stream<OfflineMutationFailure> get failures => _failuresController.stream;

  /// Snapshot of the pending mutations, oldest first.
  List<MutationRecord> get pending => List.unmodifiable(_queue);

  /// Number of pending mutations.
  int get length => _queue.length;

  /// Check if queue has pending items.
  bool get hasPending => _queue.isNotEmpty;

  /// Whether a [flush] is running.
  bool get isFlushing => _flushFuture != null;

  /// Completes once every pending write to [store] has finished.
  Future<void> whenPersisted() => _writes;

  /// Add a mutation to the queue.
  void enqueue(MutationRecord record) {
    _queue.add(record);
    if (store != null && !_isEncodable(record)) {
      debugPrint(
        'OfflineQueue: [${record.method}] ${record.path} has a non-JSON payload '
        '(${record.data.runtimeType}); it is kept in memory only and will be '
        'lost if the app restarts.',
      );
    }
    _changed();
    debugPrint(
        'OfflineQueue: Enqueued [${record.method}] ${record.path} (Total: ${_queue.length})');
  }

  /// Load the records saved in [store] (once; later calls return the same
  /// future). Corrupt data is logged and dropped. Restored records are placed
  /// before the ones enqueued since the queue was created.
  Future<void> restore() => _restoreFuture ??= _restore();

  Future<void> _restore() async {
    final store = this.store;
    if (store == null) return;
    String? raw;
    try {
      raw = await store.read(storageKey);
    } catch (e) {
      debugPrint('OfflineQueue: failed to read $storageKey: $e');
      return;
    }
    if (raw == null || raw.isEmpty) return;

    final restored = <MutationRecord>[];
    var dropped = 0;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) throw const FormatException('not a list');
      for (final item in decoded) {
        try {
          final record =
              MutationRecord.fromJson(Map<String, dynamic>.from(item as Map))
                ..persisted = true;
          restored.add(record);
        } catch (e) {
          dropped++;
        }
      }
    } catch (e) {
      debugPrint('OfflineQueue: dropping corrupt data under $storageKey: $e');
      _changed();
      return;
    }
    if (dropped > 0) {
      debugPrint('OfflineQueue: dropped $dropped corrupt record(s)');
    }

    final known = _queue.map((r) => r.id).toSet();
    _queue.insertAll(0, restored.where((r) => !known.contains(r.id)));
    if (dropped > 0) {
      _changed();
    } else {
      _emit();
    }
  }

  /// Replay all queued mutations in FIFO order using [executor].
  ///
  /// * `true` → the record is removed.
  /// * an unreachable server (network error, 408, 429, 503) → the record is
  ///   kept untouched and the flush stops. These never count as attempts, so
  ///   a device that stays offline never loses queued work.
  /// * `false` or another server error (5xx) → the record is kept, its
  ///   [MutationRecord.retryCount] grows and the flush stops so later
  ///   mutations never overtake it. After [maxRetries] attempts it is dropped
  ///   and emitted on [failures].
  /// * a permanent error (other 4xx) → the record is dropped, emitted on
  ///   [failures] and the flush continues.
  ///
  /// Concurrent calls share the running flush. Returns the number of
  /// successfully replayed records.
  Future<int> flush(
    Future<bool> Function(MutationRecord record) executor,
  ) {
    return _flushFuture ??=
        _flush(executor).whenComplete(() => _flushFuture = null);
  }

  Future<int> _flush(
    Future<bool> Function(MutationRecord record) executor,
  ) async {
    if (_queue.isEmpty) return 0;

    int successCount = 0;
    final List<MutationRecord> pending = List.from(_queue);

    for (final record in pending) {
      if (!_queue.contains(record)) continue; // cleared meanwhile
      Object? error;
      bool success;
      try {
        success = await executor(record);
      } catch (e) {
        error = e;
        success = false;
      }

      if (success) {
        _queue.remove(record);
        successCount++;
        _changed();
        continue;
      }

      if (error != null && isPermanentFailure(error)) {
        debugPrint(
            'OfflineQueue: dropping rejected [${record.method}] ${record.path}: $error');
        _drop(record, OfflineMutationFailureReason.rejected, error);
        continue;
      }

      if (error != null && isConnectivityFailure(error)) {
        debugPrint(
            'OfflineQueue: server unreachable, keeping [${record.method}] ${record.path} for later: $error');
        break;
      }

      record.retryCount++;
      if (error != null) {
        debugPrint(
            'OfflineQueue replay failed for [${record.method}] ${record.path}: $error');
      }
      if (record.retryCount >= maxRetries) {
        debugPrint(
            'OfflineQueue: dropping [${record.method}] ${record.path} after ${record.retryCount} attempt(s)');
        _drop(record, OfflineMutationFailureReason.maxRetriesExceeded, error);
      } else {
        _changed();
      }
      // Stop sequential flush on failure to avoid out-of-order execution.
      break;
    }

    return successCount;
  }

  /// Whether [error] means the request never got a real answer from the
  /// server (offline, timeout, rate limited or maintenance), so retrying later
  /// is always safe and must not consume the retry budget.
  static bool isConnectivityFailure(Object error) {
    if (error is LaravelNetworkException) return true;
    if (error is DioException) {
      if (error.error is LaravelNetworkException) return true;
      if (error.response == null && error.error is! LaravelException) {
        return true;
      }
    }
    final status = statusCodeOf(error);
    return status == 408 || status == 429 || status == 503;
  }

  /// Whether [error] means the server will never accept the mutation:
  /// any 4xx except 408 (timeout) and 429 (rate limited).
  static bool isPermanentFailure(Object error) {
    if (error is LaravelNetworkException) return false;
    if (error is DioException && error.error is LaravelNetworkException) {
      return false;
    }
    final status = statusCodeOf(error);
    if (status == null) return false;
    return status >= 400 && status < 500 && status != 408 && status != 429;
  }

  /// Extract the HTTP status code carried by [error], when any.
  static int? statusCodeOf(Object? error) {
    if (error is LaravelException) return error.statusCode;
    if (error is DioException) {
      final inner = error.error;
      if (inner is LaravelException && inner.statusCode != null) {
        return inner.statusCode;
      }
      return error.response?.statusCode;
    }
    return null;
  }

  /// Clear all mutations in the queue.
  void clear() {
    _queue.clear();
    _changed();
  }

  void dispose() {
    _queueController.close();
    _failuresController.close();
  }

  void _drop(
      MutationRecord record, OfflineMutationFailureReason reason, Object? e) {
    _queue.remove(record);
    _changed();
    if (!_failuresController.isClosed) {
      _failuresController.add(
          OfflineMutationFailure(record: record, reason: reason, error: e));
    }
  }

  void _emit() {
    if (!_queueController.isClosed) {
      _queueController.add(List.unmodifiable(_queue));
    }
  }

  /// Emit the new queue and persist it.
  void _changed() {
    _emit();
    final store = this.store;
    if (store == null) return;
    _writes = _writes.then((_) async {
      // Never overwrite saved records that were not loaded yet.
      await restore();
      final encoded = <Object?>[];
      for (final record in _queue) {
        final json = _encodeRecord(record);
        record.persisted = json != null;
        if (json != null) encoded.add(json);
      }
      try {
        await store.write(storageKey, jsonEncode(encoded));
      } catch (e) {
        debugPrint('OfflineQueue: failed to persist $storageKey: $e');
      }
    });
  }

  static Object? _encodeRecord(MutationRecord record) {
    try {
      final json = record.toJson();
      // Round-trip to make sure the payload is plain JSON.
      return jsonDecode(jsonEncode(json));
    } catch (_) {
      return null;
    }
  }

  static bool _isEncodable(MutationRecord record) =>
      _encodeRecord(record) != null;
}
