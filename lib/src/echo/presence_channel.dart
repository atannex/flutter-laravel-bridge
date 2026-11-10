import 'private_channel.dart';

typedef MembersCallback = void Function(List<dynamic> members);
typedef MemberCallback = void Function(dynamic member);

/// Represents an authenticated presence broadcast channel with active members tracking.
///
/// Members are tracked by their presence `user_id` (the key of the Pusher
/// presence hash), so removals work whether or not the member info itself
/// carries an `id` field.
class PresenceChannel extends PrivateChannel {
  final List<MembersCallback> _hereCallbacks = [];
  final List<MemberCallback> _joiningCallbacks = [];
  final List<MemberCallback> _leavingCallbacks = [];
  final Map<String, dynamic> _members = {};

  PresenceChannel(super.name, [super.whisperSender]);

  /// Current list of active presence members in the channel.
  List<dynamic> get members => List.unmodifiable(_members.values);

  /// Presence ids of the active members.
  List<String> get memberIds => List.unmodifiable(_members.keys);

  /// Callback executed when the client successfully subscribes and receives the initial member list.
  PresenceChannel here(MembersCallback callback) {
    _hereCallbacks.add(callback);
    if (_members.isNotEmpty) {
      callback(members);
    }
    return this;
  }

  /// Callback executed when a new member joins the presence channel.
  PresenceChannel joining(MemberCallback callback) {
    _joiningCallbacks.add(callback);
    return this;
  }

  /// Callback executed when a member leaves the presence channel.
  /// The callback receives the member info that was stored for that member.
  PresenceChannel leaving(MemberCallback callback) {
    _leavingCallbacks.add(callback);
    return this;
  }

  static String? _idOf(dynamic value) {
    if (value is Map) {
      final id = value['user_id'] ?? value['id'];
      return id?.toString();
    }
    return value?.toString();
  }

  /// Internal handler for initial member list from Reverb / Pusher.
  void handleSubscriptionSucceeded(dynamic data) {
    _members.clear();
    if (data is Map && data['presence'] is Map) {
      final presence = data['presence'] as Map;
      final hash = presence['hash'];
      if (hash is Map) {
        hash.forEach((key, val) => _members[key.toString()] = val);
      }
      final ids = presence['ids'];
      if (ids is List) {
        for (final id in ids) {
          _members.putIfAbsent(id.toString(), () => {'id': id});
        }
      }
    }
    for (final cb in List<MembersCallback>.from(_hereCallbacks)) {
      cb(members);
    }
  }

  /// Internal handler when a member joins.
  void handleMemberAdded(dynamic data) {
    final member = data is Map ? (data['user_info'] ?? data) : data;
    final id = _idOf(data) ?? _idOf(member);
    if (id == null) return;
    _members[id] = member;
    for (final cb in List<MemberCallback>.from(_joiningCallbacks)) {
      cb(member);
    }
  }

  /// Internal handler when a member leaves.
  void handleMemberRemoved(dynamic data) {
    final id = _idOf(data);
    if (id == null) return;

    dynamic removed = _members.remove(id);
    if (removed == null) {
      // Fall back to matching on the member info's own id fields.
      final key = _members.entries
          .where((e) => _idOf(e.value) == id)
          .map((e) => e.key)
          .firstOrNull;
      if (key != null) removed = _members.remove(key);
    }

    final member = removed ?? data;
    for (final cb in List<MemberCallback>.from(_leavingCallbacks)) {
      cb(member);
    }
  }
}
