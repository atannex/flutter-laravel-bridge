import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LaravelValidationError', () {
    test('extracts field errors accurately', () {
      final error = LaravelValidationError(
        message: 'The given data was invalid.',
        fieldErrors: {
          'email': ['The email field is required.', 'The email must be valid.'],
          'password': ['Password must be at least 8 characters.'],
        },
      );

      expect(error.has('email'), isTrue);
      expect(error.has('non_existent'), isFalse);
      expect(error.first('email'), equals('The email field is required.'));
      expect(error.first('password'),
          equals('Password must be at least 8 characters.'));
      expect(error.first('non_existent'), isNull);
      expect(error.allMessages.length, equals(3));
    });
  });
}
