import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 智能记账自动关联标签开关（默认开启）
final smartBillingAutoTagsProvider = StateProvider<bool>((ref) => true);

/// 智能记账自动添加附件开关（默认开启）
final smartBillingAutoAttachmentProvider = StateProvider<bool>((ref) => true);

/// 相册图片成功记账后，是否询问删除系统相册中的原截图。
///
/// 默认关闭。该能力具有破坏性，而且只有在应用内附件副本保存成功后才允许
/// 删除原图；真正删除前还会再次要求用户确认。
final smartBillingDeleteSourceAfterImportProvider =
    StateProvider<bool>((ref) => false);

/// 智能记账自动关联标签持久化初始化
final smartBillingAutoTagsInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getBool('smartBillingAutoTags');
  if (saved != null) {
    ref.read(smartBillingAutoTagsProvider.notifier).state = saved;
  }
  ref.listen<bool>(smartBillingAutoTagsProvider, (prev, next) async {
    await prefs.setBool('smartBillingAutoTags', next);
  });
});

/// 智能记账自动添加附件持久化初始化
final smartBillingAutoAttachmentInitProvider = FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getBool('smartBillingAutoAttachment');
  if (saved != null) {
    ref.read(smartBillingAutoAttachmentProvider.notifier).state = saved;
  }
  ref.listen<bool>(smartBillingAutoAttachmentProvider, (prev, next) async {
    await prefs.setBool('smartBillingAutoAttachment', next);
  });
});

/// “成功记账后删除原截图”设置持久化初始化。
final smartBillingDeleteSourceAfterImportInitProvider =
    FutureProvider<void>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getBool('smartBillingDeleteSourceAfterImport');
  if (saved != null) {
    ref.read(smartBillingDeleteSourceAfterImportProvider.notifier).state = saved;
  }
  ref.listen<bool>(smartBillingDeleteSourceAfterImportProvider,
      (prev, next) async {
    await prefs.setBool('smartBillingDeleteSourceAfterImport', next);
  });
});
