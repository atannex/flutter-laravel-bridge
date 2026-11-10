import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ApiResponse', () {
    test('parses enterprise success envelope correctly', () {
      final json = {
        'success': true,
        'message': 'Loaded successfully',
        'data': {'id': 42, 'name': 'Enterprise Unit'},
        'errors': null,
        'meta': {'timestamp': '2026-11-09T19:00:00Z', 'api_version': 'v1'},
      };

      final response = ApiResponse<Map<String, dynamic>>.fromJson(json);

      expect(response.success, isTrue);
      expect(response.message, equals('Loaded successfully'));
      expect(response.data?['id'], equals(42));
      expect(response.errors, isNull);
      expect(response.metaValue('api_version'), equals('v1'));
    });

    test('parses error envelope correctly', () {
      final json = {
        'success': false,
        'message': 'Invalid input',
        'data': null,
        'errors': {
          'email': ['The email field is required.']
        },
        'meta': {'trace_id': 'abc-123'},
      };

      final response = ApiResponse<dynamic>.fromJson(json);

      expect(response.success, isFalse);
      expect(response.message, equals('Invalid input'));
      expect(response.data, isNull);
      expect(response.errors, isNotNull);
      expect(response.metaValue('trace_id'), equals('abc-123'));
    });
  });
}
