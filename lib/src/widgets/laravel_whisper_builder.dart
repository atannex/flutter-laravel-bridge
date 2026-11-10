import 'dart:async';
import 'package:flutter/material.dart';
import '../echo/channel.dart';

/// Widget for displaying ephemeral client-to-client events like typing indicators.
class LaravelWhisperBuilder extends StatefulWidget {
  final Channel channel;
  final String event;
  final Duration autoResetDuration;
  final Widget Function(
      BuildContext context, dynamic whisperData, bool isActive) builder;

  const LaravelWhisperBuilder({
    super.key,
    required this.channel,
    required this.event,
    this.autoResetDuration = const Duration(seconds: 3),
    required this.builder,
  });

  @override
  State<LaravelWhisperBuilder> createState() => _LaravelWhisperBuilderState();
}

class _LaravelWhisperBuilderState extends State<LaravelWhisperBuilder> {
  dynamic _data;
  bool _isActive = false;
  Timer? _resetTimer;

  @override
  void initState() {
    super.initState();
    widget.channel.listenForWhisper(widget.event, _onWhisper);
  }

  void _onWhisper(dynamic data) {
    if (!mounted) return;

    _resetTimer?.cancel();
    setState(() {
      _data = data;
      _isActive = true;
    });

    _resetTimer = Timer(widget.autoResetDuration, () {
      if (mounted) {
        setState(() {
          _isActive = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    widget.channel.stopListeningForWhisper(widget.event, _onWhisper);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _data, _isActive);
  }
}
