import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:voicegpt/app/routes/app.routes.dart';
import 'package:voicegpt/core/notifiers/user.notifier.dart';
import 'package:voicegpt/core/utils/message_helper.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login(BuildContext context) async {
    final userNotifier = context.read<UserNotifier>();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final result = await userNotifier.login(
      _usernameController.text.trim(),
      _passwordController.text,
    );

    if (!mounted) return;
    if (result.success) {
      MessageHelper.showSuccess(context, '登录成功');
      Navigator.of(context).pushReplacementNamed(
        AppRoutes.postLoginDecisionRoute,
      );
    } else {
      MessageHelper.showError(
        context,
        userNotifier.errorMessage ?? '登录失败',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('登录'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      body: SafeArea(
        child: Consumer<UserNotifier>(
          builder: (context, userNotifier, _) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 20),
                    const Text(
                      'VoiceGPT',
                      style:
                          TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),
                    TextFormField(
                      controller: _usernameController,
                      enabled: !userNotifier.isLoading,
                      decoration: const InputDecoration(
                        labelText: '用户名/邮箱',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return '请输入用户名或邮箱';
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      enabled: !userNotifier.isLoading,
                      decoration: const InputDecoration(
                        labelText: '密码',
                        border: OutlineInputBorder(),
                      ),
                      obscureText: true,
                      validator: (v) {
                        if (v == null || v.isEmpty) return '请输入密码';
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: userNotifier.isLoading
                            ? null
                            : () => _login(context),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue[600],
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: userNotifier.isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white),
                                ),
                              )
                            : const Text(
                                '登录',
                                style: TextStyle(fontSize: 16),
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: userNotifier.isLoading
                          ? null
                          : () {
                              Navigator.of(context)
                                  .pushNamed(AppRoutes.registerRoute);
                            },
                      child: const Text('还没有账号？立即注册'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
