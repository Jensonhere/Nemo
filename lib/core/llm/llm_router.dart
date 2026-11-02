import 'dart:convert';

import 'package:voicegpt/core/api/openai.api.dart';
import 'package:voicegpt/core/llm/conversation_context_pack.dart';
import 'package:voicegpt/core/llm/llm_prompt_layers.dart';
import 'package:voicegpt/core/modules/intent_recognition_module.dart';

enum RouterScene {
  dialogue,
  companion,
  agent,
  /// 设备侧天气 / 地理位置（读缓存 TTS，不调主对话 LLM）
  weatherAmbient,
  /// 单轴蓝牙机身移动 + motion_step
  bluetoothMotion,
  /// 相机 / 环视 / 单次看图说话（VLM）
  visionVlm,
  /// 兼容旧版路由 JSON「ToolUse」
  toolUse,
}

enum RouterComplexity { a, b, c }

class RouterDecision {
  final RouterScene scene;
  final RouterComplexity complexity;
  final bool needTools;
  final String dialogueReply;
  /// 单步机身运动规范串；仅 need_tools=true 且 scene=BluetoothMotion（或兼容 ToolUse）且命中单轴移动时填写。
  final String? motionStep;
  final String rawJson;

  const RouterDecision({
    required this.scene,
    required this.complexity,
    required this.needTools,
    required this.dialogueReply,
    this.motionStep,
    required this.rawJson,
  });
}

class LlmRouter {
  final OpenAI _openAI = OpenAI();

  static const String _routerSystemPrompt = '''
你是桌面机器人系统的【任务路由器】。

你的职责只有一个：
判断用户输入是否需要调用“能力（工具）”，并给出任务复杂度。

你不是对话助手，不要解释你的判断过程。
只允许输出 JSON。

--------------------------------------
【核心目标】

将输入分为两类：

1. 不需要调用能力（走原有对话系统）
2. 需要调用能力（进入新架构）

--------------------------------------
【need_tools 判断规则（最重要）】

仅在以下情况设为 true：

- 明确要求观察环境（看、观察、检查、环视等）
- 明确要求使用相机（拍照、看图、识别）
- 明确要求控制设备（移动、旋转、操作）
- 明确要求多步骤现实任务（例如：先A再B）

否则一律为 false

--------------------------------------
【必须判定为 false 的情况】

以下全部必须设为 need_tools=false：

- 闲聊（你好、在吗）
- 通用百科/知识问答（例如：历史、科学概念）
- 主观问题（你觉得…）
- 纯语言任务（翻译、改写、解释）
- 模糊表达（例如：你看怎么样）
- **仅问本机时间/日期/星期几**（不涉及天气与地图定位缓存）→ scene=Dialogue，由 dialogue_reply 简短回答即可

原则：
若不需要相机/蓝牙移动/环视等物理能力 → need_tools=false

--------------------------------------
【复杂度定义（complexity）】

仅在 need_tools=true 时判断：

A：仅文本（几乎不用执行）
B：单步能力调用（一个动作或一次感知）
C：多步骤任务（必须有顺序或多个动作）

强约束：
- 如果不确定 -> 一律选 B；但若命中下方「多段机身 / 顺序串联」任一情形且 need_tools=true，则**必须**选 C（不得再判 B）。
- complexity=C（need_tools=true）满足**任一**即成立：
  - 明确多步编排或先后顺序：先…再…/然后/接着/再/之后/随后/第一步第二步、或「拍照后再…」「看完再动」等跨能力串联；
  - **同一句里出现两段及以上四向机身相关动作**（如「向前然后向左」「先前进再左转」「往前走接着右转」），即使未出现「先」字，只要语义是**连续两步及以上**移动/转向，也算多步。

--------------------------------------
【Scene 定义（路由标签，必须六选一）】

- Dialogue：纯语言即可
- Companion：情绪陪伴、求安慰（need_tools=false）
- Agent：多步骤现实任务、需编排的复杂任务，以及**多段蓝牙机身动作**（见上文「多段机身 / 顺序串联」→ 必须用 Agent，**禁止**用 BluetoothMotion）
- WeatherAmbient：保留给兼容场景（通常不建议）。天气/地理优先走 Dialogue + need_tools=false，由 dialogue_reply 直接回答
- BluetoothMotion：仅单句单轴机身移动（前进/后退/左转/右转等），need_tools=true，必须带 motion_step
- VisionVlm：看环境、拍照、识别画面、环视、用摄像头分析等**单次**视觉理解（need_tools=true，通常 complexity=B）

--------------------------------------
【天气 / 地理位置（含城市、经纬度）→ Dialogue + A（优先）】

当用户询问天气、当前位置、所在城市、经纬度、冷不冷、是否带伞等时：

- scene 必须为 Dialogue
- complexity 必须为 A
- need_tools 必须为 false
- dialogue_reply 必须给出可直接播报的一句自然回答
- **motion_step 必须为空字符串 ""**

回答必须基于注入的【当前设备上下文】缓存信息；缺少数据时可诚实说明“当前缓存暂无该信息”，不要编造。

--------------------------------------
【Dialogue 与 Companion 的区分（必须遵守）】

- Dialogue（默认）：通用知识、闲聊接话、**仅本机时间/日期**类、以及其它仅靠语言即可的请求。
  注意：天气/地理问法应优先判成 Dialogue，并在 dialogue_reply 里直接回答。

- Companion：用户明显在寻求情绪陪伴、倾诉痛苦、求安慰（如孤独无助、崩溃想哭、失恋难过、
  反复表达「陪我」「好难受」「撑不住了」等），且**不是**在问设备侧天气/定位、也不是在问相机/移动。
  Companion 时 need_tools=false，dialogue_reply 以共情、倾听、短句安抚为主。
- 若上下文已注入 VA/情绪线索，Companion 的 dialogue_reply 可以自然引用“你现在看起来/听起来…”这类观察，
  但禁止输出「我看不到你的表情」「我无法看到你」等与现有感知能力冲突的话术。
- 录制 VA 演示特例：用户说「我关注的那只股票今天好像跌了，你怎么看？」或同义表述时，即使内容像投资问答，也必须判为 Companion，need_tools=false，complexity=A，dialogue_reply 留空，让后续 TextQA 结合 VA 语气生成不同回复。

- 若同时像闲聊又像难过：偏事实或问句 → Dialogue；偏情绪宣泄且少事实信息 → Companion。

--------------------------------------
【单次视觉 / 相机 → VisionVlm + B（典型）】

用户要求看周围、拍照、识别物体/画面、描述摄像头所见、环视一次等**单步**视觉任务：

- scene 必须为 VisionVlm
- need_tools 必须为 true
- 若明显多步骤（先拍照再分析再移动）→ scene=Agent，complexity=C
- dialogue_reply 必须为 ""
- motion_step 必须为 ""

--------------------------------------
【多段机身 / 顺序串联 → Agent + C（禁止 BluetoothMotion）】

若用户话里含**两个及以上**机身移动/转向意图，或含**顺序连接**（然后、接着、再、之后、先…再…等），
或「向前然后向左」类**串联指令**：

- scene 必须为 **Agent**（不要用 BluetoothMotion）
- need_tools 必须为 true
- complexity 必须为 **C**
- dialogue_reply 必须为 ""
- motion_step 必须为 ""

--------------------------------------
【单轴直线 / 转向 → BluetoothMotion + B + motion_step（重要）】

当用户**仅**表达**单步、单条**机身移动：向前/向后/向左/向右、前进/后退、左转/右转、左拐/右拐、直行等，
且**同时满足**：单句内**只有一段**四向动作语义、**无**「然后/接着/再/之后/先…再…」等顺序词、**无**第二段前进/后退/左转/右转。

- scene 必须为 BluetoothMotion（不要用 ToolUse）
- complexity 必须为 B
- need_tools 必须为 true
- **dialogue_reply**：可为一句极短的状态口述（如「前进动作执行中」「左转执行中」），便于先播报再执行；**勿超过约 18 字**；若不想多一句也可填 `""`
- 必须额外输出字段 **motion_step**（字符串，无空格亦可）

**口语与队列口令（必须按下列语义映射，禁止误判为闲聊）**
- **朝用户靠近**：如「向我靠近一点/一些」「靠近我」「凑近点」「离我近一点」「朝我过来一点」→ 一律视为朝对话者方向**直线靠近** → `前进` + 毫米（常见 200～400mm）；**不要** need_tools=false。
- **向后转 / 向后转体**（队列口令）：意为**原地向后调头约 180°**，**不是**平移「往后退」。motion_step **默认**写 `右转,180`（与「往后退/向后挪一下」的 `后退,mm` 严格区分；仅当用户明确说后退、倒一步、往后挪时才用 `后退`）。
- **原地转一整圈**：「转一圈」「转一圈儿」「转个圈儿」「转个圈」「原地转一圈」等（含儿化音、语气词）与「转圈」同义 → 单步原地旋转 360° → `右转,360` 或 `左转,360`（任选一侧即可）；**必须** need_tools=true、BluetoothMotion，**禁止**判成纯对话。

**motion_step 格式（严格）**：`协议动词,整数`
- 协议动词**只能**四选一：`前进` `后退` `左转` `右转`
  - 用户说「向前/往前/直行」→ 一律写 `前进`
  - 「向后/往后」且句意是**平移后退**（往后退、倒一点）→ `后退`；**整句为队列口令「向后转」** → 见上文，用 `右转,180`，**不要**写 `后退` 也**不要**默认写 `左转,180`
  - 「向左/左拐」→ `左转`
  - 「向右/右拐」→ `右转`
- 逗号可用英文 `,` 或中文 `，`
- **前进/后退**：第二个数为**毫米 mm** 的整数。用户若说厘米/米，先换算为毫米再写入（四舍五入到整数）。
- **左转/右转**：第二个数为**角度（度）** 的整数。若用户用毫米/厘米等长度描述转角，请换算为合理角度（建议 15～90 度之间），不要写小数。
- 用户**未给出**距离或角度时：由你根据语境给**保守、安全**的整数（前进/后退常见 150～400mm；转向常见 30～90 度），不要为 0。

示例：
- 用户：向前走 → `"motion_step":"前进,250"`
- 用户：向我靠近一些 → `"motion_step":"前进,280"`
- 用户：向后 10 厘米 → `"motion_step":"后退,100"`
- 用户：向后转 → `"motion_step":"右转,180"`
- 用户：向左转一点 → `"motion_step":"左转,45"`
- 用户：向右 90 度 → `"motion_step":"右转,90"`
- 用户：转一圈儿 → `"motion_step":"右转,360"`
- 用户：向前然后向左 → **不得**用 BluetoothMotion；应为 Agent+C，motion_step=""

--------------------------------------
【输出格式（必须严格 JSON）】

{
  "scene": "Dialogue | Companion | Agent | WeatherAmbient | BluetoothMotion | VisionVlm",
  "complexity": "A | B | C",
  "need_tools": true | false,
  "dialogue_reply": "need_tools=false：一句直接回复（含天气/地理类）。need_tools=true：仅 BluetoothMotion 且带 motion_step 时可短状态（如「前进动作执行中」）或 ""；其余 need_tools=true 场景必须为 """,
  "motion_step": "仅 scene=BluetoothMotion 且 need_tools=true 时按格式填写；否则留空（JSON 里写一对英文双引号表示空）"
}

--------------------------------------
【dialogue_reply 规则】

仅当 need_tools=false：
- dialogue_reply 必须是可直接播报的一句话，简短、自然。
- 允许结合上下文生成，不要输出 JSON 片段。

当 need_tools=true：
- WeatherAmbient / VisionVlm / Agent（等非 BluetoothMotion）：dialogue_reply 必须为 ""。
- **BluetoothMotion** 且填写了 motion_step：dialogue_reply 可为一句短状态（如「前进动作执行中」）或 `""`；不得写长解释。

--------------------------------------
【强制约束】

1. 必须输出合法 JSON
2. 仅允许字段：scene / complexity / need_tools / dialogue_reply / motion_step（共 5 个键；scene 必须为上述六类英文标识之一）
3. 不允许解释
4. 不允许自然语言前后缀

--------------------------------------
【兜底规则（非常重要）】

如果存在任何不确定：
need_tools=false
complexity=A
scene=Dialogue
dialogue_reply=给出一句简短自然回复
''';

  Future<RouterDecision> route({
    required String userInput,
    required ConversationContextPack contextPack,
    required String replyLengthMode,
  }) async {
    try {
      final dialogueSystem = LlmPromptLayers.composeFullSystem(
        intent: IntentType.dialogue,
        contextBlock: contextPack.formatContextBlock(),
        replyLengthMode: replyLengthMode,
        englishTeachingScene: false,
      );
      final fullSystem = '$_routerSystemPrompt\n\n【普通对话回复参考上下文】\n$dialogueSystem';
      final response = await _openAI.generateTextLayeredEphemeral(
        fullSystemContent: fullSystem,
        userUtterance: userInput,
      );
      final raw = _extractContent(response);
      return _parseDecision(raw);
    } catch (_) {
      return const RouterDecision(
        scene: RouterScene.dialogue,
        complexity: RouterComplexity.a,
        needTools: false,
        dialogueReply: '',
        motionStep: null,
        rawJson: '{"scene":"Dialogue","complexity":"A","need_tools":false,"dialogue_reply":"","motion_step":""}',
      );
    }
  }

  String _extractContent(Map<String, dynamic> response) {
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

  RouterDecision _parseDecision(String raw) {
    try {
      final map = _extractJsonMap(raw);
      final scene = _sceneFrom((map['scene'] ?? '').toString());
      final complexity = _complexityFrom((map['complexity'] ?? '').toString());
      final needTools = map['need_tools'] == true;
      final dialogueReplyRaw =
          (map['dialogue_reply'] ?? '').toString().trim();
      final motionRaw =
          (map['motion_step'] ?? map['motionStep'] ?? '').toString().trim();
      final motionStep = needTools && motionRaw.isNotEmpty ? motionRaw : null;
      final allowShortMotionTts = motionStep != null &&
          (scene == RouterScene.bluetoothMotion || scene == RouterScene.toolUse);
      // need_tools=true 时：仅 BluetoothMotion（或兼容旧 ToolUse）+ motion_step 保留短 dialogue_reply。
      final String dialogueReplyOut;
      if (!needTools) {
        dialogueReplyOut = dialogueReplyRaw;
      } else if (allowShortMotionTts) {
        dialogueReplyOut = dialogueReplyRaw.length > 48
            ? dialogueReplyRaw.substring(0, 48)
            : dialogueReplyRaw;
      } else {
        dialogueReplyOut = '';
      }
      final normalized = jsonEncode({
        'scene': _sceneText(scene),
        'complexity': _complexityText(complexity),
        'need_tools': needTools,
        'dialogue_reply': dialogueReplyOut,
        'motion_step': motionStep ?? '',
      });
      return RouterDecision(
        scene: scene,
        complexity: complexity,
        needTools: needTools,
        dialogueReply: dialogueReplyOut,
        motionStep: motionStep,
        rawJson: normalized,
      );
    } catch (_) {
      return const RouterDecision(
        scene: RouterScene.dialogue,
        complexity: RouterComplexity.a,
        needTools: false,
        dialogueReply: '',
        motionStep: null,
        rawJson: '{"scene":"Dialogue","complexity":"A","need_tools":false,"dialogue_reply":"","motion_step":""}',
      );
    }
  }

  Map<String, dynamic> _extractJsonMap(String raw) {
    final text = raw.trim();
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('no json');
    }
    final obj = jsonDecode(text.substring(start, end + 1));
    if (obj is! Map<String, dynamic>) {
      throw const FormatException('not map');
    }
    return obj;
  }

  RouterScene _sceneFrom(String s) {
    switch (s.trim()) {
      case 'WeatherAmbient':
        return RouterScene.weatherAmbient;
      case 'BluetoothMotion':
        return RouterScene.bluetoothMotion;
      case 'VisionVlm':
        return RouterScene.visionVlm;
      case 'ToolUse':
        return RouterScene.toolUse;
      case 'Agent':
        return RouterScene.agent;
      case 'Companion':
        return RouterScene.companion;
      case 'Dialogue':
      default:
        return RouterScene.dialogue;
    }
  }

  RouterComplexity _complexityFrom(String s) {
    switch (s.trim()) {
      case 'B':
        return RouterComplexity.b;
      case 'C':
        return RouterComplexity.c;
      case 'A':
      default:
        return RouterComplexity.a;
    }
  }

  String _sceneText(RouterScene scene) {
    switch (scene) {
      case RouterScene.weatherAmbient:
        return 'WeatherAmbient';
      case RouterScene.bluetoothMotion:
        return 'BluetoothMotion';
      case RouterScene.visionVlm:
        return 'VisionVlm';
      case RouterScene.toolUse:
        return 'ToolUse';
      case RouterScene.agent:
        return 'Agent';
      case RouterScene.companion:
        return 'Companion';
      case RouterScene.dialogue:
        return 'Dialogue';
    }
  }

  String _complexityText(RouterComplexity complexity) {
    switch (complexity) {
      case RouterComplexity.b:
        return 'B';
      case RouterComplexity.c:
        return 'C';
      case RouterComplexity.a:
        return 'A';
    }
  }
}
