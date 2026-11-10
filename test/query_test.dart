import 'package:flutter_laravel_bridge/flutter_laravel_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LaravelQuery', () {
    test('serializes filters, includes, sorts, and pagination correctly', () {
      final query = LaravelQuery()
          .filter('status', 'active')
          .filter('role_id', 2)
          .include(['author', 'comments.user'])
          .sort('-created_at')
          .sort('title')
          .append(['is_favorite'])
          .selectFields('users', ['id', 'name'])
          .page(3, perPage: 25)
          .param('custom_flag', 'true');

      final params = query.toMap();

      expect(params['filter[status]'], equals('active'));
      expect(params['filter[role_id]'], equals(2));
      expect(params['include'], equals('author,comments.user'));
      expect(params['sort'], equals('-created_at,title'));
      expect(params['append'], equals('is_favorite'));
      expect(params['fields[users]'], equals('id,name'));
      expect(params['page'], equals(3));
      expect(params['per_page'], equals(25));
      expect(params['custom_flag'], equals('true'));
    });
  });
}
