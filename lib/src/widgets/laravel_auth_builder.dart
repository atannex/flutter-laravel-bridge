import 'package:flutter/material.dart';
import '../auth/auth_manager.dart';
import '../auth/auth_state.dart';

/// Convenient widget that listens to [AuthManager] and rebuilds on authentication state changes.
class LaravelAuthBuilder<TUser> extends StatelessWidget {
  final AuthManager<TUser> authManager;
  final Widget Function(BuildContext context, TUser user)? authenticated;
  final Widget Function(BuildContext context)? unauthenticated;
  final Widget Function(BuildContext context)? loading;
  final Widget Function(BuildContext context, AuthError error)? error;
  final Widget Function(BuildContext context, AuthState state, TUser? user)?
      builder;

  const LaravelAuthBuilder({
    super.key,
    required this.authManager,
    this.authenticated,
    this.unauthenticated,
    this.loading,
    this.error,
    this.builder,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: authManager.stateStream,
      initialData: authManager.currentState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? const Unauthenticated();

        if (builder != null) {
          return builder!(context, state, authManager.currentUser);
        }

        switch (state) {
          case Authenticating():
          case RefreshingToken():
            return loading != null
                ? loading!(context)
                : const Center(child: CircularProgressIndicator());

          case Authenticated():
            return authenticated != null
                ? authenticated!(context, state.user as TUser)
                : const SizedBox.shrink();

          case AuthError():
            return error != null
                ? error!(context, state)
                : Center(child: Text('Error: ${state.message}'));

          case Unauthenticated():
            return unauthenticated != null
                ? unauthenticated!(context)
                : const SizedBox.shrink();
        }
      },
    );
  }
}
