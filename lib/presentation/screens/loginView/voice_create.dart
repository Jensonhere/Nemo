import 'package:flutter/material.dart';
import 'package:voicegpt/app/routes/app.routes.dart';

class VoiceCreatePage extends StatefulWidget {
  const VoiceCreatePage({super.key});

  @override
  State<VoiceCreatePage> createState() => _VoiceCreatePageState();
}

class _VoiceCreatePageState extends State<VoiceCreatePage> {
  String? _selectedFileName;
  final _nameController = TextEditingController(text: '我的自定义语音');

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择语音文件（示例）'),
        children: [
          ListTile(
            leading: const Icon(Icons.audio_file),
            title: const Text('example_1.wav'),
            onTap: () => Navigator.pop(ctx, 'example_1.wav'),
          ),
          ListTile(
            leading: const Icon(Icons.audio_file),
            title: const Text('example_2.mp3'),
            onTap: () => Navigator.pop(ctx, 'example_2.mp3'),
          ),
          ListTile(
            leading: const Icon(Icons.cancel),
            title: const Text('取消'),
            onTap: () => Navigator.pop(ctx, null),
          ),
        ],
      ),
    );

    if (!mounted) return;
    setState(() => _selectedFileName = result);
  }

  void _create() {
    if (_selectedFileName == null || _nameController.text.trim().isEmpty) {
      return;
    }

    Navigator.of(context).pushReplacementNamed(AppRoutes.userRoute);
  }

  @override
  Widget build(BuildContext context) {
    final canCreate =
        _selectedFileName != null && _nameController.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('创建自定义语音'),
        backgroundColor: Colors.deepPurple[700],
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '上传您的语音文件并调整参数（示例实现）',
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: '语音名称',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 18),
              GestureDetector(
                onTap: _pickFile,
                child: Container(
                  width: double.infinity,
                  height: 120,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: Colors.grey[50],
                    border: Border.all(
                      color: _selectedFileName == null
                          ? Colors.grey[300]!
                          : Colors.green,
                      width: 2,
                    ),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: _selectedFileName == null
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              Icon(Icons.cloud_upload,
                                  size: 38, color: Colors.grey),
                              SizedBox(height: 10),
                              Text('点击选择语音文件'),
                            ],
                          ),
                        )
                      : Row(
                          children: [
                            const Icon(Icons.audio_file, color: Colors.green),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _selectedFileName!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              onPressed: () =>
                                  setState(() => _selectedFileName = null),
                              icon: const Icon(Icons.delete, color: Colors.red),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: canCreate ? _create : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        canCreate ? Colors.deepPurple : Colors.grey[400],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 2,
                  ),
                  child: const Text(
                    '创建语音并继续',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
