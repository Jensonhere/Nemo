# 🤖 BERT 模型集成说明

## 📋 概述

已成功将真正的 tf_bert 模型集成到意图识别模块中，替换了原有的关键词匹配方式。现在系统支持两种模式：

1. **🤖 BERT 深度学习模式**（主要）：使用 TensorFlow Lite 模型进行意图识别
2. **🔤 关键词匹配模式**（备用）：当模型不可用时自动降级

## 🏗️ 架构设计

### 核心组件

1. **`BertTokenizer`** (`lib/core/utils/bert_tokenizer.dart`)
   - 自定义实现的 BERT tokenizer
   - 基于 WordPiece 算法
   - 支持中文文本预处理和分词

2. **`IntentRecognitionModule`** (更新版)
   - 智能模式切换
   - TFLite 模型推理
   - 自动降级机制

3. **调试工具**
   - 测试页面：`IntentRecognitionTestPage`
   - 调试助手：`DebugHelper`

## 🚀 功能特性

### BERT 模型特性
- ✅ **真正的深度学习推理**：使用训练好的 BERT 模型
- ✅ **智能文本预处理**：同音字替换、标点处理
- ✅ **Softmax 概率输出**：提供准确的置信度
- ✅ **自动降级机制**：模型失败时自动切换到关键词模式

### Tokenizer 特性
- ✅ **WordPiece 分词**：支持中文字符的细粒度切分
- ✅ **特殊标记处理**：[CLS], [SEP], [PAD], [UNK], [MASK]
- ✅ **长度控制**：自动截断和填充到固定长度
- ✅ **注意力掩码**：正确生成 attention_mask

## 📊 模型配置

### 输入格式
```
maxLen: 32 (序列最大长度)
输入顺序: [attention_mask, input_ids]
输出: [1, num_labels] 的概率分布
```

### 标签映射
```json
[
  "command",    // 动作指令
  "dialogue",   // 纯文本对话  
  "emotion",    // 情绪识别
  "image"       // 图片分析
]
```

## 🧪 测试和调试

### 测试页面
通过路由 `/intent-test` 访问专门的测试界面：

```dart
Navigator.pushNamed(context, '/intent-test');
```

**功能包括：**
- 📝 实时意图识别测试
- 🔄 BERT/关键词模式切换
- 📊 详细的推理结果显示
- 🔤 Tokenizer 结果查看
- 📋 预设测试用例

### 调试工具
```dart
import 'package:voicegpt/core/utils/debug_helper.dart';

// 运行完整诊断
await DebugHelper.runFullDiagnostics();

// 单独测试
await DebugHelper.testIntentRecognition();
await DebugHelper.testTokenizer();
await DebugHelper.compareModels();
await DebugHelper.performanceTest();
```

## 📈 性能对比

### 准确性
- **BERT 模式**：基于深度学习，理论上更准确
- **关键词模式**：基于规则，在特定场景下仍然有效

### 延迟
- **BERT 模式**：~50-100ms（取决于设备性能）
- **关键词模式**：~1-5ms（几乎实时）

### 内存占用
- **BERT 模式**：需要加载模型文件（约2-5MB）
- **关键词模式**：几乎不占用额外内存

## 🔧 使用方式

### 基本用法
```dart
final intentModule = IntentRecognitionModule();
await intentModule.initialize();

final result = await intentModule.predictIntent("前进十米");
print("意图: ${result.intent}");
print("置信度: ${result.confidence}");
```

### 模式切换
```dart
// 切换到关键词模式
intentModule.setUseDeepLearningModel(false);

// 切换回 BERT 模式
intentModule.setUseDeepLearningModel(true);

// 获取当前状态
final info = intentModule.getModelInfo();
```

### 测试 Tokenizer
```dart
final tokenResult = intentModule.testTokenizer("测试文本");
if (tokenResult != null) {
  print("Tokens: ${tokenResult.tokens}");
  print("Input IDs: ${tokenResult.inputIds}");
}
```

## 🛠️ 故障排除

### 常见问题

1. **模型文件未找到**
   ```
   ❌ 确保 assets/intent_model.tflite 存在
   ❌ 检查 pubspec.yaml 中的 assets 配置
   ```

2. **词汇表加载失败**
   ```
   ❌ 确保 assets/vocab.txt 存在
   ❌ 检查文件编码是否为 UTF-8
   ```

3. **标签映射错误**
   ```
   ❌ 确保 assets/labels.json 格式正确
   ❌ 标签顺序必须与模型训练时一致
   ```

### 自动降级
当 BERT 模型不可用时，系统会自动：
1. 输出警告日志
2. 切换到关键词匹配模式
3. 继续提供意图识别服务

## 📂 文件结构

```
lib/core/
├── modules/
│   ├── intent_recognition_module.dart    # 主要模块
│   └── intent_recognition_test.dart      # 测试页面
└── utils/
    ├── bert_tokenizer.dart               # BERT tokenizer
    └── debug_helper.dart                 # 调试工具

assets/
├── intent_model.tflite                   # BERT 模型文件
├── labels.json                          # 标签映射
└── vocab.txt                           # BERT 词汇表
```

## 🔮 未来扩展

1. **模型优化**
   - 支持更大的 BERT 模型
   - 添加模型量化支持
   - 支持动态序列长度

2. **多语言支持**
   - 英文 BERT 模型
   - 多语言混合识别

3. **在线更新**
   - 支持模型热更新
   - 云端模型同步

4. **性能优化**
   - GPU 加速支持
   - 模型缓存机制
   - 批量推理支持

---

**🎯 总结**: BERT 模型已成功集成，提供了高精度的意图识别能力，同时保持了系统的稳定性和向后兼容性。通过智能降级机制，确保在任何情况下都能提供意图识别服务。
