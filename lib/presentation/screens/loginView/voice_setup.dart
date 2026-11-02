import 'package:flutter/material.dart';
import 'package:voicegpt/app/routes/app.routes.dart';

class VoiceProfile {
  final String name;
  final String id;
  final IconData icon;
  final Color color;
  final bool isCustom;
  final String description;

  const VoiceProfile({
    required this.name,
    required this.id,
    required this.icon,
    required this.color,
    required this.isCustom,
    required this.description,
  });
}

class VoiceSetupPage extends StatefulWidget {
  const VoiceSetupPage({super.key});

  @override
  State<VoiceSetupPage> createState() => _VoiceSetupPageState();
}

class _VoiceSetupPageState extends State<VoiceSetupPage> {
  final List<VoiceProfile> _voices = const [
    VoiceProfile(
      name: '温柔女声',
      id: 'voice_female_gentle',
      icon: Icons.female,
      color: Colors.pink,
      isCustom: false,
      description: '温暖柔和的女声，适合情感表达',
    ),
    VoiceProfile(
      name: '磁性男声',
      id: 'voice_male_magnetic',
      icon: Icons.male,
      color: Colors.blue,
      isCustom: false,
      description: '沉稳磁性的男声，适合正式场合',
    ),
    VoiceProfile(
      name: '自定义声线',
      id: 'custom',
      icon: Icons.build,
      color: Colors.purple,
      isCustom: true,
      description: '上传自定义语音模型（示例实现）',
    ),
  ];

  VoiceProfile? _selected;

  @override
  Widget build(BuildContext context) {
    final canContinue = _selected != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('语音设置'),
        backgroundColor: Colors.deepPurple[700],
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '选择语音声线',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                '请选择您喜欢的语音声线，这是必要设置。',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 22),
              Expanded(
                child: GridView.builder(
                  itemCount: _voices.length,
                  shrinkWrap: true,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                    childAspectRatio: 0.85,
                  ),
                  itemBuilder: (context, index) {
                    final voice = _voices[index];
                    final isSelected = _selected?.id == voice.id;

                    return InkWell(
                      onTap: () => setState(() => _selected = voice),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          color: isSelected
                              ? voice.color.withOpacity(0.12)
                              : Colors.grey[100],
                          border: Border.all(
                            color:
                                isSelected ? voice.color : Colors.transparent,
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(voice.icon,
                                size: 34,
                                color: isSelected
                                    ? voice.color
                                    : Colors.grey[700]),
                            const SizedBox(height: 12),
                            Text(
                              voice.name,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                                color:
                                    isSelected ? voice.color : Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              voice.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: canContinue
                      ? () {
                          final selected = _selected!;
                          if (selected.isCustom) {
                            Navigator.of(context)
                                .pushNamed(AppRoutes.voicecreateRoute);
                          } else {
                            Navigator.of(context)
                                .pushNamed(AppRoutes.userRoute);
                          }
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        canContinue ? Colors.deepPurple : Colors.grey[400],
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                    elevation: 2,
                  ),
                  child: const Text(
                    '继续设置',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
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
