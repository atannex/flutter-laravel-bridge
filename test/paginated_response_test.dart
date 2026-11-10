import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PaginatedResponse', () {
    test('parses Laravel paginated JSON format', () {
      final json = {
        'data': [
          {'id': 1, 'title': 'First Post'},
          {'id': 2, 'title': 'Second Post'},
        ],
        'meta': {
          'current_page': 1,
          'last_page': 5,
          'per_page': 2,
          'total': 10,
          'has_more': true,
        }
      };

      final paginated = PaginatedResponse<Map<String, dynamic>>.fromJson(
        json,
        (item) => item as Map<String, dynamic>,
      );

      expect(paginated.data.length, equals(2));
      expect(paginated.currentPage, equals(1));
      expect(paginated.lastPage, equals(5));
      expect(paginated.total, equals(10));
      expect(paginated.hasMore, isTrue);
    });

    test('appendPage concatenates items', () {
      final page1 = PaginatedResponse<int>(
        data: [1, 2],
        currentPage: 1,
        lastPage: 2,
        perPage: 2,
        total: 4,
        hasMore: true,
      );

      final page2 = PaginatedResponse<int>(
        data: [3, 4],
        currentPage: 2,
        lastPage: 2,
        perPage: 2,
        total: 4,
        hasMore: false,
      );

      final combined = page1.appendPage(page2);

      expect(combined.data, equals([1, 2, 3, 4]));
      expect(combined.currentPage, equals(2));
      expect(combined.hasMore, isFalse);
    });
  });
}
