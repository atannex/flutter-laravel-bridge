/// Represents a paginated list of items from Laravel's LengthAware or Cursor paginators.
class PaginatedResponse<T> {
  final List<T> data;
  final int currentPage;
  final int? lastPage;
  final int perPage;
  final int? total;
  final bool hasMore;
  final String? nextPageUrl;
  final String? prevPageUrl;
  final Map<String, dynamic>? rawMeta;

  const PaginatedResponse({
    required this.data,
    required this.currentPage,
    this.lastPage,
    required this.perPage,
    this.total,
    required this.hasMore,
    this.nextPageUrl,
    this.prevPageUrl,
    this.rawMeta,
  });

  /// Factory to parse from either envelope format:
  /// 1. Standard Laravel Flutter Bridge envelope:
  ///    `{ "data": [...], "meta": { "current_page": 1, "per_page": 15, "last_page": 3, "total": 45, "has_more": true } }`
  /// 2. Native Laravel paginator JSON:
  ///    `{ "data": [...], "current_page": 1, "per_page": 15, "last_page": 3, "total": 45, "next_page_url": "..." }`
  factory PaginatedResponse.fromJson(
    Map<String, dynamic> json,
    T Function(dynamic item) itemParser,
  ) {
    // Determine where data items reside
    final rawList = json['data'] as List<dynamic>? ?? <dynamic>[];
    final items = rawList.map(itemParser).toList();

    // Look for meta block first, otherwise fallback to root attributes
    final meta = json['meta'] as Map<String, dynamic>? ?? json;

    final currentPage = (meta['current_page'] as num?)?.toInt() ?? 1;
    final lastPage = (meta['last_page'] as num?)?.toInt();
    final perPage = (meta['per_page'] as num?)?.toInt() ?? items.length;
    final total = (meta['total'] as num?)?.toInt();
    final nextPageUrl = meta['next_page_url'] as String?;
    final prevPageUrl = meta['prev_page_url'] as String?;

    final hasMore = (meta['has_more'] as bool?) ??
        (lastPage != null ? currentPage < lastPage : nextPageUrl != null);

    return PaginatedResponse<T>(
      data: items,
      currentPage: currentPage,
      lastPage: lastPage,
      perPage: perPage,
      total: total,
      hasMore: hasMore,
      nextPageUrl: nextPageUrl,
      prevPageUrl: prevPageUrl,
      rawMeta: meta,
    );
  }

  /// Create an empty paginated response.
  factory PaginatedResponse.empty() {
    return const PaginatedResponse(
      data: [],
      currentPage: 1,
      lastPage: 1,
      perPage: 15,
      total: 0,
      hasMore: false,
    );
  }

  /// Combines this page's items with another subsequent page's items.
  PaginatedResponse<T> appendPage(PaginatedResponse<T> nextPage) {
    return PaginatedResponse<T>(
      data: [...data, ...nextPage.data],
      currentPage: nextPage.currentPage,
      lastPage: nextPage.lastPage ?? lastPage,
      perPage: nextPage.perPage,
      total: nextPage.total ?? total,
      hasMore: nextPage.hasMore,
      nextPageUrl: nextPage.nextPageUrl,
      prevPageUrl: prevPageUrl,
      rawMeta: nextPage.rawMeta,
    );
  }
}
