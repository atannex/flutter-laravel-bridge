library flutter_laravel_bridge;

// Core Facade
export 'src/laravel.dart';

// Client & Options
export 'src/client/laravel_client.dart';
export 'src/client/laravel_options.dart';
export 'src/models/api_response.dart';

// Authentication
export 'src/auth/auth_manager.dart';
export 'src/auth/auth_state.dart';
export 'src/auth/token_storage.dart';

// HTTP interceptors
export 'src/client/interceptors/auth_interceptor.dart';
export 'src/client/interceptors/connection_interceptor.dart';
export 'src/client/interceptors/error_interceptor.dart';

// Exceptions
export 'src/exceptions/laravel_exception.dart';

// Connection management (profiles, sessions, commands)
export 'src/connection/bridge_command.dart';
export 'src/connection/bridge_endpoints.dart';
export 'src/connection/bridge_ids.dart' show BridgeIds, compareBridgeVersions;
export 'src/connection/bridge_version.dart';
export 'src/connection/connection_manager.dart';
export 'src/connection/connection_session.dart';
export 'src/connection/connection_state.dart';
export 'src/connection/connection_store.dart';
export 'src/connection/laravel_connection.dart';
export 'src/connection/server_info.dart';

// Pagination & Query
export 'src/pagination/paginated_response.dart';
export 'src/query/laravel_query.dart';

// Real-Time Echo, WebSockets & Real-Time Sync
export 'src/echo/laravel_echo.dart';
export 'src/echo/laravel_sse_client.dart';
export 'src/echo/echo_options.dart';
export 'src/echo/channel.dart';
export 'src/echo/private_channel.dart';
export 'src/echo/presence_channel.dart';
export 'src/sync/laravel_realtime_store.dart';

// Device & Push Notifications
export 'src/device/device_manager.dart';

// Persistent storage
export 'src/storage/key_value_store.dart';

// Offline Queue & Cache
export 'src/offline/offline_queue.dart';
export 'src/offline/mutation_record.dart';
export 'src/cache/cache_policy.dart';

// File Upload
export 'src/upload/laravel_uploader.dart';

// UI Widgets
export 'src/widgets/laravel_auth_builder.dart';
export 'src/widgets/laravel_realtime_builder.dart';
export 'src/widgets/laravel_paginated_list_view.dart';
export 'src/widgets/laravel_presence_builder.dart';
export 'src/widgets/laravel_whisper_builder.dart';
export 'src/widgets/laravel_connection_indicator.dart';
export 'src/widgets/laravel_connection_builder.dart';
export 'src/widgets/laravel_connection_banner.dart';
export 'src/widgets/laravel_connection_manager_view.dart';
export 'src/widgets/laravel_sessions_view.dart';
