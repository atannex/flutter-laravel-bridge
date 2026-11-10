import 'package:flutter/material.dart';

import '../connection/connection_manager.dart';
import '../connection/connection_session.dart';
import '../exceptions/laravel_exception.dart';
import '../laravel.dart';
import 'laravel_connection_builder.dart';

/// Lists the remote sessions (devices) of the signed-in user, lets them revoke
/// a single session or sign out every other device.
class LaravelSessionsView extends StatefulWidget {
  /// Manager to use; defaults to [Laravel.connections].
  final LaravelConnectionManager? manager;

  /// Screen title.
  final String title;

  /// Only list active sessions (`?status=active`).
  final bool activeOnly;

  /// Wrap the list in a [Scaffold] with an app bar. Disable to embed.
  final bool showScaffold;

  const LaravelSessionsView({
    super.key,
    this.manager,
    this.title = 'Active sessions',
    this.activeOnly = false,
    this.showScaffold = true,
  });

  /// Icon representing a session platform.
  static IconData platformIcon(String? platform) {
    switch (platform) {
      case 'android':
        return Icons.android;
      case 'ios':
        return Icons.phone_iphone;
      case 'web':
        return Icons.language;
      case 'macos':
        return Icons.laptop_mac;
      case 'windows':
        return Icons.desktop_windows_outlined;
      case 'linux':
        return Icons.computer;
      case 'fuchsia':
        return Icons.devices_other;
      default:
        return Icons.devices;
    }
  }

  @override
  State<LaravelSessionsView> createState() => _LaravelSessionsViewState();
}

class _LaravelSessionsViewState extends State<LaravelSessionsView> {
  late LaravelConnectionManager _manager;
  List<ConnectionSession>? _sessions;
  Object? _error;
  bool _loading = false;
  final Set<String> _revoking = {};
  bool _revokingOthers = false;

  @override
  void initState() {
    super.initState();
    _manager = widget.manager ?? Laravel.connections;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sessions =
          await _manager.sessions(status: widget.activeOnly ? 'active' : null);
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  bool _isCurrent(ConnectionSession session) =>
      session.isCurrent || session.id == _manager.session?.id;

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }

  Future<bool> _confirm(
      {required String title,
      required String message,
      required String action}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.logout),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action)),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _revoke(ConnectionSession session) async {
    final current = _isCurrent(session);
    final confirmed = await _confirm(
      title: current
          ? 'Sign out this device?'
          : 'Sign out ${_deviceLabel(session)}?',
      message: current
          ? 'You will be signed out of this app on this device.'
          : 'That device will be signed out immediately and will need to sign in again.',
      action: 'Sign out',
    );
    if (!confirmed) return;

    setState(() => _revoking.add(session.id));
    try {
      await _manager.revokeSession(session.id);
      _showMessage('${_deviceLabel(session)} signed out');
      if (!current) await _load();
    } catch (e) {
      _showMessage(_describe(e), error: true);
    } finally {
      if (mounted) setState(() => _revoking.remove(session.id));
    }
  }

  Future<void> _revokeOthers() async {
    final confirmed = await _confirm(
      title: 'Sign out all other devices?',
      message:
          'Every other device signed in to your account will be signed out.',
      action: 'Sign out all',
    );
    if (!confirmed) return;

    setState(() => _revokingOthers = true);
    try {
      final count = await _manager.revokeOtherSessions();
      _showMessage(
          count == 1 ? '1 device signed out' : '$count devices signed out');
      await _load();
    } catch (e) {
      _showMessage(_describe(e), error: true);
    } finally {
      if (mounted) setState(() => _revokingOthers = false);
    }
  }

  static String _deviceLabel(ConnectionSession session) {
    final name = session.deviceName;
    if (name != null && name.isNotEmpty) return name;
    final platform = session.platform;
    if (platform != null && platform.isNotEmpty) {
      return platform == 'ios'
          ? 'iOS device'
          : '${platform[0].toUpperCase()}${platform.substring(1)} device';
    }
    return 'Unknown device';
  }

  static String _describe(Object error) =>
      error is LaravelException ? error.message : error.toString();

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = _sessions;

    if (sessions == null && _loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (sessions == null && _error != null) {
      final error = _error!;
      final unauthenticated = error is LaravelAuthenticationException;
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(32),
        children: [
          const SizedBox(height: 48),
          Icon(
            unauthenticated ? Icons.lock_outline : Icons.error_outline,
            size: 56,
            color: theme.colorScheme.error,
          ),
          const SizedBox(height: 16),
          Text(
            unauthenticated
                ? 'Sign in to see your sessions'
                : 'Could not load sessions',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(_describe(error), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Center(
              child: OutlinedButton(
                  onPressed: _load, child: const Text('Try again'))),
        ],
      );
    }

    final list = sessions ?? const <ConnectionSession>[];
    final sorted = [...list]..sort((a, b) {
        if (_isCurrent(a) != _isCurrent(b)) return _isCurrent(a) ? -1 : 1;
        final aSeen = a.lastSeenAt ?? a.connectedAt ?? DateTime(0);
        final bSeen = b.lastSeenAt ?? b.connectedAt ?? DateTime(0);
        return bSeen.compareTo(aSeen);
      });
    final hasOthers = sorted.any((s) => !_isCurrent(s) && !s.isRevoked);

    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: sorted.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: const [
                    SizedBox(height: 96),
                    Center(child: Text('No sessions found')),
                  ],
                )
              : ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: sorted.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 72),
                  itemBuilder: (context, index) => _SessionTile(
                    session: sorted[index],
                    label: _deviceLabel(sorted[index]),
                    isCurrent: _isCurrent(sorted[index]),
                    revoking: _revoking.contains(sorted[index].id),
                    onRevoke: sorted[index].isRevoked
                        ? null
                        : () => _revoke(sorted[index]),
                  ),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: hasOthers && !_revokingOthers ? _revokeOthers : null,
                icon: _revokingOthers
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.logout),
                label: const Text('Sign out all other devices'),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = RefreshIndicator(onRefresh: _load, child: _buildBody(context));
    if (!widget.showScaffold) return body;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: body,
    );
  }
}

class _SessionTile extends StatelessWidget {
  final ConnectionSession session;
  final String label;
  final bool isCurrent;
  final bool revoking;
  final VoidCallback? onRevoke;

  const _SessionTile({
    required this.session,
    required this.label,
    required this.isCurrent,
    required this.revoking,
    required this.onRevoke,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final online = session.isOnline || isCurrent;

    final details = <String>[
      if (session.appVersion != null) 'App ${session.appVersion}',
      if (session.osVersion != null)
        '${session.platform ?? 'OS'} ${session.osVersion}',
      if (session.isRevoked)
        'Revoked ${formatRelativeTime(session.revokedAt)}'
      else
        isCurrent
            ? 'Active now'
            : 'Last seen ${formatRelativeTime(session.lastSeenAt ?? session.connectedAt)}',
      if (session.ipAddress != null) session.ipAddress!,
    ];

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            backgroundColor: isCurrent
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            foregroundColor:
                isCurrent ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
            child: Icon(LaravelSessionsView.platformIcon(session.platform)),
          ),
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: session.isRevoked
                    ? scheme.error
                    : (online ? const Color(0xFF2E7D32) : scheme.outline),
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surface, width: 2),
              ),
            ),
          ),
        ],
      ),
      title: Row(
        children: [
          Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (isCurrent) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'This device',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: scheme.onPrimary),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(details.join(' · ')),
      trailing: revoking
          ? const SizedBox.square(
              dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : (onRevoke == null
              ? null
              : IconButton(
                  tooltip:
                      isCurrent ? 'Sign out this device' : 'Sign out device',
                  icon: Icon(Icons.logout, color: scheme.error),
                  onPressed: onRevoke,
                )),
    );
  }
}
