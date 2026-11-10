import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_bridge_server.dart';

const _profile = LaravelConnection(
  id: 'alpha',
  name: 'Alpha',
  baseUrl: 'https://alpha.test',
  appKey: 'fba_test',
);

/// A connection manager wired to one [FakeBridgeServer] with a movable clock
/// and an offline user cache.
class _Harness {
  final FakeBridgeServer server;
  final InMemoryKeyValueStore users;
  final LaravelConnectionManager manager;
  final _Clock clock;

  _Harness(this.server, this.users, this.manager, this.clock);

  static Future<_Harness> create({
    void Function(FakeBridgeServer server)? configure,
    bool connect = true,
  }) async {
    final server = FakeBridgeServer(name: 'Alpha');
    configure?.call(server);
    final users = InMemoryKeyValueStore();
    final clock = _Clock(DateTime(2026, 11, 10, 9));
    final manager = LaravelConnectionManager(
      options: const LaravelOptions(
        baseUrl: 'https://unused.test',
        appVersion: '1.0.0',
        platform: 'android',
        deviceId: 'device-1',
        enableLogging: false,
      ),
      store: InMemoryConnectionStore(connections: const [_profile]),
      tokenStorage: InMemoryTokenStorage(),
      userStore: users,
      httpClientAdapterFactory: (_) => server,
      enableTimers: false,
      random: Random(1),
      clock: clock.call,
    );
    await manager.load();
    if (connect) await manager.connect();
    return _Harness(server, users, manager, clock);
  }

  AuthManager<dynamic> get auth => manager.auth!;

  Future<void> login([String email = 'a@example.com']) =>
      auth.login(email: email, password: 'secret');

  /// Move server and client time together.
  void advance(Duration duration) {
    server.advance(duration);
    clock.now = clock.now.add(duration);
  }

  Map<String, dynamic>? get cachedUser {
    final raw =
        users.values[LaravelConnectionManager.userStorageKeyFor(_profile.id)];
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  int get requestCount => server.requests.length;

  Future<void> dispose() => manager.dispose();
}

class _Clock {
  DateTime now;
  _Clock(this.now);
  DateTime call() => now;
}

Future<T> _throws<T extends Object>(Future<Object?> Function() action) async {
  try {
    await action();
  } catch (e) {
    if (e is T) return e;
    fail('Expected $T, got ${e.runtimeType}: $e');
  }
  fail('Expected $T, nothing was thrown');
}

LaravelException _translate(int status, Map<String, dynamic> body) {
  final options = RequestOptions(path: 'api/flutter/x');
  return ErrorInterceptor.translate(DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response:
        Response<dynamic>(requestOptions: options, statusCode: status, data: {
      'success': false,
      'data': null,
      ...body,
    }),
  ));
}

void main() {
  group('Feature discovery', () {
    test('handshake features.fortify is parsed and exposed everywhere',
        () async {
      final h = await _Harness.create(configure: (s) {
        s.fortify['passkeys'] = false;
        s.fortify['password_timeout'] = 900;
        s.fortify['codes'] = {'length': 8, 'ttl': 300};
        s.fortify['future_flag'] = true;
      });
      addTearDown(h.dispose);

      final f = h.manager.fortify;
      expect(f.advertised, isTrue);
      expect(f.installed, isTrue);
      expect(f.registration, isTrue);
      expect(f.resetPasswords, isTrue);
      expect(f.emailVerification, isTrue);
      expect(f.updateProfileInformation, isTrue);
      expect(f.updatePasswords, isTrue);
      expect(f.twoFactorAuthentication, isTrue);
      expect(f.twoFactorConfirm, isTrue);
      expect(f.twoFactorConfirmPassword, isTrue);
      expect(f.passkeys, isFalse);
      expect(f.username, 'email');
      expect(f.passwordMin, 8);
      expect(f.passwordTimeout, const Duration(minutes: 15));
      expect(f.codes.length, 8);
      expect(f.codes.ttl, const Duration(minutes: 5));
      expect(f.enabled, isTrue);
      expect(f.passkeysConfirmPassword, isTrue);
      expect(f.lowercaseUsernames, isFalse);
      expect(f.resetChannel, 'code');
      expect(f.has('future_flag'), isTrue);
      expect(f.has('unknown'), isFalse);

      expect(h.manager.serverInfo!.fortify.passkeys, isFalse);
      expect(h.manager.serverInfo!.features.fortify.installed, isTrue);
      expect(h.auth.fortify.passwordTimeout, const Duration(minutes: 15));
    });

    test('a server without features.fortify gets safe defaults', () async {
      final h = await _Harness.create(configure: (s) {
        s.advertiseFortify = false;
      });
      addTearDown(h.dispose);

      final f = h.auth.fortify;
      expect(f.advertised, isFalse);
      expect(f.installed, isFalse);
      expect(f.registration, isTrue, reason: 'mirrors features.registration');
      expect(f.resetPasswords, isFalse);
      expect(f.emailVerification, isFalse);
      expect(f.updateProfileInformation, isFalse);
      expect(f.updatePasswords, isFalse);
      expect(f.twoFactorAuthentication, isFalse);
      expect(f.passkeys, isFalse);
      expect(f.passwordTimeout, const Duration(seconds: 10800));
      expect(f.codes.length, 6);

      // Not advertised → nothing is blocked locally, the request goes out.
      final before = h.requestCount;
      await h.auth.forgotPassword('a@example.com');
      expect(h.requestCount, before + 1);
    });

    test('defaults before any handshake and without a manager', () {
      const info = ServerInfo();
      expect(info.fortify.advertised, isFalse);
      expect(
          const FortifyFeatures.unavailable(registration: false).registration,
          isFalse);
      final parsed = ServerFeatures.fromJson({'registration': false});
      expect(parsed.fortify.advertised, isFalse);
      expect(parsed.fortify.registration, isFalse);
      expect(FortifyFeatures.fromJson(null).advertised, isFalse);
    });

    test('tolerates string / int flags and round-trips through toJson', () {
      final info = ServerInfo.fromJson({
        'features': {
          'registration': true,
          'fortify': {
            'installed': '1',
            'reset_passwords': 'true',
            'passkeys': 0,
            'password_timeout': '600',
          },
        },
      });
      expect(info.fortify.installed, isTrue);
      expect(info.fortify.resetPasswords, isTrue);
      expect(info.fortify.passkeys, isFalse);
      expect(info.fortify.passwordTimeout, const Duration(minutes: 10));

      final again = ServerInfo.fromJson(info.toJson());
      expect(again.fortify.advertised, isTrue);
      expect(again.fortify.resetPasswords, isTrue);
      expect(again.fortify.passwordTimeout, const Duration(minutes: 10));
      expect(
          ServerInfo.fromJson(const ServerInfo().toJson()).fortify.advertised,
          isFalse);
    });

    test('refreshFortifyFeatures reads GET config (plain client)', () async {
      final server = FakeBridgeServer()..fortify['passkeys'] = false;
      final client = LaravelClient(
        options: const LaravelOptions(
            baseUrl: 'https://alpha.test', enableLogging: false),
      )..rawDio.httpClientAdapter = server;
      final auth = AuthManager<Map<String, dynamic>>(
        client: client,
        userParser: (j) => j,
        proactiveRefresh: false,
      );
      addTearDown(auth.dispose);

      expect(auth.fortify.advertised, isFalse);
      final features = await auth.refreshFortifyFeatures();
      expect(server.requests.last.path, 'api/flutter/config');
      expect(features.advertised, isTrue);
      expect(auth.fortify.passkeys, isFalse);
      await _throws<LaravelFeatureDisabledException>(
          () => auth.passkeys.list());

      auth.fortify = null;
      expect(auth.fortify.advertised, isFalse);
    });
  });

  group('Forgot / reset password', () {
    late _Harness h;
    setUp(() async => h = await _Harness.create());
    tearDown(() => h.dispose());

    test('forgotPassword emails a code without revealing the account',
        () async {
      final request = await h.auth.forgotPassword('a@example.com');
      expect(request.sent, isTrue);
      expect(request.channel, 'code');
      expect(request.usesCode, isTrue);
      expect(request.expiresIn, const Duration(minutes: 10));
      expect(h.server.lastCode('a@example.com'), isNotNull);
      expect(h.server.lastCode('a@example.com')!.length, 6);
      final sent = h.server.requestsTo('auth/forgot-password').single;
      expect(sent.header('Authorization'), isNull);
      expect(sent.body, {'email': 'a@example.com'});

      final unknown = await h.auth.forgotPassword('nobody@example.com');
      expect(unknown.sent, isTrue);
      expect(h.server.lastCode('nobody@example.com'), isNull);
    });

    test('code → reset token → new password; every token revoked', () async {
      await h.login();
      expect(h.server.accessTokens.containsValue(1), isTrue);

      await h.auth.forgotPassword('a@example.com');
      final token = await h.auth.verifyPasswordResetCode(
          email: 'a@example.com', code: h.server.lastCode('a@example.com')!);
      expect(token, isNotEmpty);

      await h.auth.resetPassword(
        email: 'a@example.com',
        password: 'new-password',
        passwordConfirmation: 'new-password',
        resetToken: token,
      );
      final body = h.server.requestsTo('auth/reset-password').single.body;
      expect(body, {
        'email': 'a@example.com',
        'password': 'new-password',
        'password_confirmation': 'new-password',
        'reset_token': token,
      });
      expect(h.server.users['a@example.com']!['password'], 'new-password');
      expect(h.server.accessTokens.containsValue(1), isFalse);

      // This device's connection was revoked with the rest: the next request
      // signs it out.
      await _throws<LaravelConnectionRevokedException>(
          () => h.auth.fetchUserProfile());
      await Future<void>.delayed(Duration.zero);
      expect(h.auth.isAuthenticated, isFalse);
    });

    test('a reset token is single use', () async {
      await h.auth.forgotPassword('a@example.com');
      final token = await h.auth.verifyPasswordResetCode(
          email: 'a@example.com', code: h.server.lastCode('a@example.com')!);
      await h.auth.resetPassword(
          email: 'a@example.com',
          password: 'new-password',
          passwordConfirmation: 'new-password',
          resetToken: token);
      final reused = await _throws<LaravelCodeException>(() => h.auth
          .resetPassword(
              email: 'a@example.com',
              password: 'another-one',
              passwordConfirmation: 'another-one',
              resetToken: token));
      expect(reused.kind, LaravelCodeErrorKind.invalid);
      expect(reused.isResetToken, isTrue);
      expect(reused.errorCode, LaravelErrorCode.resetTokenInvalid);
      expect(reused.statusCode, 422);
      expect(h.server.users['a@example.com']!['password'], 'new-password');
    });

    test('a Fortify broker token from the email link works too', () async {
      h.server.brokerTokens['broker-abc'] = 'a@example.com';
      await h.auth.resetPassword(
        email: 'a@example.com',
        password: 'from-the-link',
        passwordConfirmation: 'from-the-link',
        token: 'broker-abc',
      );
      expect(h.server.requestsTo('auth/reset-password').single.body['token'],
          'broker-abc');
      expect(h.server.users['a@example.com']!['password'], 'from-the-link');
    });

    test('resetPassword needs a token (no request otherwise)', () async {
      final before = h.requestCount;
      expect(
        () => h.auth.resetPassword(
            email: 'a@example.com', password: 'x', passwordConfirmation: 'x'),
        throwsArgumentError,
      );
      expect(h.requestCount, before);
    });

    test('password rules come back as a plain validation error', () async {
      await h.auth.forgotPassword('a@example.com');
      final token = await h.auth.verifyPasswordResetCode(
          email: 'a@example.com', code: h.server.lastCode('a@example.com')!);
      final error = await _throws<LaravelValidationError>(() => h.auth
          .resetPassword(
              email: 'a@example.com',
              password: 'short',
              passwordConfirmation: 'short',
              resetToken: token));
      expect(error, isNot(isA<LaravelCodeException>()));
      expect(error.has('password'), isTrue);
    });

    test('wrong code → LaravelCodeException(invalid)', () async {
      await h.auth.forgotPassword('a@example.com');
      final error = await _throws<LaravelCodeException>(() => h.auth
          .verifyPasswordResetCode(email: 'a@example.com', code: '000000'));
      expect(error, isA<LaravelValidationError>());
      expect(error.kind, LaravelCodeErrorKind.invalid);
      expect(error.isInvalid, isTrue);
      expect(error.needsNewCode, isFalse);
      expect(error.statusCode, 422);
      expect(error.errorCode, LaravelErrorCode.codeInvalid);
      expect(error.first('code'), 'The code is invalid.');
    });

    test('expired code → LaravelCodeException(expired)', () async {
      await h.auth.forgotPassword('a@example.com');
      final code = h.server.lastCode('a@example.com')!;
      h.advance(const Duration(minutes: 10, seconds: 1));
      final error = await _throws<LaravelCodeException>(() =>
          h.auth.verifyPasswordResetCode(email: 'a@example.com', code: code));
      expect(error.kind, LaravelCodeErrorKind.expired);
      expect(error.isExpired, isTrue);
      expect(error.needsNewCode, isTrue);
      expect(error.errorCode, LaravelErrorCode.codeExpired);
    });

    test('five wrong attempts lock the code, even the right one', () async {
      await h.auth.forgotPassword('a@example.com');
      final code = h.server.lastCode('a@example.com')!;
      for (var i = 0; i < 5; i++) {
        final e = await _throws<LaravelCodeException>(() => h.auth
            .verifyPasswordResetCode(email: 'a@example.com', code: '999999'));
        expect(e.kind, LaravelCodeErrorKind.invalid);
      }
      final locked = await _throws<LaravelCodeException>(() =>
          h.auth.verifyPasswordResetCode(email: 'a@example.com', code: code));
      expect(locked.kind, LaravelCodeErrorKind.locked);
      expect(locked.isLocked, isTrue);
      expect(locked.statusCode, 423);
      expect(locked.errorCode, LaravelErrorCode.codeLocked);

      // A fresh code works again.
      await h.auth.forgotPassword('a@example.com');
      expect(
          await h.auth.verifyPasswordResetCode(
              email: 'a@example.com',
              code: h.server.lastCode('a@example.com')!),
          isNotEmpty);
    });

    test('codes are single use', () async {
      await h.auth.forgotPassword('a@example.com');
      final code = h.server.lastCode('a@example.com')!;
      await h.auth.verifyPasswordResetCode(email: 'a@example.com', code: code);
      final again = await _throws<LaravelCodeException>(() =>
          h.auth.verifyPasswordResetCode(email: 'a@example.com', code: code));
      expect(again.kind, LaravelCodeErrorKind.invalid);
    });

    test('forgotPassword is rate limited', () async {
      h.server.forgotPasswordLimit = 2;
      await h.auth.forgotPassword('a@example.com');
      await h.auth.forgotPassword('a@example.com');
      await _throws<LaravelRateLimitException>(
          () => h.auth.forgotPassword('a@example.com'));
    });
  });

  group('Email verification', () {
    late _Harness h;
    setUp(() async {
      h = await _Harness.create();
      await h.login('b@example.com');
    });
    tearDown(() => h.dispose());

    test('verifyEmail refreshes the user, the cache and the state', () async {
      expect((h.auth.currentUser as Map)['email_verified'], isFalse);
      expect(h.cachedUser!['email_verified'], isFalse);

      await h.auth.sendEmailVerification();
      final sent =
          h.server.requestsTo('auth/email/verification-notification').single;
      expect(sent.header('Authorization'), startsWith('Bearer '));
      final code = h.server.lastCode('b@example.com', 'verify')!;

      final states = <AuthState>[];
      final sub = h.auth.stateStream.listen(states.add);
      final user = await h.auth.verifyEmail(code) as Map;
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(user['email_verified'], isTrue);
      expect(user['email_verified_at'], isNotNull);
      expect((h.auth.currentUser as Map)['email_verified'], isTrue);
      expect(h.cachedUser!['email_verified'], isTrue);
      final last = states.last as Authenticated;
      expect((last.user as Map)['email_verified'], isTrue);
      expect(last.accessToken, isNotEmpty);

      // Already verified now.
      await _throws<LaravelAlreadyVerifiedException>(
          () => h.auth.sendEmailVerification());
    });

    test('already verified → LaravelAlreadyVerifiedException (409)', () async {
      await h.auth.logout();
      await h.login('a@example.com');
      final error = await _throws<LaravelAlreadyVerifiedException>(
          () => h.auth.sendEmailVerification());
      expect(error.statusCode, 409);
      expect(error.errorCode, LaravelErrorCode.alreadyVerified);
    });

    test('wrong / expired / locked verification codes', () async {
      await h.auth.sendEmailVerification();
      final code = h.server.lastCode('b@example.com', 'verify')!;
      final wrong = await _throws<LaravelCodeException>(
          () => h.auth.verifyEmail('111111'));
      expect(wrong.kind, LaravelCodeErrorKind.invalid);
      expect((h.auth.currentUser as Map)['email_verified'], isFalse);

      h.advance(const Duration(minutes: 11));
      final expired =
          await _throws<LaravelCodeException>(() => h.auth.verifyEmail(code));
      expect(expired.kind, LaravelCodeErrorKind.expired);

      await h.auth.sendEmailVerification();
      for (var i = 0; i < 5; i++) {
        await _throws<LaravelCodeException>(() => h.auth.verifyEmail('1'));
      }
      final locked = await _throws<LaravelCodeException>(() =>
          h.auth.verifyEmail(h.server.lastCode('b@example.com', 'verify')!));
      expect(locked.kind, LaravelCodeErrorKind.locked);
    });
  });

  group('Profile and password', () {
    late _Harness h;
    setUp(() async {
      h = await _Harness.create();
      await h.login();
    });
    tearDown(() => h.dispose());

    test('updateProfile updates the current user, cache and state', () async {
      final states = <AuthState>[];
      final sub = h.auth.stateStream.listen(states.add);
      final user = await h.auth
          .updateProfile({'name': 'Alice B.', 'email': 'a@example.com'}) as Map;
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      final sent = h.server.requestsTo('auth/user/profile-information').single;
      expect(sent.method, 'PUT');
      expect(sent.body, {'name': 'Alice B.', 'email': 'a@example.com'});
      expect(user['name'], 'Alice B.');
      expect((h.auth.currentUser as Map)['name'], 'Alice B.');
      expect(h.cachedUser!['name'], 'Alice B.');
      expect(
          ((states.single as Authenticated).user as Map)['name'], 'Alice B.');
    });

    test('changing the email clears its verification', () async {
      final user = await h.auth
          .updateProfile({'name': 'Alice', 'email': 'alice@new.test'}) as Map;
      expect(user['email'], 'alice@new.test');
      expect(user['email_verified'], isFalse);
      expect(h.cachedUser!['email'], 'alice@new.test');
    });

    test('profile validation errors', () async {
      final error = await _throws<LaravelValidationError>(() =>
          h.auth.updateProfile({'name': 'Alice', 'email': 'b@example.com'}));
      expect(error.first('email'), 'The email has already been taken.');
      expect((h.auth.currentUser as Map)['email'], 'a@example.com');
    });

    test('updatePassword checks the current password', () async {
      final error = await _throws<LaravelValidationError>(() => h.auth
          .updatePassword(
              currentPassword: 'wrong',
              password: 'brand-new-pass',
              passwordConfirmation: 'brand-new-pass'));
      expect(error.has('current_password'), isTrue);
    });

    test('updatePassword (optionally signing out other devices)', () async {
      // A second device of the same user.
      final other = AuthManager<Map<String, dynamic>>(
        client: LaravelClient(
          options: const LaravelOptions(
              baseUrl: 'https://alpha.test', enableLogging: false),
        )..rawDio.httpClientAdapter = h.server,
        userParser: (j) => j,
        proactiveRefresh: false,
      );
      addTearDown(other.dispose);
      await other.login(email: 'a@example.com', password: 'secret');
      final otherToken = await other.tokenStorage.getAccessToken();
      final ownToken = await h.auth.tokenStorage.getAccessToken();

      await h.auth.updatePassword(
        currentPassword: 'secret',
        password: 'brand-new-pass',
        passwordConfirmation: 'brand-new-pass',
        revokeOtherSessions: true,
      );
      final sent = h.server.requestsTo('auth/user/password').single;
      expect(sent.method, 'PUT');
      expect(sent.body, {
        'current_password': 'secret',
        'password': 'brand-new-pass',
        'password_confirmation': 'brand-new-pass',
        'revoke_other_sessions': true,
      });
      expect(h.server.users['a@example.com']!['password'], 'brand-new-pass');
      expect(h.server.accessTokens.containsKey(otherToken), isFalse);
      expect(h.server.accessTokens.containsKey(ownToken), isTrue);
      expect(await h.auth.fetchUserProfile(), isNotNull);
    });

    test('updatePassword without revoking keeps the other devices', () async {
      await h.auth.updatePassword(
        currentPassword: 'secret',
        password: 'brand-new-pass',
        passwordConfirmation: 'brand-new-pass',
      );
      expect(
          h.server.requestsTo('auth/user/password').single.body
              as Map<String, dynamic>,
          isNot(contains('revoke_other_sessions')));
    });
  });

  group('Password confirmation', () {
    late _Harness h;
    setUp(() async {
      h = await _Harness.create();
      await h.login();
    });
    tearDown(() => h.dispose());

    test('wrong password → validation error password_invalid', () async {
      final error = await _throws<LaravelValidationError>(
          () => h.auth.confirmPassword('nope'));
      expect(error.errorCode, LaravelErrorCode.passwordInvalid);
      expect(error.has('password'), isTrue);
      expect(h.auth.isPasswordConfirmed, isFalse);
    });

    test('confirmPassword opens a window; isConfirmed judges it locally',
        () async {
      final start = h.clock.now;
      final confirmation = await h.auth.confirmPassword('secret');
      expect(confirmation.confirmed, isTrue);
      expect(confirmation.expiresIn, const Duration(hours: 3));
      expect(confirmation.confirmedAt, start);
      expect(confirmation.expiresAt, start.add(const Duration(hours: 3)));
      expect(confirmation.isConfirmed(start), isTrue);
      expect(confirmation.isConfirmed(start.add(const Duration(hours: 3))),
          isFalse);
      expect(h.auth.passwordConfirmation, same(confirmation));
      expect(h.auth.isPasswordConfirmed, isTrue);

      h.advance(const Duration(hours: 3));
      expect(h.auth.isPasswordConfirmed, isFalse);
    });

    test('confirmedPasswordStatus reports the remaining window', () async {
      final before = await h.auth.confirmedPasswordStatus();
      expect(before.confirmed, isFalse);
      expect(before.isConfirmed(), isFalse);
      expect(before.confirmedAt, isNull);

      final start = h.clock.now;
      await h.auth.confirmPassword('secret');
      h.advance(const Duration(hours: 1));
      final status = await h.auth.confirmedPasswordStatus();
      expect(status.confirmed, isTrue);
      expect(status.expiresIn, const Duration(hours: 2));
      expect(status.confirmedAt, start);
      expect(status.isConfirmed(h.clock.now), isTrue);

      h.advance(const Duration(hours: 2));
      final lapsed = await h.auth.confirmedPasswordStatus();
      expect(lapsed.confirmed, isFalse);
    });

    test('signing out forgets the confirmation', () async {
      await h.auth.confirmPassword('secret');
      await h.auth.logout();
      expect(h.auth.passwordConfirmation, isNull);
    });
  });

  group('runWithPasswordConfirmation', () {
    late _Harness h;
    setUp(() async {
      h = await _Harness.create();
      await h.login();
    });
    tearDown(() => h.dispose());

    test('asks once, confirms and retries', () async {
      var asked = 0;
      final codes = await h.auth.runWithPasswordConfirmation(
        () => h.auth.twoFactor.enable(),
        () async {
          asked++;
          return 'secret';
        },
      );
      expect(codes.enabled, isTrue);
      expect(asked, 1);
      expect(h.server.requestsTo('auth/user/confirm-password'), hasLength(1));
      expect(
          h.server.requestsTo('auth/user/two-factor-authentication',
              method: 'POST'),
          hasLength(2));
      expect(h.auth.isPasswordConfirmed, isTrue);
    });

    test('does not ask when no confirmation is needed', () async {
      await h.auth.confirmPassword('secret');
      var asked = 0;
      await h.auth.runWithPasswordConfirmation(() => h.auth.twoFactor.enable(),
          () async {
        asked++;
        return 'secret';
      });
      expect(asked, 0);
    });

    test('a cancelled prompt rethrows the 423', () async {
      final error = await _throws<LaravelPasswordConfirmationRequiredException>(
          () => h.auth.runWithPasswordConfirmation(
              () => h.auth.twoFactor.enable(), () async => null));
      expect(error.statusCode, 423);
      expect(h.server.requestsTo('auth/user/confirm-password'), isEmpty);
    });

    test('a wrong password fails without retrying', () async {
      final error = await _throws<LaravelValidationError>(() => h.auth
          .runWithPasswordConfirmation(
              () => h.auth.twoFactor.enable(), () async => 'wrong'));
      expect(error.errorCode, LaravelErrorCode.passwordInvalid);
      expect(
          h.server.requestsTo('auth/user/two-factor-authentication',
              method: 'POST'),
          hasLength(1));
    });

    test('other errors pass through untouched', () async {
      var asked = 0;
      await _throws<LaravelNotFoundException>(() => h.auth
              .runWithPasswordConfirmation(() => h.auth.twoFactor.qrCode(),
                  () async {
            asked++;
            return 'secret';
          }));
      expect(asked, 0);
    });
  });

  group('Two-factor management', () {
    late _Harness h;
    setUp(() async {
      h = await _Harness.create();
      await h.login();
    });
    tearDown(() => h.dispose());

    test('needs a recent password confirmation', () async {
      final error = await _throws<LaravelPasswordConfirmationRequiredException>(
          () => h.auth.twoFactor.enable());
      expect(error.statusCode, 423);
      expect(error.errorCode, LaravelErrorCode.passwordConfirmationRequired);
      await _throws<LaravelPasswordConfirmationRequiredException>(
          () => h.auth.twoFactor.disable());
      await _throws<LaravelPasswordConfirmationRequiredException>(
          () => h.auth.twoFactor.regenerateRecoveryCodes());
    });

    test('QR code before enabling → two_factor_not_enabled', () async {
      final error = await _throws<LaravelNotFoundException>(
          () => h.auth.twoFactor.qrCode());
      expect(error, isNot(isA<LaravelFeatureDisabledException>()));
      expect(error.errorCode, LaravelErrorCode.twoFactorNotEnabled);
      await _throws<LaravelNotFoundException>(
          () => h.auth.twoFactor.secretKey());
    });

    test('enable → QR → confirm → recovery codes → sign-in → disable',
        () async {
      await h.auth.confirmPassword('secret');

      final status = await h.auth.twoFactor.enable();
      expect(status.enabled, isTrue);
      expect(status.confirmed, isFalse);
      expect(status.requiresConfirmation, isTrue);
      expect(status.needsConfirmation, isTrue);
      var user = h.auth.currentUser as Map;
      expect(user['two_factor_enabled'], isFalse);
      expect(user['two_factor_pending_confirmation'], isTrue);
      expect(h.cachedUser!['two_factor_pending_confirmation'], isTrue);

      final qr = await h.auth.twoFactor.qrCode();
      expect(qr.svg, startsWith('<svg'));
      expect(qr.url, startsWith('otpauth://totp/'));
      expect(qr.url, contains('secret=JBSWY3DPEHPK3PXP'));
      expect(await h.auth.twoFactor.secretKey(), 'JBSWY3DPEHPK3PXP');

      final wrong = await _throws<LaravelTwoFactorRequiredException>(
          () => h.auth.twoFactor.confirm('000000'));
      expect(wrong.invalid, isTrue);
      expect(wrong.first('code'), isNotNull);

      final states = <AuthState>[];
      final sub = h.auth.stateStream.listen(states.add);
      user = await h.auth.twoFactor.confirm('123456') as Map;
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(user['two_factor_enabled'], isTrue);
      expect(user['two_factor_pending_confirmation'], isFalse);
      expect((h.auth.currentUser as Map)['two_factor_enabled'], isTrue);
      expect(h.cachedUser!['two_factor_enabled'], isTrue);
      expect(((states.last as Authenticated).user as Map)['two_factor_enabled'],
          isTrue);

      final codes = await h.auth.twoFactor.recoveryCodes();
      expect(codes, hasLength(8));
      final fresh = await h.auth.twoFactor.regenerateRecoveryCodes();
      expect(fresh, hasLength(8));
      expect(fresh, isNot(equals(codes)));
      expect(await h.auth.twoFactor.recoveryCodes(), fresh);

      // Signing in now needs a code; a recovery code works once.
      await h.auth.logout();
      await _throws<LaravelTwoFactorRequiredException>(() => h.login());
      await h.auth.login(
          email: 'a@example.com', password: 'secret', recoveryCode: fresh[0]);
      await h.auth.logout();
      final reused = await _throws<LaravelTwoFactorRequiredException>(() =>
          h.auth.login(
              email: 'a@example.com',
              password: 'secret',
              recoveryCode: fresh[0]));
      expect(reused.invalid, isTrue);
      await h.auth
          .login(email: 'a@example.com', password: 'secret', code: '123456');

      // New token: confirm again, then disable.
      await h.auth.confirmPassword('secret');
      await h.auth.twoFactor.disable();
      expect((h.auth.currentUser as Map)['two_factor_enabled'], isFalse);
      expect(h.cachedUser!['two_factor_enabled'], isFalse);
      await h.auth.logout();
      await h.login();
      expect(h.auth.isAuthenticated, isTrue);
    });

    test('the confirmation window lapses after password_timeout', () async {
      await h.auth.confirmPassword('secret');
      await h.auth.twoFactor.enable();
      await h.auth.twoFactor.confirm('123456');
      expect(await h.auth.twoFactor.recoveryCodes(), hasLength(8));

      h.advance(const Duration(hours: 3, seconds: 1));
      await _throws<LaravelPasswordConfirmationRequiredException>(
          () => h.auth.twoFactor.recoveryCodes());
      expect(h.auth.passwordConfirmation, isNull);
      expect(h.auth.isPasswordConfirmed, isFalse);
    });

    test('without two_factor_confirm / confirm_password', () async {
      await h.dispose();
      h = await _Harness.create(configure: (s) {
        s.fortify['two_factor_confirm'] = false;
        s.fortify['two_factor_confirm_password'] = false;
      });
      await h.login();
      expect(h.auth.fortify.twoFactorConfirm, isFalse);
      final status = await h.auth.twoFactor.enable();
      expect(status.confirmed, isTrue);
      expect(status.requiresConfirmation, isFalse);
      expect(status.needsConfirmation, isFalse);
      expect((h.auth.currentUser as Map)['two_factor_enabled'], isTrue);
      await h.auth.twoFactor.disable();
      expect(h.server.requestsTo('auth/user/confirm-password'), isEmpty);
    });
  });

  group('Passkeys', () {
    late _Harness h;
    setUp(() async {
      h = await _Harness.create();
      await h.login();
    });
    tearDown(() => h.dispose());

    test('list parses passkeys', () async {
      final passkeys = await h.auth.passkeys.list();
      expect(passkeys, hasLength(2));
      expect(passkeys[0].id, 'pk-1');
      expect(passkeys[0].name, 'MacBook');
      expect(passkeys[0].createdAt, DateTime.utc(2026, 5, 1, 8));
      expect(passkeys[0].lastUsedAt, DateTime.utc(2026, 11, 1, 8));
      expect(passkeys[1].lastUsedAt, isNull);
      expect(passkeys[1].toJson()['name'], 'iPhone');
      expect((h.auth.currentUser as Map)['passkeys_count'], 2);
    });

    test('rename returns the updated passkey', () async {
      final renamed = await h.auth.passkeys.rename('pk-2', 'Work phone');
      expect(renamed.id, 'pk-2');
      expect(renamed.name, 'Work phone');
      final sent = h.server.requestsTo('auth/user/passkeys/pk-2').single;
      expect(sent.method, 'PATCH');
      expect(sent.body, {'name': 'Work phone'});
      expect((await h.auth.passkeys.list())[1].name, 'Work phone');
    });

    test('delete needs a password confirmation', () async {
      await _throws<LaravelPasswordConfirmationRequiredException>(
          () => h.auth.passkeys.delete('pk-1'));
      await h.auth.runWithPasswordConfirmation(
          () => h.auth.passkeys.delete('pk-1'), () async => 'secret');
      final left = await h.auth.passkeys.list();
      expect(left.map((p) => p.id), ['pk-2']);
    });

    test('passkeys_confirm_password off → delete without confirming', () async {
      h.server.fortify['passkeys_confirm_password'] = false;
      await h.auth.passkeys.delete('pk-2');
      expect((await h.auth.passkeys.list()).single.id, 'pk-1');
    });

    test('unknown passkey → LaravelNotFoundException', () async {
      await _throws<LaravelNotFoundException>(
          () => h.auth.passkeys.rename('missing', 'x'));
    });
  });

  group('Feature gating', () {
    test('disabled features throw locally without a request', () async {
      final h = await _Harness.create(configure: (s) {
        for (final key in [
          'registration',
          'reset_passwords',
          'email_verification',
          'update_profile_information',
          'update_passwords',
          'two_factor_authentication',
          'passkeys',
        ]) {
          s.fortify[key] = false;
        }
      });
      addTearDown(h.dispose);
      await h.login();
      final auth = h.auth;

      final calls = <String, Future<Object?> Function()>{
        'registration': () => auth.register(
            name: 'C', email: 'c@example.com', password: 'secret-pass'),
        'reset_passwords': () => auth.forgotPassword('a@example.com'),
        'reset_passwords ': () =>
            auth.verifyPasswordResetCode(email: 'a@example.com', code: '1'),
        'reset_passwords  ': () => auth.resetPassword(
            email: 'a@example.com',
            password: 'p',
            passwordConfirmation: 'p',
            resetToken: 't'),
        'email_verification': () => auth.sendEmailVerification(),
        'email_verification ': () => auth.verifyEmail('123456'),
        'update_profile_information': () => auth.updateProfile({'name': 'x'}),
        'update_passwords': () => auth.updatePassword(
            currentPassword: 'secret',
            password: 'p',
            passwordConfirmation: 'p'),
        'two_factor_authentication': () => auth.twoFactor.enable(),
        'two_factor_authentication ': () => auth.twoFactor.qrCode(),
        'two_factor_authentication  ': () => auth.twoFactor.secretKey(),
        'two_factor_authentication   ': () => auth.twoFactor.confirm('1'),
        'two_factor_authentication    ': () => auth.twoFactor.recoveryCodes(),
        'two_factor_authentication     ': () =>
            auth.twoFactor.regenerateRecoveryCodes(),
        'two_factor_authentication      ': () => auth.twoFactor.disable(),
        'passkeys': () => auth.passkeys.list(),
        'passkeys ': () => auth.passkeys.rename('pk-1', 'x'),
        'passkeys  ': () => auth.passkeys.delete('pk-1'),
      };

      final before = h.requestCount;
      for (final entry in calls.entries) {
        final error =
            await _throws<LaravelFeatureDisabledException>(entry.value);
        expect(error.feature, entry.key.trim(), reason: entry.key);
        expect(error.errorCode, LaravelErrorCode.featureDisabled);
        expect(error.statusCode, 404);
        expect(error, isA<LaravelNotFoundException>());
      }
      expect(h.requestCount, before, reason: 'nothing was sent');

      // Password confirmation is not a toggleable feature.
      expect((await auth.confirmPassword('secret')).confirmed, isTrue);
    });

    test('server-side feature_disabled maps to the same exception', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      await h.login();
      // The server switched passkeys off after the handshake.
      h.server.fortify['passkeys'] = false;
      final error = await _throws<LaravelFeatureDisabledException>(
          () => h.auth.passkeys.list());
      expect(error.feature, 'passkeys');
      expect(h.server.requestsTo('auth/user/passkeys'), hasLength(1));

      // After a refresh the client knows and stops asking.
      await h.manager.refreshServerInfo();
      expect(h.manager.fortify.passkeys, isFalse);
      await _throws<LaravelFeatureDisabledException>(
          () => h.auth.passkeys.list());
      expect(h.server.requestsTo('auth/user/passkeys'), hasLength(1));
    });
  });

  group('Error mapping', () {
    test('423 password_confirmation_required (and bare 423)', () {
      final e = _translate(423, {
        'message': 'Confirm your password.',
        'meta': {'error_code': 'password_confirmation_required'},
      });
      expect(e, isA<LaravelPasswordConfirmationRequiredException>());
      expect(e.message, 'Confirm your password.');
      expect(e.statusCode, 423);
      expect(_translate(423, {'message': 'Password confirmation required.'}),
          isA<LaravelPasswordConfirmationRequiredException>());
    });

    test('code errors carry their kind and field errors', () {
      for (final entry in {
        'code_invalid': LaravelCodeErrorKind.invalid,
        'code_expired': LaravelCodeErrorKind.expired,
        'reset_token_invalid': LaravelCodeErrorKind.invalid,
      }.entries) {
        final e = _translate(422, {
          'message': 'Bad',
          'errors': {
            'code': ['Bad']
          },
          'meta': {'error_code': entry.key},
        });
        expect(e, isA<LaravelCodeException>());
        e as LaravelCodeException;
        expect(e.kind, entry.value);
        expect(e.errorCode, entry.key);
        expect(e.statusCode, 422);
        expect(e.first('code'), 'Bad');
      }
      final locked = _translate(423, {
        'meta': {'error_code': 'code_locked'}
      }) as LaravelCodeException;
      expect(locked.kind, LaravelCodeErrorKind.locked);
      expect(locked.statusCode, 423);
      expect(locked.message, 'Too many attempts. Request a new code.');
    });

    test('404 feature_disabled vs a plain 404', () {
      final e = _translate(404, {
        'meta': {'error_code': 'feature_disabled'},
        'errors': {
          'feature': ['passkeys']
        },
      });
      expect(e, isA<LaravelFeatureDisabledException>());
      expect((e as LaravelFeatureDisabledException).feature, 'passkeys');
      final plain = _translate(404, {
        'meta': {'error_code': 'two_factor_not_enabled'}
      });
      expect(plain, isNot(isA<LaravelFeatureDisabledException>()));
      expect(plain, isA<LaravelNotFoundException>());
      expect(plain.errorCode, 'two_factor_not_enabled');
    });

    test('403 feature_disabled (bridge feature) keeps its mapping', () {
      final e = _translate(403, {
        'meta': {'error_code': 'feature_disabled'}
      });
      expect(e, isA<LaravelPermissionException>());
      expect(e, isNot(isA<LaravelFeatureDisabledException>()));
      expect(e.errorCode, 'feature_disabled');
    });

    test('409 already_verified', () {
      final e = _translate(409, {
        'meta': {'error_code': 'already_verified'}
      });
      expect(e, isA<LaravelAlreadyVerifiedException>());
      expect(e.statusCode, 409);
    });

    test('existing mappings are unchanged', () {
      expect(
          _translate(422, {
            'errors': {
              'email': ['x']
            },
            'meta': {'error_code': 'validation_failed'}
          }),
          allOf(isA<LaravelValidationError>(),
              isNot(isA<LaravelCodeException>())));
      expect(
          _translate(422, {
            'data': {'two_factor': true},
            'meta': {'error_code': 'two_factor_invalid'}
          }),
          isA<LaravelTwoFactorRequiredException>());
      expect(_translate(404, {}), isA<LaravelNotFoundException>());
      expect(_translate(409, {}).runtimeType, LaravelException);
      expect(
          _translate(404, {
            'meta': {'error_code': 'connection_not_found'}
          }),
          isA<LaravelConnectionNotFoundException>());
    });

    test('exceptions describe themselves', () {
      expect(
          LaravelCodeException(message: 'm', kind: LaravelCodeErrorKind.expired)
              .toString(),
          contains('expired'));
      expect(
          LaravelCodeException(message: 'm', kind: LaravelCodeErrorKind.locked)
              .statusCode,
          423);
      expect(
          const LaravelFeatureDisabledException(feature: 'passkeys').toString(),
          contains('passkeys'));
      expect(const LaravelPasswordConfirmationRequiredException().errorCode,
          LaravelErrorCode.passwordConfirmationRequired);
    });
  });
}
