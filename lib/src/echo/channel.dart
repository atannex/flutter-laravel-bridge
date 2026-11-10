import 'dart:async';

typedef EventCallback = void Function(dynamic data);
typedef WhisperSender = void Function(
    String channelName, String event, dynamic data);

/// Represents a broadcast channel (public, private, or presence).
class Channel {
  final String name;
  final WhisperSender? _whisperSender;
  final Map<String, List<EventCallback>> _eventListeners = {};
  final _streamController = StreamController<Map<String, dynamic>>.broadcast();

  Channel(this.name, [this._whisperSender]);

  /// Stream of all events received on this channel.
  Stream<Map<String, dynamic>> get eventStream => _streamController.stream;

  /// Register a listener for a specific event name.
  Channel listen(String event, EventCallback callback) {
    final cleanEvent = _normalizeEvent(event);
    _eventListeners.putIfAbsent(cleanEvent, () => []).add(callback);
    return this;
  }

  /// Remove a listener for a specific event name.
  Channel stopListening(String event, [EventCallback? callback]) {
    final cleanEvent = _normalizeEvent(event);
    if (callback != null) {
      _eventListeners[cleanEvent]?.remove(callback);
    } else {
      _eventListeners.remove(cleanEvent);
    }
    return this;
  }

  /// Send a real-time client whisper event directly to other channel members without hitting the HTTP backend.
  /// Note: Whisper events must be enabled in Pusher/Reverb and channels must be private or presence.
  Channel whisper(String event, dynamic data) {
    final clientEvent = event.startsWith('client-') ? event : 'client-$event';
    if (_whisperSender != null) {
      _whisperSender(name, clientEvent, data);
    }
    return this;
  }

  /// Listen for client whisper events (e.g. typing indicators, peer cursors).
  Channel listenForWhisper(String event, EventCallback callback) {
    final clientEvent = event.startsWith('client-') ? event : 'client-$event';
    return listen(clientEvent, callback);
  }

  /// Stop listening for client whisper events.
  Channel stopListeningForWhisper(String event, [EventCallback? callback]) {
    final clientEvent = event.startsWith('client-') ? event : 'client-$event';
    return stopListening(clientEvent, callback);
  }

  /// Dispatch an incoming event to registered callbacks.
  void dispatch(String event, dynamic data) {
    if (!_streamController.isClosed) {
      _streamController.add({'event': event, 'data': data});
    }

    final cleanEvent = _normalizeEvent(event);
    final listeners = _eventListeners[cleanEvent];
    if (listeners != null) {
      for (final callback in List<EventCallback>.from(listeners)) {
        callback(data);
      }
    }

    // Also check unqualified event name (e.g. 'OrderShipped' matching 'App\Events\OrderShipped'
    // or 'App.Events.OrderShipped')
    if (cleanEvent.contains('.') || cleanEvent.contains('\\')) {
      final shortName = cleanEvent.split(RegExp(r'[.\\]')).last;
      if (shortName != cleanEvent) {
        final shortListeners = _eventListeners[shortName];
        if (shortListeners != null) {
          for (final callback in List<EventCallback>.from(shortListeners)) {
            callback(data);
          }
        }
      }
    }
  }

  /// Strip the Laravel Echo "absolute name" markers (leading `.` or `\`).
  static String _normalizeEvent(String event) {
    var result = event;
    while (result.startsWith('.') || result.startsWith('\\')) {
      result = result.substring(1);
    }
    return result;
  }

  /// Close resources.
  void dispose() {
    _eventListeners.clear();
    _streamController.close();
  }
}
