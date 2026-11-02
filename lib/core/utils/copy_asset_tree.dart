import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// 将 [AssetManifest.json] 中所有以 [assetDirPrefix] 开头的资源（如 `assets/foo/`）
/// 按相对路径写入 [targetDir]，与 VOSK 模型拷贝方式一致。
Future<void> copyAssetTreeIntoDirectory({
  required String assetDirPrefix,
  required Directory targetDir,
}) async {
  final manifestContent = await rootBundle.loadString('AssetManifest.json');
  final Map<String, dynamic> manifestMap = json.decode(manifestContent);

  for (final key in manifestMap.keys) {
    if (!key.startsWith(assetDirPrefix)) continue;
    final byteData = await rootBundle.load(key);
    final relative = key.substring(assetDirPrefix.length);
    final file = File(p.join(targetDir.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(byteData.buffer.asUint8List());
  }
}
