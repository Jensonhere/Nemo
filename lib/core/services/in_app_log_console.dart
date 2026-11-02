import 'dart:collection';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class InAppLogConsole {
  InAppLogConsole._();

  static final InAppLogConsole instance = InAppLogConsole._();

  static const int _maxLines = 1000;
  final Queue<String> _lines = Queue<String>();

  void add(String message) {
    final now = DateTime.now();
    final prefix =
        '[${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}.${_three(now.millisecond)}]';
    final parts = message.split(RegExp(r'\r?\n'));

    for (final part in parts) {
      _lines.addLast('$prefix $part');
      while (_lines.length > _maxLines) {
        _lines.removeFirst();
      }
    }
  }

  List<String> getRecentLogs() => List<String>.unmodifiable(_lines);

  String getAllText() => _lines.join('\n');

  void clear() {
    _lines.clear();
  }

  Future<File> saveToFile() async {
    try {
      Directory? baseDir;
      try {
        baseDir = await getExternalStorageDirectory();
      } catch (e) {
        _logInternal('[IN_APP_LOG] external_dir_error error=$e');
      }

      if (baseDir == null) {
        _logInternal(
          '[IN_APP_LOG] external_dir_unavailable fallback=application_documents',
        );
        baseDir = await getApplicationDocumentsDirectory();
      }

      final logDir = Directory('${baseDir.path}/logs');
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }

      final timestamp = _fileTimestamp(DateTime.now());
      final file = File('${logDir.path}/app_log_$timestamp.txt');
      await file.writeAsString(getAllText(), flush: true);

      _logInternal('[IN_APP_LOG] save success path=${file.path}');
      return file;
    } catch (e) {
      _logInternal('[IN_APP_LOG] save failed error=$e');
      rethrow;
    }
  }

  void _logInternal(String message) {
    print(message);
    add(message);
  }

  static String _fileTimestamp(DateTime dateTime) {
    return '${dateTime.year}'
        '${_two(dateTime.month)}'
        '${_two(dateTime.day)}_'
        '${_two(dateTime.hour)}'
        '${_two(dateTime.minute)}'
        '${_two(dateTime.second)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  static String _three(int value) => value.toString().padLeft(3, '0');
}
