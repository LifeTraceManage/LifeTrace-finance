import 'package:beecount/services/gallery_source_cleanup_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GalleryCleanupPolicy', () {
    test('allows deletion only after complete bookkeeping and attachment copy', () {
      expect(
        GalleryCleanupPolicy.canDeleteOriginal(
          bookkeepingSucceeded: true,
          failedBillCount: 0,
          attachmentCopyReady: true,
        ),
        isTrue,
      );
    });

    test('keeps original when bookkeeping produced no saved bill', () {
      expect(
        GalleryCleanupPolicy.canDeleteOriginal(
          bookkeepingSucceeded: false,
          failedBillCount: 0,
          attachmentCopyReady: true,
        ),
        isFalse,
      );
    });

    test('keeps original when any bill in the image failed to persist', () {
      expect(
        GalleryCleanupPolicy.canDeleteOriginal(
          bookkeepingSucceeded: true,
          failedBillCount: 1,
          attachmentCopyReady: true,
        ),
        isFalse,
      );
    });

    test('keeps original when app attachment copy is incomplete', () {
      expect(
        GalleryCleanupPolicy.canDeleteOriginal(
          bookkeepingSucceeded: true,
          failedBillCount: 0,
          attachmentCopyReady: false,
        ),
        isFalse,
      );
    });
  });
}
