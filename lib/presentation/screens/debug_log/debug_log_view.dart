import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voicegpt/core/services/in_app_log_console.dart';

class DebugLogView extends StatefulWidget {
  const DebugLogView({super.key});

  @override
  State<DebugLogView> createState() => _DebugLogViewState();
}

class _DebugLogViewState extends State<DebugLogView> {
  List<String> _logs = const [];
  String _status = '';
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _logs = InAppLogConsole.instance.getRecentLogs();
    });
  }

  void _clear() {
    InAppLogConsole.instance.clear();
    setState(() {
      _logs = const [];
      _status = '日志已清空';
    });
  }

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
      _status = '正在保存日志...';
    });

    try {
      final File file = await InAppLogConsole.instance.saveToFile();
      if (!mounted) return;
      setState(() {
        _status = '日志已保存: ${file.path}';
        _logs = InAppLogConsole.instance.getRecentLogs();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('日志已保存: ${file.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = '保存失败: $e';
        _logs = InAppLogConsole.instance.getRecentLogs();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _copyAll() async {
    final text = InAppLogConsole.instance.getAllText();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() {
      _status = '已复制 ${_logs.length} 行日志';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('日志已复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101214),
      appBar: AppBar(
        title: Text('实时日志 (${_logs.length})'),
        backgroundColor: const Color(0xFF1B1F24),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_all),
            onPressed: _copyAll,
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
            onPressed: _clear,
          ),
          IconButton(
            tooltip: '保存日志',
            icon: _isSaving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_alt),
            onPressed: _isSaving ? null : _save,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_status.isNotEmpty)
              Container(
                width: double.infinity,
                color: const Color(0xFF24313B),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: SelectableText(
                  _status,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            Expanded(
              child: _logs.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无日志',
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        return SelectableText(
                          _logs[index],
                          style: const TextStyle(
                            color: Color(0xFFE4E8ED),
                            fontSize: 12,
                            fontFamily: 'monospace',
                            height: 1.35,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
