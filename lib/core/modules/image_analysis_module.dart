import 'dart:async';
import 'package:voicegpt/core/api/openai.api.dart';
import 'package:voicegpt/core/llm/llm_prompt_layers.dart';
import 'package:voicegpt/core/services/camera_service.dart';
import 'package:voicegpt/core/services/camera_resource_manager.dart'
    show CameraTaskPriority;
/// 图片分析模块
/// 处理图像相关的用户请求，使用视觉大模型分析图片内容
class ImageAnalysisModule {
  static final ImageAnalysisModule _instance = ImageAnalysisModule._internal();
  factory ImageAnalysisModule() => _instance;
  ImageAnalysisModule._internal();

  final OpenAI _openAI = OpenAI();
  CameraService? _cameraService;

  bool _isProcessing = false;

  /// 当前是否正在处理
  bool get isProcessing => _isProcessing;

  /// 处理图片分析请求
  Future<ImageAnalysisResult> processImageAnalysis(String userRequest,
      {String? conversationContext,
      CameraTaskPriority cameraCapturePriority =
          CameraTaskPriority.normal}) async {
    if (_isProcessing) {
      print("⏳ 图片分析模块正在处理中，忽略新请求");
      return ImageAnalysisResult(
        success: false,
        response: "系统正在处理中，请稍候",
        userRequest: userRequest,
      );
    }

    _isProcessing = true;
    print("📷 开始处理图片分析: $userRequest");

    try {
      // 观察类表情在 TTS 开播前由 ConversationController 对齐，此处不提前播放

      // 初始化摄像头服务
      await _initializeCameraService();

      // 拍照
      String imagePath = await _captureImage(cameraCapturePriority);

      // 构建分析提示词
      String prompt = _buildAnalysisPrompt(userRequest, conversationContext);

      // 调用视觉大模型进行分析
      final response = await _openAI.generateImageText(prompt, imagePath);
      final analysisResult = _extractVisionContent(response);
      print("✅ 图片分析处理成功");
      return ImageAnalysisResult(
        success: true,
        response: analysisResult,
        userRequest: userRequest,
        imagePath: imagePath,
      );
    } catch (e) {
      print("❌ 图片分析处理失败: $e");
      return ImageAnalysisResult(
        success: false,
        response: "抱歉，我现在无法分析图片，请稍后再试。",
        userRequest: userRequest,
        error: e.toString(),
      );
    } finally {
      _isProcessing = false;
    }
  }

  /// 仅拍照，不触发视觉分析（用于多角度采集后统一分析）
  Future<String> captureImageOnly(
      {CameraTaskPriority cameraCapturePriority =
          CameraTaskPriority.normal}) async {
    await _initializeCameraService();
    return _captureImage(cameraCapturePriority);
  }

  /// 多图联合分析（一次把多张图发给 VLM）
  Future<ImageAnalysisResult> processMultiImageAnalysis(
    String userRequest,
    List<String> imagePaths, {
    String? conversationContext,
  }) async {
    if (_isProcessing) {
      print("⏳ 图片分析模块正在处理中，忽略新请求");
      return ImageAnalysisResult(
        success: false,
        response: "系统正在处理中，请稍候",
        userRequest: userRequest,
      );
    }
    if (imagePaths.isEmpty) {
      return ImageAnalysisResult(
        success: false,
        response: "没有可用于联合分析的图片",
        userRequest: userRequest,
      );
    }

    _isProcessing = true;
    print("📷 开始多图联合分析: count=${imagePaths.length}, req=$userRequest");
    try {
      final prompt = _buildMultiImageAnalysisPrompt(
        userRequest,
        conversationContext,
        imagePaths.length,
      );
      final response = await _openAI.generateImageTextBatch(prompt, imagePaths);
      final analysisResult = _extractVisionContent(response);
      return ImageAnalysisResult(
        success: true,
        response: analysisResult,
        userRequest: userRequest,
        imagePath: imagePaths.first,
      );
    } catch (e) {
      print("❌ 多图联合分析失败: $e");
      return ImageAnalysisResult(
        success: false,
        response: "抱歉，我现在无法完成多图联合分析，请稍后再试。",
        userRequest: userRequest,
        error: e.toString(),
      );
    } finally {
      _isProcessing = false;
    }
  }

  /// 初始化摄像头服务
  Future<void> _initializeCameraService() async {
    if (_cameraService == null) {
      _cameraService = CameraService();
      await _cameraService!.initialize();
      print("📷 摄像头服务初始化完成");
    }
  }

  /// 拍照
  Future<String> _captureImage(CameraTaskPriority priority) async {
    if (_cameraService == null) {
      throw Exception("摄像头服务未初始化");
    }

    try {
      final imagePath = await _cameraService!.captureImage(
        priority: priority,
        timeout: const Duration(seconds: 3),
        keepStreamOn: true,
      );
      print("📸 拍照完成: $imagePath");
      return imagePath;
    } catch (e) {
      throw Exception("拍照失败: $e");
    }
  }

  static String _vlPlainTextSuffix() =>
      '\n${LlmPromptLayers.imageChainPlainTextOutputRules}';

  /// 构建分析提示词
  String _buildAnalysisPrompt(String userRequest, String? conversationContext) {
    StringBuffer prompt = StringBuffer();

    // 基础分析指令
    prompt.writeln("请仔细观察这张图片，并根据用户的要求进行分析。");
    prompt.writeln("用户请求：$userRequest");

    // 添加上下文信息
    if (conversationContext != null && conversationContext.isNotEmpty) {
      prompt.writeln("对话上下文：$conversationContext");
      prompt.writeln("请结合对话上下文来回答用户的问题。");
    }

    // 分析要求
    prompt.writeln("");
    prompt.writeln("分析要求：");
    prompt.writeln("1. 详细描述图片中的内容");
    prompt.writeln("2. 根据用户的具体要求进行针对性分析");
    prompt.writeln("3. 如果图片中有文字，请识别并说明");
    prompt.writeln("4. 如果用户询问特定物品或场景，请重点描述");
    prompt.writeln("5. 用简洁友好的语言回答");

    // 常见场景的特殊处理
    String lowerRequest = userRequest.toLowerCase();
    if (lowerRequest.contains('颜色')) {
      prompt.writeln("6. 特别注意描述图片中的颜色信息");
    } else if (lowerRequest.contains('数量') || lowerRequest.contains('多少')) {
      prompt.writeln("6. 特别注意统计图片中相关物品的数量");
    } else if (lowerRequest.contains('位置') || lowerRequest.contains('在哪')) {
      prompt.writeln("6. 特别注意描述物品的位置关系");
    }

    prompt.write(_vlPlainTextSuffix());
    return prompt.toString();
  }

  String _buildMultiImageAnalysisPrompt(
      String userRequest, String? conversationContext, int count) {
    final prompt = StringBuffer();
    prompt.writeln("你会收到同一任务下不同角度拍摄的多张图片（共 $count 张）。");
    prompt.writeln("请先逐张观察，再做跨图整合分析，避免只看其中一张。");
    prompt.writeln("用户请求：$userRequest");
    if (conversationContext != null && conversationContext.isNotEmpty) {
      prompt.writeln("对话上下文：$conversationContext");
    }
    prompt.writeln("");
    prompt.writeln("输出要求：");
    prompt.writeln("1. 先给出各角度的关键发现（可分点）");
    prompt.writeln("2. 再给出综合结论（整体判断、差异与一致点）");
    prompt.writeln("3. 如有风险/障碍物/重要细节，明确指出来源角度");
    prompt.write(_vlPlainTextSuffix());
    return prompt.toString();
  }

  String _extractVisionContent(Map<String, dynamic> response) {
    if (response['choices'] == null || response['choices'].isEmpty) {
      throw Exception("视觉模型响应格式错误");
    }
    return response['choices'][0]['message']['content'].toString();
  }

  /// 分析图片中的文字内容
  Future<ImageAnalysisResult> analyzeTextInImage(String userRequest,
      {String? conversationContext}) async {
    print("📝 开始分析图片中的文字内容");

    String prompt = """
    请识别图片中的所有文字内容，并根据用户要求进行处理。
    
    用户请求：$userRequest
    ${conversationContext != null ? '对话上下文：$conversationContext' : ''}
    
    请：
    1. 准确识别图片中的所有文字
    2. 按照从左到右、从上到下的顺序整理文字
    3. 如果有表格或特殊格式，请保持原有结构
    4. 根据用户的具体要求进行相应的处理或解释
    ${_vlPlainTextSuffix()}
    """;

    return await processImageAnalysis(prompt,
        conversationContext: conversationContext);
  }

  /// 分析图片中的物品
  Future<ImageAnalysisResult> analyzeObjectsInImage(String userRequest,
      {String? conversationContext}) async {
    print("🔍 开始分析图片中的物品");

    String prompt = """
    请识别并描述图片中的所有物品。
    
    用户请求：$userRequest
    ${conversationContext != null ? '对话上下文：$conversationContext' : ''}
    
    请：
    1. 列出图片中的主要物品
    2. 描述每个物品的特征（颜色、形状、大小等）
    3. 说明物品之间的位置关系
    4. 如果用户询问特定物品，请重点描述
    ${_vlPlainTextSuffix()}
    """;

    return await processImageAnalysis(prompt,
        conversationContext: conversationContext);
  }

  /// 分析当前场景
  Future<ImageAnalysisResult> analyzeCurrentScene(String userRequest,
      {String? conversationContext}) async {
    print("🎬 开始分析当前场景");

    String prompt = """
    请分析这张图片展示的场景情况。
    
    用户请求：$userRequest
    ${conversationContext != null ? '对话上下文：$conversationContext' : ''}
    
    请：
    1. 描述这是什么场景（室内/户外、具体环境等）
    2. 分析场景中的主要元素和活动
    3. 评估场景的氛围和特点
    4. 如果有人物，描述他们在做什么
    ${_vlPlainTextSuffix()}
    """;

    return await processImageAnalysis(prompt,
        conversationContext: conversationContext);
  }

  /// 释放资源
  Future<void> dispose() async {
    if (_cameraService != null) {
      await _cameraService!.dispose();
      _cameraService = null;
      print("📷 图片分析模块摄像头资源已释放");
    }
  }
}

/// 图片分析结果
class ImageAnalysisResult {
  final bool success;
  final String response;
  final String userRequest;
  final String? imagePath;
  final String? error;
  final DateTime timestamp;

  ImageAnalysisResult({
    required this.success,
    required this.response,
    required this.userRequest,
    this.imagePath,
    this.error,
  }) : timestamp = DateTime.now();

  @override
  String toString() {
    return 'ImageAnalysisResult{success: $success, userRequest: "$userRequest", response: "$response"${error != null ? ', error: "$error"' : ''}}';
  }
}
