import 'dart:async';
import '../echo/channel.dart';

/// Reactive real-time data store that automatically synchronizes an in-memory collection
/// with Laravel broadcast events (`Created`, `Updated`, `Deleted`).
class LaravelRealtimeStore<T> {
  final Channel channel;
  final String createdEvent;
  final String updatedEvent;
  final String deletedEvent;
  final T Function(dynamic json) itemParser;
  final dynamic Function(T item) idOf;

  final List<T> _items = [];
  final _itemsController = StreamController<List<T>>.broadcast();

  /// Current synchronized list of items.
  List<T> get items => List.unmodifiable(_items);

  /// Reactive stream emitting the list whenever real-time additions, updates, or deletions occur.
  Stream<List<T>> get stream => _itemsController.stream;

  LaravelRealtimeStore({
    required this.channel,
    required this.itemParser,
    required this.idOf,
    this.createdEvent = 'Created',
    this.updatedEvent = 'Updated',
    this.deletedEvent = 'Deleted',
    List<T>? initialItems,
  }) {
    if (initialItems != null) {
      _items.addAll(initialItems);
      _itemsController.add(List.unmodifiable(_items));
    }
    _bindListeners();
  }

  void _bindListeners() {
    // 1. Listen for Created event
    channel.listen(createdEvent, (data) {
      final item = itemParser(data);
      _items.insert(0, item);
      _itemsController.add(List.unmodifiable(_items));
    });

    // 2. Listen for Updated event
    channel.listen(updatedEvent, (data) {
      final updatedItem = itemParser(data);
      final targetId = idOf(updatedItem);
      final index = _items.indexWhere((it) => idOf(it) == targetId);

      if (index != -1) {
        _items[index] = updatedItem;
      } else {
        _items.insert(0, updatedItem);
      }
      _itemsController.add(List.unmodifiable(_items));
    });

    // 3. Listen for Deleted event
    channel.listen(deletedEvent, (data) {
      final deletedId = data is Map ? (data['id'] ?? data['deleted_id']) : data;
      _items.removeWhere((it) => idOf(it) == deletedId);
      _itemsController.add(List.unmodifiable(_items));
    });
  }

  /// Manually replace or populate initial items (e.g. from an HTTP paginated fetch).
  void setItems(List<T> newItems) {
    _items.clear();
    _items.addAll(newItems);
    _itemsController.add(List.unmodifiable(_items));
  }

  /// Clean up channel listeners and stream controllers.
  void dispose() {
    channel.stopListening(createdEvent);
    channel.stopListening(updatedEvent);
    channel.stopListening(deletedEvent);
    _itemsController.close();
  }
}
