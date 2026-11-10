import 'package:flutter/material.dart';

import '../connection/connection_manager.dart';
import '../connection/connection_state.dart';
import '../exceptions/laravel_exception.dart';
import '../laravel.dart';
import 'laravel_connection_builder.dart';

/// Where [LaravelConnectionBanner] shows its banner.
enum LaravelBannerPosition { top, bottom }

/// Wraps [child] and slides in a banner while the connection is offline,
/// reconnecting, revoked, failed or requires an app update.
///
/// Works anywhere, including `MaterialApp.builder`:
///
/// ```dart
/// MaterialApp(
///   builder: (context, child) => LaravelConnectionBanner(
///     onUpdate: (e) => launchUrl(Uri.parse(e.updateUrl!)),
///     child: child!,
///   ),
/// )
/// ```
class LaravelConnectionBanner extends StatelessWidget {
  final Widget child;

  /// Manager to observe; defaults to [Laravel.connections].
  final LaravelConnectionManager? manager;

  /// Statuses that show the banner.
  final Set<ConnectionStatus> statuses;

  /// Called by the "Retry" action. Defaults to `manager.connect()`.
  final Future<void> Function()? onRetry;

  /// Called by the "Update" action for [ConnectionStatus.upgradeRequired].
  /// The action is hidden when null.
  final void Function(LaravelUpgradeRequiredException exception)? onUpdate;

  /// Called by the "Sign in" action for [ConnectionStatus.revoked].
  /// Defaults to reconnecting (a new session is opened).
  final VoidCallback? onRevoked;

  final LaravelBannerPosition position;

  /// Replace the default banner content.
  final Widget Function(BuildContext context, LaravelConnectionState state)?
      bannerBuilder;

  const LaravelConnectionBanner({
    super.key,
    required this.child,
    this.manager,
    this.statuses = const {
      ConnectionStatus.offline,
      ConnectionStatus.reconnecting,
      ConnectionStatus.revoked,
      ConnectionStatus.upgradeRequired,
      ConnectionStatus.failed,
    },
    this.onRetry,
    this.onUpdate,
    this.onRevoked,
    this.position = LaravelBannerPosition.top,
    this.bannerBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final resolved = manager ?? Laravel.connections;
    return LaravelConnectionBuilder(
      manager: resolved,
      builder: (context, state) {
        final visible = statuses.contains(state.status);
        final banner = AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SizeTransition(sizeFactor: animation, child: child),
          ),
          child: visible
              ? KeyedSubtree(
                  key: ValueKey(state.status),
                  child: bannerBuilder?.call(context, state) ??
                      _DefaultBanner(
                        state: state,
                        position: position,
                        onRetry: onRetry ?? resolved.connect,
                        onUpdate: onUpdate,
                        onRevoked: onRevoked ?? () => resolved.connect(),
                      ),
                )
              : const SizedBox(width: double.infinity),
        );

        final body = visible
            ? MediaQuery.removePadding(
                context: context,
                removeTop: position == LaravelBannerPosition.top,
                removeBottom: position == LaravelBannerPosition.bottom,
                child: child,
              )
            : child;

        return Column(
          children: [
            if (position == LaravelBannerPosition.top) banner,
            Expanded(child: body),
            if (position == LaravelBannerPosition.bottom) banner,
          ],
        );
      },
    );
  }
}

class _DefaultBanner extends StatefulWidget {
  final LaravelConnectionState state;
  final LaravelBannerPosition position;
  final Future<void> Function() onRetry;
  final void Function(LaravelUpgradeRequiredException exception)? onUpdate;
  final VoidCallback onRevoked;

  const _DefaultBanner({
    required this.state,
    required this.position,
    required this.onRetry,
    required this.onUpdate,
    required this.onRevoked,
  });

  @override
  State<_DefaultBanner> createState() => _DefaultBannerState();
}

class _DefaultBannerState extends State<_DefaultBanner> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final error = state.error;

    late final String title;
    String? subtitle;
    late final IconData icon;
    Color background = scheme.errorContainer;
    Color foreground = scheme.onErrorContainer;
    final actions = <Widget>[];

    switch (state.status) {
      case ConnectionStatus.offline:
        icon = Icons.cloud_off_outlined;
        if (error is LaravelMaintenanceException) {
          title = 'Service under maintenance';
          subtitle = error.message;
        } else {
          title = 'You are offline';
          final retryAt = state.nextRetryAt;
          if (retryAt != null) {
            final seconds = retryAt.difference(DateTime.now()).inSeconds;
            subtitle = seconds > 0 ? 'Retrying in ${seconds}s…' : 'Retrying…';
          } else {
            subtitle = 'Changes will sync when the connection is back.';
          }
        }
        background = scheme.secondaryContainer;
        foreground = scheme.onSecondaryContainer;
        actions.add(_action('Retry', _retrying ? null : _retry, foreground));
        break;
      case ConnectionStatus.reconnecting:
        icon = Icons.sync;
        title = 'Reconnecting…';
        subtitle = state.reconnectAttempt > 1
            ? 'Attempt ${state.reconnectAttempt}'
            : null;
        background = scheme.secondaryContainer;
        foreground = scheme.onSecondaryContainer;
        break;
      case ConnectionStatus.revoked:
        icon = Icons.block;
        title = 'This device was signed out';
        subtitle =
            error is LaravelConnectionRevokedException && error.reason != null
                ? error.reason
                : 'The session was revoked from another device.';
        actions.add(_action('Sign in', widget.onRevoked, foreground));
        break;
      case ConnectionStatus.upgradeRequired:
        icon = Icons.system_update;
        title = 'Update required';
        final upgrade = error is LaravelUpgradeRequiredException ? error : null;
        subtitle = upgrade?.minVersion != null
            ? 'Version ${upgrade!.minVersion} or newer is required'
                '${upgrade.currentVersion != null ? ' (you have ${upgrade.currentVersion})' : ''}.'
            : 'Please update the app to continue.';
        if (upgrade != null && widget.onUpdate != null) {
          actions.add(
              _action('Update', () => widget.onUpdate!(upgrade), foreground));
        }
        break;
      case ConnectionStatus.failed:
        icon = Icons.error_outline;
        title = 'Cannot connect to the server';
        subtitle =
            error is LaravelException ? error.message : error?.toString();
        actions.add(_action('Retry', _retrying ? null : _retry, foreground));
        break;
      case ConnectionStatus.idle:
      case ConnectionStatus.connecting:
      case ConnectionStatus.connected:
        icon = Icons.cloud_outlined;
        title = ConnectionStatusStyle.of(context, state.status).label;
        background = scheme.surfaceContainerHighest;
        foreground = scheme.onSurface;
        break;
    }

    final busy = state.status == ConnectionStatus.reconnecting || _retrying;

    return Material(
      color: background,
      child: SafeArea(
        top: widget.position == LaravelBannerPosition.top,
        bottom: widget.position == LaravelBannerPosition.bottom,
        child: Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                if (busy)
                  SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: foreground),
                  )
                else
                  Icon(icon, color: foreground, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(color: foreground),
                      ),
                      if (subtitle != null && subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: foreground),
                        ),
                    ],
                  ),
                ),
                ...actions,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _action(String label, VoidCallback? onPressed, Color color) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(foregroundColor: color),
      child: Text(label),
    );
  }
}
