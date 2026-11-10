/// Represents an enqueued HTTP mutation stored for replay when connection restores.
class MutationRecord {
  final String id;
  final String method;
  final String path;
  final dynamic data;
  final Map<String, dynamic>? queryParameters;
  final DateTime createdAt;
  int retryCount;

  /// Whether this record is written to the queue's persistent store.
  /// `false` without a store, or when [data] is not JSON-encodable (e.g.
  /// `FormData`, streams) — such records only live in memory.
  bool persisted = false;

  MutationRecord({
    required this.id,
    required this.method,
    required this.path,
    this.data,
    this.queryParameters,
    DateTime? createdAt,
    this.retryCount = 0,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'method': method,
        'path': path,
        'data': data,
        'queryParameters': queryParameters,
        'createdAt': createdAt.toIso8601String(),
        'retryCount': retryCount,
      };

  factory MutationRecord.fromJson(Map<String, dynamic> json) => MutationRecord(
        id: json['id'] as String,
        method: json['method'] as String,
        path: json['path'] as String,
        data: json['data'],
        queryParameters: json['queryParameters'] == null
            ? null
            : Map<String, dynamic>.from(json['queryParameters'] as Map),
        createdAt: DateTime.tryParse(json['createdAt'].toString()),
        retryCount: (json['retryCount'] as num?)?.toInt() ?? 0,
      );
}
