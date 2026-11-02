package com.dev.voicegpt

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class BluetoothConnectionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action

        when (action) {
            BluetoothAdapter.ACTION_STATE_CHANGED -> {
                val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
                if (state == BluetoothAdapter.STATE_ON) {
                    Log.d("BTReceiver", "蓝牙已开启，准备自动重连")

                    // 获取已缓存的 FlutterEngine
                    val flutterEngine = FlutterEngineCache.getInstance().get("my_engine_id")
                    if (flutterEngine != null) {
                        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bluetooth_channel")
                            .invokeMethod("reconnectToLastDevice", null)
                    } else {
                        Log.e("BTReceiver", "FlutterEngine 未初始化")
                    }
                }
            }
        }
    }
}
