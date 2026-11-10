import 'package:flutter/material.dart';
import '../echo/channel.dart';

/// Widget that binds to a Laravel broadcast channel and rebuilds on incoming events.
class LaravelRealtimeBuilder extends StatefulWidget {
  final Channel channel;
  final String event;
  final Widget Function(BuildContext context, dynamic lastEventData) builder;
  final dynamic initialData;

  const LaravelRealtimeBuilder({
    super.key,
    required this.channel,
    required this.event,
    required this.builder,
    this.initialData,
  });

  @override
  State<LaravelRealtimeBuilder> createState() => _LaravelRealtimeBuilderState();
}

class _LaravelRealtimeBuilderState extends State<LaravelRealtimeBuilder> {
  late dynamic _lastData;

  @override
  void initState() {
    super.initState();
    _lastData = widget.initialData;
    widget.channel.listen(widget.event, _onEvent);
  }

  void _onEvent(dynamic data) {
    if (mounted) {
      setState(() {
        _lastData = data;
      });
    }
  }

  @override
  void dispose() {
    widget.channel.stopListening(widget.event, _onEvent);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _lastData);
  }
}
