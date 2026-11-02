import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:voicegpt/core/services/bluetooth_service.dart';

/// 左上角：蓝牙未连接、权限未授予时显示对应标签；就绪后自动隐藏。
class ConnectionPermissionStatusStrip extends StatefulWidget {
  const ConnectionPermissionStatusStrip({super.key});

  @override
  State<ConnectionPermissionStatusStrip> createState() =>
      _ConnectionPermissionStatusStripState();
}

class _ConnectionPermissionStatusStripState
    extends State<ConnectionPermissionStatusStrip>
    with WidgetsBindingObserver {
  bool? _micGranted;
  bool? _locationGranted;
  bool? _cameraGranted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissions();
    }
  }

  Future<void> _refreshPermissions() async {
    final mic = await Permission.microphone.status;
    final loc = await Permission.locationWhenInUse.status;
    final cam = await Permission.camera.status;
    if (!mounted) return;
    setState(() {
      _micGranted = mic.isGranted;
      _locationGranted = loc.isGranted;
      _cameraGranted = cam.isGranted;
    });
  }

  Widget _chip(String text, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<MyBluetoothService>(
      builder: (context, bluetooth, _) {
        final chips = <Widget>[];

        if (!bluetooth.isConnected) {
          chips.add(_chip(
            '蓝牙未连接',
            Icons.bluetooth_disabled,
            Colors.orangeAccent,
          ));
        }
        if (_micGranted == false) {
          chips.add(_chip('麦克风未授权', Icons.mic_off, Colors.redAccent));
        }
        if (_locationGranted == false) {
          chips.add(_chip('定位未授权', Icons.location_off, Colors.amberAccent));
        }
        if (_cameraGranted == false) {
          chips.add(_chip('相机未授权', Icons.videocam_off, Colors.deepOrangeAccent));
        }

        if (chips.isEmpty) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: chips,
          ),
        );
      },
    );
  }
}
