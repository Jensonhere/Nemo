import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:voicegpt/app/routes/app.routes.dart';
import 'package:voicegpt/core/models/conversation_history_turn.dart';
import 'package:voicegpt/core/models/login_result.dart';
import 'package:voicegpt/core/models/tts_voice_option.dart';
import 'package:voicegpt/core/modules/conversation_controller.dart';
import 'package:voicegpt/core/notifiers/user.notifier.dart';
import 'package:voicegpt/core/storage/preference_manager.dart';
import 'package:voicegpt/core/utils/message_helper.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final PreferenceManager _prefs = PreferenceManager();

  static const Color _bg = Color(0xFF0E1116);
  static const Color _panel = Color(0xFF181D24);
  static const Color _panelSoft = Color(0xFF202734);
  static const Color _line = Color(0xFF2B3442);
  static const Color _text = Color(0xFFF4F7FB);
  static const Color _muted = Color(0xFF9CA9B8);
  static const Color _accent = Color(0xFF4DB7C8);
  static const Color _warm = Color(0xFFF0B45A);

  @override
  Widget build(BuildContext context) {
    final userNotifier = context.watch<UserNotifier>();
    final user = userNotifier.currentUser;

    return WillPopScope(
      onWillPop: () async {
        Navigator.of(context).maybePop();
        return true;
      },
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _bg,
          foregroundColor: _text,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: const Text(
            '设置',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildAccountSummary(user),
                const SizedBox(height: 14),
                _buildVoiceSection(context),
                const SizedBox(height: 14),
                _buildFeatureSection(),
                const SizedBox(height: 14),
                _buildRobotSection(),
                const SizedBox(height: 14),
                _buildPrivateAgentBlock(context, user),
                const SizedBox(height: 14),
                _buildHistorySection(user),
                const SizedBox(height: 18),
                _buildAuthActions(userNotifier, user),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAccountSummary(User? user) {
    final loggedIn = user != null;
    final displayName =
        loggedIn ? (user.username.isNotEmpty ? user.username : user.id) : '未登录';
    final detail = loggedIn ? user.email : '登录后可使用账号独立历史记录';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: loggedIn ? _accent.withOpacity(0.18) : _panelSoft,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              loggedIn ? Icons.person : Icons.person_outline,
              color: loggedIn ? _accent : _muted,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 13),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: loggedIn ? _accent.withOpacity(0.14) : _panelSoft,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: loggedIn ? _accent.withOpacity(0.45) : _line,
              ),
            ),
            child: Text(
              loggedIn ? '已登录' : '访客',
              style: TextStyle(
                color: loggedIn ? _accent : _muted,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVoiceSection(BuildContext context) {
    final selected = _prefs.getTtsVoiceOption();

    return _settingsPanel(
      icon: Icons.record_voice_over,
      title: '语音声线',
      subtitle: '音量跟随系统，应用内不再单独调节音量或语速',
      children: [
        _systemVolumeRow(),
        const SizedBox(height: 12),
        ...ttsVoiceOptions.map(
          (option) => _voiceOptionTile(
            context,
            option,
            selected.voiceType == option.voiceType,
          ),
        ),
      ],
    );
  }

  Widget _systemVolumeRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: _panelSoft,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: const Row(
        children: [
          Icon(Icons.volume_up_outlined, color: _warm, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              '语音音量',
              style: TextStyle(
                color: _text,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            '跟随系统',
            style: TextStyle(color: _warm, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _voiceOptionTile(
    BuildContext context,
    TtsVoiceOption option,
    bool selected,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected ? _accent.withOpacity(0.14) : _panelSoft,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () async {
            await _prefs.setTtsVoiceType(option.voiceType);
            if (!mounted) return;
            unawaited(
              context
                  .read<ConversationController>()
                  .updateTtsVoiceType(option.voiceType),
            );
            setState(() {});
            MessageHelper.showInfo(context, '已切换为${option.name}');
          },
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? _accent : _line,
                width: selected ? 1.4 : 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? _accent.withOpacity(0.18) : _bg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    option.category.contains('男') ? Icons.male : Icons.female,
                    color: selected ? _accent : _muted,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              option.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _text,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            option.category,
                            style: TextStyle(
                              color: selected ? _accent : _muted,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        option.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _muted,
                          fontSize: 12,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected ? _accent : _muted,
                  size: 21,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureSection() {
    return _settingsPanel(
      icon: Icons.tune,
      title: '功能开关',
      subtitle: '控制识别、感知和环境相关能力',
      children: [
        _switchRow(
          icon: Icons.front_hand_outlined,
          title: '手势识别',
          value: _prefs.getGestureRecognitionEnabled(),
          onChanged: (value) async {
            await _prefs.setGestureRecognitionEnabled(value);
            setState(() {});
          },
        ),
        _divider(),
        _switchRow(
          icon: Icons.mood_outlined,
          title: '情绪识别',
          value: _prefs.getEmotionRecognitionEnabled(),
          onChanged: (value) async {
            await _prefs.setEmotionRecognitionEnabled(value);
            setState(() {});
          },
        ),
        _divider(),
        _switchRow(
          icon: Icons.sensors_outlined,
          title: '环境监测',
          value: _prefs.getEnvironmentMonitoringEnabled(),
          onChanged: (value) async {
            await _prefs.setEnvironmentMonitoringEnabled(value);
            setState(() {});
          },
        ),
      ],
    );
  }

  Widget _buildRobotSection() {
    return _settingsPanel(
      icon: Icons.smart_toy_outlined,
      title: '机器人设置',
      subtitle: '名称和回复风格',
      children: [
        _navigationRow(
          icon: Icons.badge_outlined,
          title: '机器人名称',
          value: _prefs.getRobotName(),
          onTap: _showRobotNameDialog,
        ),
        _divider(),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.psychology_outlined, color: _muted, size: 22),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '机器人性格',
                  style: TextStyle(
                    color: _text,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 128,
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: _panelSoft,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _line),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _prefs.getRobotPersonality(),
                    isExpanded: true,
                    dropdownColor: _panel,
                    iconEnabledColor: _muted,
                    style: const TextStyle(
                      color: _text,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                    items: const [
                      DropdownMenuItem(value: 'friendly', child: Text('友好型')),
                      DropdownMenuItem(
                        value: 'professional',
                        child: Text('专业型'),
                      ),
                      DropdownMenuItem(value: 'humorous', child: Text('幽默型')),
                      DropdownMenuItem(value: 'caring', child: Text('关怀型')),
                    ],
                    onChanged: (value) async {
                      if (value == null) return;
                      await _prefs.setRobotPersonality(value);
                      setState(() {});
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showRobotNameDialog() async {
    final controller = TextEditingController(text: _prefs.getRobotName());
    final value = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: _panel,
          title: const Text('机器人名称', style: TextStyle(color: _text)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: _text),
            decoration: InputDecoration(
              filled: true,
              fillColor: _panelSoft,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _line),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _accent),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (value == null) return;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    await _prefs.setRobotName(trimmed);
    if (mounted) setState(() {});
  }

  Widget _buildPrivateAgentBlock(BuildContext context, User? user) {
    return FutureBuilder(
      future: _prefs.getPrivateAgentProfileModel(user?.id ?? ''),
      builder: (context, snapshot) {
        final profile = snapshot.data;
        final subtitle = user == null ? '未登录' : (profile?.name ?? '未创建');

        return _settingsPanel(
          icon: Icons.person_search_outlined,
          title: '私人智能体',
          subtitle: '当前状态：$subtitle',
          children: [
            _navigationRow(
              icon: Icons.auto_awesome_outlined,
              title: '智能体资料',
              value: user == null ? '登录后设置' : '进入编辑',
              onTap: () {
                Navigator.of(context).pushNamed(
                  AppRoutes.privateAgentCreateRoute,
                );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildHistorySection(User? user) {
    if (user == null) {
      return _settingsPanel(
        icon: Icons.history,
        title: '对话历史',
        subtitle: '登录后显示当前账号的历史记录',
        children: [_emptyState('未登录账号')],
      );
    }

    return FutureBuilder<List<ConversationHistoryTurn>>(
      future: _prefs.getConversationHistory(user.id),
      builder: (context, snapshot) {
        final history = snapshot.data ?? const <ConversationHistoryTurn>[];
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        final visibleHistory = history.take(8).toList(growable: false);

        return _settingsPanel(
          icon: Icons.history,
          title: '对话历史',
          subtitle: isLoading ? '正在读取当前账号的历史记录' : '当前账号已保存 ${history.length} 条',
          trailing: history.isEmpty
              ? null
              : TextButton.icon(
                  onPressed: () => _confirmClearHistory(user),
                  icon: const Icon(Icons.delete_outline, size: 17),
                  label: const Text('清空'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
          children: [
            if (isLoading)
              _emptyState('正在读取历史记录')
            else if (history.isEmpty)
              _emptyState('暂无历史对话')
            else
              for (var i = 0; i < visibleHistory.length; i++) ...[
                if (i > 0) _divider(),
                _historyTurnTile(visibleHistory[i]),
              ],
          ],
        );
      },
    );
  }

  Widget _historyTurnTile(ConversationHistoryTurn turn) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.schedule, size: 15, color: _muted),
              const SizedBox(width: 6),
              Text(
                _formatHistoryTime(turn.createdAt),
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '你：${turn.userText}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _text,
              fontSize: 13,
              height: 1.35,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            '小航：${turn.assistantText}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _muted,
              fontSize: 13,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearHistory(User user) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: _panel,
          title: const Text('清空对话历史', style: TextStyle(color: _text)),
          content: const Text(
            '将删除当前账号的本地对话历史。',
            style: TextStyle(color: _muted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child:
                  const Text('清空', style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    await _prefs.clearConversationHistory(user.id);
    if (!mounted) return;
    setState(() {});
    MessageHelper.showInfo(context, '已清空当前账号历史');
  }

  Widget _emptyState(String text) {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(
        text,
        style: const TextStyle(color: _muted, fontSize: 13),
      ),
    );
  }

  Widget _buildAuthActions(UserNotifier userNotifier, User? user) {
    final isLoggedIn = userNotifier.isLoggedIn;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton.icon(
          onPressed: () {
            Navigator.of(context).pushNamed(AppRoutes.loginRoute);
          },
          icon: const Icon(Icons.login),
          label: Text(isLoggedIn ? '切换账号' : '登录账号'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _accent,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () {
            Navigator.of(context).pushNamed(AppRoutes.registerRoute);
          },
          icon: const Icon(Icons.app_registration),
          label: const Text('注册新账号'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _text,
            side: const BorderSide(color: _line),
            padding: const EdgeInsets.symmetric(vertical: 13),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        if (isLoggedIn) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () async {
              await userNotifier.logout();
              if (!mounted) return;
              MessageHelper.showInfo(context, '已退出登录');
              Navigator.of(context).pushNamedAndRemoveUntil(
                AppRoutes.postLoginDecisionRoute,
                (route) => false,
              );
            },
            icon: const Icon(Icons.logout),
            label: const Text('退出当前登录'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _settingsPanel({
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Widget> children,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: _accent, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: _text,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _muted,
                        fontSize: 12,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _switchRow({
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: _muted, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                color: _text,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Switch.adaptive(
            value: value,
            activeColor: _accent,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _navigationRow({
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: _muted, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: _muted, fontSize: 13),
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right, color: _muted, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _divider() {
    return const Divider(height: 1, thickness: 1, color: _line);
  }

  String _formatHistoryTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    final now = DateTime.now();
    final sameDay =
        now.year == time.year && now.month == time.month && now.day == time.day;
    final clock = '${two(time.hour)}:${two(time.minute)}';
    if (sameDay) return clock;
    return '${two(time.month)}-${two(time.day)} $clock';
  }
}
