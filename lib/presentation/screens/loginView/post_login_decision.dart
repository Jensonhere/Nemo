import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:voicegpt/app/routes/app.routes.dart';
import 'package:voicegpt/core/notifiers/user.notifier.dart';

/// 登录后决策页面
/// 当前实现：恢复会话完成后统一进入主界面（home）
class PostLoginDecisionScreen extends StatefulWidget {
  const PostLoginDecisionScreen({super.key});

  @override
  State<PostLoginDecisionScreen> createState() =>
      _PostLoginDecisionScreenState();
}

class _PostLoginDecisionScreenState extends State<PostLoginDecisionScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final userNotifier = context.read<UserNotifier>();
      await userNotifier.restoreSession();
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(AppRoutes.homeRoute);
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在加载...'),
          ],
        ),
      ),
    );
  }
}
