import 'dart:convert';

import 'package:voicegpt/core/api/openai.api.dart';
import 'package:voicegpt/core/llm/planner_expression_catalog.dart';

/// 单步规划：动作类别 + 执行时推荐表情 + 指令/文案；蓝牙步可带与动作**并行**的短口播。
class PlannerStep {
  final String action;
  final String expression;
  final String reply;
  /// 仅「蓝牙动作」：与 `reply`（动作指令）同时播放的短句；为空则客户端用极短默认语气。
  final String? parallelTts;

  const PlannerStep({
    required this.action,
    required this.expression,
    required this.reply,
    this.parallelTts,
  });
}

/// Planner LLM 输出（仅用于展示 / 日志；执行器应按步调用 UI 表情接口）。
class PlannerResult {
  final List<PlannerStep> steps;
  final String rawContent;

  const PlannerResult({
    required this.steps,
    required this.rawContent,
  });
}

/// Agent + C 时：把用户目标拆成有序步骤 JSON（不写入主对话历史）。
class LlmPlanner {
  final OpenAI _openAI = OpenAI();

  static String get _plannerSystemPrompt => '''
你是桌面机器人系统的【任务规划器（Planner）】。

职责：把用户的多步骤、有先后顺序的复杂请求，分解为可顺序执行的若干步骤（仅规划、不执行、不闲聊）。
每一步必须包含：action / expression / reply；**蓝牙动作**还可选 **parallel_tts**（与动作并行播报的短句）。

--------------------------------------
【先做语义净化：去无意义话术，再规划】

在拆 step 之前，先把用户输入里“不可执行/无任务价值”的口语杂质自动过滤，只保留可执行目标。

应忽略（示例）：
- 寒暄/称呼：你好、小航、在吗、那个、嗯、啊、就是
- 客套/语气词：麻烦你、请你帮我、能不能、可以的话、谢谢、辛苦了
- 纯情绪或附和：好吧、随便、你看着办、都行、快点、拜托了

应保留（示例）：
- 明确动作与顺序：向前、左转、停止、先…再…
- 视觉任务：调用VLM、看看前面、识别当前场景
- 播报目标：告诉我结果、播报一下

净化后若只剩空话、无法提炼执行目标：输出 1 个 TTS 播报 step，reply 说明「未识别到可执行任务，请重述」。

--------------------------------------
【动作类别（action）】

每一步的 "action" 必须从下列三类中选一项（字符串完全一致）：
- 蓝牙动作
- 视觉/VLM
- TTS 播报

动作判定参考：
- 机身移动、转向、停止、避障、蓝牙控制 -> 蓝牙动作
- 打开相机、拍照、看图识别、视觉理解 -> 视觉/VLM
- 向用户说话、播报状态、解释结论 -> TTS 播报

--------------------------------------
【一步一事：与系统三类能力对齐】

系统实际只会做三件事：**蓝牙动作**（机身移动）、**视觉/VLM**（拍照+视觉推理）、**TTS 播报**（语音）。
- 用户说「先向前，再向前 30mm」→ 必须拆成 **两个** step，两步 action 均为「蓝牙动作」，每步 **reply** 各写**一条**可被动作模块解析的自然语言（如「前进 200」「前进 30」），**禁止**把两条指令塞进同一个 step；每步可写 **parallel_tts**（约 4～18 字），如「好，先往前走」「收到，左转一点」，客户端会与动作**同时**播报，不必等动作结束。
- 用户说「向前然后向左」→ 至少两个「蓝牙动作」step，顺序与语义一致。
- **连续多步同为「蓝牙动作」时，expression 不要每步都用同一个标签**，请在白名单内轮换（如 观察 → 坚定 → 热切 → 眨眼），让观感更丰富。
- 头部动作规范（协议 0x10）：脑袋角度是**绝对角度**，reply 里涉及抬头/低头/上升/下降时，角度请落在 **8~20**；点头语义可写「点头」或「点头 12」，执行层会做下-上-中序列。
- 「视觉/VLM」步的 reply 写本步给视觉模块的**用户意图/问句**（如「看看前面有什么」）；**不要**在同一步里塞入「播完识别结论」的长文案——客户端会在本步内：先完成视觉推理，再**播完模型返回的分析全文（可能截断）**，**全部播完后**才会进入下一步；若还需额外口播总结，可再单独拆一步「TTS 播报」。
- 「TTS 播报」步只负责说话，reply 为要播报的完整口播稿。
- 当用户表达「调用VLM并描述当前场景/看看并说说」这类意图时，默认只输出**一个**「视觉/VLM」step，不要再额外生成“描述一下结果”的 TTS step（因为视觉步已会自动播报分析结果）。
- 若用户要求「旋转一圈并每90度拍照，最后统一分析」这类**先采集后合并分析**任务：请规划为「蓝牙动作 + 视觉/VLM(仅采集)」交替的多步（共4次采集），最后再给**1个**「视觉/VLM(联合分析)」step；前4个视觉步的 reply 要写“仅拍照采集，不分析”，最后一步 reply 要写“把前面采集的多张图一起分析并给结论”。

--------------------------------------
【表情标签（expression）】

每一步的 "expression" 必须从下列**且仅下列**中选一项（字符串完全一致）：
${PlannerExpressionCatalog.allowedLabelsForPrompt()}

选表情原则（示例，可按语义变通）：
- 机身移动、原地转向、避障等待、环视环境、读传感器：优先 **观察**；也可 **坚定**。
- 打开相机、拍照、截图、VLM/看图识别：优先 **可爱**；需要冷静审视画面时可用 **观察**。
- 向用户语音播报结果、解释说明：**说话**；简短确认可用 **眨眼**。
- 推理、规划、等模型：**思考**。
- 用户致谢场景、任务成功收尾：可用 **感激**、**开心**。
- 用户表达难过/独处感、安抚场景：**孤独**、**倾听**、**委屈**、**失落** 择一贴合语境。
- 突发异常、碰撞风险、禁止操作：**愤怒** 或 **惊讶**。
- 发现有趣结果、超预期：**惊喜**。
- 急切催促执行下一小步：**热切**。
- 迷路找目标、找人找物：**寻找**。
- 听不懂指令、信息不足：**疑惑**。
- 轻微无语、小迷糊：**晕**。
- 待机过渡、无特别情绪：**眨眼**。
- 亲密互动、飞吻类：**KISS**（仅大写三个字母）。

硬性规则：
1. 只输出一个 JSON 对象，不要 markdown、不要代码围栏、不要前后解释。
2. JSON 顶层必须包含键 "steps"，值为**数组**；数组每一项为对象，且必须同时包含：
   - "action"：字符串，三选一（蓝牙动作 / 视觉/VLM / TTS 播报）。
   - "expression"：字符串，上表白名单中的**一项**。
   - "reply"：字符串。蓝牙步：写**动作指令**（如「前进 200」）；视觉步：写**给视觉模块的问句/意图**；TTS 步：写**完整口播稿**。
   - "parallel_tts"：**可选**，仅蓝牙步建议填写；与动作并行播放的短口播（不要写动作参数本身）。
3. 步骤数量通常 2～8；若用户明确只有单一动作，允许仅 1 个对象。
4. 除 "steps" 外不要输出其它顶层键；不要嵌套子计划。
5. 客户端执行：蓝牙步内 **expression / 蓝牙动作 / parallel_tts** 三者并行；视觉步仍为先识别再播完结论再进入下一步；纯 TTS 步为表情与口播并行。

示例输出（多段移动拆步 + 表情轮换 + 并行口播）：
{"steps":[
  {"action":"蓝牙动作","expression":"观察","reply":"前进 200","parallel_tts":"好，先往前走"},
  {"action":"蓝牙动作","expression":"坚定","reply":"左转 90","parallel_tts":"马上左转"}
]}
''';

  Future<PlannerResult> plan({required String userGoal}) async {
    try {
      final distilledGoal = _distillGoal(userGoal);
      if (!_looksActionable(distilledGoal)) {
        return const PlannerResult(
          steps: [
            PlannerStep(
              action: 'TTS 播报',
              expression: '疑惑',
              reply: '我还没识别到可执行任务，请再具体说一次。',
            ),
          ],
          rawContent: 'distilled-non-actionable',
        );
      }
      final response = await _openAI.generateTextEphemeralNoHistory(
        systemContent: _plannerSystemPrompt,
        userUtterance: distilledGoal,
      );
      final raw = _extractAssistantText(response);
      final steps = _parseSteps(raw);
      if (steps.isEmpty) {
        return const PlannerResult(
          steps: [
            PlannerStep(
              action: 'TTS 播报',
              expression: '疑惑',
              reply: '我还没识别到可执行任务，请再具体说一次。',
            ),
          ],
          rawContent: 'parsed-empty',
        );
      }
      return PlannerResult(steps: steps, rawContent: raw);
    } catch (e) {
      return PlannerResult(steps: const [], rawContent: 'error: $e');
    }
  }

  String _distillGoal(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    const fillers = <String>[
      '你好',
      '小航',
      '在吗',
      '那个',
      '嗯',
      '啊',
      '就是',
      '麻烦你',
      '请你',
      '帮我',
      '能不能',
      '可以的话',
      '谢谢',
      '辛苦了',
      '好吧',
      '随便',
      '你看着办',
      '都行',
      '快点',
      '拜托了',
    ];
    for (final f in fillers) {
      s = s.replaceAll(f, ' ');
    }
    s = s.replaceAll(RegExp(r'[，。！？、,.!?;；:：]+'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.isEmpty ? raw.trim() : s;
  }

  bool _looksActionable(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), '');
    if (t.isEmpty) return false;
    const hints = [
      '前进',
      '后退',
      '左转',
      '右转',
      '转圈',
      '旋转',
      '停止',
      '抬头',
      '低头',
      '上升',
      '下降',
      '点头',
      '先',
      '再',
      '然后',
      '接着',
      '调用vlm',
      '视觉',
      '相机',
      '拍照',
      '识别',
      '看看',
      '描述场景',
      '播报',
      '告诉我',
    ];
    return hints.any((k) => t.toLowerCase().contains(k));
  }

  String _extractAssistantText(Map<String, dynamic> response) {
    if (response['choices'] is List && (response['choices'] as List).isNotEmpty) {
      final choice = (response['choices'] as List).first;
      if (choice is Map<String, dynamic>) {
        if (choice['message'] is Map && choice['message']['content'] != null) {
          return choice['message']['content'].toString();
        }
        if (choice['text'] != null) return choice['text'].toString();
      }
    }
    return (response['content'] ?? response['text'] ?? '').toString();
  }

  List<PlannerStep> _parseSteps(String raw) {
    final text = raw.trim();
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return const [];
    try {
      final obj = jsonDecode(text.substring(start, end + 1));
      if (obj is! Map<String, dynamic>) return const [];
      final rawList = obj['steps'];
      if (rawList is! List) return const [];
      final out = <PlannerStep>[];
      for (final e in rawList) {
        if (e is String) {
          final s = e.trim();
          if (s.isNotEmpty) {
            out.add(PlannerStep(
              action: 'TTS 播报',
              expression: '思考',
              reply: s,
              parallelTts: null,
            ));
          }
          continue;
        }
        if (e is Map) {
          final m = Map<String, dynamic>.from(e);
          final action = _canonicalAction(
            (m['action'] ?? m['type'] ?? m['category']).toString(),
          );
          final reply = (m['reply'] ??
                  m['text'] ??
                  m['step'] ??
                  m['description'] ??
                  m['content'] ??
                  '')
              .toString()
              .trim();
          if (reply.isEmpty) continue;
          final exprRaw = (m['expression'] ??
                  m['emotion'] ??
                  m['face'] ??
                  m['表情'])
              .toString();
          final expr = PlannerExpressionCatalog.canonicalize(exprRaw);
          final parallelRaw = (m['parallel_tts'] ??
                  m['parallelTts'] ??
                  m['tts_parallel'] ??
                  m['speak_parallel'] ??
                  '')
              .toString()
              .trim();
          final parallelTts = parallelRaw.isEmpty ? null : parallelRaw;
          out.add(PlannerStep(
            action: action,
            expression: expr,
            reply: reply,
            parallelTts: parallelTts,
          ));
        }
      }
      final compact = _compactVisionNarrationSteps(out);
      return _filterMeaningfulSteps(compact);
    } catch (_) {
      return const [];
    }
  }

  List<PlannerStep> _compactVisionNarrationSteps(List<PlannerStep> src) {
    if (src.length < 2) return src;
    final out = <PlannerStep>[];
    for (var i = 0; i < src.length; i++) {
      final cur = src[i];
      if (i > 0) {
        final prev = src[i - 1];
        final text = cur.reply.replaceAll(RegExp(r'\s+'), '').toLowerCase();
        final isGenericVisionNarration = cur.action == 'TTS 播报' &&
            prev.action == '视觉/VLM' &&
            (text.contains('描述当前场景') ||
                text.contains('播报识别结果') ||
                text.contains('播报分析结果') ||
                text.contains('开始描述') ||
                text.contains('说说看到了什么'));
        if (isGenericVisionNarration) {
          continue;
        }
      }
      out.add(cur);
    }
    return out;
  }

  List<PlannerStep> _filterMeaningfulSteps(List<PlannerStep> src) {
    final out = <PlannerStep>[];
    for (final s in src) {
      final text = s.reply.replaceAll(RegExp(r'\s+'), '').toLowerCase();
      if (text.isEmpty) continue;
      if (s.action == '蓝牙动作') {
        const actionHints = [
          '前进',
          '后退',
          '左转',
          '右转',
          '转圈',
          '旋转',
          '停止',
          '抬头',
          '低头',
          '上升',
          '下降',
          '点头',
        ];
        if (!actionHints.any(text.contains)) {
          continue;
        }
      }
      if (s.action == '视觉/VLM') {
        const visionHints = [
          '视觉',
          'vlm',
          '相机',
          '拍照',
          '识别',
          '看看',
          '场景',
          '分析',
          '多图',
          '联合',
          '综合',
        ];
        if (!visionHints.any(text.contains)) {
          continue;
        }
      }
      out.add(s);
    }
    return out;
  }

  String _canonicalAction(String raw) {
    final t = raw.trim();
    if (t.contains('蓝牙') || t.contains('动作') || t.contains('移动') || t.contains('转')) {
      return '蓝牙动作';
    }
    if (t.contains('视觉') || t.contains('vlm') || t.contains('相机') || t.contains('拍照') || t.contains('识别')) {
      return '视觉/VLM';
    }
    if (t.contains('tts') || t.contains('播报') || t.contains('语音') || t.contains('回复')) {
      return 'TTS 播报';
    }
    return 'TTS 播报';
  }
}
