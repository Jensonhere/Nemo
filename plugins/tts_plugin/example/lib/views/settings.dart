import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../config.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});
  @override
  State<StatefulWidget> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final _secretid_controller = TextEditingController();
  final _secretkey_controller = TextEditingController();
  final _token_controller = TextEditingController();
  bool _enable_token = false;

  @override
  void initState() {
    super.initState();
    _secretid_controller.text = secretId;
    _secretkey_controller.text = secretKey;
    _enable_token = false;
    if (token != null) {
      _token_controller.text = token!;
      _enable_token = true;
    }
  }

  Widget show_token() {
    return _enable_token
        ? Row(
      children: [
        Expanded(
            child: TextField(
              controller: _token_controller,
            )),
        const SizedBox(width: 10)
      ],
    )
        : Container();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        home: Scaffold(
            appBar: AppBar(
              title: const Text('设置'),
              leading: BackButton(onPressed: () {
                Navigator.pop(context);
              }),
            ),
            body: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(5, 0, 5, 0),
              child: Column(
                children: [
                  const SizedBox(
                    height: 10,
                  ),
                  Row(
                    children: const [
                      Expanded(child: Text('SECRETID')),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                          child: TextField(
                            controller: _secretid_controller,
                          )),
                    ],
                  ),
                  const SizedBox(
                    height: 10,
                  ),
                  Row(
                    children: const [
                      Expanded(child: Text('SECRETKEY')),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                          child: TextField(
                            controller: _secretkey_controller,
                          )),
                      const SizedBox(width: 10)
                    ],
                  ),
                  const SizedBox(
                    height: 10,
                  ),
                  Row(
                    children: [
                      const Expanded(child: Text('TOKEN (临时密钥)')),
                      Checkbox(
                          value: _enable_token,
                          onChanged: (e) {
                            setState(() {
                              _enable_token = e!;
                            });
                          })
                    ],
                  ),
                  show_token(),
                  const SizedBox(
                    height: 20,
                  ),
                  Row(children: [
                    const Expanded(child: SizedBox()),
                    ElevatedButton(onPressed: (){
                      setState(() {
                        secretId = "";
                        secretKey = "";
                        if (_enable_token) {
                          token = "";
                          _token_controller.text = "";
                        }
                        _secretid_controller.text = "";
                        _secretkey_controller.text = "";
                      });
                    }, child: const Text('清除')),
                    const SizedBox(width: 5,),
                    ElevatedButton(
                        onPressed: () {
                          secretId = _secretid_controller.text;
                          secretKey = _secretkey_controller.text;
                          if (_enable_token) {
                            token = _token_controller.text;
                          } else {
                            token = null;
                          }
                        },
                        child: const Text('保存'))
                  ])
                ],
              ),
            )));
  }
}
