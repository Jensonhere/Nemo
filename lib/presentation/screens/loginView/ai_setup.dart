import 'package:flutter/material.dart';
import 'package:voicegpt/app/routes/app.routes.dart';

class PersonSetupPage extends StatefulWidget {
  const PersonSetupPage({super.key});

  @override
  State<PersonSetupPage> createState() => _PersonSetupPageState();
}

class _PersonSetupPageState extends State<PersonSetupPage> {
  String? _selectedPersonality;

  final List<PersonalityOption> _personalities = [
    PersonalityOption(
      emoji: '🌞',
      name: '阳光活力型',
      description: '积极乐观，充满能量，总是能给您带来好心情。善于鼓励和肯定。',
    ),
    PersonalityOption(
      emoji: '🤔',
      name: '睿智博学型',
      description: '理性冷静，知识渊博，像一位耐心的导师。善于分析和提供深度见解。',
    ),
    PersonalityOption(
      emoji: '🤝',
      name: '温柔治愈型',
      description: '善解人意，体贴入微，能提供情绪价值。是一个绝佳的倾听者。',
    ),
    PersonalityOption(
      emoji: '⚡',
      name: '简洁高效型',
      description: '回复直接，切中要害，不拖泥带水。适合追求效率的用户。',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final canContinue = _selectedPersonality != null;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('创造您的专属伙伴'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '现在，来创造您的专属伙伴！',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '选择您喜欢的性格，让TA独一无二。',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.black54,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                '选择性格（核心特质）',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 16),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: 0.78,
                ),
                itemCount: _personalities.length,
                itemBuilder: (context, index) {
                  final p = _personalities[index];
                  final isSelected = _selectedPersonality == p.name;
                  return GestureDetector(
                    onTap: () => setState(() => _selectedPersonality = p.name),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.blue[50] : Colors.grey[50],
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isSelected ? Colors.blue : Colors.grey[300]!,
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: Text(p.emoji,
                                style: const TextStyle(fontSize: 24)),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            p.name,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            p.description,
                            textAlign: TextAlign.center,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[700],
                              height: 1.3,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color:
                                  isSelected ? Colors.blue : Colors.transparent,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSelected
                                    ? Colors.blue
                                    : Colors.grey[400]!,
                                width: 2,
                              ),
                            ),
                            child: isSelected
                                ? const Icon(Icons.check,
                                    size: 12, color: Colors.white)
                                : null,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: canContinue
                      ? () {
                          Navigator.of(context).pushNamed(AppRoutes.voiceRoute);
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        canContinue ? Colors.blue[600] : Colors.grey[400],
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  child: const Text(
                    '开始对话！',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PersonalityOption {
  final String emoji;
  final String name;
  final String description;

  const PersonalityOption({
    required this.emoji,
    required this.name,
    required this.description,
  });
}
