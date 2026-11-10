# Real-Time Model Synchronization & `LaravelRealtimeStore`

The `flutter_laravel_bridge` and `laravel-flutter-bridge` work together to provide reactive real-time model synchronization. Changes made on the server or by other users (created, updated, deleted) propagate in real time and automatically update in-memory collections and Flutter UI components without full page reloads or polling.

---

## 1. Backend: Emitting Model Broadcasts in Laravel

Laravel provides model events and broadcast events. Use the `BroadcastsToFlutter` trait on your broadcast events to standardize channel names, format metadata, and sanitize payloads:

```php
namespace App\Events;

use App\Models\Task;
use Atannex\LaravelFlutterBridge\Traits\BroadcastsToFlutter;
use Illuminate\Broadcasting\Channel;
use Illuminate\Contracts\Broadcasting\ShouldBroadcast;
use Illuminate\Queue\SerializesModels;

class TaskUpdated implements ShouldBroadcast
{
    use SerializesModels, BroadcastsToFlutter;

    public function __construct(public Task $task) {}

    /**
     * Broadcast to task project channel or user private channel.
     */
    public function broadcastOn(): Channel
    {
        return $this->privateUserChannel($this->task->user_id);
        // Or for public/project scope:
        // return $this->publicFlutterChannel("projects.{$this->task->project_id}");
    }

    /**
     * Payload delivered to Flutter.
     */
    public function broadcastWith(): array
    {
        return $this->formatFlutterPayload([
            'id' => $this->task->id,
            'title' => $this->task->title,
            'status' => $this->task->status,
            'updated_at' => $this->task->updated_at->toIso8601String(),
        ]);
    }
}
```

### Auto-Broadcasting Model Observers

You can also hook Laravel Eloquent observers to broadcast automatically:

```php
namespace App\Observers;

use App\Events\TaskCreated;
use App\Events\TaskUpdated;
use App\Events\TaskDeleted;
use App\Models\Task;

class TaskObserver
{
    public function created(Task $task): void
    {
        broadcast(new TaskCreated($task));
    }

    public function updated(Task $task): void
    {
        broadcast(new TaskUpdated($task));
    }

    public function deleted(Task $task): void
    {
        broadcast(new TaskDeleted($task->id));
    }
}
```

---

## 2. Flutter: Reactive Synchronization with `LaravelRealtimeStore`

`LaravelRealtimeStore<T>` manages an in-memory list synchronized with Laravel Reverb broadcast events.

### Setup

```dart
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';

class Task {
  final int id;
  final String title;
  final String status;

  Task({required this.id, required this.title, required this.status});

  factory Task.fromJson(dynamic json) {
    final map = json as Map<String, dynamic>;
    return Task(
      id: map['id'] as int,
      title: map['title'] as String,
      status: map['status'] as String? ?? 'pending',
    );
  }
}

// 1. Join or get private channel
final userChannel = Laravel.echo.private('users.${currentUser.id}');

// 2. Initialize Realtime Store
final taskStore = LaravelRealtimeStore<Task>(
  channel: userChannel,
  itemParser: (json) => Task.fromJson(json),
  idOf: (task) => task.id,
  createdEvent: 'TaskCreated',
  updatedEvent: 'TaskUpdated',
  deletedEvent: 'TaskDeleted',
);

// 3. Populate initial items from HTTP REST endpoint
final response = await Laravel.http.get('/api/tasks');
final tasks = (response.data as List).map((j) => Task.fromJson(j)).toList();
taskStore.setItems(tasks);
```

### UI Integration: StreamBuilder

Whenever a `TaskCreated`, `TaskUpdated`, or `TaskDeleted` event arrives via WebSocket, `LaravelRealtimeStore` mutates its list and triggers an emission on `taskStore.stream`:

```dart
class TaskListScreen extends StatelessWidget {
  final LaravelRealtimeStore<Task> store;

  const TaskListScreen({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Task>>(
      stream: store.stream,
      initialData: store.items,
      builder: (context, snapshot) {
        final tasks = snapshot.data ?? [];

        if (tasks.isEmpty) {
          return const Center(child: Text('No tasks available'));
        }

        return ListView.builder(
          itemCount: tasks.length,
          itemBuilder: (context, index) {
            final task = tasks[index];
            return ListTile(
              title: Text(task.title),
              subtitle: Text(task.status),
              trailing: task.status == 'completed'
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : const Icon(Icons.pending, color: Colors.orange),
            );
          },
        );
      },
    );
  }
}
```

---

## 3. Realtime Connection Indicator

Keep users informed of WebSocket health with `LaravelConnectionIndicator`:

```dart
AppBar(
  title: const Text('My Realtime Dashboard'),
  actions: [
    Padding(
      padding: const EdgeInsets.only(right: 16.0),
      child: Center(
        child: LaravelConnectionIndicator(
          echo: Laravel.echo,
          showLabel: true,
        ),
      ),
    ),
  ],
)
```

The indicator automatically transitions between:
- 🟢 **Live** (Green) — Reverb WebSocket connected.
- 🟡 **Connecting / Reconnecting** (Amber) — Auto-reconnect with exponential backoff.
- ⚪ **Offline** (Grey) — Disconnected.

---

## 4. Disposal and Lifecycle

Always dispose the store in your StatefulWidget's `dispose()` method or state management container to unsubscribe listeners:

```dart
@override
void dispose() {
  taskStore.dispose();
  super.dispose();
}
```
