import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:voicegpt/app/routes/app.routes.dart';
import 'app/provider/app.provider.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:voicegpt/core/storage/app_database.dart';
import 'package:voicegpt/core/storage/preference_manager.dart';

import 'core/services/bluetooth_service.dart'; // 使用 MyBluetoothService

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  sherpa_onnx.initBindings();
  await PreferenceManager().init();
  await AppDatabase.instance.init();

  // 设置包含刘海区域的全屏显示
  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.edgeToEdge,
    overlays: [],
  );

  // 设置系统UI样式 - 确保刘海区域为黑色
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarDividerColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // 方向由 AndroidManifest 的 sensorLandscape 统一管理（仅左右横屏），
  // 避免 Flutter 层再次锁定导致个别机型旋转不跟随。
  // 启用屏幕常亮
  await WakelockPlus.enable();

  // ✅ 创建并尝试自动重连蓝牙
  final bluetoothService = MyBluetoothService();
  await bluetoothService.startAutoReconnect();

  //runApp(const Core());
  runApp(Core(bluetoothService: bluetoothService));
}

class Core extends StatelessWidget {
  final MyBluetoothService bluetoothService;
  //const Core({Key? key}) : super(key: key);
  const Core({Key? key, required this.bluetoothService}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ...AppProvider.providers,
        ChangeNotifierProvider<MyBluetoothService>.value(
          value: bluetoothService,
        ),
      ],
      child: const Lava(),
    );
  }
}

class Lava extends StatelessWidget {
  const Lava({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VoiceGPT',
      debugShowCheckedModeBanner: false,
      initialRoute: AppRoutes.splashRoute,
      theme: ThemeData(
        fontFamily: 'roboto',
      ),
      routes: AppRoutes.routes,
    );
  }
}
