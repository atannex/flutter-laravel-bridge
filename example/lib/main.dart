import 'package:flutter/material.dart';
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Example User Model matching Laravel User
class User {
  final int id;
  final String name;
  final String email;

  const User({
    required this.id,
    required this.name,
    required this.email,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: (json['id'] as num).toInt(),
      name: json['name'] as String? ?? '',
      email: json['email'] as String? ?? '',
    );
  }
}

/// Example Post Model
class Post {
  final int id;
  final String title;
  final String content;

  const Post({required this.id, required this.title, required this.content});

  factory Post.fromJson(Map<String, dynamic> json) {
    return Post(
      id: (json['id'] as num).toInt(),
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
    );
  }
}

/// Encrypted, persistent key-value store (Keychain / Android Keystore).
/// The bridge only needs async read / write / delete callbacks, so any plugin
/// (SharedPreferences, Hive…) can be adapted the same way.
const _secure = FlutterSecureStorage();

final _storage = DelegateKeyValueStore(
  read: (key) => _secure.read(key: key),
  write: (key, value) => _secure.write(key: key, value: value),
  delete: (key) => _secure.delete(key: key),
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Laravel.initialize<User>(
    options: const LaravelOptions(
      baseUrl:
          'http://10.0.2.2:8000', // 10.0.2.2 for Android emulator to access host Laravel
      appKey: 'fba_replace_with_your_app_key', // php artisan flutter:app:create
      platform: 'android',
      appVersion: '1.0.0',
      deviceName: 'Pixel 8 Demo',
      enableLogging: true,
    ),
    userParser: (json) => User.fromJson(json),
    // One store for everything, so logins survive app restarts: tokens
    // (namespaced per connection profile), profiles + active profile + device
    // id, and each profile's offline queue and response cache.
    // Pass tokenStorage / connectionStore / offlineQueueStore / cacheStore to
    // split them (e.g. SharedPreferences for the non-secret queue and cache).
    storage: _storage,
    // Echo is configured from the server handshake (`broadcasting` block).
    autoConfigureEcho: true,
    onSessionRevoked: (reason) =>
        debugPrint('Signed out remotely: ${reason ?? 'no reason'}'),
    onUpgradeRequired: (e) =>
        debugPrint('Update to ${e.minVersion} required: ${e.updateUrl}'),
    onCommand: (command) {
      if (command.type == BridgeCommandType.message) {
        _messengerKey.currentState?.showSnackBar(
          SnackBar(
              content:
                  Text(command.payload['title']?.toString() ?? 'New message')),
        );
      }
    },
  );

  runApp(const ExampleApp());
}

final _messengerKey = GlobalKey<ScaffoldMessengerState>();

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Laravel Flutter Bridge Demo',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messengerKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      // Offline / reconnecting / revoked / update-required banner above every route.
      builder: (context, child) => LaravelConnectionBanner(
        onUpdate: (e) => _messengerKey.currentState?.showSnackBar(
          SnackBar(
              content: Text('Open ${e.updateUrl ?? 'the store'} to update')),
        ),
        child: child ?? const SizedBox.shrink(),
      ),
      routes: {
        '/settings/connections': (_) => const LaravelConnectionManagerView(),
        '/settings/sessions': (_) => const LaravelSessionsView(),
      },
      home: const RootGate(),
    );
  }
}

class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    // Laravel.changes fires when the active connection changes: client, auth and
    // echo are new instances, so rebuild everything that captured the old ones.
    return StreamBuilder<void>(
      stream: Laravel.changes,
      builder: (context, _) {
        final auth = Laravel.auth<User>();
        return LaravelAuthBuilder<User>(
          key: ObjectKey(auth),
          authManager: auth,
          authenticated: (context, user) => DashboardScreen(user: user),
          unauthenticated: (context) => const LoginScreen(),
          loading: (context) => const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          ),
        );
      },
    );
  }
}

class SettingsButton extends StatelessWidget {
  const SettingsButton({super.key});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.settings_outlined),
      onSelected: (route) => Navigator.of(context).pushNamed(route),
      itemBuilder: (context) => [
        const PopupMenuItem(
            value: '/settings/connections', child: Text('Connections')),
        if (Laravel.auth<User>().isAuthenticated)
          const PopupMenuItem(
              value: '/settings/sessions', child: Text('Signed-in devices')),
      ],
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController(text: 'test@example.com');
  final _passwordController = TextEditingController(text: 'password');
  String? _emailError;
  String? _generalError;
  bool _isLoading = false;

  Future<void> _handleLogin() async {
    setState(() {
      _isLoading = true;
      _emailError = null;
      _generalError = null;
    });

    try {
      await Laravel.auth<User>().login(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        deviceName: 'Pixel 8 Demo',
      );
    } on LaravelValidationError catch (e) {
      setState(() {
        _emailError = e.first('email');
        _generalError = e.message;
      });
    } on LaravelException catch (e) {
      setState(() {
        _generalError = e.message;
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Laravel Fortify over the bridge: reset the password with the emailed code.
  Future<void> _forgotPassword() async {
    final auth = Laravel.auth<User>();
    final email = _emailController.text.trim();
    try {
      await auth.forgotPassword(email);
      if (!mounted) return;
      final code = await _prompt(context, 'Code sent to $email');
      if (code == null || !mounted) return;
      final resetToken =
          await auth.verifyPasswordResetCode(email: email, code: code);
      if (!mounted) return;
      final password = await _prompt(context, 'New password', obscure: true);
      if (password == null) return;
      await auth.resetPassword(
        email: email,
        password: password,
        passwordConfirmation: password,
        resetToken: resetToken,
      );
      setState(() => _generalError = 'Password changed. Sign in again.');
    } on LaravelCodeException catch (e) {
      setState(() => _generalError =
          e.needsNewCode ? '${e.message} Ask for a new code.' : e.message);
    } on LaravelException catch (e) {
      setState(() => _generalError = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Laravel Bridge Login'),
        actions: [
          LaravelConnectionIndicator(manager: Laravel.connections),
          const SettingsButton(),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_generalError != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.red.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_generalError!,
                    style: TextStyle(color: Colors.red.shade900)),
              ),
            TextField(
              controller: _emailController,
              decoration: InputDecoration(
                labelText: 'Email Address',
                errorText: _emailError,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _handleLogin,
                child: _isLoading
                    ? const CircularProgressIndicator()
                    : const Text('Sign In with Sanctum'),
              ),
            ),
            if (Laravel.fortify.resetPasswords)
              TextButton(
                onPressed: _isLoading ? null : _forgotPassword,
                child: const Text('Forgot password?'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Ask for one line of text (a code or a password); `null` when cancelled.
Future<String?> _prompt(BuildContext context, String title,
    {bool obscure = false}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
          controller: controller, obscureText: obscure, autofocus: true),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('OK')),
      ],
    ),
  );
}

class DashboardScreen extends StatelessWidget {
  final User user;

  const DashboardScreen({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Welcome, ${user.name}'),
        actions: [
          LaravelConnectionIndicator(manager: Laravel.connections),
          const SettingsButton(),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => Laravel.auth<User>().logout(),
          ),
        ],
      ),
      body: LaravelPaginatedListView<Post>(
        fetchPage: (page) => Laravel.client.paginate<Post>(
          '/api/posts',
          page: page,
          itemParser: (json) => Post.fromJson(json),
        ),
        separator: const Divider(height: 1),
        itemBuilder: (context, post, index) {
          return ListTile(
            title: Text(post.title),
            subtitle: Text(post.content),
          );
        },
        emptyBuilder: (context) => const Center(
          child: Text('No posts found. Create one on Laravel backend!'),
        ),
      ),
    );
  }
}
