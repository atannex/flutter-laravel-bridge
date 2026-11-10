# Presence Channels & Live Room Management

Presence channels build on private authenticated channels by maintaining a live directory of users who are currently subscribed to the channel.

---

## 1. Defining Presence Channels in Laravel

In `routes/channels.php`:

```php
use App\Models\User;
use Illuminate\Support\Facades\Broadcast;

Broadcast::channel('chat.room.{roomId}', function (User $user, int $roomId) {
    // Return array containing public member info displayed to other participants
    return [
        'id' => $user->id,
        'name' => $user->name,
        'avatar' => $user->avatar_url,
    ];
});
```

---

## 2. Joining Presence Channels in Flutter

```dart
final room = Laravel.echo.join('chat.room.101');

room
  .here((members) {
    print('Initial active member list: $members');
  })
  .joining((newMember) {
    print('${newMember['name']} joined the room');
  })
  .leaving((departedMember) {
    print('${departedMember['name']} left the room');
  })
  .listen('MessageSent', (data) {
    print('Message from ${data['sender']}: ${data['body']}');
  });
```

---

## 3. UI Display with `LaravelPresenceBuilder`

Build an active participants avatar row effortlessly:

```dart
LaravelPresenceBuilder(
  presenceChannel: Laravel.echo.join('chat.room.101'),
  builder: (context, members) {
    return SizedBox(
      height: 48,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: members.length,
        itemBuilder: (context, index) {
          final member = members[index];
          return CircleAvatar(
            child: Text(member['name'][0]),
          );
        },
      ),
    );
  },
);
```
