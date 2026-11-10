import '../echo/echo_options.dart';
import 'bridge_endpoints.dart';
import 'bridge_ids.dart';

/// A saved backend target ("connection profile") the user can add, test,
/// edit, switch to and delete.
///
/// Profiles live only on the device (see [ConnectionStore]); the live link to
/// the server is a [ConnectionSession].
///
/// ```dart
/// const production = LaravelConnection(
///   id: 'production',
///   name: 'Production',
///   baseUrl: 'https://api.acme.com',
///   appKey: 'fba_…',
/// );
/// ```
class LaravelConnection {
  /// Stable identifier (also used to namespace this profile's tokens).
  final String id;

  /// Human readable name shown in the connection manager.
  final String name;

  /// Base URL of the Laravel application, e.g. `https://api.acme.com`.
  final String baseUrl;

  /// Bridge route prefix (`flutter-bridge.prefix` on the server).
  final String prefix;

  /// App key (`fba_…`) identifying this Flutter app on the server.
  final String? appKey;

  /// Extra headers sent with every request to this backend.
  final Map<String, String> headers;

  /// Configure Laravel Echo automatically from the handshake `broadcasting` block.
  final bool autoConfigureEcho;

  /// Explicit Echo options; take precedence over the server advertised ones.
  final EchoOptions? echoOptions;

  /// Last time a session was successfully established with this backend.
  final DateTime? lastConnectedAt;

  /// Free-form application data attached to the profile.
  final Map<String, dynamic> metadata;

  const LaravelConnection({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.prefix = 'api/flutter',
    this.appKey,
    this.headers = const {},
    this.autoConfigureEcho = true,
    this.echoOptions,
    this.lastConnectedAt,
    this.metadata = const {},
  });

  /// Create a profile with a freshly generated id.
  factory LaravelConnection.create({
    required String name,
    required String baseUrl,
    String prefix = 'api/flutter',
    String? appKey,
    Map<String, String> headers = const {},
    bool autoConfigureEcho = true,
    EchoOptions? echoOptions,
    Map<String, dynamic> metadata = const {},
  }) {
    return LaravelConnection(
      id: BridgeIds.uuid(),
      name: name,
      baseUrl: baseUrl,
      prefix: prefix,
      appKey: appKey,
      headers: headers,
      autoConfigureEcho: autoConfigureEcho,
      echoOptions: echoOptions,
      metadata: metadata,
    );
  }

  /// Restore a profile serialised with [toJson].
  factory LaravelConnection.fromJson(Map<String, dynamic> json) {
    final rawEcho = json['echo_options'];
    return LaravelConnection(
      id: json['id'].toString(),
      name: json['name']?.toString() ?? '',
      baseUrl: json['base_url']?.toString() ?? '',
      prefix: json['prefix'] as String? ?? 'api/flutter',
      appKey: json['app_key'] as String?,
      headers: parseBridgeMap(json['headers'])
          .map((k, v) => MapEntry(k, v.toString())),
      autoConfigureEcho: parseBridgeBool(json['auto_configure_echo']) ?? true,
      echoOptions:
          rawEcho is Map ? EchoOptions.fromJson(parseBridgeMap(rawEcho)) : null,
      lastConnectedAt: parseBridgeDate(json['last_connected_at']),
      metadata: parseBridgeMap(json['metadata']),
    );
  }

  /// Serialise to a JSON-compatible map.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'base_url': baseUrl,
        'prefix': prefix,
        'app_key': appKey,
        'headers': headers,
        'auto_configure_echo': autoConfigureEcho,
        'echo_options': echoOptions?.toJson(),
        'last_connected_at': lastConnectedAt?.toUtc().toIso8601String(),
        'metadata': metadata,
      };

  /// Base URL without trailing slashes.
  String get normalizedBaseUrl {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// Prefix without leading/trailing slashes.
  String get normalizedPrefix => BridgeEndpoints.normalizePrefix(prefix);

  /// Host part of [baseUrl], useful for display.
  String get host => Uri.tryParse(baseUrl)?.host ?? baseUrl;

  /// Whether a change from [other] to this profile requires rebuilding the HTTP client.
  bool differsTransportFrom(LaravelConnection other) =>
      normalizedBaseUrl != other.normalizedBaseUrl ||
      normalizedPrefix != other.normalizedPrefix ||
      appKey != other.appKey ||
      autoConfigureEcho != other.autoConfigureEcho ||
      echoOptions != other.echoOptions ||
      !bridgeJsonEquals(headers, other.headers);

  /// Validate a user-entered base URL. Returns an error message or `null`.
  static String? validateBaseUrl(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Base URL is required';
    final uri = Uri.tryParse(text);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return 'Enter a full http:// or https:// URL';
    }
    if (uri.host.isEmpty) return 'Base URL must include a host';
    return null;
  }

  /// Create a copy with updated values. Pass `clearAppKey`, `clearEchoOptions`
  /// or `clearLastConnectedAt` to reset nullable fields.
  LaravelConnection copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? prefix,
    String? appKey,
    bool clearAppKey = false,
    Map<String, String>? headers,
    bool? autoConfigureEcho,
    EchoOptions? echoOptions,
    bool clearEchoOptions = false,
    DateTime? lastConnectedAt,
    bool clearLastConnectedAt = false,
    Map<String, dynamic>? metadata,
  }) {
    return LaravelConnection(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      prefix: prefix ?? this.prefix,
      appKey: clearAppKey ? null : (appKey ?? this.appKey),
      headers: headers ?? this.headers,
      autoConfigureEcho: autoConfigureEcho ?? this.autoConfigureEcho,
      echoOptions: clearEchoOptions ? null : (echoOptions ?? this.echoOptions),
      lastConnectedAt: clearLastConnectedAt
          ? null
          : (lastConnectedAt ?? this.lastConnectedAt),
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LaravelConnection &&
          other.id == id &&
          other.name == name &&
          other.baseUrl == baseUrl &&
          other.prefix == prefix &&
          other.appKey == appKey &&
          bridgeJsonEquals(other.headers, headers) &&
          other.autoConfigureEcho == autoConfigureEcho &&
          other.echoOptions == echoOptions &&
          other.lastConnectedAt == lastConnectedAt &&
          bridgeJsonEquals(other.metadata, metadata);

  @override
  int get hashCode => Object.hash(
        id,
        name,
        baseUrl,
        prefix,
        appKey,
        bridgeJsonHash(headers),
        autoConfigureEcho,
        echoOptions,
        lastConnectedAt,
        bridgeJsonHash(metadata),
      );

  @override
  String toString() => 'LaravelConnection($id, $name, $baseUrl/$prefix)';
}
