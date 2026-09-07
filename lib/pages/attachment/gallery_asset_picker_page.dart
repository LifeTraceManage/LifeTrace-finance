import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

/// 相册账单图片选择页。
///
/// 与 image_picker 不同，这里直接保留 [AssetEntity.id]。这样记账成功并且原图
/// 已可靠复制为账单附件后，可以通过系统媒体 API 删除相册中的原始截图，而
/// 不是误删 image_picker 产生的临时缓存文件。
class GalleryAssetPickerPage extends StatefulWidget {
  final int maxSelection;

  const GalleryAssetPickerPage({
    super.key,
    this.maxSelection = 30,
  });

  @override
  State<GalleryAssetPickerPage> createState() => _GalleryAssetPickerPageState();
}

class _GalleryAssetPickerPageState extends State<GalleryAssetPickerPage> {
  static const int _pageSize = 80;

  final ScrollController _scrollController = ScrollController();
  final Map<String, AssetEntity> _selected = <String, AssetEntity>{};

  AssetPathEntity? _allPath;
  final List<AssetEntity> _assets = <AssetEntity>[];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || _loadingMore || !_hasMore) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 500) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!permission.hasAccess) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = '没有相册访问权限';
        });
        return;
      }

      final paths = await PhotoManager.getAssetPathList(
        onlyAll: true,
        type: RequestType.image,
      );
      if (!mounted) return;
      if (paths.isEmpty) {
        setState(() {
          _loading = false;
          _error = '相册中没有可用图片';
        });
        return;
      }

      _allPath = paths.first;
      final firstPage = await _allPath!.getAssetListPaged(
        page: 0,
        size: _pageSize,
        type: RequestType.image,
      );
      if (!mounted) return;
      setState(() {
        _assets.addAll(firstPage);
        _page = 1;
        _hasMore = firstPage.length == _pageSize;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载相册失败：$e';
      });
    }
  }

  Future<void> _loadMore() async {
    final path = _allPath;
    if (path == null || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final next = await path.getAssetListPaged(
        page: _page,
        size: _pageSize,
        type: RequestType.image,
      );
      if (!mounted) return;
      setState(() {
        _assets.addAll(next);
        _page++;
        _hasMore = next.length == _pageSize;
      });
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _toggle(AssetEntity asset) {
    setState(() {
      if (_selected.containsKey(asset.id)) {
        _selected.remove(asset.id);
        return;
      }
      if (_selected.length >= widget.maxSelection) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('最多选择 ${widget.maxSelection} 张图片')),
        );
        return;
      }
      _selected[asset.id] = asset;
    });
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty
            ? '选择账单截图'
            : '已选择 ${_selected.length}/${widget.maxSelection}'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () => Navigator.of(context).pop(
                      _selected.values.toList(growable: false),
                    ),
            child: const Text('完成'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.photo_library_outlined, size: 48),
                        const SizedBox(height: 12),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: PhotoManager.openSetting,
                          child: const Text('打开系统设置'),
                        ),
                      ],
                    ),
                  ),
                )
              : GridView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(2),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 2,
                    crossAxisSpacing: 2,
                  ),
                  itemCount: _assets.length + (_loadingMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= _assets.length) {
                      return const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    final asset = _assets[index];
                    final selectedIndex =
                        _selected.keys.toList().indexOf(asset.id);
                    return GestureDetector(
                      onTap: () => _toggle(asset),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _AssetThumbnail(asset: asset),
                          if (selectedIndex >= 0)
                            Container(
                              color: Colors.black.withValues(alpha: 0.18),
                            ),
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: selectedIndex >= 0
                                    ? primary
                                    : Colors.black.withValues(alpha: 0.35),
                                border: Border.all(
                                  color: Colors.white,
                                  width: 1.5,
                                ),
                              ),
                              child: selectedIndex >= 0
                                  ? Text(
                                      '${selectedIndex + 1}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}

class _AssetThumbnail extends StatelessWidget {
  final AssetEntity asset;

  const _AssetThumbnail({required this.asset});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: asset.thumbnailDataWithSize(const ThumbnailSize.square(240)),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) {
          return Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          );
        }
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        );
      },
    );
  }
}
