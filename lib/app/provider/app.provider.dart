import 'package:provider/provider.dart';
import 'package:voicegpt/core/notifiers/openai.notifier.dart';
import 'package:voicegpt/core/notifiers/speech_notifier_simplified.dart';
import 'package:voicegpt/core/notifiers/user.notifier.dart';
import 'package:voicegpt/core/modules/ui_animation_module.dart';
import 'package:voicegpt/core/modules/conversation_controller.dart';

class AppProvider {
  static List<ChangeNotifierProvider> providers = [
    ChangeNotifierProvider<OpenAINotifier>(
      create: (_) => OpenAINotifier(),
    ),
    ChangeNotifierProvider<SpeechNotifierSimplified>(
      create: (_) => SpeechNotifierSimplified(),
    ),
    ChangeNotifierProvider<UIAnimationModule>(
      create: (_) => UIAnimationModule(),
    ),
    ChangeNotifierProvider<ConversationController>(
      create: (_) => ConversationController(),
    ),
    ChangeNotifierProvider<UserNotifier>(
      create: (_) => UserNotifier(),
    ),
  ];
}
