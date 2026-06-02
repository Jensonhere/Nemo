import 'package:voicegpt/presentation/screens/debug_log/debug_log_view.dart';
import 'package:voicegpt/presentation/screens/homeView/home.view.dart';
import 'package:voicegpt/presentation/screens/splashView/splash.view.dart';

class AppRoutes {
  static const String splashRoute = "/splash";
  static const String homeRoute = "/home";
  static const String debugLogRoute = "/debug-log";

  static final routes = {
    splashRoute: (context) => const SplashView(),
    homeRoute: (context) => const HomeView(),
    debugLogRoute: (context) => const DebugLogView(),
  };
}
