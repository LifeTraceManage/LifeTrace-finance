import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:photo_manager/photo_manager.dart';

import 'system/logger_service.dart';

/// 删除相册原图前的安全判定。
///
/// 只有账单已经完整入库、应用内附件副本保存成功时，才允许把原截图列为
/// 删除候选。任何部分失败都保留相册原图，方便用户重新识别或人工核对。
class GalleryCleanupPolicy {
  const GalleryCleanupPolicy._();

  static bool canDeleteOriginal({
    required bool bookkeepingSucceeded,
    required int failedBillCount,
    required bool attachmentCopyReady,
  }) {
    return bookkeepingSucceeded &&
        failedBillCount == 0 &&
        attachmentCopyReady;
  }
}

/// 相册原图清理结果。
class GallerySourceCleanupResult {
  final int requestedCount;
  final int matchedCount;
  final int deletedCount;
  final bool permissionDenied;
  final bool unsupported;

  const GallerySourceCleanupResult({
    required this.requestedCount,
    required this.matchedCount,
    required this.deletedCount,
    this.permissionDenied = false,
    this.unsupported = false,
  });

  int get notMatchedCount => requestedCount - matchedCount;
  int get deleteFailedCount => matchedCount - deletedCount;
}

/// 将 image_picker 返回的“精确缓存副本”反查到系统相册资源，再通过
/// photo_manager 请求系统删除。
///
/// 为什么不能直接 `File.delete()`：image_picker 在 Android 上会把 Photo Picker
/// 返回的 content:// URI 复制到 App cache，File.path 指向缓存，不是系统相册原图。
/// 本服务通过 文件名 + 文件大小 + SHA256 三重匹配 AssetEntity，避免仅靠文件名
/// 误删同名照片。
class GallerySourceCleanupService {
  static const String _tag = 'GallerySourceCleanup';
  static const int _pageSize = 200;

  const GallerySourceCleanupService();

  Future<GallerySourceCleanupResult> deleteOriginals(
    List<File> exactSourceCopies,
  ) async {
    if (exactSourceCopies.isEmpty) {
      return const GallerySourceCleanupResult(
        requestedCount: 0,
        matchedCount: 0,
        deletedCount: 0,
      );
    }

    // 当前项目主要在 Android 使用该能力；其它平台先保持原图，不做破坏性操作。
    if (!Platform.isAndroid) {
      return GallerySourceCleanupResult(
        requestedCount: exactSourceCopies.length,
        matchedCount: 0,
        deletedCount: 0,
        unsupported: true,
      );
    }

    try {
      final permission = await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          androidPermission: AndroidPermission(
            type: RequestType.image,
            mediaLocation: false,
          ),
        ),
      );
      if (!permission.hasAccess) {
        logger.warning(_tag, '用户未授予相册读取权限，保留原截图');
        return GallerySourceCleanupResult(
          requestedCount: exactSourceCopies.length,
          matchedCount: 0,
          deletedCount: 0,
          permissionDenied: true,
        );
      }

      final fingerprints = <_SourceFingerprint>[];
      for (final file in exactSourceCopies) {
        if (!await file.exists()) {
          logger.warning(_tag, '待清理缓存副本不存在: ${file.path}');
          continue;
        }
        fingerprints.add(await _SourceFingerprint.fromFile(file));
      }

      if (fingerprints.isEmpty) {
        return GallerySourceCleanupResult(
          requestedCount: exactSourceCopies.length,
          matchedCount: 0,
          deletedCount: 0,
        );
      }

      final unresolved = <int>{
        for (var i = 0; i < fingerprints.length; i++) i,
      };
      final matchedIds = <String>[];
      final total = await PhotoManager.getAssetCount(type: RequestType.image);
      final pages = (total + _pageSize - 1) ~/ _pageSize;

      for (var page = 0; page < pages && unresolved.isNotEmpty; page++) {
        final assets = await PhotoManager.getAssetListPaged(
          page: page,
          pageCount: _pageSize,
          type: RequestType.image,
        );

        for (final asset in assets) {
          if (unresolved.isEmpty) break;

          final title = asset.title ?? await asset.titleAsync;
          final sameNameIndexes = unresolved
              .where((i) => fingerprints[i].fileName == title)
              .toList(growable: false);
          if (sameNameIndexes.isEmpty) continue;

          final assetSize = await asset.fileSize;
          final sameSizeIndexes = sameNameIndexes
              .where((i) => fingerprints[i].size == assetSize)
              .toList(growable: false);
          if (sameSizeIndexes.isEmpty) continue;

          // 文件名和大小都一致仍可能存在重复文件，最后用内容哈希确认。
          final assetFile = await asset.originFile ?? await asset.file;
          if (assetFile == null || !await assetFile.exists()) continue;
          final assetDigest = await _sha256Of(assetFile);

          for (final index in sameSizeIndexes) {
            if (fingerprints[index].sha256 == assetDigest) {
              matchedIds.add(asset.id);
              unresolved.remove(index);
              break;
            }
          }
        }
      }

      if (matchedIds.isEmpty) {
        logger.warning(_tag, '未能在系统相册精确匹配待删除原图，全部保留');
        return GallerySourceCleanupResult(
          requestedCount: exactSourceCopies.length,
          matchedCount: 0,
          deletedCount: 0,
        );
      }

      // Android 11+ photo_manager 会走系统确认/回收站语义；用户拒绝时返回空列表。
      final deletedIds = await PhotoManager.editor.deleteWithIds(matchedIds);
      logger.info(
        _tag,
        '原截图清理完成: requested=${exactSourceCopies.length}, '
        'matched=${matchedIds.length}, deleted=${deletedIds.length}',
      );

      return GallerySourceCleanupResult(
        requestedCount: exactSourceCopies.length,
        matchedCount: matchedIds.length,
        deletedCount: deletedIds.length,
      );
    } catch (e, st) {
      // 删除失败绝不能影响已经完成的记账，也不能尝试降级为 File.delete()。
      logger.error(_tag, '删除系统相册原截图失败，已保留原图', e, st);
      return GallerySourceCleanupResult(
        requestedCount: exactSourceCopies.length,
        matchedCount: 0,
        deletedCount: 0,
      );
    }
  }
}

class _SourceFingerprint {
  final String fileName;
  final int size;
  final String sha256;

  const _SourceFingerprint({
    required this.fileName,
    required this.size,
    required this.sha256,
  });

  static Future<_SourceFingerprint> fromFile(File file) async {
    return _SourceFingerprint(
      fileName: path.basename(file.path),
      size: await file.length(),
      sha256: await _sha256Of(file),
    );
  }
}

Future<String> _sha256Of(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}
