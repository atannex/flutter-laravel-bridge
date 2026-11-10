import 'dart:async';

import 'package:flutter/material.dart';

import '../connection/bridge_endpoints.dart';
import '../connection/connection_manager.dart';
import '../connection/connection_state.dart';
import '../connection/laravel_connection.dart';
import '../exceptions/laravel_exception.dart';
import '../laravel.dart';
import 'laravel_connection_builder.dart';
import 'laravel_sessions_view.dart';

/// Complete Material 3 screen to manage backend connection profiles:
/// list with status, latency and active marker, tap to switch, add / edit
/// with a live "Test connection" probe, delete with confirmation,
/// pull-to-refresh latency checks and an optional sessions shortcut.
class LaravelConnectionManagerView extends StatefulWidget {
  /// Manager to drive; defaults to [Laravel.connections].
  final LaravelConnectionManager? manager;

  /// Screen title.
  final String title;

  /// Show the "Active sessions" action (opens [LaravelSessionsView]).
  final bool showSessionsButton;

  /// Custom handler for the sessions action (defaults to pushing [LaravelSessionsView]).
  final VoidCallback? onOpenSessions;

  /// Allow adding / editing / deleting profiles.
  final bool allowEditing;

  /// Show the app key field in the editor.
  final bool showAppKeyField;

  /// Called after the active connection changed.
  final void Function(LaravelConnection connection)? onSwitched;

  const LaravelConnectionManagerView({
    super.key,
    this.manager,
    this.title = 'Connections',
    this.showSessionsButton = true,
    this.onOpenSessions,
    this.allowEditing = true,
    this.showAppKeyField = true,
    this.onSwitched,
  });

  @override
  State<LaravelConnectionManagerView> createState() =>
      _LaravelConnectionManagerViewState();
}

class _LaravelConnectionManagerViewState
    extends State<LaravelConnectionManagerView> {
  late LaravelConnectionManager _manager;
  final Map<String, ConnectionProbeResult> _probes = {};
  final Set<String> _probing = {};
  String? _switchingId;

  @override
  void initState() {
    super.initState();
    _manager = widget.manager ?? Laravel.connections;
  }

  @override
  void didUpdateWidget(covariant LaravelConnectionManagerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.manager != widget.manager) {
      _manager = widget.manager ?? Laravel.connections;
    }
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
  }

  Future<void> _refreshAll() async {
    final futures = <Future<void>>[];
    for (final profile in _manager.connections) {
      futures.add(_probe(profile));
    }
    await Future.wait(futures);
  }

  Future<void> _probe(LaravelConnection profile) async {
    if (_probing.contains(profile.id)) return;
    setState(() => _probing.add(profile.id));
    ConnectionProbeResult result;
    try {
      if (profile.id == _manager.activeId && _manager.client != null) {
        final latency = await _manager.ping();
        result = ConnectionProbeResult(
            ok: true, latency: latency, serverInfo: _manager.serverInfo);
      } else {
        result = await _manager.test(profile);
      }
    } catch (e) {
      result = ConnectionProbeResult(ok: false, error: e);
    }
    if (!mounted) return;
    setState(() {
      _probing.remove(profile.id);
      _probes[profile.id] = result;
    });
  }

  Future<void> _switchTo(LaravelConnection profile) async {
    if (_switchingId != null) return;
    if (profile.id == _manager.activeId && _manager.state.isConnected) return;
    setState(() => _switchingId = profile.id);
    try {
      await _manager.switchTo(profile.id);
      final state = _manager.state;
      if (state.status == ConnectionStatus.connected) {
        _showMessage('Connected to ${profile.name}');
      } else {
        _showMessage(
          'Switched to ${profile.name} (${ConnectionStatusStyle.of(context, state.status).label.toLowerCase()})',
          error: state.status.isProblem,
        );
      }
      widget.onSwitched?.call(profile);
    } catch (e) {
      _showMessage('Could not switch: ${_describe(e)}', error: true);
    } finally {
      if (mounted) setState(() => _switchingId = null);
    }
  }

  Future<void> _openEditor([LaravelConnection? existing]) async {
    final result = await showModalBottomSheet<LaravelConnection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => LaravelConnectionEditor(
        manager: _manager,
        initial: existing,
        showAppKeyField: widget.showAppKeyField,
      ),
    );
    if (result == null || !mounted) return;

    try {
      if (existing == null) {
        final makeActive = _manager.connections.isEmpty;
        await _manager.add(result, makeActive: makeActive);
        _showMessage('Added ${result.name}');
      } else {
        await _manager.update(result);
        _showMessage('Saved ${result.name}');
      }
      _probes.remove(result.id);
    } catch (e) {
      _showMessage(_describe(e), error: true);
    }
  }

  Future<void> _confirmDelete(LaravelConnection profile) async {
    final isActive = profile.id == _manager.activeId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text('Delete ${profile.name}?'),
        content: Text(
          isActive
              ? 'This is the active connection. It will be disconnected and you will be '
                  'signed out of ${profile.host}.'
              : 'Saved credentials for ${profile.host} will be removed from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _manager.remove(profile.id);
      _probes.remove(profile.id);
      _showMessage('Deleted ${profile.name}');
    } catch (e) {
      _showMessage(_describe(e), error: true);
    }
  }

  void _openSessions() {
    if (widget.onOpenSessions != null) {
      widget.onOpenSessions!();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
          builder: (_) => LaravelSessionsView(manager: _manager)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (widget.showSessionsButton)
            IconButton(
              tooltip: 'Active sessions',
              icon: const Icon(Icons.devices_other_outlined),
              onPressed: _manager.client == null ? null : _openSessions,
            ),
          IconButton(
            tooltip: 'Check all',
            icon: const Icon(Icons.network_check),
            onPressed: _refreshAll,
          ),
        ],
      ),
      floatingActionButton: widget.allowEditing
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add),
              label: const Text('Add connection'),
            )
          : null,
      body: StreamBuilder<List<LaravelConnection>>(
        stream: _manager.connectionsStream,
        initialData: _manager.connections,
        builder: (context, profilesSnapshot) {
          final profiles = profilesSnapshot.data ?? _manager.connections;
          return LaravelConnectionBuilder(
            manager: _manager,
            builder: (context, state) {
              return RefreshIndicator(
                onRefresh: _refreshAll,
                child: profiles.isEmpty
                    ? _EmptyState(
                        onAdd: widget.allowEditing ? () => _openEditor() : null)
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                        itemCount: profiles.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final profile = profiles[index];
                          final isActive = profile.id == _manager.activeId;
                          return _ConnectionTile(
                            profile: profile,
                            isActive: isActive,
                            state: isActive ? state : null,
                            probe: _probes[profile.id],
                            probing: _probing.contains(profile.id),
                            switching: _switchingId == profile.id,
                            allowEditing: widget.allowEditing,
                            onTap: () => _switchTo(profile),
                            onEdit: () => _openEditor(profile),
                            onTest: () => _probe(profile),
                            onDelete: () => _confirmDelete(profile),
                            onReconnect: () => _manager.connect(),
                          );
                        },
                      ),
              );
            },
          );
        },
      ),
    );
  }
}

String _describe(Object error) =>
    error is LaravelException ? error.message : error.toString();

class _EmptyState extends StatelessWidget {
  final VoidCallback? onAdd;

  const _EmptyState({this.onAdd});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 48),
        Icon(Icons.dns_outlined, size: 64, color: theme.colorScheme.outline),
        const SizedBox(height: 16),
        Text('No connections yet',
            textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          'Add a Laravel server to get started.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        if (onAdd != null) ...[
          const SizedBox(height: 24),
          Center(
            child: FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add connection'),
            ),
          ),
        ],
      ],
    );
  }
}

enum _TileAction { edit, test, reconnect, delete }

class _ConnectionTile extends StatelessWidget {
  final LaravelConnection profile;
  final bool isActive;
  final LaravelConnectionState? state;
  final ConnectionProbeResult? probe;
  final bool probing;
  final bool switching;
  final bool allowEditing;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onTest;
  final VoidCallback onDelete;
  final VoidCallback onReconnect;

  const _ConnectionTile({
    required this.profile,
    required this.isActive,
    required this.state,
    required this.probe,
    required this.probing,
    required this.switching,
    required this.allowEditing,
    required this.onTap,
    required this.onEdit,
    required this.onTest,
    required this.onDelete,
    required this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final latency = (isActive ? state?.latency : null) ?? probe?.latency;

    final Widget statusChip;
    if (isActive && state != null) {
      statusChip = LaravelConnectionStatusChip(status: state!.status);
    } else if (probe != null) {
      statusChip = LaravelConnectionStatusChip(
        status:
            probe!.ok ? ConnectionStatus.connected : ConnectionStatus.failed,
        label: probe!.ok ? 'Reachable' : 'Unreachable',
      );
    } else {
      statusChip = const LaravelConnectionStatusChip(
          status: ConnectionStatus.idle, label: 'Inactive');
    }

    final details = <String>[
      '${profile.normalizedBaseUrl}/${profile.normalizedPrefix}',
      if (latency != null) formatLatency(latency),
      if (profile.lastConnectedAt != null)
        'Last used ${formatRelativeTime(profile.lastConnectedAt)}',
    ];
    final serverName = isActive
        ? state?.serverInfo?.server.name
        : probe?.serverInfo?.server.name;
    final probeError =
        !isActive && probe != null && !probe!.ok ? probe!.errorMessage : null;
    final activeError = isActive &&
            state != null &&
            state!.status.isProblem &&
            state!.error != null
        ? _describe(state!.error!)
        : null;

    return Card(
      elevation: 0,
      color: isActive
          ? scheme.primaryContainer.withValues(alpha: 0.45)
          : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isActive ? scheme.primary : scheme.outlineVariant,
          width: isActive ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: switching ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: switching || probing
                    ? const SizedBox.square(
                        dimension: 40,
                        child: Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : CircleAvatar(
                        backgroundColor: isActive
                            ? scheme.primary
                            : scheme.secondaryContainer,
                        foregroundColor: isActive
                            ? scheme.onPrimary
                            : scheme.onSecondaryContainer,
                        child: Icon(isActive ? Icons.check : Icons.dns_outlined,
                            size: 20),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            profile.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        if (isActive) ...[
                          const SizedBox(width: 8),
                          Text(
                            'ACTIVE',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      details.join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    if (serverName != null)
                      Text(
                        serverName,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    if (probeError != null || activeError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          (probeError ?? activeError)!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.error),
                        ),
                      ),
                    const SizedBox(height: 8),
                    statusChip,
                  ],
                ),
              ),
              PopupMenuButton<_TileAction>(
                tooltip: 'More',
                onSelected: (action) {
                  switch (action) {
                    case _TileAction.edit:
                      onEdit();
                      break;
                    case _TileAction.test:
                      onTest();
                      break;
                    case _TileAction.reconnect:
                      onReconnect();
                      break;
                    case _TileAction.delete:
                      onDelete();
                      break;
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: _TileAction.test,
                    child: ListTile(
                        leading: Icon(Icons.network_check),
                        title: Text('Test')),
                  ),
                  if (isActive)
                    const PopupMenuItem(
                      value: _TileAction.reconnect,
                      child: ListTile(
                          leading: Icon(Icons.refresh),
                          title: Text('Reconnect')),
                    ),
                  if (allowEditing) ...[
                    const PopupMenuItem(
                      value: _TileAction.edit,
                      child: ListTile(
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Edit')),
                    ),
                    const PopupMenuItem(
                      value: _TileAction.delete,
                      child: ListTile(
                          leading: Icon(Icons.delete_outline),
                          title: Text('Delete')),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Form used by [LaravelConnectionManagerView] to add or edit a profile.
/// Pops the resulting [LaravelConnection] (or null when cancelled).
class LaravelConnectionEditor extends StatefulWidget {
  final LaravelConnectionManager manager;
  final LaravelConnection? initial;
  final bool showAppKeyField;

  const LaravelConnectionEditor({
    super.key,
    required this.manager,
    this.initial,
    this.showAppKeyField = true,
  });

  @override
  State<LaravelConnectionEditor> createState() =>
      _LaravelConnectionEditorState();
}

class _LaravelConnectionEditorState extends State<LaravelConnectionEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _appKey;
  late final TextEditingController _prefix;
  ConnectionProbeResult? _probe;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? '');
    _baseUrl = TextEditingController(text: initial?.baseUrl ?? 'https://');
    _appKey = TextEditingController(text: initial?.appKey ?? '');
    _prefix = TextEditingController(
        text: initial?.prefix ?? BridgeEndpoints.defaultPrefix);
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _appKey.dispose();
    _prefix.dispose();
    super.dispose();
  }

  LaravelConnection _build() {
    final appKey = _appKey.text.trim();
    final prefix = BridgeEndpoints.normalizePrefix(_prefix.text);
    final baseUrl = _baseUrl.text.trim();
    final name = _name.text.trim().isEmpty
        ? (Uri.tryParse(baseUrl)?.host ?? baseUrl)
        : _name.text.trim();
    final initial = widget.initial;
    if (initial == null) {
      return LaravelConnection.create(
        name: name,
        baseUrl: baseUrl,
        prefix: prefix.isEmpty ? BridgeEndpoints.defaultPrefix : prefix,
        appKey: appKey.isEmpty ? null : appKey,
      );
    }
    return initial.copyWith(
      name: name,
      baseUrl: baseUrl,
      prefix: prefix.isEmpty ? BridgeEndpoints.defaultPrefix : prefix,
      appKey: appKey.isEmpty ? null : appKey,
      clearAppKey: appKey.isEmpty,
    );
  }

  Future<void> _test() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _testing = true;
      _probe = null;
    });
    final result = await widget.manager.test(_build());
    if (!mounted) return;
    setState(() {
      _testing = false;
      _probe = result;
      // Pre-fill the name from the server when the user left it empty.
      final serverName = result.serverInfo?.server.name;
      if (_name.text.trim().isEmpty && serverName != null)
        _name.text = serverName;
    });
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(_build());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEditing = widget.initial != null;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(isEditing ? 'Edit connection' : 'Add connection',
                  style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey('laravel-connection-name'),
                controller: _name,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Production',
                  prefixIcon: Icon(Icons.label_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('laravel-connection-url'),
                controller: _baseUrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.next,
                validator: LaravelConnection.validateBaseUrl,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  hintText: 'https://api.example.com',
                  prefixIcon: Icon(Icons.link),
                  border: OutlineInputBorder(),
                ),
              ),
              if (widget.showAppKeyField) ...[
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('laravel-connection-app-key'),
                  controller: _appKey,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'App key (optional)',
                    hintText: 'fba_…',
                    prefixIcon: Icon(Icons.key_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('laravel-connection-prefix'),
                controller: _prefix,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Route prefix',
                  helperText: 'flutter-bridge.prefix on the server',
                  prefixIcon: Icon(Icons.alt_route),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              if (_testing || _probe != null)
                _ProbeResultCard(result: _probe, testing: _testing),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: const Icon(Icons.network_check),
                      label: const Text('Test connection'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(isEditing ? 'Save' : 'Add'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProbeResultCard extends StatelessWidget {
  final ConnectionProbeResult? result;
  final bool testing;

  const _ProbeResultCard({required this.result, required this.testing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (testing || result == null) {
      return const Card(
        elevation: 0,
        child: ListTile(
          leading: SizedBox.square(
              dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
          title: Text('Testing connection…'),
        ),
      );
    }

    final probe = result!;
    final info = probe.serverInfo;
    final lines = <String>[
      if (probe.latency != null) 'Latency ${formatLatency(probe.latency)}',
      if (info?.server.name != null) info!.server.name!,
      if (info?.server.environment != null) info!.server.environment!,
      if (info?.bridge.version != null) 'Bridge ${info!.bridge.version}',
      if (info?.app?.name != null) 'App ${info!.app!.name}',
    ];

    return Card(
      elevation: 0,
      color: probe.ok ? scheme.primaryContainer : scheme.errorContainer,
      child: ListTile(
        leading: Icon(
          probe.ok ? Icons.check_circle_outline : Icons.error_outline,
          color: probe.ok ? scheme.onPrimaryContainer : scheme.onErrorContainer,
        ),
        title: Text(
          probe.ok ? 'Connection successful' : 'Connection failed',
          style: TextStyle(
              color: probe.ok
                  ? scheme.onPrimaryContainer
                  : scheme.onErrorContainer),
        ),
        subtitle: Text(
          probe.ok
              ? lines.join(' · ')
              : (probe.errorMessage ?? 'Unknown error'),
          style: TextStyle(
              color: probe.ok
                  ? scheme.onPrimaryContainer
                  : scheme.onErrorContainer),
        ),
      ),
    );
  }
}
