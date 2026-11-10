/// Fluent query builder to compose Laravel / Spatie QueryBuilder compatible HTTP parameters.
class LaravelQuery {
  final Map<String, dynamic> _filters = {};
  final List<String> _includes = [];
  final List<String> _sorts = [];
  final List<String> _appends = [];
  final Map<String, List<String>> _fields = {};
  int? _page;
  int? _perPage;
  final Map<String, dynamic> _customParams = {};

  LaravelQuery();

  /// Filter results: e.g. `filter('status', 'published')` -> `filter[status]=published`.
  LaravelQuery filter(String field, dynamic value) {
    if (value != null) {
      _filters[field] = value;
    }
    return this;
  }

  /// Add multiple filters at once.
  LaravelQuery filters(Map<String, dynamic> map) {
    map.forEach((k, v) {
      if (v != null) _filters[k] = v;
    });
    return this;
  }

  /// Request eager-loaded Eloquent relationships: e.g. `include(['author', 'comments.user'])`.
  LaravelQuery include(List<String> relationships) {
    _includes.addAll(relationships);
    return this;
  }

  /// Sort by field. Prefix with `-` for descending order (e.g. `sort('-created_at')`).
  LaravelQuery sort(String field) {
    _sorts.add(field);
    return this;
  }

  /// Sort by multiple fields.
  LaravelQuery sorts(List<String> fields) {
    _sorts.addAll(fields);
    return this;
  }

  /// Request appended Eloquent accessors: e.g. `append(['is_favorite', 'full_name'])`.
  LaravelQuery append(List<String> accessors) {
    _appends.addAll(accessors);
    return this;
  }

  /// Select specific sparse fields: e.g. `selectFields('users', ['id', 'name'])` -> `fields[users]=id,name`.
  LaravelQuery selectFields(String resource, List<String> fields) {
    _fields[resource] = fields;
    return this;
  }

  /// Specify page and items per page.
  LaravelQuery page(int page, {int? perPage}) {
    _page = page;
    _perPage = perPage;
    return this;
  }

  /// Add an arbitrary custom query parameter.
  LaravelQuery param(String key, dynamic value) {
    if (value != null) {
      _customParams[key] = value;
    }
    return this;
  }

  /// Build into a query parameter map accepted by Dio and Laravel.
  Map<String, dynamic> toMap() {
    final Map<String, dynamic> params = Map.from(_customParams);

    // Filters: filter[field]=value
    for (final entry in _filters.entries) {
      params['filter[${entry.key}]'] = entry.value;
    }

    // Includes: include=author,comments
    if (_includes.isNotEmpty) {
      params['include'] = _includes.toSet().join(',');
    }

    // Sorts: sort=-created_at,title
    if (_sorts.isNotEmpty) {
      params['sort'] = _sorts.toSet().join(',');
    }

    // Appends: append=is_favorite
    if (_appends.isNotEmpty) {
      params['append'] = _appends.toSet().join(',');
    }

    // Sparse Fields: fields[resource]=id,name
    for (final entry in _fields.entries) {
      params['fields[${entry.key}]'] = entry.value.toSet().join(',');
    }

    // Pagination
    if (_page != null) {
      params['page'] = _page;
    }
    if (_perPage != null) {
      params['per_page'] = _perPage;
    }

    return params;
  }
}
