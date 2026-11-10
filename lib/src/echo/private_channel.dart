import 'channel.dart';

/// Represents a private authenticated broadcast channel.
class PrivateChannel extends Channel {
  PrivateChannel(super.name, [super.whisperSender]);
}
