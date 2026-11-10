import 'package:flutter/material.dart';
import '../pagination/paginated_response.dart';

/// Full-featured infinite scrolling list view with pull-to-refresh for Laravel paginated endpoints.
class LaravelPaginatedListView<T> extends StatefulWidget {
  final Future<PaginatedResponse<T>> Function(int page) fetchPage;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;
  final Widget Function(BuildContext context)? emptyBuilder;
  final Widget Function(
      BuildContext context, dynamic error, VoidCallback retry)? errorBuilder;
  final Widget Function(BuildContext context)? loadingBuilder;
  final ScrollPhysics? physics;
  final EdgeInsetsGeometry padding;
  final Widget? separator;

  const LaravelPaginatedListView({
    super.key,
    required this.fetchPage,
    required this.itemBuilder,
    this.emptyBuilder,
    this.errorBuilder,
    this.loadingBuilder,
    this.physics,
    this.padding = EdgeInsets.zero,
    this.separator,
  });

  @override
  State<LaravelPaginatedListView<T>> createState() =>
      _LaravelPaginatedListViewState<T>();
}

class _LaravelPaginatedListViewState<T>
    extends State<LaravelPaginatedListView<T>> {
  final ScrollController _scrollController = ScrollController();
  final List<T> _items = [];

  int _currentPage = 1;
  bool _hasMore = true;
  bool _isLoading = false;
  bool _isInitialLoading = true;
  dynamic _error;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadFirstPage();
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _isInitialLoading = true;
      _error = null;
    });

    try {
      final response = await widget.fetchPage(1);
      if (mounted) {
        setState(() {
          _items.clear();
          _items.addAll(response.data);
          _currentPage = response.currentPage;
          _hasMore = response.hasMore;
          _isInitialLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _isInitialLoading = false;
        });
      }
    }
  }

  Future<void> _loadNextPage() async {
    if (_isLoading || !_hasMore) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final response = await widget.fetchPage(_currentPage + 1);
      if (mounted) {
        setState(() {
          _items.addAll(response.data);
          _currentPage = response.currentPage;
          _hasMore = response.hasMore;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadNextPage();
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitialLoading) {
      return widget.loadingBuilder != null
          ? widget.loadingBuilder!(context)
          : const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _items.isEmpty) {
      return widget.errorBuilder != null
          ? widget.errorBuilder!(context, _error, _loadFirstPage)
          : Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Error loading data: $_error'),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _loadFirstPage,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
    }

    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadFirstPage,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.7,
            child: widget.emptyBuilder != null
                ? widget.emptyBuilder!(context)
                : const Center(child: Text('No items found')),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFirstPage,
      child: ListView.separated(
        controller: _scrollController,
        physics: widget.physics ?? const AlwaysScrollableScrollPhysics(),
        padding: widget.padding,
        itemCount: _items.length + (_hasMore ? 1 : 0),
        separatorBuilder: (context, index) {
          if (index >= _items.length - 1 && _hasMore) {
            return const SizedBox.shrink();
          }
          return widget.separator ?? const SizedBox.shrink();
        },
        itemBuilder: (context, index) {
          if (index == _items.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }

          return widget.itemBuilder(context, _items[index], index);
        },
      ),
    );
  }
}
