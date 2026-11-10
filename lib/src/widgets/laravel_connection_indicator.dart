import 'package:flutter/material.dart';
import '../connection/connection_manager.dart';
import '../connection/connection_state.dart';
import '../echo/laravel_echo.dart';

/// Real-time visual badge showing WebSocket connection health, or — when a
/// [LaravelConnectionManager] is given — the backend session health.
class LaravelConnectionIndicator extends StatelessWidget {
  final LaravelEcho? echo;
  final LaravelConnectionManager? manager;
  final bool showLabel;

  const LaravelConnectionIndicator({
    super.key,
    this.echo,
    this.manager,
    this.showLabel = true,
  }) : assert(echo != null || manager != null,
            'Provide either an echo or a manager');

  @override
  Widget build(BuildContext context) {
    final connectionManager = manager;
    if (connectionManager != null) {
      return StreamBuilder<LaravelConnectionState>(
        stream: connectionManager.stateStream,
        initialData: connectionManager.state,
        builder: (context, snapshot) {
          final status = snapshot.data?.status ?? ConnectionStatus.idle;
          final Color color;
          final String label;
          switch (status) {
            case ConnectionStatus.connected:
              color = Colors.green;
              label = 'Live';
              break;
            case ConnectionStatus.connecting:
            case ConnectionStatus.reconnecting:
              color = Colors.amber;
              label = 'Connecting...';
              break;
            case ConnectionStatus.offline:
            case ConnectionStatus.idle:
              color = Colors.grey;
              label = 'Offline';
              break;
            case ConnectionStatus.failed:
            case ConnectionStatus.revoked:
              color = Colors.red;
              label =
                  status == ConnectionStatus.revoked ? 'Signed out' : 'Error';
              break;
            case ConnectionStatus.upgradeRequired:
              color = Colors.red;
              label = 'Update required';
              break;
          }
          return _badge(color, label);
        },
      );
    }

    final socket = echo!;
    return StreamBuilder<EchoConnectionState>(
      stream: socket.connectionStateStream,
      initialData: socket.connectionState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? EchoConnectionState.disconnected;

        Color dotColor;
        String label;

        switch (state) {
          case EchoConnectionState.connected:
            dotColor = Colors.green;
            label = 'Live';
            break;
          case EchoConnectionState.connecting:
          case EchoConnectionState.reconnecting:
            dotColor = Colors.amber;
            label = 'Connecting...';
            break;
          case EchoConnectionState.disconnected:
            dotColor = Colors.grey;
            label = 'Offline';
            break;
        }

        return _badge(dotColor, label);
      },
    );
  }

  Widget _badge(Color dotColor, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
          ),
        ),
        if (showLabel) ...[
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: dotColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}
