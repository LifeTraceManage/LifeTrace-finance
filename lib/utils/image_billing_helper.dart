import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:photo_manager/photo_manager.dart';

import '../ai/core/prompt_builder.dart';
import '../ai/providers/ai_provider_config.dart';
import '../ai/providers/ai_provider_manager.dart';
import '../l10n/app_localizations.dart';
import '../pages/attachment/gallery_asset_picker_page.dart';
import '../providers.dart';
import '../providers/ai_chat_providers.dart';
import '../services/ai/bookkeeping_result.dart';
import '../services/attachment_service.dart';
import '../services/billing/post_processor.dart';
import '../services/data/tag_seed_service.dart';
import '../services/system/logger_service.dart';
import '../widgets/ui/ui.dart';
import 'bounded_async_runner.dart';

/// 图片记账入口(相册/相机)。
///
/// 相册入口支持一次选择多张图片，每张图片仍复用现有 [AiBookkeeper.fromImage]
/// 单图识别链路。批量模式只在客户端做有界并发调度，不会把所有图片塞进同一个
/// Vision 请求，也不会因为一张失败而中断整个批次。
///
/// 相册图片通过 [AssetEntity] 保留真实媒体资产 ID。只有账单成功创建并且原图
/// 已完整复制到应用私有附件目录后，才会请求系统删除相册原图；相机拍摄不做
/// 相册源文件删除。
class ImageBillingHelper {
  static const int _maxGalleryImages = 30;
  static const int _batchConcurrency = 2;

  /// 从相册选择一张或多张图片并自动记账。
  ///
  /// 使用资产感知选择页，目的是保留相册原始 Asset ID。image_picker 返回的
  /// XFile 在 Android/iOS 上可能只是临时缓存路径，不能可靠用于删除相册原图。
  static Future<void> pickImageForBilling(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final l10n = AppLocalizations.of(context);
    try {
      final assets = await Navigator.of(context).push<List<AssetEntity>>(
        MaterialPageRoute(
          builder: (_) => const GalleryAssetPickerPage(
            maxSelection: _maxGalleryImages,
          ),
        ),
      );
      if (assets == null || assets.isEmpty || !context.mounted) return;

      await _processPickedImages(
        context,
        ref,
        assets
            .map((asset) => _BillingImageInput.gallery(asset))
            .toList(growable: false),
        ImageSource.gallery,
      );
    } catch (e, st) {
      logger.error('ImageBilling', '选择相册图片失败', e, st);
      if (context.mounted) {
        showToast(context, l10n.aiOcrFailed(e.toString()));
      }
    }
  }

  /// 打开相机拍照并自动记账。相机仍保持单张流程。
  static Future<void> openCameraForBilling(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final l10n = AppLocalizations.of(context);
    try {
      final pickedFile = await ImagePicker().pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (pickedFile == null || !context.mounted) return;
      await _processPickedImages(
        context,
        ref,
        [_BillingImageInput.camera(File(pickedFile.path))],
        ImageSource.camera,
      );
    } catch (e, st) {
      logger.error('ImageBilling', '相机记账失败', e, st);
      if (context.mounted) {
        showToast(context, l10n.aiOcrFailed(e.toString()));
      }
    }
  }

  static Future<void> _processPickedImages(
    BuildContext context,
    WidgetRef ref,
    List<_BillingImageInput> pickedImages,
    ImageSource source,
  ) async {
    if (pickedImages.isEmpty) return;
    final l10n = AppLocalizations.of(context);

    ValueNotifier<_BatchBillingProgress>? progress;
    Future<void>? dialogFuture;
    var dialogOpen = false;

    try {
      // 1. AI Vision 配置兜底。先选图再检查，用户取消选择时不打扰。
      if (!await AIProviderManager.isCapabilityConfigured(
          AICapabilityType.vision)) {
        if (!context.mounted) return;
        showToast(context, l10n.aiNotConfiguredHint);
        return;
      }

      // 2. 当前账本只查一次，整个批次共用同一账本上下文。
      final currentLedger = await ref.read(currentLedgerProvider.future);
      if (currentLedger == null) {
        if (!context.mounted) return;
        showToast(context, l10n.aiOcrNoLedger);
        return;
      }
      if (!context.mounted) return;

      final autoAddAttachment = ref.read(smartBillingAutoAttachmentProvider);
      final billingTypes = <String>[
        source == ImageSource.gallery
            ? TagSeedService.billingTypeImage
            : TagSeedService.billingTypeCamera,
        TagSeedService.billingTypeAi,
      ];
      final attachmentService = ref.read(attachmentServiceProvider);
      final bookkeeper = ref.read(aiBookkeeperProvider);

      // 3. 显示统一识别进度。单张时保持原来的转圈样式；多张才展示进度条。
      progress = ValueNotifier<_BatchBillingProgress>(
        _BatchBillingProgress(total: pickedImages.length),
      );
      dialogFuture = showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (_) => _BillingProgressDialog(
          progress: progress!,
          l10n: l10n,
        ),
      );
      dialogOpen = true;

      // 4. 每张图片独立调用现有单图识别链路，默认最多并发 2 个请求。
      final outcomes =
          await BoundedAsyncRunner.run<_BillingImageInput, _BillingImageOutcome>(
        items: pickedImages,
        concurrency: pickedImages.length == 1 ? 1 : _batchConcurrency,
        task: (pickedImage, index) async {
          final imageFile = await pickedImage.resolveFile();
          if (imageFile == null) {
            throw StateError('无法读取第 ${index + 1} 张相册图片');
          }

          var attachmentAttempted = 0;
          var attachmentSaved = 0;

          final result = await bookkeeper.fromImage(
            image: imageFile,
            ledgerId: currentLedger.id,
            billGuard: PromptBuilder.billGuardForImage,
            billingTypes: billingTypes,
            l10n: l10n,
            // 一张图识别出多笔时，每笔都挂原图，保持现有溯源语义。
            onSaved: autoAddAttachment
                ? (txId, _) async {
                    attachmentAttempted++;
                    final attachment = await attachmentService.saveAttachment(
                      transactionId: txId,
                      sourceFile: imageFile,
                      index: 0,
                    );
                    if (attachment != null) attachmentSaved++;
                  }
                : null,
          );

          // 删除源图是不可逆操作，条件必须全部满足：
          // 1) 来自相册且有真实 assetId；2) 至少一笔账单成功；
          // 3) 自动附件开启；4) 每笔成功账单都确实保存了附件。
          final canDeleteSource = pickedImage.assetId != null &&
              result.success &&
              autoAddAttachment &&
              attachmentAttempted == result.savedCount &&
              attachmentSaved == result.savedCount;

          if (pickedImage.assetId != null && result.success && !canDeleteSource) {
            logger.warning(
              'ImageBilling',
              '保留相册原图 ${pickedImage.assetId}: '
                  'autoAttachment=$autoAddAttachment, '
                  'saved=${result.savedCount}, '
                  'attachmentAttempted=$attachmentAttempted, '
                  'attachmentSaved=$attachmentSaved',
            );
          }

          return _BillingImageOutcome(
            result: result,
            deletableAssetId:
                canDeleteSource ? pickedImage.assetId : null,
          );
        },
        onProgress: (completed, total, taskResult) {
          final previous = progress!.value;
          final result = taskResult.value?.result;
          final failedDelta = taskResult.isFailure
              ? 1
              : (result?.failedCount ?? 0);
          progress.value = previous.copyWith(
            completed: completed,
            savedTransactions:
                previous.savedTransactions + (result?.savedCount ?? 0),
            failedItems: previous.failedItems + failedDelta,
          );
        },
      );

      // 记录单项异常，但不影响其它图片。
      for (final outcome in outcomes) {
        if (outcome.isFailure) {
          logger.error(
            'ImageBilling',
            '批量图片第 ${outcome.index + 1} 项识别失败',
            outcome.error,
            outcome.stackTrace,
          );
        }
      }

      if (context.mounted && dialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        dialogOpen = false;
      }
      await dialogFuture;
      progress.dispose();
      progress = null;
      dialogFuture = null;

      if (!context.mounted) return;

      // 5. 聚合批量结果。一张截图本身可能返回多笔 BillInfo，因此按实际交易数汇总。
      final successfulResults = outcomes
          .where((o) => o.value != null)
          .map((o) => o.value!.result)
          .toList(growable: false);
      final savedCount = successfulResults.fold<int>(
        0,
        (sum, result) => sum + result.savedCount,
      );
      final failedCount = outcomes.where((o) => o.isFailure).length +
          successfulResults.fold<int>(
            0,
            (sum, result) => sum + result.failedCount,
          );
      final noBillCount = successfulResults
          .where((result) => !result.success && result.failedCount == 0)
          .length;

      if (savedCount == 0) {
        if (pickedImages.length == 1 && outcomes.first.isFailure) {
          showToast(
            context,
            l10n.aiOcrFailed(outcomes.first.error.toString()),
          );
        } else {
          showToast(
            context,
            failedCount > 0 ? l10n.aiOcrCheckLog : l10n.aiOcrNoBill,
          );
        }
        return;
      }

      // 6. 所有图片结束后只做一次后处理/同步，避免每张图都重复刷新和推云。
      await PostProcessor.run(
        ref,
        ledgerId: currentLedger.id,
        tags: true,
        attachments: autoAddAttachment,
      );
      if (!context.mounted) return;

      // 7. 后处理成功后再删除相册源图。系统可能显示删除确认弹窗；用户拒绝
      //    时返回空列表，不影响已经创建的账单和应用内附件。
      final deletableAssetIds = outcomes
          .where((o) => o.value?.deletableAssetId != null)
          .map((o) => o.value!.deletableAssetId!)
          .toSet()
          .toList(growable: false);
      var deletedSourceCount = 0;
      var sourceDeleteFailed = false;
      if (deletableAssetIds.isNotEmpty) {
        try {
          final deleted = await PhotoManager.editor.deleteWithIds(
            deletableAssetIds,
          );
          deletedSourceCount = deleted.length;
          sourceDeleteFailed = deletedSourceCount < deletableAssetIds.length;
          logger.info(
            'ImageBilling',
            '相册源图删除: requested=${deletableAssetIds.length}, '
                'deleted=$deletedSourceCount',
          );
        } catch (e, st) {
          sourceDeleteFailed = true;
          logger.error('ImageBilling', '删除相册原截图失败，账单与附件保持不变', e, st);
        }
      }

      final firstBill = successfulResults
          .expand((result) => result.savedBills)
          .first;
      final totalAbsAmount = successfulResults.fold<double>(
        0,
        (sum, result) => sum + result.totalAbsAmount,
      );
      final unconvertedCurrencies = <String>{
        for (final result in successfulResults)
          ...result.unconvertedCurrencies,
      }.toList()
        ..sort();

      final typeText = firstBill.type?.name == 'income'
          ? l10n.aiTypeIncome
          : l10n.aiTypeExpense;
      final amountStr = totalAbsAmount.toStringAsFixed(2);
      var toastText = (pickedImages.length > 1 || savedCount > 1)
          ? '${l10n.aiOcrSuccess(typeText, amountStr)} × $savedCount'
          : l10n.aiOcrSuccess(typeText, amountStr);

      if (deletedSourceCount > 0) {
        toastText = '$toastText\n已删除相册原截图 $deletedSourceCount 张';
      }
      if (sourceDeleteFailed) {
        toastText = '$toastText\n部分原截图未删除，可稍后手动清理';
      }
      if (failedCount > 0) {
        toastText = '$toastText\n${l10n.commonFailed}: $failedCount';
      }
      if (pickedImages.length > 1 && noBillCount > 0) {
        toastText = '$toastText\n${l10n.aiOcrNoBill}: $noBillCount';
      }
      if (unconvertedCurrencies.isNotEmpty) {
        toastText =
            '$toastText\n${l10n.aiBillingRateMissingHint(unconvertedCurrencies.join('、'))}';
      }
      showToast(context, toastText);
    } catch (e, st) {
      logger.error('ImageBilling', '图片记账批次异常', e, st);
      if (context.mounted && dialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        dialogOpen = false;
      }
      if (dialogFuture != null) {
        await dialogFuture;
      }
      progress?.dispose();
      if (context.mounted) {
        showToast(context, l10n.aiOcrFailed(e.toString()));
      }
    }
  }
}

class _BillingImageInput {
  final File? file;
  final AssetEntity? asset;

  const _BillingImageInput._({this.file, this.asset});

  factory _BillingImageInput.gallery(AssetEntity asset) =>
      _BillingImageInput._(asset: asset);

  factory _BillingImageInput.camera(File file) =>
      _BillingImageInput._(file: file);

  String? get assetId => asset?.id;

  Future<File?> resolveFile() async {
    if (file != null) return file;
    return asset?.file;
  }
}

class _BillingImageOutcome {
  final BookkeepingResult result;
  final String? deletableAssetId;

  const _BillingImageOutcome({
    required this.result,
    this.deletableAssetId,
  });
}

class _BatchBillingProgress {
  final int total;
  final int completed;
  final int savedTransactions;
  final int failedItems;

  const _BatchBillingProgress({
    required this.total,
    this.completed = 0,
    this.savedTransactions = 0,
    this.failedItems = 0,
  });

  _BatchBillingProgress copyWith({
    int? completed,
    int? savedTransactions,
    int? failedItems,
  }) {
    return _BatchBillingProgress(
      total: total,
      completed: completed ?? this.completed,
      savedTransactions: savedTransactions ?? this.savedTransactions,
      failedItems: failedItems ?? this.failedItems,
    );
  }
}

class _BillingProgressDialog extends StatelessWidget {
  final ValueNotifier<_BatchBillingProgress> progress;
  final AppLocalizations l10n;

  const _BillingProgressDialog({
    required this.progress,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: ValueListenableBuilder<_BatchBillingProgress>(
              valueListenable: progress,
              builder: (context, state, _) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(l10n.aiOcrRecognizing),
                    if (state.total > 1) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        width: 220,
                        child: LinearProgressIndicator(
                          value: state.total == 0
                              ? 0
                              : state.completed / state.total,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text('${state.completed} / ${state.total}'),
                      if (state.savedTransactions > 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${l10n.commonSuccess}: ${state.savedTransactions}',
                        ),
                      ],
                      if (state.failedItems > 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${l10n.commonFailed}: ${state.failedItems}',
                        ),
                      ],
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
