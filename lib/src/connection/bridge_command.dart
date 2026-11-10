import 'bridge_ids.dart';

/// Well-known server → client command types (CONNECTIONS.md §5).
class BridgeCommandType {
  BridgeCommandType._();

  /// Session revoked: clear tokens, status `revoked`, `onSessionRevoked`.
  static const String revoked = 'revoked';

  /// Server-side logout: clear tokens, auth → Unauthenticated.
  static const String logout = 'logout';

  /// Re-run the handshake and update `ServerInfo`.
  static const String refreshConfig = 'refresh_config';

  /// Force an app update: status `upgradeRequired`.
  static const String forceUpdate = 'force_update';

  /// Free-form message; only emitted on the commands stream.
  static const String message = 'message';
}

/// How a [BridgeCommand] reached the client.
enum BridgeCommandSource {
  /// Delivered in a heartbeat response.
  heartbeat,

  /// Pushed over the `private-flutter.connections.{id}` broadcast channel.
  broadcast,
}

/// A command queued by the server for one connection session.
class BridgeCommand {
  /// Unique command id used for de-duplication.
  final String id;

  /// Command type, see [BridgeCommandType].
  final String type;
  final Map<String, dynamic> payload;
  final DateTime? createdAt;
  final BridgeCommandSource source;

  const BridgeCommand({
    required this.id,
    required this.type,
    this.payload = const {},
    this.createdAt,
    this.source = BridgeCommandSource.heartbeat,
  });

  /// Parse a command object (accepts numeric ids).
  factory BridgeCommand.fromJson(
    Map<String, dynamic> json, {
    BridgeCommandSource source = BridgeCommandSource.heartbeat,
  }) {
    return BridgeCommand(
      id: json['id'].toString(),
      type: json['type']?.toString() ?? 'unknown',
      payload: parseBridgeMap(json['payload']),
      createdAt: parseBridgeDate(json['created_at']),
      source: source,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'payload': payload,
        'created_at': createdAt?.toIso8601String(),
      };

  /// Optional `reason` carried by `revoked` / `logout` commands.
  String? get reason => payload['reason']?.toString();

  bool get isBuiltIn =>
      type == BridgeCommandType.revoked ||
      type == BridgeCommandType.logout ||
      type == BridgeCommandType.refreshConfig ||
      type == BridgeCommandType.forceUpdate;

  @override
  bool operator ==(Object other) =>
      other is BridgeCommand && other.id == id && other.type == type;

  @override
  int get hashCode => Object.hash(id, type);

  @override
  String toString() => 'BridgeCommand($id, $type, $payload)';
}
