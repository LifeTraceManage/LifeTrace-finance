/// Runs asynchronous work with a bounded number of concurrent tasks.
///
/// The runner preserves the input order in the returned list, isolates task
/// failures so one item cannot abort the whole batch, and reports completion
/// after every item. It is intentionally UI-agnostic so image billing and
/// other batch flows can reuse the same scheduling primitive.
class BoundedAsyncRunner {
  const BoundedAsyncRunner._();

  static Future<List<BatchTaskResult<R>>> run<T, R>({
    required List<T> items,
    required Future<R> Function(T item, int index) task,
    int concurrency = 2,
    void Function(
      int completed,
      int total,
      BatchTaskResult<R> result,
    )? onProgress,
  }) async {
    if (concurrency < 1) {
      throw ArgumentError.value(concurrency, 'concurrency', 'must be >= 1');
    }
    if (items.isEmpty) return <BatchTaskResult<R>>[];

    final results = List<BatchTaskResult<R>?>.filled(items.length, null);
    var nextIndex = 0;
    var completed = 0;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex;
        if (index >= items.length) return;
        nextIndex++;

        late final BatchTaskResult<R> result;
        try {
          final value = await task(items[index], index);
          result = BatchTaskResult<R>.success(index: index, value: value);
        } catch (error, stackTrace) {
          result = BatchTaskResult<R>.failure(
            index: index,
            error: error,
            stackTrace: stackTrace,
          );
        }

        results[index] = result;
        completed++;
        onProgress?.call(completed, items.length, result);
      }
    }

    final workerCount = concurrency < items.length ? concurrency : items.length;
    await Future.wait(List.generate(workerCount, (_) => worker()));

    return results.cast<BatchTaskResult<R>>();
  }
}

class BatchTaskResult<R> {
  final int index;
  final R? value;
  final Object? error;
  final StackTrace? stackTrace;

  const BatchTaskResult._({
    required this.index,
    this.value,
    this.error,
    this.stackTrace,
  });

  factory BatchTaskResult.success({
    required int index,
    required R value,
  }) {
    return BatchTaskResult<R>._(index: index, value: value);
  }

  factory BatchTaskResult.failure({
    required int index,
    required Object error,
    required StackTrace stackTrace,
  }) {
    return BatchTaskResult<R>._(
      index: index,
      error: error,
      stackTrace: stackTrace,
    );
  }

  bool get isSuccess => error == null;
  bool get isFailure => error != null;
}
