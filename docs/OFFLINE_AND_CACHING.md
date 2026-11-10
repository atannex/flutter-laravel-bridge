# Offline Mutation Queuing & Caching

Mobile apps frequently experience intermittent connectivity (elevators, subways, dead zones). The Laravel & Flutter Bridge includes first-class offline mutation queuing and caching policies.

---

## 1. Caching Policies

The client supports four caching strategies for GET requests:

| Policy | Behavior | Best Used For |
| :--- | :--- | :--- |
| `CachePolicy.networkOnly` | Bypasses local cache, always fetches fresh data from server. | Real-time prices, live chat, checkout balances. |
| `CachePolicy.cacheFirst` | Checks cache; returns immediately if found, else fetches from server. | User settings, catalogs, categories, static metadata. |
| `CachePolicy.networkFirst` | Tries server first; falls back to cached copy if offline. | Feeds, dashboards, transaction histories. |
| `CachePolicy.cacheOnly` | Only queries local cache; never triggers a network request. | Pure offline browsing modes. |

### Usage Example:
```dart
final response = await Laravel.client.get<Map<String, dynamic>>(
  '/api/catalog',
  cachePolicy: CachePolicy.networkFirst,
  cacheTtl: const Duration(hours: 1),
);
```

---

## 2. Offline Mutation Queuing

When executing state-changing mutations (`POST`, `PUT`, `PATCH`, `DELETE`) with `queueIfOffline: true`, requests that fail due to network loss are automatically held in the `OfflineQueue`.

```dart
try {
  await Laravel.client.post(
    '/api/tasks',
    data: {'title': 'Inspect Generator Unit 4', 'priority': 'high'},
    queueIfOffline: true, // Will automatically enqueue if network is down
  );
} on LaravelNetworkException {
  print('Network unavailable. Request enqueued for background sync.');
}
```

### Replaying Queued Mutations
The connection manager flushes the active profile's queue automatically every time its status
becomes `connected`. You can also flush manually (e.g. on a `connectivity_plus` event):

```dart
final count = await Laravel.client.flushOfflineQueue();
print('Flushed $count pending offline mutations successfully!');
```

### Replay rules

* Records are replayed in **FIFO** order; a flush stops at the first transient failure so later
  mutations never overtake an earlier one. Concurrent `flush` calls share the running flush.
* **Permanent failures** — any 4xx except `408` and `429` (e.g. 422 validation, 404, 403) — drop the
  record immediately and the flush continues.
* **Server unreachable** — network errors, timeouts, 408, 429, 503 — keep the record untouched.
  These never count as attempts, so a device that stays offline never loses queued work.
* **Server errors** — other 5xx — keep the record and increment `retryCount`. After `maxRetries`
  attempts (default 5) the record is dropped.
* Every dropped record is emitted on `failures`:

```dart
Laravel.client.offlineQueue.failures.listen((failure) {
  // failure.reason: OfflineMutationFailureReason.rejected | maxRetriesExceeded
  showSnackBar('Could not sync ${failure.record.path} (${failure.statusCode})');
});
```

---

## 3. Persistence across restarts

By default the queue and cache live in memory. Pass a `BridgeKeyValueStore` to
`Laravel.initialize` and both are persisted **per connection profile**:

| Data | Key | Parameter |
| :--- | :--- | :--- |
| Offline queue | `flutter_laravel_offline_queue:<profileId>` | `offlineQueueStore` (falls back to `storage`) |
| Response cache | `flutter_laravel_cache:<profileId>` | `cacheStore` (falls back to `storage`) |

```dart
final prefs = SharedPreferencesAsync(); // non-secret data
final plain = DelegateKeyValueStore(
  read: prefs.getString,
  write: prefs.setString,
  delete: prefs.remove,
);

await Laravel.initialize<User>(
  options: options,
  userParser: User.fromJson,
  storage: secureStore,       // tokens + profiles (see SECURITY_BEST_PRACTICES.md)
  offlineQueueStore: plain,
  cacheStore: plain,
);
```

* **Queue**: written after every enqueue / flush / clear and restored before the profile connects.
  Corrupt data is logged and dropped. Only JSON-encodable payloads are persisted — `FormData`,
  streams and other objects stay in memory (`record.persisted == false`) and a debug warning is
  printed.
* **Cache**: write-through on `put` / `invalidate` / `invalidatePrefix` / `clear`, restored lazily on
  the first cached read (or `cacheManager.restore()`), with the expiry stored so expired entries are
  pruned on load. At most `maxEntries` (default 200) entries are kept; the least recently used are
  evicted first.

```dart
Laravel.client.cacheManager.invalidatePrefix('api/posts'); // after creating a post
```

Removing a profile (`Laravel.connections.remove(id)`) deletes its tokens, queue and cache.
Standalone use: `OfflineQueue(store: store, storageKey: 'my_queue', maxRetries: 3)` and
`CacheManager(store: store, storageKey: 'my_cache', maxEntries: 500)`.
