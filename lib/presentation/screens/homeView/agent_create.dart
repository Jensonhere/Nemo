import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:voicegpt/core/models/private_agent_profile.dart';
import 'package:voicegpt/core/notifiers/user.notifier.dart';
import 'package:voicegpt/core/storage/preference_manager.dart';
import 'package:voicegpt/core/utils/message_helper.dart';

class AgentCreatePage extends StatefulWidget {
  const AgentCreatePage({super.key});

  @override
  State<AgentCreatePage> createState() => _AgentCreatePageState();
}

class _AgentCreatePageState extends State<AgentCreatePage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _personaController = TextEditingController();

  String _style = 'friendly';
  String? _voice;
  bool _isSaving = false;

  @override
  void dispose() {
    _nameController.dispose();
    _personaController.dispose();
    super.dispose();
  }

  Future<void> _save(BuildContext context) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final userNotifier = context.read<UserNotifier>();
    final user = userNotifier.currentUser;
    final prefs = PreferenceManager();

    if (user == null) {
      MessageHelper.showError(context, '请先登录后再创建私人智能体');
      return;
    }

    setState(() => _isSaving = true);

    final profile = PrivateAgentProfile(
      userId: user.id,
      name: _nameController.text.trim(),
      persona: _personaController.text.trim(),
      style: _style,
      voice: _voice,
      updatedAt: DateTime.now(),
    );

    final ok = await prefs.setPrivateAgentProfileModel(profile);
    if (!mounted) return;

    setState(() => _isSaving = false);
    if (!ok) {
      MessageHelper.showError(context, '保存失败：私人智能体配置无效');
      return;
    }

    MessageHelper.showSuccess(context, '私人智能体已保存');
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<UserNotifier>().currentUser;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('私人智能体创建'),
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: '智能体名称',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return '请输入名称';
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _personaController,
                  minLines: 4,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '人设描述（persona）',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return '请输入人设描述';
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: _style,
                  decoration: const InputDecoration(
                    labelText: '对话风格',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'friendly', child: Text('友好型')),
                    DropdownMenuItem(value: 'professional', child: Text('专业型')),
                    DropdownMenuItem(value: 'humorous', child: Text('幽默型')),
                    DropdownMenuItem(value: 'caring', child: Text('关怀型')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _style = v);
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  decoration: const InputDecoration(
                    labelText: '语音（可选）',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => _voice = v.trim().isEmpty ? null : v.trim(),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _isSaving ? null : () => _save(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue[600],
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 2,
                    ),
                    child: _isSaving
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            user == null ? '请先登录' : '保存私人智能体',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
