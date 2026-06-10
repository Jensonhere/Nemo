import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:voicegpt/app/routes/app.routes.dart';
import 'package:voicegpt/core/notifiers/user.notifier.dart';
import 'package:voicegpt/core/storage/preference_manager.dart';
import 'package:voicegpt/core/models/login_result.dart';
import 'package:voicegpt/core/utils/message_helper.dart';
import 'package:voicegpt/presentation/widgets/setting_item.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final PreferenceManager _prefs = PreferenceManager();

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
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.grey[900],
          foregroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: const Text('设置'),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingSection(
                  title: '语音设置',
                  icon: Icons.volume_up,
                  children: [
                    SettingSwitch(
                      title: '语音播报 (TTS)',
                      value: _prefs.getTtsEnabled(),
                      onChanged: (value) async {
                        await _prefs.setTtsEnabled(value);
                        setState(() {});
                      },
                    ),
                    SettingSwitch(
                      title: '唤醒词检测',
                      value: _prefs.getWakeWordEnabled(),
                      onChanged: (value) async {
                        await _prefs.setWakeWordEnabled(value);
                        setState(() {});
                      },
                    ),
                    SettingSlider(
                      title: '语音音量',
                      value: _prefs.getTtsVolume(),
                      min: 0.0,
                      max: 1.0,
                      divisions: 10,
                      labelBuilder: (v) => v.toStringAsFixed(1),
                      onChanged: (v) async {
                        await _prefs.setTtsVolume(v);
                        setState(() {});
                      },
                    ),
                    SettingSlider(
                      title: '语音语速',
                      value: _prefs.getTtsSpeed(),
                      min: -1.0,
                      max: 1.0,
                      divisions: 20,
                      labelBuilder: (v) => v.toStringAsFixed(1),
                      onChanged: (v) async {
                        await _prefs.setTtsSpeed(v);
                        setState(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SettingSection(
                  title: '对话设置',
                  icon: Icons.chat,
                  children: [
                    SettingSlider(
                      title: '对话超时时间',
                      value: _prefs.getConversationTimeout().toDouble(),
                      min: 5,
                      max: 30,
                      divisions: 25,
                      labelBuilder: (v) => '${v.toInt()}秒',
                      onChanged: (v) async {
                        await _prefs.setConversationTimeout(v.toInt());
                        setState(() {});
                      },
                    ),
                    SettingSwitch(
                      title: '自动开始监听',
                      value: _prefs.getAutoStartListening(),
                      onChanged: (value) async {
                        await _prefs.setAutoStartListening(value);
                        setState(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SettingSection(
                  title: '功能开关',
                  icon: Icons.toggle_on,
                  children: [
                    SettingSwitch(
                      title: '手势识别',
                      value: _prefs.getGestureRecognitionEnabled(),
                      onChanged: (value) async {
                        await _prefs.setGestureRecognitionEnabled(value);
                        setState(() {});
                      },
                    ),
                    SettingSwitch(
                      title: '情绪识别',
                      value: _prefs.getEmotionRecognitionEnabled(),
                      onChanged: (value) async {
                        await _prefs.setEmotionRecognitionEnabled(value);
                        setState(() {});
                      },
                    ),
                    SettingSwitch(
                      title: '环境监测',
                      value: _prefs.getEnvironmentMonitoringEnabled(),
                      onChanged: (value) async {
                        await _prefs.setEnvironmentMonitoringEnabled(value);
                        setState(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SettingSection(
                  title: '机器人设置',
                  icon: Icons.smart_toy,
                  children: [
                    SettingInput(
                      title: '机器人名称',
                      value: _prefs.getRobotName(),
                      onChanged: (v) async {
                        await _prefs.setRobotName(v);
                        setState(() {});
                      },
                    ),
                    SettingDropdown<String>(
                      title: '机器人性格',
                      value: _prefs.getRobotPersonality(),
                      items: const [
                        DropdownMenuItem(value: 'friendly', child: Text('友好型')),
                        DropdownMenuItem(
                            value: 'professional', child: Text('专业型')),
                        DropdownMenuItem(value: 'humorous', child: Text('幽默型')),
                        DropdownMenuItem(value: 'caring', child: Text('关怀型')),
                      ],
                      onChanged: (v) async {
                        if (v == null) return;
                        await _prefs.setRobotPersonality(v);
                        setState(() {});
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // 私人智能体
                _buildPrivateAgentBlock(context, user),
                const SizedBox(height: 16),

                // 登录/注册/退出
                _buildAuthActions(userNotifier, user),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrivateAgentBlock(BuildContext context, User? user) {
    return FutureBuilder(
      future: _prefs.getPrivateAgentProfileModel(user?.id ?? ''),
      builder: (context, snapshot) {
        final profile = snapshot.data;
        final subtitle = user == null ? '未登录' : (profile?.name ?? '未创建');

        return Container(
          decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.person_search, color: Colors.blue),
                title: const Text(
                  '私人智能体',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
                ),
                subtitle:
                    Text(subtitle, style: const TextStyle(color: Colors.grey)),
                trailing:
                    const Icon(Icons.chevron_right, color: Colors.white70),
                onTap: () {
                  Navigator.of(context)
                      .pushNamed(AppRoutes.privateAgentCreateRoute);
                },
              ),
            ],
          ),
        );
      },
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
            backgroundColor: Colors.blue[700],
            padding: const EdgeInsets.symmetric(vertical: 14),
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
            side: BorderSide(color: Colors.blue[400]!),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        if (isLoggedIn) ...[
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () async {
                await userNotifier.logout();
                if (!mounted) return;
                MessageHelper.showInfo(context, '已退出登录');
                if (mounted) {
                  Navigator.of(context).pushNamedAndRemoveUntil(
                    AppRoutes.postLoginDecisionRoute,
                    (route) => false,
                  );
                }
              },
              icon: const Icon(Icons.logout),
              label: const Text('退出当前登录'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red[800],
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (user != null)
            Text(
              '当前登录：${user.username.isNotEmpty ? user.username : user.id}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
        ],
      ],
    );
  }
}
