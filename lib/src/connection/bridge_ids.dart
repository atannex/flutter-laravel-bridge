import 'dart:math';

/// Cryptographically secure identifier helpers used by the bridge
/// (connection profile ids, generated device ids, offline mutation ids).
class BridgeIds {
  BridgeIds._();

  static final Random _random = Random.secure();

  /// Generate an RFC 4122 version 4 UUID using [Random.secure].
  static String uuid([Random? random]) {
    final rng = random ?? _random;
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant

    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

/// Parse an ISO-8601 value coming from the server, tolerating `null` and garbage.
DateTime? parseBridgeDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  return DateTime.tryParse(value.toString());
}

/// Coerce a JSON value to `int`, accepting numeric strings.
int? parseBridgeInt(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

/// Coerce a JSON value to `bool`, accepting `0/1` and `"true"/"false"`.
bool? parseBridgeBool(dynamic value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value.toString().toLowerCase();
  if (text == 'true' || text == '1') return true;
  if (text == 'false' || text == '0') return false;
  return null;
}

/// Coerce a JSON value to a `Map<String, dynamic>` (empty when not a map).
Map<String, dynamic> parseBridgeMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, val) => MapEntry(key.toString(), val));
  }
  return <String, dynamic>{};
}

/// Compare two semantic version strings (`1.2.10` > `1.2.9`). Non-numeric
/// suffixes (`-beta`, `+5`) are ignored. Returns <0, 0 or >0.
int compareBridgeVersions(String a, String b) {
  List<int> parts(String v) => v
      .split(RegExp(r'[+\-]'))
      .first
      .split('.')
      .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();

  final pa = parts(a);
  final pb = parts(b);
  final length = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < length; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// Deep equality for JSON-like structures (maps, lists, scalars).
bool bridgeJsonEquals(dynamic a, dynamic b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !bridgeJsonEquals(a[key], b[key]))
        return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!bridgeJsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// Order-independent deep hash matching [bridgeJsonEquals].
int bridgeJsonHash(dynamic value) {
  if (value is Map) {
    var hash = 0;
    value.forEach((k, v) => hash ^= Object.hash(k, bridgeJsonHash(v)));
    return hash;
  }
  if (value is List) return Object.hashAll(value.map(bridgeJsonHash));
  return value.hashCode;
}
