import 'dart:io';

import 'package:crypto/crypto.dart';
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

/// 将 image_picker 返回的“精确缓存副本”反查到系统相册资源，再请求系统删除。
///
/// 为什么不能直接 `File.delete()`：Android Photo Picker 会把 content:// 媒体复制
/// 到 App cache，XFile.path 通常指向缓存，不是系统相册原图。
///
/// 这里不依赖缓存文件名，因为缓存名不保证等于相册原始文件名。先按文件大小
/// 初筛，再对候选 AssetEntity 的原始内容计算 SHA-256，只有内容完全一致才删除。
/// 找不到精确匹配时宁可保留，不做任何模糊删除。
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

    // 当前功能只在 Android 开启。其它平台保留原图，避免引入未经验证的删除语义。
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

          final assetSize = await asset.fileSize;
          final sameSizeIndexes = unresolved
              .where((i) => fingerprints[i].size == assetSize)
              .toList(growable: false);
          if (sameSizeIndexes.isEmpty) continue;

          // 大小相同仍可能是不同图片，必须再做内容哈希确认。
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

      // Android 11+ 由系统负责删除确认/回收站语义。用户拒绝时不会强制删除。
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
      // 删除失败绝不能影响已经完成的记账，也不能降级为 File.delete()。
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
  final int size;
  final String sha256;

  const _SourceFingerprint({
    required this.size,
    required this.sha256,
  });

  static Future<_SourceFingerprint> fromFile(File file) async {
    return _SourceFingerprint(
      size: await file.length(),
      sha256: await _sha256Of(file),
    );
  }
}

Future<String> _sha256Of(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}
