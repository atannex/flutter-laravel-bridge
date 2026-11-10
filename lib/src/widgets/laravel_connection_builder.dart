import 'package:flutter/material.dart';

import '../connection/connection_manager.dart';
import '../connection/connection_state.dart';
import '../laravel.dart';

/// Rebuilds whenever the [LaravelConnectionManager] state changes.
///
/// ```dart
/// LaravelConnectionBuilder(
///   builder: (context, state) => Text(state.status.name),
/// )
/// ```
class LaravelConnectionBuilder extends StatelessWidget {
  /// Manager to observe; defaults to [Laravel.connections].
  final LaravelConnectionManager? manager;
  final Widget Function(BuildContext context, LaravelConnectionState state)
      builder;

  const LaravelConnectionBuilder({
    super.key,
    this.manager,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    final resolved = manager ?? Laravel.connections;
    return StreamBuilder<LaravelConnectionState>(
      stream: resolved.stateStream,
      initialData: resolved.state,
      builder: (context, snapshot) =>
          builder(context, snapshot.data ?? resolved.state),
    );
  }
}

/// Visual presentation (label, icon, colour) of a [ConnectionStatus].
class ConnectionStatusStyle {
  final String label;
  final IconData icon;
  final Color color;

  const ConnectionStatusStyle(this.label, this.icon, this.color);

  /// Resolve the style of [status] against the current theme.
  static ConnectionStatusStyle of(
      BuildContext context, ConnectionStatus status) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case ConnectionStatus.idle:
        return ConnectionStatusStyle(
            'Idle', Icons.pause_circle_outline, scheme.outline);
      case ConnectionStatus.connecting:
        return ConnectionStatusStyle('Connecting', Icons.sync, scheme.tertiary);
      case ConnectionStatus.connected:
        return const ConnectionStatusStyle(
            'Connected', Icons.cloud_done_outlined, Color(0xFF2E7D32));
      case ConnectionStatus.reconnecting:
        return const ConnectionStatusStyle(
            'Reconnecting', Icons.sync_problem, Color(0xFFEF6C00));
      case ConnectionStatus.offline:
        return const ConnectionStatusStyle(
            'Offline', Icons.cloud_off_outlined, Color(0xFFEF6C00));
      case ConnectionStatus.failed:
        return ConnectionStatusStyle(
            'Failed', Icons.error_outline, scheme.error);
      case ConnectionStatus.revoked:
        return ConnectionStatusStyle('Revoked', Icons.block, scheme.error);
      case ConnectionStatus.upgradeRequired:
        return ConnectionStatusStyle(
            'Update required', Icons.system_update, scheme.error);
    }
  }
}

/// Compact Material 3 chip describing a [ConnectionStatus].
class LaravelConnectionStatusChip extends StatelessWidget {
  final ConnectionStatus status;

  /// Optional override of the label.
  final String? label;

  const LaravelConnectionStatusChip(
      {super.key, required this.status, this.label});

  @override
  Widget build(BuildContext context) {
    final style = ConnectionStatusStyle.of(context, status);
    final textStyle = Theme.of(context).textTheme.labelSmall;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: style.color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: 14, color: style.color),
          const SizedBox(width: 4),
          Text(
            label ?? style.label,
            style: textStyle?.copyWith(
                color: style.color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Human friendly relative time ("just now", "5 min ago", "2 d ago").
String formatRelativeTime(DateTime? time, {DateTime? now}) {
  if (time == null) return 'never';
  final reference = now ?? DateTime.now();
  final diff = reference.difference(time.toLocal());
  if (diff.isNegative || diff.inSeconds < 45) return 'just now';
  if (diff.inMinutes < 60)
    return '${diff.inMinutes < 1 ? 1 : diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  if (diff.inDays < 7) return '${diff.inDays} d ago';
  final local = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}

/// Format a latency for display ("42 ms").
String formatLatency(Duration? latency) =>
    latency == null ? '—' : '${latency.inMilliseconds} ms';
