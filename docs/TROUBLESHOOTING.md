# Troubleshooting & Common Pitfalls

A quick-reference guide to resolving common networking, authorization, and environment issues when bridging Flutter and Laravel.

---

## 1. Localhost & Networking Issues

### Issue: Flutter app on Android Emulator throws `Connection Refused` or `SocketException`
- **Cause**: Inside the Android Emulator, `localhost` (or `127.0.0.1`) refers to the simulated phone itself, not your host computer running Laravel!
- **Solution**:
  - Android Emulator: Use `http://10.0.2.2:8000`.
  - iOS Simulator: Can use `http://127.0.0.1:8000` or `http://localhost:8000`.
  - Physical Devices: Use your computer's local Wi-Fi IP address (e.g. `http://192.168.1.50:8000`), and run Laravel with `--host=0.0.0.0`:
    ```bash
    php artisan serve --host=0.0.0.0 --port=8000
    ```

---

## 2. CORS Errors in Flutter Web

### Issue: `XMLHttpRequest error` or `CORS policy: No 'Access-Control-Allow-Origin' header`
- **Cause**: Web browsers enforce Same-Origin Policy for HTTP requests and WebSocket handshakes.
- **Solution**: Update `config/cors.php` in Laravel:
  ```php
  return [
      'paths' => ['api/*', 'sanctum/csrf-cookie'],
      'allowed_methods' => ['*'],
      'allowed_origins' => ['*'],
      'allowed_headers' => ['*', 'X-Flutter-Platform', 'X-Flutter-App-Version', 'X-Flutter-Device-Id'],
      'exposed_headers' => ['X-Laravel-Flutter-Bridge'],
      'max_age' => 86400,
      'supports_credentials' => true,
  ];
  ```

---

## 3. Reverb / WebSocket Connection Drops

### Issue: `WebSocketChannelException: Connection refused` or ping timeouts
- **Check 1**: Is Reverb actually running?
  ```bash
  php artisan reverb:start --debug
  ```
- **Check 2**: Ensure Reverb host is bound to `0.0.0.0` in your `.env` so it listens to external connections:
  ```ini
  REVERB_HOST="0.0.0.0"
  REVERB_PORT=8080
  ```
- **Check 3**: On Android, if you are not using SSL (`http://` or `ws://`), ensure `android:usesCleartextTraffic="true"` is enabled in your `android/app/src/main/AndroidManifest.xml`:
  ```xml
  <application
      android:usesCleartextTraffic="true"
      ... >
  ```

---

## 4. Sanctum 401 Unauthorized Loop

### Issue: App keeps returning 401 even after logging in
- **Check 1**: Make sure `Bearer <token>` is present in outgoing headers. The bridge's `AuthInterceptor` attaches this automatically as long as the token is stored.
- **Check 2**: Ensure your `App\Models\User` has the `Laravel\Sanctum\HasApiTokens` trait.
- **Check 3**: If using custom route middleware, make sure routes are protected by `auth:sanctum` (not `auth:web` or `auth:api`).

---

## 5. Stale / Orphaned Device Tokens

### Issue: Push notifications fail with `UNREGISTERED` error from FCM
- **Cause**: User uninstalled the app or cleared app data without logging out.
- **Solution**: The `create_flutter_devices_table` migration records `last_active_at`. Set up a daily scheduled command in Laravel `routes/console.php` to prune inactive tokens:
  ```php
  use Atannex\LaravelFlutterBridge\Models\FlutterDevice;
  use Illuminate\Support\Facades\Schedule;

  Schedule::call(function () {
      FlutterDevice::where('last_active_at', '<', now()->subDays(90))->delete();
  })->daily();
  ```
