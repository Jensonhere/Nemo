package com.tencent.cloud.tts.plugin.tts_plugin;

import android.app.Activity;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import com.tencent.cloud.libqcloudtts.TtsController;
import com.tencent.cloud.libqcloudtts.TtsError;
import com.tencent.cloud.libqcloudtts.TtsMode;
import com.tencent.cloud.libqcloudtts.TtsResultListener;
import com.tencent.cloud.libqcloudtts.engine.offlineModule.auth.QCloudOfflineAuthInfo;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/** TtsPlugin */
public class TtsPlugin implements FlutterPlugin, MethodCallHandler, ActivityAware {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private MethodChannel channel;
  private Activity activity;
  private boolean isFlutterEngineAttached = true;

  private final ExecutorService executorService = Executors.newSingleThreadExecutor();
  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
    channel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), "tts_plugin");
    channel.setMethodCallHandler(this);
    isFlutterEngineAttached = true;
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    TtsController ttsController = TtsController.getInstance();
    if (call.method.equals("TTSController.config")) {
      String secretId = call.argument("secretId");
      String secretKey = call.argument("secretKey");
      String token = call.argument("token");
      float voiceSpeed = ((Double)call.argument("voiceSpeed")).floatValue();
      float voiceVolume = ((Double)call.argument("voiceVolume")).floatValue();
      int voiceType = call.argument("voiceType");
      int voiceLanguage = call.argument("voiceLanguage");
      String codec = call.argument("codec");
      int connectTimeout = call.argument("connectTimeout");
      int readTimeout = call.argument("readTimeout");
      ttsController.setSecretId(secretId);
      ttsController.setSecretKey(secretKey);
      ttsController.setToken(token);
      ttsController.setOnlineVoiceSpeed(voiceSpeed);
      ttsController.setOnlineVoiceVolume(voiceVolume);
      ttsController.setOnlineVoiceType(voiceType);
      ttsController.setOnlineVoiceLanguage(voiceLanguage);
      ttsController.setOnlineCodec(codec);
      ttsController.setConnectTimeout(connectTimeout);
      ttsController.setReadTimeout(readTimeout);
    }
    else if (call.method.equals("TTSController.init")) {
      ttsController.init(activity.getApplicationContext(), TtsMode.ONLINE, new TtsResultListener() {
        @Override
        public void onSynthesizeData(byte[] bytes, String s, String s1, int i) {
        }

        @Override
        public void onSynthesizeData(byte[] bytes, String utteranceId, String text, int engineType, String requestId) {}

        @Override
        public void onSynthesizeData(byte[] bytes, String utteranceId, String text, int engineType, String requestId, String respJson) {
          new Handler(Looper.getMainLooper()).post(new Runnable() {
            @Override
            public void run() {
              Map args = new HashMap();
              args.put("data", bytes);
              args.put("text", text);
              args.put("utteranceId", utteranceId);
              args.put("resp", respJson);
              sendMessage("onSynthesizeData", args);
            }
          });
        }

        @Override
        public void onError(TtsError ttsError, String s, String s1) {
          new Handler(Looper.getMainLooper()).post(new Runnable() {
            @Override
            public void run() {
              Map args = new HashMap();
              args.put("code", ttsError.getCode());
              args.put("message", ttsError.getMessage());
              if(ttsError.getServiceError() != null){
                args.put("serverMessage", ttsError.getServiceError().getResponse());
              }
              sendMessage("onError", args);
            }
          });
        }

        @Override
        public void onOfflineAuthInfo(QCloudOfflineAuthInfo qCloudOfflineAuthInfo) { }
      });
      result.success(null);
    }
    else if (call.method.equals("TTSController.synthesize")) {
      String text = call.argument("text");
      String utteranceId = call.argument("utteranceId");
      ttsController.synthesize(text, utteranceId);
      result.success(null);
    }
    else if (call.method.equals("TTSController.release")) {
      TtsController.release();
      result.success(null);
    }
    else if (call.method.equals("TTSController.cancel")) {
      executorService.submit(() -> {
        try {
          if (isFlutterEngineAttached) {
            ttsController.cancel();
            result.success(null);
          }
        } catch (Exception e) {
          if (isFlutterEngineAttached) {
            result.error("CANCEL_ERROR", e.getMessage(), null);
          }
        }
      });
    }
    else if (call.method.equals("TTSController.setApiParam")) {
      String key = call.argument("key");
      Object value = call.argument("value");
      if (value instanceof String) {
        ttsController.setOnlineParam(key, (String) value);
      }else if(value instanceof Boolean) {
        ttsController.setOnlineParam(key, (boolean) value);
      }else if(value instanceof Integer) {
        ttsController.setOnlineParam(key, (int) value);
      }else if(value instanceof Long) {
        ttsController.setOnlineParam(key, (long) value);
      }else if(value instanceof Float) {
        ttsController.setOnlineParam(key, (float) value);
      }else if(value instanceof Double) {
        ttsController.setOnlineParam(key, (float) value);
      }
      result.success(null);
    }
    else {
      result.notImplemented();
    }
  }

  private void sendMessage(String method, Object args) {
    if (isFlutterEngineAttached) {
      channel.invokeMethod(method, args);
    }else{

    }
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
    isFlutterEngineAttached = false;
  }

  @Override
  public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
    activity = binding.getActivity();
  }

  @Override
  public void onDetachedFromActivityForConfigChanges() {
    activity = null;
    executorService.shutdownNow();
  }

  @Override
  public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
    activity = binding.getActivity();
  }

  @Override
  public void onDetachedFromActivity() {
    activity = null;
  }
}
