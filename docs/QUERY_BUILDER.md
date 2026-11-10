# Fluent Query Builder for Laravel & Flutter

Building search, filter, sorting, and eager loading logic between mobile and backend is a frequent source of bugs and custom parsing logic.

The `flutter_laravel_bridge` includes `LaravelQuery` which provides an intuitive, fluent builder that natively serializes into query strings compatible with Laravel, Eloquent, and the popular Spatie QueryBuilder package.

---

## 1. Syntax Comparison

Instead of manually constructing URL query strings:
```dart
// ❌ Error-prone manual string concatenation:
final url = '/api/products?filter[status]=active&filter[price_min]=10&include=category,reviews&sort=-created_at&page=1';
```

Use the typesafe fluent query builder:
```dart
// ✅ Clean, chainable, and null-safe:
final query = LaravelQuery()
    .filter('status', 'active')
    .filter('price_min', 10)
    .include(['category', 'reviews'])
    .sort('-created_at')
    .page(1, perPage: 20);

final response = await Laravel.client.paginate<Product>(
    '/api/products',
    query: query,
    itemParser: Product.fromJson,
);
```

---

## 2. Supported Operations

### 2.1 Filtering (`filter`)
Maps to `filter[key]=value`:
```dart
query.filter('status', 'published')
     .filter('author_id', 42);
// Output: ?filter[status]=published&filter[author_id]=42
```

### 2.2 Eager Loading Relationships (`include`)
Maps to comma-separated `include=relation1,relation2`:
```dart
query.include(['author', 'comments.user']);
// Output: ?include=author,comments.user
```

### 2.3 Sorting (`sort` / `sorts`)
Maps to comma-separated `sort=field1,-field2` (prefix with `-` for descending):
```dart
query.sort('-published_at')
     .sort('title');
// Output: ?sort=-published_at,title
```

### 2.4 Appending Computed Accessors (`append`)
Maps to `append=accessor1,accessor2`:
```dart
query.append(['is_bookmarked', 'formatted_price']);
// Output: ?append=is_bookmarked,formatted_price
```

### 2.5 Sparse Fieldsets (`selectFields`)
Requests only specific columns to save bandwidth:
```dart
query.selectFields('users', ['id', 'name', 'avatar'])
     .selectFields('posts', ['id', 'title']);
// Output: ?fields[users]=id,name,avatar&fields[posts]=id,title
```

---

## 3. Laravel Backend Consumption

On the Laravel side, handle these parameters seamlessly using Eloquent or Spatie QueryBuilder:

```php
use App\Models\Post;
use Spatie\QueryBuilder\QueryBuilder;
use Spatie\QueryBuilder\AllowedFilter;

class PostController extends Controller
{
    public function index()
    {
        $posts = QueryBuilder::for(Post::class)
            ->allowedFilters(['status', 'author_id'])
            ->allowedIncludes(['author', 'comments.user'])
            ->allowedSorts(['published_at', 'title'])
            ->allowedAppends(['is_bookmarked'])
            ->paginate();

        return response()->flutterPaginated($posts);
    }
}
```
