import 'package:flutter/material.dart';
import '../echo/presence_channel.dart';

/// Widget that subscribes to a Laravel presence channel and builds UI reflecting online participants in real time.
class LaravelPresenceBuilder extends StatefulWidget {
  final PresenceChannel presenceChannel;
  final Widget Function(BuildContext context, List<dynamic> members) builder;

  const LaravelPresenceBuilder({
    super.key,
    required this.presenceChannel,
    required this.builder,
  });

  @override
  State<LaravelPresenceBuilder> createState() => _LaravelPresenceBuilderState();
}

class _LaravelPresenceBuilderState extends State<LaravelPresenceBuilder> {
  List<dynamic> _members = [];

  @override
  void initState() {
    super.initState();
    _members = List.from(widget.presenceChannel.members);

    widget.presenceChannel.here((members) {
      if (mounted) setState(() => _members = List.from(members));
    }).joining((member) {
      if (mounted)
        setState(() => _members = List.from(widget.presenceChannel.members));
    }).leaving((member) {
      if (mounted)
        setState(() => _members = List.from(widget.presenceChannel.members));
    });
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _members);
  }
}
