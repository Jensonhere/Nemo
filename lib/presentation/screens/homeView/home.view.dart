import 'dart:async';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import 'package:voicegpt/app/routes/app.routes.dart';
import 'package:voicegpt/core/notifiers/openai.notifier.dart';
import 'package:voicegpt/core/notifiers/speech_notifier_simplified.dart';
import 'package:voicegpt/presentation/widgets/owner_voiceprint_library_panel.dart';
import 'package:voicegpt/core/services/fullscreen_service.dart';
import 'package:voicegpt/core/services/bluetooth_service.dart';
import 'package:voicegpt/presentation/widgets/connection_permission_status_strip.dart';

class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  String _currentAnimation = 'assets/emotion/face2/眨眼.json'; // 初始表情
  Timer? _animationTimer;
  bool _isExitingChat = false;
  String? _lastSpecialEmotion; // 记录上次的特殊表情
  bool _hasSpecialEmotionInCurrentResponse = false; // 当前回答中是否有特殊表情
  // 新增：负能量分阶段控制变量
  String _negativeEmotionStage = 'none'; // none, stage1, stage2
  Timer? _negativeEmotionTimer;

  // 新增：正能量分阶段控制变量
  String _positiveEmotionStage = 'none'; // none, stage1, stage2
  Timer? _positiveEmotionTimer;

  // 新增：违规词汇分阶段控制变量
  String _inappropriateEmotionStage = 'none'; // none, stage1, stage2
  Timer? _inappropriateEmotionTimer;

  // 新增：指令型词汇分阶段控制变量
  String _commandEmotionStage = 'none'; // none, stage1, stage2
  Timer? _commandEmotionTimer;

  // 新增：正常聊天分阶段控制变量
  String _normalChatEmotionStage = 'none'; // none, stage1, stage2
  Timer? _normalChatEmotionTimer;

  // 新增：唤醒词响应分阶段控制变量
  String _wakeUpEmotionStage = 'none'; // none, stage1, stage2
  Timer? _wakeUpEmotionTimer;

  bool get _legacyKeywordEmotionsWhenIdle => false;

  @override
  void initState() {
    super.initState();

    // 初始化全屏服务
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FullscreenService().enableFullscreen();
    });

    // 在 widget 初始化后，延迟初始化 GestureService 和 SpeechNotifier
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) {
        final speechNotifier =
            Provider.of<SpeechNotifierSimplified>(context, listen: false);

        // === 新增：设置蓝牙服务 ===
        final bluetoothService =
            Provider.of<MyBluetoothService>(context, listen: false);
        speechNotifier.setBluetoothService(bluetoothService);
        print("🔗 已将蓝牙服务传递给语音通知器");

        // === 关键修复：初始化 SpeechNotifierSimplified ===
        print("🎤 开始初始化语音通知器...");
        await speechNotifier.initialize();
        print("✅ 语音通知器初始化完成");

        // 调用 SpeechNotifierSimplified 中的方法来初始化手势服务
        speechNotifier.initializeGestureService(context); // 传递 context
        // 注意：手势识别服务的启动由语音命令 "手势识别" 触发

        // === 新增：设置界面线程服务的回调函数 ===
        // 通过SpeechNotifierSimplified设置界面线程服务回调
        speechNotifier.setInterfaceServiceCallback((String animationPath) {
          if (mounted) {
            setState(() {
              _currentAnimation = animationPath;
              print('🎭 UI层收到界面线程服务通知，切换到表情: $animationPath');
            });
          }
        });
        print('🎭 界面线程服务回调函数设置完成');
      }
    });
  }

  @override
  void dispose() {
    _animationTimer?.cancel();
    _negativeEmotionTimer?.cancel();
    _positiveEmotionTimer?.cancel();
    _inappropriateEmotionTimer?.cancel();
    _commandEmotionTimer?.cancel();
    _normalChatEmotionTimer?.cancel();
    _wakeUpEmotionTimer?.cancel();
    super.dispose();
  }

  // 切换动画的方法
  void _switchAnimation(String animationPath, {Duration? duration}) {
    setState(() {
      _currentAnimation = animationPath;
    });
    // 如果指定了持续时间，则在指定时间后恢复到默认状态
    if (duration != null) {
      _animationTimer?.cancel();
      _animationTimer = Timer(duration, () {
        if (mounted) {
          setState(() {
            _currentAnimation = 'assets/emotion/face2/眨眼.json'; // 恢复到默认表情
          });
        }
      });
    }
  }

  // 获取当前应该显示的表情动画
  String _getCurrentAnimation(SpeechNotifierSimplified speechNotifier) {
    final speech = speechNotifier;
    final input = speech.getTextSpeech;
    final isWakeUp = speech.isWakeUpActive;
    final isChatting = speech.isInConversationMode;
    final isTtsPlaying = speech.isTtsPlaying;
    final isListening = speech.isListening;
    final isInappropriate = speech.isInappropriateContent;
    final isEnvironmentMonitoring = speech.isEnvironmentMonitoring;
    final currentExpression = speech.currentExpression;

    // 全局状态重置：如果在聊天模式但仍在退出状态，强制重置
    if (isChatting && _isExitingChat) {
      print('🔄 全局状态重置：检测到聊天模式下的退出状态，强制重置');
      _isExitingChat = false;
    }
    // 调试信息
    print('🔍 表情切换调试信息:');
    print('  - 输入文本: "$input"');
    print('  - 唤醒状态: $isWakeUp');
    print('  - 聊天模式: $isChatting');
    print('  - TTS播放: $isTtsPlaying');
    print('  - 监听状态: $isListening');
    print('  - 环境监测: $isEnvironmentMonitoring');
    print('  - 违规内容: $isInappropriate');
    print('  - 退出聊天: $_isExitingChat');
    print('  - 当前回答有特殊表情: $_hasSpecialEmotionInCurrentResponse');
    print('  - 上次特殊表情: $_lastSpecialEmotion');
    print('  - 当前界面线程动画: $_currentAnimation');

    // 0. 最高优先级：如果设置了currentExpression，直接使用它
    if (currentExpression != null) {
      print('🎭 显示用户监测反馈表情: ${currentExpression}');
      // 重置特殊表情状态，避免冲突
      _hasSpecialEmotionInCurrentResponse = false;
      _lastSpecialEmotion = null;
      return currentExpression;
    }

    if (isEnvironmentMonitoring) {
      if (_isExitingChat) {
        print('🔄 环境监测中，清除退出聊天状态');
        _isExitingChat = false;
      }
      print('🎭 环境监测中，保持界面线程当前表情: $_currentAnimation');
      return _currentAnimation;
    }

    // 1. 检测违规行为 - 最高优先级
    if (isInappropriate) {
      print('😠 显示愤怒表情 (违规内容)');
      _hasSpecialEmotionInCurrentResponse = true;
      _lastSpecialEmotion = 'assets/emotion/face2/愤怒/01/愤怒 01.json';
      return 'assets/emotion/face2/愤怒/01/愤怒 01.json';
    }

    // 2. 连续对话模式下的界面管理 - 完全依赖新系统 UIAnimationModule
    if (isChatting) {
      // 重置退出聊天状态，确保连续对话模式正常工作
      if (_isExitingChat) {
        print('🔄 进入连续对话模式，重置退出状态');
        _isExitingChat = false;
      }

      // === 完全使用新系统：UIAnimationModule 管理所有连续对话动画 ===
      print('🎭 连续对话模式中，完全使用UIAnimationModule管理的表情: $_currentAnimation');
      return _currentAnimation;
    }

    // 3. 非连续对话模式下的原有逻辑（已关闭：简化版常态应眨眼，勿用语义尾稿误判为可爱等）
    // 检测正能量和负能量词汇 - 在非聊天模式下检测
    if (_legacyKeywordEmotionsWhenIdle &&
        input.isNotEmpty &&
        input != "等待唤醒词...") {
      // 确保所有表情阶段状态都被正确初始化
      if (_negativeEmotionStage == 'none' &&
          _positiveEmotionStage == 'none' &&
          _inappropriateEmotionStage == 'none' &&
          _commandEmotionStage == 'none' &&
          _normalChatEmotionStage == 'none' &&
          _wakeUpEmotionStage == 'none') {
        print('🔄 非连续对话模式表情状态初始化完成');
      }
      // 正能量词汇列表
      final positiveWords = [
        '开心',
        '高兴',
        '喜悦',
        '快乐',
        '愉快',
        '兴奋',
        '激动',
        '满足',
        '满意',
        '幸福',
        '欢乐',
        '欣喜',
        '愉悦',
        '舒畅',
        '爽快',
        '痛快',
        '畅快',
        '舒心',
        '安心',
        '放心',
        '欣慰',
        '安慰',
        '温暖',
        '温馨',
        '甜蜜',
        '美好',
        '美妙',
        '精彩',
        '出色',
        '优秀',
        '棒',
        '好',
        '赞',
        '棒极了',
        '太好了',
        '真棒',
        '真不错',
        '真厉害',
        '真优秀',
        '喜欢',
        '爱',
        '热爱',
        '喜爱',
        '钟爱',
        '迷恋',
        '着迷',
        '陶醉',
        '沉醉',
        '享受',
        '感恩',
        '感谢',
        '感激',
        '谢谢',
        '多谢',
        '谢谢您',
        '感谢您',
        '感激不尽',
        '感恩戴德',
        '祝福',
        '祝愿',
        '希望',
        '期待',
        '憧憬',
        '向往',
        '梦想',
        '理想',
        '目标',
        '追求',
        '成功',
        '胜利',
        '成就',
        '突破',
        '进步',
        '提升',
        '成长',
        '发展',
        '前进',
        '向前',
        '阳光',
        '明媚',
        '灿烂',
        '辉煌',
        '光明',
        '明亮',
        '清晰',
        '明朗',
        '晴朗',
        '顺利',
        '顺心',
        '顺意',
        '顺风',
        '顺畅',
        '顺手',
        '顺利完成',
        '顺利通过',
        '顺利解决',
        '顺利实现',
        '达成',
        '结束',
        '毕业',
        // 新增积极情绪词
        '自信',
        '满足',
        '感动',
        '宽容',
        '理解',
        '支持',
        '认可',
        '尊重',
        '关心',
        '被爱',
        '鼓励',
        '赞美',
        '表扬',
        '奖励',
        '帮助',
        '包容',
        '信任',
        '依靠',
        '陪伴',
        '照顾',
        '守护',
        '保护',
        '温暖',
        '感动',
        '感激',
        '感恩',
        '祝福',
        '欣赏',
        '喜欢',
        '爱护',
        '宠爱',
        '重视',
        '关注',
        '期待',
        '希望',
        '梦想',
        '实现',
        '成功',
        '成就',
        '突破',
        '进步',
        '提升',
        '成长',
        '发展',
        '前进',
        '向前',
        '阳光',
        '明媚',
        '灿烂',
        '辉煌',
        '光明',
        '明亮',
        '清晰',
        '明朗',
        '晴朗',
        '顺利',
        '顺心',
        '被顺意',
        '顺风',
        '顺畅',
        '顺手',
        '完成',
        '顺利通过',
        '解决',
        '实现',
        '达成',
        '结束',
        '毕业',
        '升学',
        '就业',
        '晋升',
        '结婚',
        '生子',
        '安家',
        '发财',
        '致富',
        '成功',
        '幸福',
        '健康',
        '平安',
        '如意',
        '吉祥',
        '美满',
        '团圆',
        '和谐',
        '安康',
        // 新增好的事情名词
        '升职',
        '加薪',
        '中奖',
        '结婚',
        '生子',
        '团聚',
        '康复',
        '治愈',
        '和解',
        '合作',
        '创新',
        '突破',
        '进步',
        '成长',
        '收获',
        '丰收',
        '喜讯',
        '喜事',
        '好消息',
        '表扬',
        '奖励',
        '荣誉',
        '嘉奖',
        '称赞',
        '赞美',
        '鼓励',
        '支持',
        '帮助',
        '关心',
        '照顾',
        '守护',
        '保护',
        '陪伴',
        '信任',
        '依靠',
        '包容',
        '理解',
        '尊重',
        '欣赏',
        '爱护',
        '宠爱',
        '重视',
        '关注',
        '期待',
        '希望',
        '梦想',
        '实现',
        '成功',
        '成就',
        '突破',
        '进步',
        '提升',
        '成长',
        '发展',
        '前进',
        '向前',
        '阳光',
        '明媚',
        '灿烂',
        '辉煌',
        '光明',
        '明亮',
        '清晰',
        '明朗',
        '晴朗',
        '顺利',
        '顺心',
        '顺意',
        '顺风',
        '顺畅',
        '顺手',
        '完成',
        '通过',
        '解决',
        '实现',
        '达成',
        '结束',
        '毕业',
        '升学',
        '就业',
        '晋升',
        '结婚',
        '生子',
        '安家',
        '发财',
        '致富',
        '成功',
        '幸福',
        '健康',
        '平安',
        '如意',
        '吉祥',
        '美满',
        '团圆',
        '和谐',
        '安康'
      ];
      // 负能量词汇列表
      final negativeWords = [
        '悲伤',
        '难过',
        '沮丧',
        '绝望',
        '失落',
        '孤独',
        '无助',
        '抑郁',
        '焦虑',
        '烦躁',
        '恐惧',
        '害怕',
        '担心',
        '紧张',
        '压力',
        '疲惫',
        '累',
        '心累',
        '心力交瘁',
        '精疲力尽',
        '无聊',
        '空虚',
        '冷漠',
        '麻木',
        '无感',
        '无望',
        '无奈',
        '无助感',
        '无力',
        '无能为力',
        '自卑',
        '自责',
        '愧疚',
        '羞愧',
        '尴尬',
        '后悔',
        '懊悔',
        '悔恨',
        '遗憾',
        '愤怒',
        '生气',
        '恼火',
        '暴躁',
        '暴怒',
        '狂怒',
        '烦',
        '烦心',
        '烦恼',
        '心烦',
        '郁闷',
        '低落',
        '消沉',
        '不安',
        '不适',
        '不舒服',
        '难受',
        '痛苦',
        '苦闷',
        '苦恼',
        '绝望',
        '崩溃',
        '恐慌',
        '惊慌',
        '惊恐',
        '惶恐',
        '惶惶',
        '惴惴',
        '惆怅',
        '惋惜',
        '哀伤',
        '哀愁',
        '哀怨',
        '哀叹',
        '哀痛',
        '哀悼',
        '哀思',
        '哀鸣',
        '哀号',
        '哀哭',
        '忧伤',
        '忧愁',
        '忧虑',
        '忧郁',
        '忧心',
        '忧闷',
        '忧苦',
        '忧伤',
        '忧郁',
        '忧心忡忡',
        '恐惧感',
        '焦虑感',
        '孤独感',
        '无助感',
        '绝望感',
        '羞耻感',
        '愧疚感',
        '自卑感',
        '疲惫感',
        '压力大',
        '压力山大',
        '心情差',
        '心情不好',
        '情绪低落',
        '情绪崩溃',
        '情绪失控',
        '情绪不稳',
        '情绪波动',
        '情绪压抑',
        '情绪紧张',
        '情绪焦虑',
        '情绪烦躁',
        '情绪疲惫',
        '情绪无力',
        '情绪无助',
        '情绪绝望',
        '情绪孤独',
        '情绪悲伤',
        '情绪难过',
        '情绪痛苦',
        '情绪苦闷',
        '情绪忧郁',
        '情绪忧伤',
        '情绪忧愁',
        '情绪忧虑',
        '情绪恐惧',
        '情绪害怕',
        '情绪担心',
        '情绪紧张',
        '情绪压力',
        '情绪麻木',
        '情绪空虚',
        '情绪冷漠',
        '情绪无感',
        '情绪无望',
        '情绪无奈',
        '情绪无能为力',
        '情绪自卑',
        '情绪自责',
        '情绪愧疚',
        '情绪羞愧',
        '情绪羞耻',
        '情绪尴尬',
        '情绪后悔',
        '情绪懊悔',
        '情绪悔恨',
        '情绪遗憾'
      ];

      // 违规词汇列表
      final inappropriateWords = [
        '傻逼',
        '笨蛋',
        '白痴',
        '蠢货',
        '废物',
        '垃圾',
        '滚蛋',
        '去死',
        '该死',
        '混蛋',
        '王八蛋',
        '狗屎',
        '放屁',
        '闭嘴',
        '滚开',
        '滚远点',
        '神经病',
        '疯子',
        '变态',
        '恶心',
        '讨厌',
        '烦人',
        '讨厌鬼',
        '烦人精',
        '讨厌死了',
        '烦死了',
        '恶心死了',
        '滚蛋吧',
        '去死吧',
        '该死的东西',
        '混蛋东西',
        '王八蛋东西',
        '狗屎东西',
        '放屁东西',
        '闭嘴东西',
        '滚开东西',
        '滚远点东西',
        '神经病东西',
        '疯子东西',
        '变态东西',
        '恶心东西',
        '讨厌东西',
        '烦人东西',
        '讨厌鬼东西',
        '烦人精东西'
      ];

      // 指令型词汇列表
      final commandWords = [
        // 前进相关
        '前进', '向前', '向前走', '往前走', '走', '直行', '前行', '往前', '前移', '前走', '当前走',
        '往前进', '向前进', '前方', '往前方', '向前方', '前面',
        // 后退相关
        '后退', '向后', '向后走', '往后走', '退', '后移', '往后', '退后', '后走', '往后退', '向后退',
        '后方', '往后方', '向后方', '后面',
        // 左转相关
        '左转', '向左转', '向左', '转左', '左移', '往左转', '左拐', '向左拐', '往左', '左边', '向左边',
        '往左边', '左面', '向左面',
        // 右转相关
        '右转', '向右转', '向右', '转右', '右移', '往右转', '右拐', '向右拐', '往右', '右边', '向右边',
        '往右边', '右面', '向右面',
        // 脑袋角度相关
        '脑袋角度', '抬头', '低头', '抬头角度', '低头角度', '头部角度', '头角度', '仰头', '俯头', '头向上',
        '头向下', '向上看', '向下看', '仰视', '俯视',
        // 点头相关
        '点头', '上下点头',
        // 转圈相关
        '转一圈', '转圈', '转一周', '旋转', '自转', '自转一周', '自转一圈', '旋转一周', '旋转一圈', '原地转'
      ];

      // 检测违规词汇
      bool hasInappropriateWords =
          inappropriateWords.any((word) => input.contains(word));
      if (hasInappropriateWords) {
        if (_inappropriateEmotionStage == 'none') {
          // 第一次检测到违规词汇，先切换为愤怒 01.json
          _inappropriateEmotionStage = 'stage1';
          _hasSpecialEmotionInCurrentResponse = true;
          _lastSpecialEmotion = 'assets/emotion/face2/愤怒/01/愤怒 01.json';
          // 启动500ms定时器，切换到愤怒 02.json
          _inappropriateEmotionTimer?.cancel();
          _inappropriateEmotionTimer = Timer(Duration(milliseconds: 500), () {
            if (mounted) {
              setState(() {
                _inappropriateEmotionStage = 'stage2';
                _lastSpecialEmotion = 'assets/emotion/face2/愤怒/02/愤怒 02.json';
              });
            }
          });
          return 'assets/emotion/face2/愤怒/01/愤怒 01.json';
        } else if (_inappropriateEmotionStage == 'stage1') {
          // 500ms内，持续显示愤怒 01.json
          return 'assets/emotion/face2/愤怒/01/愤怒 01.json';
        } else if (_inappropriateEmotionStage == 'stage2') {
          // 500ms后，持续显示愤怒 02.json
          return 'assets/emotion/face2/愤怒/02/愤怒 02.json';
        }
      }

      // 检测指令型词汇
      bool hasCommandWords = commandWords.any((word) => input.contains(word));
      if (hasCommandWords) {
        if (_commandEmotionStage == 'none') {
          // 第一次检测到指令型词汇，先切换为热切 01.json
          _commandEmotionStage = 'stage1';
          _hasSpecialEmotionInCurrentResponse = true;
          _lastSpecialEmotion = 'assets/emotion/face2/热切/01/热切 01.json';
          // 启动500ms定时器，切换到热切 2.json
          _commandEmotionTimer?.cancel();
          _commandEmotionTimer = Timer(Duration(milliseconds: 500), () {
            if (mounted) {
              setState(() {
                _commandEmotionStage = 'stage2';
                _lastSpecialEmotion = 'assets/emotion/face2/热切/02/热切 02.json';
              });
            }
          });
          return 'assets/emotion/face2/热切/01/热切 01.json';
        } else if (_commandEmotionStage == 'stage1') {
          // 500ms内，持续显示热切 01.json
          return 'assets/emotion/face2/热切/01/热切 01.json';
        } else if (_commandEmotionStage == 'stage2') {
          // 500ms后，持续显示热切 2.json
          return 'assets/emotion/face2/热切/02/热切 02.json';
        }
      }

      // 检测正能量词汇
      bool hasPositiveWords = positiveWords.any((word) => input.contains(word));
      if (hasPositiveWords) {
        if (_positiveEmotionStage == 'none') {
          // 第一次检测到正能量词汇，先切换为可爱 01.json
          _positiveEmotionStage = 'stage1';
          _hasSpecialEmotionInCurrentResponse = true;
          _lastSpecialEmotion = 'assets/emotion/face2/可爱/01/可爱 01.json';
          // 启动500ms定时器，切换到可爱 02.json
          _positiveEmotionTimer?.cancel();
          _positiveEmotionTimer = Timer(Duration(milliseconds: 500), () {
            if (mounted) {
              setState(() {
                _positiveEmotionStage = 'stage2';
                _lastSpecialEmotion = 'assets/emotion/face2/可爱/02/可爱 02.json';
              });
            }
          });
          return 'assets/emotion/face2/可爱/01/可爱 01.json';
        } else if (_positiveEmotionStage == 'stage1') {
          // 500ms内，持续显示可爱 01.json
          return 'assets/emotion/face2/可爱/01/可爱 01.json';
        } else if (_positiveEmotionStage == 'stage2') {
          // 500ms后，持续显示可爱 02.json
          return 'assets/emotion/face2/可爱/02/可爱 02.json';
        }
      }
      // 检测负能量词汇
      bool hasNegativeWords = negativeWords.any((word) => input.contains(word));
      if (hasNegativeWords) {
        if (_negativeEmotionStage == 'none') {
          // 第一次检测到负能量，先切换为失落 01.json
          _negativeEmotionStage = 'stage1';
          _hasSpecialEmotionInCurrentResponse = true;
          _lastSpecialEmotion = 'assets/emotion/face2/失落/01/失落 01.json';
          // 启动500ms定时器，切换到失落 02.json
          _negativeEmotionTimer?.cancel();
          _negativeEmotionTimer = Timer(Duration(milliseconds: 500), () {
            if (mounted) {
              setState(() {
                _negativeEmotionStage = 'stage2';
                _lastSpecialEmotion = 'assets/emotion/face2/失落/02/失落 02.json';
              });
            }
          });
          return 'assets/emotion/face2/失落/01/失落 01.json';
        } else if (_negativeEmotionStage == 'stage1') {
          // 500ms内，持续显示失落 01.json
          return 'assets/emotion/face2/失落/01/失落 01.json';
        } else if (_negativeEmotionStage == 'stage2') {
          // 500ms后，持续显示失落 02.json
          return 'assets/emotion/face2/失落/02/失落 02.json';
        }
      }

      // 检测正常聊天（没有特殊词汇时）
      bool hasSpecialWords = hasPositiveWords ||
          hasNegativeWords ||
          hasInappropriateWords ||
          hasCommandWords;
      if (!hasSpecialWords &&
          isChatting &&
          input.isNotEmpty &&
          input != "等待唤醒词...") {
        if (_normalChatEmotionStage == 'none') {
          // 第一次检测到正常聊天，先切换为说话 01.json
          _normalChatEmotionStage = 'stage1';
          _hasSpecialEmotionInCurrentResponse = true;
          _lastSpecialEmotion = 'assets/emotion/face2/说话/01/说话 01.json';
          // 启动500ms定时器，切换到说话 02.json
          _normalChatEmotionTimer?.cancel();
          _normalChatEmotionTimer = Timer(Duration(milliseconds: 500), () {
            if (mounted) {
              setState(() {
                _normalChatEmotionStage = 'stage2';
                _lastSpecialEmotion = 'assets/emotion/face2/说话/02/说话 02.json';
              });
            }
          });
          return 'assets/emotion/face2/说话/01/说话 01.json';
        } else if (_normalChatEmotionStage == 'stage1') {
          // 500ms内，持续显示说话 01.json
          return 'assets/emotion/face2/说话/01/说话 01.json';
        } else if (_normalChatEmotionStage == 'stage2') {
          // 500ms后，持续显示说话 02.json
          return 'assets/emotion/face2/说话/02/说话 02.json';
        }
      }
    }

    // 2.5. 检测唤醒词响应（仅待机态生效，避免与连续对话内 TTS 对齐逻辑打架）
    if (isWakeUp && !isChatting && !isTtsPlaying && input.contains("你好小航")) {
      if (_wakeUpEmotionStage == 'none') {
        _wakeUpEmotionStage = 'stage1';
        _hasSpecialEmotionInCurrentResponse = true;
        _lastSpecialEmotion = 'assets/emotion/face2/说话/01/说话 01.json';
        _wakeUpEmotionTimer?.cancel();
        _wakeUpEmotionTimer = Timer(const Duration(milliseconds: 500), () {
          if (mounted) {
            setState(() {
              _wakeUpEmotionStage = 'stage2';
              _lastSpecialEmotion = 'assets/emotion/face2/说话/02/说话 02.json';
            });
          }
        });
        return 'assets/emotion/face2/说话/01/说话 01.json';
      } else if (_wakeUpEmotionStage == 'stage1') {
        return 'assets/emotion/face2/说话/01/说话 01.json';
      } else if (_wakeUpEmotionStage == 'stage2') {
        return 'assets/emotion/face2/说话/02/说话 02.json';
      }
    }

    // 3. TTS播放期间的特殊处理
    if (isTtsPlaying) {
      // 环境监测反馈表情优先级最高
      if (speechNotifier.currentExpression != null) {
        print('🎭 TTS播放时使用环境监测反馈的表情');
        return speechNotifier.currentExpression!;
      }
      // 检查是否在退出聊天状态
      if (_isExitingChat) {
        print('🚪 TTS播放时处于退出聊天状态，显示眨眼.json');
        return 'assets/emotion/face2/眨眼.json';
      }
      // 其他情况使用新系统管理的动画
      return _currentAnimation;
    }
    // 4. 检测commandType - 只在聊天模式下检查（已注释，使用新的指令型词汇检测逻辑）
    /*
    if (isChatting &&
        input.isNotEmpty &&
        input != "等待唤醒词..." &&
        !_isExitingChat) {
      String? commandType = IntentService.getCommandType(input);
      print('  - 命令类型: $commandType');
      if (commandType != null) {
        // 前进/后退/左转/右转
        if (['前进', '后退', '左转', '右转'].contains(commandType)) {
          print('😱 显示震惊表情 (移动命令)');
          _hasSpecialEmotionInCurrentResponse = true;
          _lastSpecialEmotion = 'assets/face/shocked.json';
          return 'assets/face/shocked.json';
        }
        // 脑袋角度
        if (commandType == '脑袋角度') {
          print('😢 显示哭泣表情 (头部角度)');
          _hasSpecialEmotionInCurrentResponse = true;
          _lastSpecialEmotion = 'assets/face/cry1.json';
          return 'assets/face/cry1.json';
        }
      } else {
        // commandType为null时
        print('😭 显示哭泣表情 (无效命令)');
        _hasSpecialEmotionInCurrentResponse = true;
        _lastSpecialEmotion = 'assets/face/失落 02.json';
        return 'assets/face/失落 02.json';
      }
    }
    */
    // 4.5. 检测退出聊天
    final exitCommands = [
      '退出对话模式',
      '闭嘴',
      '停止对话',
      '结束对话',
      '退出',
      '不说了',
      '再见',
      '拜拜',
      '睡觉',
      '休息',
      '滚',
      '滚蛋'
    ];
    bool isExitCommand = exitCommands.any((command) => input.contains(command));

    // 检测退出聊天模式（用户说退出词汇或计时器结束自动退出）
    if (isExitCommand ||
        (!isChatting && !isTtsPlaying && _isExitingChat) ||
        _isExitingChat) {
      // 重置所有表情阶段状态
      _negativeEmotionStage = 'none';
      _positiveEmotionStage = 'none';
      _inappropriateEmotionStage = 'none';
      _commandEmotionStage = 'none';
      _normalChatEmotionStage = 'none';
      _wakeUpEmotionStage = 'none';
      _hasSpecialEmotionInCurrentResponse = false;
      _lastSpecialEmotion = null;

      print('🚪 退出聊天模式，重置所有表情状态');
      // 直接回到主界面眨眼.json
      return 'assets/emotion/face2/眨眼.json';
    }

    // 5. 唤醒词唤醒时 - 只在真正唤醒时显示
    if (isWakeUp &&
        (input.isEmpty || input == "等待唤醒词...") &&
        !isChatting &&
        !isTtsPlaying &&
        !_isExitingChat) {
      print('😄 显示默认表情 (等待唤醒)');
      return 'assets/emotion/face2/眨眼.json';
    }
    // 6. 默认状态 - 包括初始状态和退出聊天模式后的状态
    // 如果不在聊天模式且不在退出状态，显示默认表情
    if (!isChatting && !isTtsPlaying && !_isExitingChat) {
      print('😄 显示默认表情 (眨眼)');
      return 'assets/emotion/face2/眨眼.json';
    }
    // 7. 兜底状态 - 确保总是有正确的表情显示
    print('😄 显示默认表情 (眨眼) - 兜底');
    return 'assets/emotion/face2/眨眼.json';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SpeechNotifierSimplified>(
      builder: (context, speechNotifier, child) {
        // 获取当前应该显示的动画
        String animationPath = _getCurrentAnimation(speechNotifier);

        // === 修改：优化界面更新逻辑 ===
        // 如果动画路径发生变化，使用 post-frame 回调延后更新，避免在构建期间调用 setState
        if (_currentAnimation != animationPath) {
          print('🎭 UI层检测到动画路径变化: $_currentAnimation -> $animationPath');
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _currentAnimation = animationPath;
            });
          });
        }
        // 简化：TTS播放状态变化处理（仅用于非连续对话模式的特殊表情清理）
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // 如果TTS播放结束且当前有特殊表情标记（仅限非连续对话模式）
          if (!speechNotifier.isTtsPlaying &&
              _hasSpecialEmotionInCurrentResponse &&
              !speechNotifier.isInConversationMode) {
            print('🎭 TTS播放结束，清除非连续对话模式的特殊表情标记');
            _hasSpecialEmotionInCurrentResponse = false;
            _lastSpecialEmotion = null;

            // 重置所有表情阶段状态（用于环境监测等模式）
            _negativeEmotionStage = 'none';
            _positiveEmotionStage = 'none';
            _inappropriateEmotionStage = 'none';
            _commandEmotionStage = 'none';
            _normalChatEmotionStage = 'none';
            _wakeUpEmotionStage = 'none';

            // 取消所有定时器
            _negativeEmotionTimer?.cancel();
            _positiveEmotionTimer?.cancel();
            _inappropriateEmotionTimer?.cancel();
            _commandEmotionTimer?.cancel();
            _normalChatEmotionTimer?.cancel();
            _wakeUpEmotionTimer?.cancel();
          }
        });

        // 简化：连续对话模式退出检测
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // 检测从连续对话模式退出到非连续对话模式
          if (speechNotifier.isInConversationMode == false &&
              !speechNotifier.isEnvironmentMonitoring &&
              !_isExitingChat) {
            print('🚪 检测到退出连续对话模式');
            setState(() {
              _isExitingChat = true;
              _currentAnimation = 'assets/emotion/face2/眨眼.json';
            });
            print('✅ 已退出连续对话模式，回到主界面眨眼.json');
          }

          // 检测从非连续对话模式进入连续对话模式
          if (speechNotifier.isInConversationMode == true &&
              _isExitingChat == true) {
            print('🔄 检测到进入连续对话模式，重置退出状态');
            setState(() {
              _isExitingChat = false;
            });
          }

          // 强制回到默认状态：如果不在连续对话模式且不在环境监测状态
          if (speechNotifier.isInConversationMode == false &&
              !speechNotifier.isEnvironmentMonitoring &&
              !_isExitingChat &&
              speechNotifier.currentExpression == null &&
              _currentAnimation != 'assets/emotion/face2/眨眼.json') {
            print('🔄 强制切换到默认表情 (眨眼)');
            setState(() {
              _currentAnimation = 'assets/emotion/face2/眨眼.json';
            });
          }
        });
        // AI回复触发逻辑
        if (speechNotifier.isReadyToSend) {
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            final openAINotifier =
                Provider.of<OpenAINotifier>(context, listen: false);
            await openAINotifier.getResponse(
              parameter: speechNotifier.getTextSpeech,
              context: context,
            );
            speechNotifier.completeSending();
          });
        }
        return Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            left: false,
            right: false,
            child: Stack(
              children: [
                // 全屏Lottie动画背景
                Positioned.fill(
                  child: Container(
                    color: _currentAnimation.contains('失落 02.json') ||
                            _currentAnimation.contains('失落 01.json') ||
                            _currentAnimation.contains('失落.json') ||
                            _currentAnimation.contains('眨眼.json') ||
                            _currentAnimation.contains('可爱 01.json') ||
                            _currentAnimation.contains('可爱 02.json') ||
                            _currentAnimation.contains('愤怒 01.json') ||
                            _currentAnimation.contains('愤怒 02.json') ||
                            _currentAnimation.contains('热切 01.json') ||
                            _currentAnimation.contains('热切 02.json') ||
                            _currentAnimation.contains('思考 01.json') ||
                            _currentAnimation.contains('思考 02.json') ||
                            _currentAnimation.contains('说话 01.json') ||
                            _currentAnimation.contains('说话 02.json') ||
                            _currentAnimation.contains('观察 01.json') ||
                            _currentAnimation.contains('观察 02.json') ||
                            _currentAnimation.contains('坚定 01.json') ||
                            _currentAnimation.contains('坚定 02.json') ||
                            _currentAnimation.contains('惊喜 01.json') ||
                            _currentAnimation.contains('惊喜 02.json') ||
                            _currentAnimation.contains('热切.json') ||
                            _currentAnimation.contains('开心 01.json') ||
                            _currentAnimation.contains('开心 02.json') ||
                            _currentAnimation.contains('倾听 01.json') ||
                            _currentAnimation.contains('倾听 02.json') ||
                            _currentAnimation.contains('委屈 01.json') ||
                            _currentAnimation.contains('委屈 02.json') ||
                            _currentAnimation.contains('寻找 01.json') ||
                            _currentAnimation.contains('寻找 02.json') ||
                            _currentAnimation.contains('疑惑.json') ||
                            _currentAnimation.contains('晕 01.json') ||
                            _currentAnimation.contains('晕 02.json') ||
                            _currentAnimation.contains('晕.json') ||
                            _currentAnimation.contains('angry.json') ||
                            _currentAnimation.contains('cry.json') ||
                            _currentAnimation.contains('cry1.json') ||
                            _currentAnimation.contains('cry2.json') ||
                            _currentAnimation.contains('crying.json') ||
                            _currentAnimation.contains('happy.json') ||
                            _currentAnimation.contains('happy1.json') ||
                            _currentAnimation.contains('happy2.json') ||
                            _currentAnimation.contains('kiss.json') ||
                            _currentAnimation.contains('Kiss 01.json') ||
                            _currentAnimation.contains('Kiss 02.json') ||
                            _currentAnimation.contains('Love.json') ||
                            _currentAnimation.contains('sad.json') ||
                            _currentAnimation.contains('shocked.json') ||
                            _currentAnimation.contains('感激 01.json') ||
                            _currentAnimation.contains('感激 02.json') ||
                            _currentAnimation.contains('孤独 01.json') ||
                            _currentAnimation.contains('孤独 02.json')
                        ? Colors.black
                        : Colors.transparent,
                    child: Lottie.asset(
                      _currentAnimation,
                      fit: BoxFit.contain,
                      repeat: true,
                      width: MediaQuery.of(context).size.width,
                      height: MediaQuery.of(context).size.height,
                      alignment: Alignment.center,
                    ),
                  ),
                ),
                // 左上角状态信息
                _buildSpeechTextIndicator(speechNotifier),
                // 右上角：多人对话模式 + 设置
                Positioned(
                  top: 8,
                  right: 8,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '主人声纹库（1-3条）',
                        icon: Icon(
                          speechNotifier.isOwnerVoiceprintLibraryOpen
                              ? Icons.mic
                              : speechNotifier.hasOwnerVoiceprint
                                  ? Icons.mic_external_on
                                  : Icons.mic_none_outlined,
                          color: speechNotifier.isOwnerVoiceprintLibraryOpen
                              ? Colors.orangeAccent
                              : speechNotifier.isOwnerVoiceprintEnrolling
                                  ? Colors.redAccent
                                  : speechNotifier.hasOwnerVoiceprint
                                      ? Colors.lightGreenAccent
                                      : Colors.white,
                          size: 26,
                        ),
                        onPressed: speechNotifier.isOwnerVoiceprintEnrolling
                            ? null
                            : () {
                                speechNotifier.toggleOwnerVoiceprintLibrary();
                              },
                      ),
                      IconButton(
                        tooltip: '主人模式（聆听与打断均需声纹比对）',
                        icon: Icon(
                          speechNotifier.isOwnerMode
                              ? Icons.verified_user
                              : Icons.verified_user_outlined,
                          color: speechNotifier.isOwnerMode
                              ? Colors.amberAccent
                              : Colors.white,
                          size: 26,
                        ),
                        onPressed: () {
                          unawaited(
                            speechNotifier.setOwnerMode(
                              !speechNotifier.isOwnerMode,
                            ),
                          );
                        },
                      ),
                      IconButton(
                        tooltip: '主人声纹打断播报',
                        icon: Icon(
                          speechNotifier.isOwnerVoiceprintBargeInMode
                              ? Icons.fingerprint
                              : Icons.fingerprint_outlined,
                          color: speechNotifier.isOwnerVoiceprintBargeInMode
                              ? Colors.tealAccent
                              : Colors.white,
                          size: 26,
                        ),
                        onPressed: () {
                          unawaited(
                            speechNotifier.setOwnerVoiceprintBargeInMode(
                              !speechNotifier.isOwnerVoiceprintBargeInMode,
                            ),
                          );
                        },
                      ),
                      IconButton(
                        tooltip: '多人对话（按住说话）',
                        icon: Icon(
                          speechNotifier.isMultiPersonPushToTalkMode
                              ? Icons.groups
                              : Icons.groups_outlined,
                          color: speechNotifier.isMultiPersonPushToTalkMode
                              ? Colors.lightBlueAccent
                              : Colors.white,
                          size: 26,
                        ),
                        onPressed: () {
                          unawaited(
                            speechNotifier.setMultiPersonPushToTalkMode(
                              !speechNotifier.isMultiPersonPushToTalkMode,
                            ),
                          );
                        },
                      ),
                      IconButton(
                        tooltip: '日志',
                        icon: const Icon(
                          Icons.article_outlined,
                          color: Colors.white,
                          size: 26,
                        ),
                        onPressed: () {
                          Navigator.of(context).pushNamed(
                            AppRoutes.debugLogRoute,
                          );
                        },
                      ),
                      IconButton(
                        tooltip: '设置',
                        icon: const Icon(
                          Icons.settings,
                          color: Colors.white,
                          size: 26,
                        ),
                        onPressed: () {
                          Navigator.of(context).pushNamed(
                            AppRoutes.settingsRoute,
                          );
                        },
                      ),
                    ],
                  ),
                ),
                if (speechNotifier.isMultiPersonPushToTalkMode)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 24,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: _buildMultiPersonPttBar(
                        context,
                        speechNotifier,
                      ),
                    ),
                  ),
                if (speechNotifier.isOwnerVoiceprintLibraryOpen)
                  Positioned(
                    top: 96,
                    right: 6,
                    child: OwnerVoiceprintLibraryPanel(
                      speech: speechNotifier,
                    ),
                  ),
                if ((speechNotifier.isOwnerMode ||
                        speechNotifier.isOwnerVoiceprintBargeInMode) &&
                    speechNotifier.ownerVoiceprintVerifyStatusLabel != null)
                  Positioned(
                    top: 48,
                    left: 12,
                    right: 12,
                    child: Center(
                      child: _buildVoiceprintVerifyBanner(speechNotifier),
                    ),
                  ),
                if (speechNotifier.showOwnerVoiceprintStatusBanner &&
                    !speechNotifier.isOwnerVoiceprintLibraryOpen)
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom:
                        speechNotifier.isMultiPersonPushToTalkMode ? 100 : 28,
                    child:
                        _buildOwnerVoiceprintEnrollmentBanner(speechNotifier),
                  ),
                Positioned(
                  top: 52,
                  right: 16,
                  child: GestureDetector(
                    onTap: () {
                      speechNotifier.setForceEnglishTeachingMode(
                        !speechNotifier.forceEnglishTeachingMode,
                      );
                    },
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: speechNotifier.forceEnglishTeachingMode
                            ? Colors.greenAccent.withOpacity(0.9)
                            : Colors.black54,
                        borderRadius: BorderRadius.circular(17),
                        border: Border.all(
                          color: speechNotifier.forceEnglishTeachingMode
                              ? Colors.white
                              : Colors.white70,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        'E',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: speechNotifier.forceEnglishTeachingMode
                              ? Colors.black
                              : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 采录 / 提取 / 成功 / 失败状态条。
  Widget _buildOwnerVoiceprintEnrollmentBanner(
    SpeechNotifierSimplified speech,
  ) {
    final ui = speech.ownerVoiceprintUi;
    Color border;
    IconData statusIcon;
    switch (ui) {
      case OwnerVoiceprintEnrollUi.success:
        border = Colors.lightGreenAccent;
        statusIcon = Icons.check_circle_outline;
        break;
      case OwnerVoiceprintEnrollUi.failure:
        border = Colors.redAccent;
        statusIcon = Icons.error_outline;
        break;
      case OwnerVoiceprintEnrollUi.extracting:
        border = Colors.amberAccent;
        statusIcon = Icons.hourglass_top;
        break;
      case OwnerVoiceprintEnrollUi.capturing:
      case OwnerVoiceprintEnrollUi.none:
        border = Colors.orangeAccent;
        statusIcon = Icons.mic;
        break;
    }

    final showPrompt = ui == OwnerVoiceprintEnrollUi.capturing ||
        ui == OwnerVoiceprintEnrollUi.extracting;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.82),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border.withOpacity(0.9), width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(statusIcon, color: border, size: 28),
          const SizedBox(height: 8),
          if (showPrompt) ...[
            Text(
              SpeechNotifierSimplified.ownerVoiceprintEnrollmentPrompt,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (speech.ownerVoiceprintEnrollmentHint.isNotEmpty)
            Text(
              speech.ownerVoiceprintEnrollmentHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withOpacity(0.9),
                fontSize: 13,
                height: 1.3,
              ),
            ),
          if (ui == OwnerVoiceprintEnrollUi.capturing &&
              speech.ownerVoiceprintCaptureMs > 0) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: (speech.ownerVoiceprintCaptureMs / 10000).clamp(0.0, 1.0),
              backgroundColor: Colors.white12,
              color: Colors.orangeAccent,
              minHeight: 4,
            ),
          ],
        ],
      ),
    );
  }

  /// 多人对话模式：底部居中按住说话（松手定稿送大模型）。
  Widget _buildMultiPersonPttBar(
    BuildContext context,
    SpeechNotifierSimplified speech,
  ) {
    final inChat = speech.isInConversationMode;
    // 思考中不可按；播报中 isProcessing 仍为 true，须允许按住打断。
    final canHold =
        inChat && (!speech.isProcessingUserInput || speech.isTtsPlaying);
    final holding = speech.isPttRecordingHold;
    final arming = speech.isPttFingerPressed && !holding;
    // 播报与「处理中」可能同时为 true，文案须优先播报态（显示按住说话/打断）。
    final String label = !inChat
        ? '请先唤醒小航'
        : speech.isTtsPlaying
            ? (arming ? '继续按住以打断' : '按住打断并说话')
            : speech.isProcessingUserInput
                ? '处理中…'
                : holding
                    ? '松开发送'
                    : arming
                        ? '继续按住…'
                        : '按住说话';

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) {
        if (canHold) {
          unawaited(speech.multiPersonPttTouchDown());
        }
      },
      // 必须在每次抬手时都通知 notifier：快速点按时尚未进入 isPttRecordingHold，
      // 若用构建期 holding 判断会漏掉 touchUp，导致仍开麦并一直识别。
      onPointerUp: (_) {
        unawaited(speech.multiPersonPttTouchUp());
      },
      onPointerCancel: (_) {
        unawaited(speech.multiPersonPttTouchUp());
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 220,
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: canHold
              ? (holding
                  ? Colors.green.shade800
                  : arming
                      ? Colors.amber.shade900
                      : Colors.white24)
              : Colors.white10,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: holding
                ? Colors.lightGreenAccent
                : arming
                    ? Colors.amberAccent
                    : Colors.white54,
            width: (holding || arming) ? 2.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceprintVerifyBanner(SpeechNotifierSimplified notifier) {
    final label = notifier.ownerVoiceprintVerifyStatusLabel;
    if (label == null) return const SizedBox.shrink();
    final pass = notifier.lastVoiceprintVerifyResult?.pass;
    final inProgress = notifier.isVoiceprintVerifyInProgress;
    final bg = inProgress
        ? Colors.amber.withOpacity(0.92)
        : (pass == true)
            ? Colors.teal.withOpacity(0.92)
            : Colors.deepOrange.withOpacity(0.92);
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.35),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  // 保留语音文本显示（可选）
  Widget _buildSpeechTextIndicator(SpeechNotifierSimplified notifier) {
    String displayText = notifier.getTextSpeech;
    Color textColor = Colors.white;
    // 根据状态显示不同的文本和颜色
    if (notifier.isInConversationMode) {
      final vpLabel = notifier.ownerVoiceprintVerifyStatusLabel;
      if (notifier.isTtsPlaying) {
        if (notifier.isOwnerMode && notifier.hasOwnerVoiceprint) {
          displayText = '🔊 播报中（主人模式：仅主人可打断）';
        } else if (notifier.isOwnerMode) {
          displayText = '🔊 播报中（主人模式：请先录入主人声音）';
        } else if (notifier.isOwnerVoiceprintBargeInMode &&
            notifier.hasOwnerVoiceprint) {
          displayText = '🔊 播报中（仅主人声纹可打断）';
        } else if (notifier.isOwnerVoiceprintBargeInMode) {
          displayText = '🔊 播报中（请先录入主人声音）';
        } else {
          displayText = '🔊 播报中...';
        }
        textColor = Colors.blue;
      } else if (notifier.isComplexTaskExecuting) {
        displayText = "🛠️ 复杂任务执行中...";
        textColor = Colors.deepOrangeAccent;
      } else if (notifier.isProcessingUserInput) {
        displayText = "💬 思考中...";
        textColor = Colors.amber;
      } else if ((notifier.isOwnerMode ||
              notifier.isOwnerVoiceprintBargeInMode) &&
          vpLabel != null) {
        displayText = vpLabel;
        if (notifier.isVoiceprintVerifyInProgress) {
          textColor = Colors.amberAccent;
        } else if (notifier.lastVoiceprintVerifyResult?.pass == true) {
          textColor = Colors.lightGreenAccent;
        } else {
          textColor = Colors.deepOrangeAccent;
        }
      } else if (notifier.isOwnerMode && notifier.hasOwnerVoiceprint) {
        displayText = '👤 主人模式已开启（仅接受主人语音）';
        textColor = Colors.amberAccent;
      } else if (notifier.isOwnerVoiceprintBargeInMode &&
          notifier.hasOwnerVoiceprint) {
        displayText = '🔐 主人声纹打断已开启';
        textColor = Colors.tealAccent;
      } else if (notifier.isOwnerVoiceprintEnrolling) {
        displayText = '🎙️ 正在录入主人声音…';
        textColor = Colors.orangeAccent;
      } else if (notifier.ownerVoiceprintUi ==
          OwnerVoiceprintEnrollUi.failure) {
        displayText = '⚠️ 声纹录入失败，请点右上角麦克风重试';
        textColor = Colors.redAccent;
      } else if (notifier.getTextSpeech.contains('不可使用')) {
        displayText = notifier.getTextSpeech;
        textColor = Colors.redAccent;
      } else if (notifier.isMultiPersonPushToTalkMode) {
        if (notifier.isPttRecordingHold) {
          displayText = "🎙️ 录音中…松开发送";
        } else if (notifier.isPttFingerPressed) {
          displayText = "👥 继续按住以开始录音…";
        } else {
          displayText = "👥 多人模式：按住下方说话";
        }
        textColor = Colors.cyanAccent;
      } else {
        // 聆听中，或 TTS 结束后至麦克风就绪之间的短间隙：统一显示聆听中，与表情 onTtsCompleted 一致
        displayText = "🎤 聆听中...";
        textColor = Colors.green;
      }
    } else if (notifier.isWakeUpActive) {
      displayText = "👂 等待唤醒词...";
      textColor = Colors.orange;
    }

    // 获取当前表情文件名
    String currentEmotion =
        _currentAnimation.split('/').last.replaceAll('.json', '');

    // 获取思考时间标签（已简化，不再支持思考时间显示）
    String thinkingLabel = '';
    final asrDisplay = notifier.getTextSpeech.trim();
    const asrIdlePlaceholder = '等待唤醒词...';
    final asrLabel = notifier.isVaRecognitionActive ? '情绪识别' : '识别';

    // --- 新增：获取手势识别状态 ---
    String gestureStatusLabel = '';
    if (notifier.isInGestureRecognitionMode) {
      gestureStatusLabel = notifier.isGestureRecognitionActive
          ? '🤚 手势识别: ${notifier.lastRecognizedGesture.isNotEmpty ? notifier.lastRecognizedGesture : "监听中..."}'
          : '🤚 手势识别: 启动中...';
    } else if (notifier.isGestureRecognitionActive) {
      // 如果全局手势识别开着（非模式）
      gestureStatusLabel =
          '🤚 全局手势识别: ${notifier.lastRecognizedGesture.isNotEmpty ? notifier.lastRecognizedGesture : "监听中..."}';
    }
    // --- 新增结束 ---

    return Positioned(
      top: 16,
      left: 16,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ConnectionPermissionStatusStrip(),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            constraints: const BoxConstraints(maxWidth: 280),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              displayText,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: textColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SizedBox(height: 8),
          // 当前表情指示器（调试用）
          Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.purple.withOpacity(0.8),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Text(
              "😊 当前表情: $currentEmotion",
              style: TextStyle(
                fontSize: 14,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          SizedBox(height: 10),
          // 思考时间指示器
          if (thinkingLabel.isNotEmpty)
            Container(
              margin: EdgeInsets.only(top: 5),
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.8),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                thinkingLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          // 对话模式指示器
          if (notifier.isInConversationMode)
            Container(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.8),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Text(
                "💬 连续对话模式",
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          if (asrDisplay.isNotEmpty && asrDisplay != asrIdlePlaceholder)
            Container(
              margin: EdgeInsets.only(top: 8),
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              constraints: BoxConstraints(maxWidth: 380),
              decoration: BoxDecoration(
                color: Colors.blueGrey.shade800.withOpacity(0.92),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '🎙️ $asrLabel：$asrDisplay',
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                ),
              ),
            ),
          // 防重复提示 - 只在真正暂停时显示（排除正在启动 ASR 的间隙，避免与「聆听中」矛盾）
          if (notifier.isInConversationMode &&
              !notifier.isListening &&
              !notifier.isTtsPlaying &&
              !notifier.isStartingVoiceRecognition &&
              notifier.getTextSpeech.isNotEmpty) // 只有在有语音输入历史时才显示暂停提示
            Container(
              margin: EdgeInsets.only(top: 5),
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.8),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                "🔇 语音识别已暂停",
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          // --- 新增：手势识别状态指示器 ---
          if (gestureStatusLabel.isNotEmpty)
            Container(
              margin: EdgeInsets.only(top: 5),
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: notifier.isGestureRecognitionActive
                    ? Colors.teal.withOpacity(0.8)
                    : Colors.grey.withOpacity(0.8),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                gestureStatusLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          // --- 新增结束 ---
          if (notifier.isInFollowMode && notifier.currentGesture != null) ...[
            SizedBox(height: 10),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.blueAccent.withOpacity(0.85),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                "👋 当前手势：${notifier.currentGesture!}",
                style: TextStyle(
                  fontSize: 18,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ]
        ],
      ),
    );
  }
}
