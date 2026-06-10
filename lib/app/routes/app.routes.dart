import 'package:voicegpt/presentation/screens/debug_log/debug_log_view.dart';
import 'package:voicegpt/presentation/screens/homeView/agent_create.dart';
import 'package:voicegpt/presentation/screens/homeView/home.view.dart';
import 'package:voicegpt/presentation/screens/loginView/ai_setup.dart';
import 'package:voicegpt/presentation/screens/loginView/login_screen.dart';
import 'package:voicegpt/presentation/screens/loginView/post_login_decision.dart';
import 'package:voicegpt/presentation/screens/loginView/register_screen.dart';
import 'package:voicegpt/presentation/screens/loginView/user_setup.dart';
import 'package:voicegpt/presentation/screens/loginView/voice_create.dart';
import 'package:voicegpt/presentation/screens/loginView/voice_setup.dart';
import 'package:voicegpt/presentation/screens/settingsView/settings.view.dart';
import 'package:voicegpt/presentation/screens/splashView/splash.view.dart';

class AppRoutes {
  static const String splashRoute = "/splash";
  static const String homeRoute = "/home";
  static const String settingsRoute = "/settings";
  static const String debugLogRoute = "/debug-log";

  static const String loginRoute = "/login";
  static const String registerRoute = "/register";
  static const String postLoginDecisionRoute = "/post-login-decision";

  static const String setupRoute = "/setup";
  static const String voiceRoute = "/voicesetup";
  static const String voicecreateRoute = "/voicecreate";
  static const String userRoute = "/usersetup";
  static const String privateAgentCreateRoute = "/private-agent-create";

  static final routes = {
    splashRoute: (context) => const SplashView(),
    homeRoute: (context) => const HomeView(),
    settingsRoute: (context) => const SettingsView(),
    debugLogRoute: (context) => const DebugLogView(),
    loginRoute: (context) => const LoginScreen(),
    registerRoute: (context) => const RegisterScreen(),
    postLoginDecisionRoute: (context) => const PostLoginDecisionScreen(),
    setupRoute: (context) => const PersonSetupPage(),
    voiceRoute: (context) => const VoiceSetupPage(),
    voicecreateRoute: (context) => const VoiceCreatePage(),
    userRoute: (context) => const UserSetupPage(),
    privateAgentCreateRoute: (context) => const AgentCreatePage(),
  };
}
