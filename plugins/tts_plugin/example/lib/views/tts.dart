import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tts_plugin/tts_plugin.dart';
import 'package:tts_plugin_example/config.dart';
import 'package:tts_plugin_example/models/common.dart';

class TTSView extends StatefulWidget {
  const TTSView({super.key});

  @override
  State<TTSView> createState() => _TTSViewState();
}

class _TTSViewState extends State<TTSView> {
  final List<VoiceType> _voices = [
    VoiceType(1001, '智瑜(女)'),
    VoiceType(101001, "智瑜(精品-女)"),
    VoiceType(1002, "智聆(女)"),
    VoiceType(101002, "智聆(精品-女)"),
    VoiceType(1004, "智云(男)"),
    VoiceType(101004, "智云(精品-男)"),
    VoiceType(1005, "智莉(女)"),
    VoiceType(101005, "智莉(精品-女)"),
    VoiceType(101003, "智美(精品-女)"),
    VoiceType(1007, "智娜(女)"),
    VoiceType(101007, "智娜(精品-女)"),
    VoiceType(101006, "智言(精品-女)"),
    VoiceType(101014, "智宁(精品-男)"),
    VoiceType(101016, "智甜(精品-女)"),
    VoiceType(1017, "智蓉(女)"),
    VoiceType(101017, "智蓉(精品-女)"),
    VoiceType(1008, "智琪(女)"),
    VoiceType(101008, "智琪(精品-女)"),
    VoiceType(10510000, "智逍遥(男)"),
  ];

  final List<LanguageType> _languages = [
    LanguageType(1, '中文'),
    LanguageType(2, '英文'),
  ];

  final List<CodecType> _codecs = [
    CodecType("wav", 'wav'),
    CodecType("mp3", 'mp3'),
  ];

  final _textController = TextEditingController();
  String _text = "腾讯云语音合成技术可以将任意文本转化为语音，实现让机器和应用张口说话。";
  String _result = "";
  int _state = 0;
  String _synthesize_file_path = "";
  var _config = TTSControllerConfig();
  var _player = AudioPlayer();
  late StreamSubscription<TTSData> _sub;

  @override
  void initState() {
    // TODO: implement initState
    super.initState();
    _textController.text = _text;
    _config.secretId = secretId;
    _config.secretKey = secretKey;
    _config.token = token;

    final AudioContext audioContext = AudioContext(
        iOS: AudioContextIOS(
          defaultToSpeaker: true,
          category: AVAudioSessionCategory.playAndRecord,
          options: [
            AVAudioSessionOptions.defaultToSpeaker,
            AVAudioSessionOptions.mixWithOthers,
          ],
        ),
        android: AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: true,
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.gain,
        ));
    AudioPlayer.global.setGlobalAudioContext(audioContext);
    _player = AudioPlayer();
    _player.onPlayerComplete.listen((event) {
      setState(() {
        _state = 0;
      });
    });

    _sub = TTSController.instance.listener.handleError((e){
      if (e is TTSError) {
        setState((){
          _result =
          "${e.message}\n${e.serverMessage != null ? e.serverMessage! : ""}";
          _state = 0;
        });
      }else {
        setState(() {
        _result = e.toString();
        _state = 0;
      });
      }
    }).listen((ret) async {
      final dir = await getTemporaryDirectory();
      var file = await File(
          "${dir.path}/tmp_${DateTime.now().millisecondsSinceEpoch}_${_config.voiceVolume}.${_config.codec}")
          .writeAsBytes(ret.data);
      setState(() {
        _result = "合成成功";
        _state = 0;
        _synthesize_file_path =
            file.absolute.path;
      });
    });
  }

  @override
  void dispose() {
    super.dispose();
    _sub.cancel();
  }



  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        home: Scaffold(
            appBar: AppBar(
              title: const Text('TTS'),
              leading: BackButton(onPressed: () {
                Navigator.pop(context);
              }),
            ),
            body: Listener(
              onPointerDown: (evt) {
                FocusManager.instance.primaryFocus?.unfocus();
              },
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExpansionTile(
                      title: const Text('设置'),
                      children: [
                        Row(
                          children: [
                            const Expanded(child: Text('音色')),
                            DropdownButton(
                                value: _config.voiceType,
                                items: _voices.map<DropdownMenuItem>((e) {
                                  return DropdownMenuItem(
                                    value: e.id,
                                    child: Text(e.label),
                                  );
                                }).toList(),
                                onChanged: (e) {
                                  setState(() {
                                    _config.voiceType = e;
                                  });
                                })
                          ],
                        ),
                        Row(
                          children: [
                            const Expanded(child: Text('语言')),
                            DropdownButton(
                                value: _config.voiceLanguage,
                                items: _languages.map<DropdownMenuItem>((e) {
                                  return DropdownMenuItem(
                                    value: e.id,
                                    child: Text(e.label),
                                  );
                                }).toList(),
                                onChanged: (e) {
                                  setState(() {
                                    _config.voiceLanguage = e;
                                  });
                                })
                          ],
                        ),
                        Row(
                          children: [
                            const Expanded(child: Text('编码')),
                            DropdownButton(
                                value: _config.codec,
                                items: _codecs.map<DropdownMenuItem>((e) {
                                  return DropdownMenuItem(
                                    value: e.value,
                                    child: Text(e.label),
                                  );
                                }).toList(),
                                onChanged: (e) {
                                  setState(() {
                                    _config.codec = e;
                                  });
                                })
                          ],
                        ),
                        Row(
                          children: [
                            const Expanded(child: Text('倍速')),
                            Slider(
                                value: _config.voiceSpeed,
                                label: '${_config.voiceSpeed}',
                                max: 2,
                                min: -2,
                                divisions: 40,
                                onChanged: (e) {
                                  setState(() {
                                    _config.voiceSpeed =
                                        (e * 10).roundToDouble() / 10;
                                  });
                                })
                          ],
                        ),
                        Row(
                          children: [
                            const Expanded(child: Text('音量')),
                            Slider(
                                value: _config.voiceVolume,
                                label: '${_config.voiceVolume}',
                                max: 10,
                                min: 0,
                                divisions: 100,
                                onChanged: (e) {
                                  setState(() {
                                    _config.voiceVolume =
                                        (e * 10).roundToDouble() / 10;
                                  });
                                })
                          ],
                        ),
                        Row(
                          children: [
                            const Expanded(child: Text('连接超时')),
                            Slider(
                                value: _config.connectTimeout.toDouble(),
                                label: '${_config.connectTimeout}',
                                max: 30000,
                                min: 500,
                                divisions: 30000 - 500,
                                onChanged: (e) {
                                  setState(() {
                                    _config.connectTimeout = e.toInt();
                                  });
                                })
                          ],
                        ),
                        Row(
                          children: [
                            const Expanded(child: Text('读取超时')),
                            Slider(
                                value: _config.readTimeout.toDouble(),
                                label: '${_config.readTimeout}',
                                max: 60000,
                                min: 2200,
                                divisions: 60000 - 2200,
                                onChanged: (e) {
                                  setState(() {
                                    _config.readTimeout = e.toInt();
                                  });
                                })
                          ],
                        ),
                      ],
                    ),
                    const ListTile(title: Text('合成文本')),
                    TextField(
                        onChanged: (String text) async {
                          _text = text;
                        },
                        controller: _textController,
                        keyboardType: TextInputType.multiline,
                        maxLines: null),
                    Row(children: [
                      ElevatedButton(
                          onPressed: _state == 0
                              ? () async {
                                  if (_text == "") {
                                    return;
                                  }
                                  setState(() {
                                    _result = "合成中...";
                                    _state = 1;
                                    _synthesize_file_path = "";
                                  });
                                  _player.stop();
                                  TTSController.instance.config = _config;
                                  try {
                                    await TTSController.instance.setApiParam("EnableSubtitle", true);
                                    await TTSController.instance
                                        .synthesize(_text, null);
                                  } on TTSError catch (e) {
                                    setState(() {
                                      _result =
                                          "${e.message}\n${e.serverMessage != null ? e.serverMessage! : ""}";
                                      _state = 0;
                                    });
                                  } catch (e) {
                                    setState(() {
                                      _result = e.toString();
                                      _state = 0;
                                    });
                                  }
                                }
                              : null,
                          child: const Text("合成")),
                      const SizedBox(width: 10),
                      ElevatedButton(
                          onPressed:
                              (_state == 0 && _synthesize_file_path != "") ||
                                      _state == 2
                                  ? () async {
                                      if (_state == 0) {
                                        await _player.setSourceDeviceFile(
                                            _synthesize_file_path);
                                        await _player.resume();
                                        setState(() {
                                          _state = 2;
                                        });
                                      } else {
                                        await _player.release();
                                        setState(() {
                                          _state = 0;
                                        });
                                      }
                                    }
                                  : null,
                          child: Text(_state == 2 ? '停止' : '播放')),
                      const SizedBox(
                        width: 10,
                      ),
                      ElevatedButton(
                          onPressed: _state == 0 && _synthesize_file_path != ""
                              ? () async {
                                  await Share.shareFiles(
                                      [_synthesize_file_path]);
                                }
                              : null,
                          child: const Text('分享'))
                    ]),
                    ListTile(title: Text('信息: $_result'))
                  ],
                ),
              ),
            )));
  }
}
