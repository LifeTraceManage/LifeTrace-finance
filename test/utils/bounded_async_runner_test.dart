import 'dart:async';

import 'package:beecount/utils/bounded_async_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BoundedAsyncRunner', () {
    test('preserves input order while limiting concurrency', () async {
      var active = 0;
      var maxActive = 0;

      final results = await BoundedAsyncRunner.run<int, int>(
        items: [1, 2, 3, 4, 5, 6],
        concurrency: 2,
        task: (item, index) async {
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(
            Duration(milliseconds: item.isEven ? 5 : 15),
          );
          active--;
          return item * 10;
        },
      );

      expect(maxActive, lessThanOrEqualTo(2));
      expect(results.map((e) => e.value).toList(), [10, 20, 30, 40, 50, 60]);
      expect(results.every((e) => e.isSuccess), isTrue);
    });

    test('isolates failures and continues remaining tasks', () async {
      final completed = <int>[];

      final results = await BoundedAsyncRunner.run<int, int>(
        items: [1, 2, 3, 4],
        concurrency: 2,
        task: (item, index) async {
          if (item == 2) throw StateError('boom');
          return item;
        },
        onProgress: (done, total, result) {
          expect(total, 4);
          completed.add(done);
        },
      );

      expect(results[0].value, 1);
      expect(results[1].isFailure, isTrue);
      expect(results[1].error, isA<StateError>());
      expect(results[2].value, 3);
      expect(results[3].value, 4);
      expect(completed, [1, 2, 3, 4]);
    });

    test('rejects invalid concurrency', () {
      expect(
        () => BoundedAsyncRunner.run<int, int>(
          items: [1],
          concurrency: 0,
          task: (item, index) async => item,
        ),
        throwsArgumentError,
      );
    });

    test('empty input completes without invoking task', () async {
      var invoked = false;
      final results = await BoundedAsyncRunner.run<int, int>(
        items: const [],
        concurrency: 2,
        task: (item, index) async {
          invoked = true;
          return item;
        },
      );

      expect(results, isEmpty);
      expect(invoked, isFalse);
    });
  });
}
