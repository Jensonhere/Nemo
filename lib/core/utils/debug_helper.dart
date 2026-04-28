import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:voicegpt/core/modules/intent_recognition_module.dart';

/// 调试助手类
/// 提供意图识别模块的调试和诊断功能
class DebugHelper {
  static final IntentRecognitionModule _intentModule =
      IntentRecognitionModule();

  /// 测试意图识别功能
  static Future<void> testIntentRecognition() async {
    if (kDebugMode) {
      developer.log('🧪 开始测试意图识别功能', name: 'DebugHelper');

      try {
        // 初始化模块
        await _intentModule.initialize();
        final modelInfo = _intentModule.getModelInfo();

        developer.log('📊 模型信息: $modelInfo', name: 'DebugHelper');

        // 测试用例
        final testCases = [
          {'text': '前进十米', 'expected': 'command'},
          {'text': '我很开心', 'expected': 'emotion'},
          {'text': '帮我看看这张图片', 'expected': 'image'},
          {'text': '今天天气怎么样', 'expected': 'dialogue'},
          {'text': '左转九十度', 'expected': 'command'},
          {'text': '我有点难过', 'expected': 'emotion'},
          {'text': '分析一下当前场景', 'expected': 'image'},
          {'text': '你好吗', 'expected': 'dialogue'},
        ];

        int correctCount = 0;
        int totalCount = testCases.length;

        for (final testCase in testCases) {
          final text = testCase['text'] as String;
          final expected = testCase['expected'] as String;

          final result = await _intentModule.predictIntent(text);
          final predicted = result.intent.toString().split('.').last;

          final isCorrect = predicted == expected;
          if (isCorrect) correctCount++;

          developer.log(
              '🧪 测试: "$text" | 预期: $expected | 实际: $predicted | ${isCorrect ? '✅' : '❌'} | 置信度: ${(result.confidence * 100).toStringAsFixed(1)}%',
              name: 'DebugHelper');
        }

        final accuracy = (correctCount / totalCount * 100).toStringAsFixed(1);
        developer.log('📈 测试完成 | 准确率: $accuracy% ($correctCount/$totalCount)',
            name: 'DebugHelper');
      } catch (e) {
        developer.log('❌ 测试失败: $e', name: 'DebugHelper');
      }
    }
  }

  /// 测试 tokenizer 功能
  static Future<void> testTokenizer() async {
    if (kDebugMode) {
      developer.log('🔤 开始测试 Tokenizer 功能', name: 'DebugHelper');

      try {
        await _intentModule.initialize();

        final testTexts = [
          '前进十米',
          '我很开心',
          '帮我看看这张图片',
          '今天天气怎么样？',
        ];

        for (final text in testTexts) {
          final result = _intentModule.testTokenizer(text);
          if (result != null) {
            developer.log('🔤 文本: "$text"', name: 'DebugHelper');
            developer.log('   Tokens: ${result.tokens}', name: 'DebugHelper');
            developer.log('   Input IDs: ${result.inputIds}',
                name: 'DebugHelper');
            developer.log('   Attention Mask: ${result.attentionMask}',
                name: 'DebugHelper');
          } else {
            developer.log('⚠️ Tokenizer 不可用，使用关键词模式', name: 'DebugHelper');
            break;
          }
        }
      } catch (e) {
        developer.log('❌ Tokenizer 测试失败: $e', name: 'DebugHelper');
      }
    }
  }

  /// 对比两种模式的结果
  static Future<void> compareModels() async {
    if (kDebugMode) {
      developer.log('⚖️ 开始对比 BERT 模型和关键词匹配', name: 'DebugHelper');

      try {
        await _intentModule.initialize();

        final testTexts = [
          '向前走一步',
          '我感到很高兴',
          '请帮我观察一下',
          '你能告诉我时间吗',
          '右拐弯',
          '心情不好',
        ];

        for (final text in testTexts) {
          developer.log('📝 测试文本: "$text"', name: 'DebugHelper');

          // BERT 模式
          _intentModule.setUseDeepLearningModel(true);
          final bertResult = await _intentModule.predictIntent(text);

          // 关键词模式
          _intentModule.setUseDeepLearningModel(false);
          final keywordResult = await _intentModule.predictIntent(text);

          developer.log(
              '   🤖 BERT: ${bertResult.intent} (${(bertResult.confidence * 100).toStringAsFixed(1)}%)',
              name: 'DebugHelper');
          developer.log(
              '   🔤 关键词: ${keywordResult.intent} (${(keywordResult.confidence * 100).toStringAsFixed(1)}%)',
              name: 'DebugHelper');

          final agree = bertResult.intent == keywordResult.intent ? '✅' : '❌';
          developer.log('   $agree 结果一致性', name: 'DebugHelper');
        }

        // 恢复 BERT 模式
        _intentModule.setUseDeepLearningModel(true);
      } catch (e) {
        developer.log('❌ 模型对比失败: $e', name: 'DebugHelper');
      }
    }
  }

  /// 性能测试
  static Future<void> performanceTest() async {
    if (kDebugMode) {
      developer.log('⚡ 开始性能测试', name: 'DebugHelper');

      try {
        await _intentModule.initialize();

        final testText = '前进十米';
        const iterations = 10;

        // BERT 模式性能测试
        _intentModule.setUseDeepLearningModel(true);
        final bertStartTime = DateTime.now();

        for (int i = 0; i < iterations; i++) {
          await _intentModule.predictIntent(testText);
        }

        final bertDuration = DateTime.now().difference(bertStartTime);
        final bertAvg = bertDuration.inMilliseconds / iterations;

        // 关键词模式性能测试
        _intentModule.setUseDeepLearningModel(false);
        final keywordStartTime = DateTime.now();

        for (int i = 0; i < iterations; i++) {
          await _intentModule.predictIntent(testText);
        }

        final keywordDuration = DateTime.now().difference(keywordStartTime);
        final keywordAvg = keywordDuration.inMilliseconds / iterations;

        developer.log('⚡ 性能测试结果 (平均延迟):', name: 'DebugHelper');
        developer.log('   🤖 BERT 模式: ${bertAvg.toStringAsFixed(1)}ms',
            name: 'DebugHelper');
        developer.log('   🔤 关键词模式: ${keywordAvg.toStringAsFixed(1)}ms',
            name: 'DebugHelper');
        developer.log(
            '   📊 性能差异: ${(bertAvg / keywordAvg).toStringAsFixed(1)}x',
            name: 'DebugHelper');

        // 恢复 BERT 模式
        _intentModule.setUseDeepLearningModel(true);
      } catch (e) {
        developer.log('❌ 性能测试失败: $e', name: 'DebugHelper');
      }
    }
  }

  /// 运行全面测试
  static Future<void> runFullDiagnostics() async {
    if (kDebugMode) {
      developer.log('🔍 开始全面诊断测试', name: 'DebugHelper');

      await testIntentRecognition();
      await testTokenizer();
      await compareModels();
      await performanceTest();

      developer.log('✅ 全面诊断测试完成', name: 'DebugHelper');
    }
  }
}
