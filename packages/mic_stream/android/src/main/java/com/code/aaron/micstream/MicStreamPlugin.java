package com.code.aaron.micstream;

import java.util.ArrayList;
import java.util.Arrays;

import android.annotation.TargetApi;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry.Registrar;

/**
 * Patched for voicegpt: 原版 static AudioRecord + onCancel 忙等 + 与 read 并发 release
 * 会在部分机型上触发 AudioRecord.read → releaseBuffer 断言崩溃。
 * 改为：实例字段、先 join 读线程再释放、onListen 前强制完整 teardown。
 */
@TargetApi(16)
public class MicStreamPlugin implements FlutterPlugin, EventChannel.StreamHandler, MethodCallHandler {
    private static final String TAG = "MicStreamPlugin";
    private static final String MICROPHONE_CHANNEL_NAME = "aaron.code.com/mic_stream";
    private static final String MICROPHONE_METHOD_CHANNEL_NAME = "aaron.code.com/mic_stream_method_channel";

    private static final long READER_JOIN_MS = 8000;

    private final Object recorderLock = new Object();

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        registerWith(binding.getBinaryMessenger());
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        onCancel(null);
    }

    public void registerWith(Registrar registrar) {
        registerWith(registrar.messenger());
    }

    private void registerWith(BinaryMessenger messenger) {
        final EventChannel microphone = new EventChannel(messenger, MICROPHONE_CHANNEL_NAME);
        microphone.setStreamHandler(this);
        MethodChannel methodChannel = new MethodChannel(messenger, MICROPHONE_METHOD_CHANNEL_NAME);
        methodChannel.setMethodCallHandler(this);
    }

    private EventChannel.EventSink eventSink;

    /** 非 static：避免与其他引擎/热重载残留共享同一条 native 录音链路 */
    private volatile AudioRecord recorder = null;

    private int AUDIO_SOURCE = MediaRecorder.AudioSource.DEFAULT;
    /** Dart 侧 androidVoipEchoCapture；为 true 时强制 VOICE_COMMUNICATION 录音源（配合 App 层 MODE_IN_COMMUNICATION） */
    private boolean useVoipEchoCapturePath = false;
    private int SAMPLE_RATE = 16000;
    private int actualSampleRate;
    private int CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO;
    private int AUDIO_FORMAT = AudioFormat.ENCODING_PCM_8BIT;
    private int actualBitDepth;
    private int BUFFER_SIZE = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_8BIT);

    private volatile boolean record = false;
    private volatile Thread readerThread = null;

    @Override
    public void onMethodCall(MethodCall call, Result result) {
        switch (call.method) {
            case "getSampleRate":
                result.success((double) this.actualSampleRate);
                break;
            case "getBitDepth":
                result.success(this.actualBitDepth);
                break;
            case "getBufferSize":
                result.success(this.BUFFER_SIZE);
                break;
            default:
                result.notImplemented();
                break;
        }
    }

    private static class MainThreadEventSink implements EventChannel.EventSink {
        private final EventChannel.EventSink eventSink;
        private final Handler handler;

        MainThreadEventSink(EventChannel.EventSink eventSink) {
            this.eventSink = eventSink;
            handler = new Handler(Looper.getMainLooper());
        }

        @Override
        public void success(final Object o) {
            handler.post(() -> eventSink.success(o));
        }

        @Override
        public void error(final String s, final String s1, final Object o) {
            handler.post(() -> eventSink.error(s, s1, o));
        }

        @Override
        public void endOfStream() {
            handler.post(() -> eventSink.endOfStream());
        }
    }

    /** 停止读循环、等待线程退出（线程内负责 stop/release AudioRecord） */
    private void stopReaderAndJoin() {
        record = false;
        Thread t;
        synchronized (recorderLock) {
            t = readerThread;
        }
        if (t != null) {
            try {
                t.join(READER_JOIN_MS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        synchronized (recorderLock) {
            readerThread = null;
            recorder = null;
        }
    }

    private void runReader() {
        AudioRecord ar = null;
        EventChannel.EventSink sink = this.eventSink;
        try {
            Log.d(TAG, "AudioRecord ctor: source=" + AUDIO_SOURCE + " voipEchoPath=" + useVoipEchoCapturePath
                    + " rate=" + SAMPLE_RATE + " ch=" + CHANNEL_CONFIG + " fmt=" + AUDIO_FORMAT + " buf=" + BUFFER_SIZE);
            ar = new AudioRecord(AUDIO_SOURCE, SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT, BUFFER_SIZE);
            if (ar.getState() != AudioRecord.STATE_INITIALIZED) {
                Log.e(TAG, "AudioRecord not initialized (source=" + AUDIO_SOURCE + ")");
                if (sink != null) {
                    sink.error("-1", "PlatformError", null);
                }
                try {
                    ar.release();
                } catch (Exception ignored) {
                }
                return;
            }

            synchronized (recorderLock) {
                if (!record) {
                    try {
                        ar.release();
                    } catch (Exception ignored) {
                    }
                    return;
                }
                recorder = ar;
            }

            ar.startRecording();
            int spins = 0;
            while (record && ar.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING && spins < 500) {
                try {
                    Thread.sleep(2);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return;
                }
                spins++;
            }

            actualSampleRate = ar.getSampleRate();
            actualBitDepth = (ar.getAudioFormat() == AudioFormat.ENCODING_PCM_8BIT ? 8 : 16);
            Log.d(TAG, "Recording started: state=" + ar.getRecordingState() + " actualRate=" + actualSampleRate
                    + " bitDepth=" + actualBitDepth);

            while (record) {
                byte[] data = new byte[BUFFER_SIZE];
                int n = ar.read(data, 0, BUFFER_SIZE);
                if (n <= 0) {
                    break;
                }
                if (sink == null) {
                    break;
                }
                try {
                    if (n == BUFFER_SIZE) {
                        sink.success(data);
                    } else {
                        sink.success(Arrays.copyOf(data, n));
                    }
                } catch (IllegalArgumentException e) {
                    sink.error("-1", "Invalid Data", e);
                    break;
                }
            }
        } finally {
            try {
                if (ar != null) {
                    if (ar.getRecordingState() == AudioRecord.RECORDSTATE_RECORDING) {
                        ar.stop();
                    }
                }
            } catch (Exception ignored) {
            }
            try {
                if (ar != null) {
                    ar.release();
                }
            } catch (Exception ignored) {
            }
            synchronized (recorderLock) {
                if (recorder == ar) {
                    recorder = null;
                }
                if (readerThread == Thread.currentThread()) {
                    readerThread = null;
                }
            }
        }
    }

    @Override
    public void onListen(Object args, final EventChannel.EventSink eventSink) {
        @SuppressWarnings("unchecked")
        ArrayList<Object> config = (ArrayList<Object>) args;

        useVoipEchoCapturePath = false;
        switch (config.size()) {
            case 5: {
                Object v = config.get(4);
                int flag = (v instanceof Number) ? ((Number) v).intValue() : 0;
                useVoipEchoCapturePath = (flag == 1);
                Log.d(TAG, "onListen: androidVoipEchoCapture flag=" + flag);
            }
            // fall through
            case 4:
                AUDIO_FORMAT = ((Number) config.get(3)).intValue();
            case 3:
                CHANNEL_CONFIG = ((Number) config.get(2)).intValue();
            case 2:
                SAMPLE_RATE = ((Number) config.get(1)).intValue();
            case 1:
                AUDIO_SOURCE = ((Number) config.get(0)).intValue();
            default:
                try {
                    BUFFER_SIZE = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT);
                } catch (Exception e) {
                    eventSink.error("-3", "Invalid AudioRecord parameters", e);
                    return;
                }
        }

        if (useVoipEchoCapturePath) {
            AUDIO_SOURCE = MediaRecorder.AudioSource.VOICE_COMMUNICATION;
            Log.d(TAG, "VoIP echo capture path: forcing AudioSource.VOICE_COMMUNICATION (" + AUDIO_SOURCE + ")");
        } else {
            Log.d(TAG, "Standard capture: AudioSource from Dart index -> " + AUDIO_SOURCE);
        }

        if (AUDIO_FORMAT != AudioFormat.ENCODING_PCM_8BIT && AUDIO_FORMAT != AudioFormat.ENCODING_PCM_16BIT) {
            eventSink.error("-3", "Invalid Audio Format specified", null);
            return;
        }

        // 禁止在持锁期间 join 读线程，否则 runReader 的 finally 会死锁
        stopReaderAndJoin();

        synchronized (recorderLock) {
            this.eventSink = new MainThreadEventSink(eventSink);
            record = true;
            Thread t = new Thread(this::runReader, "mic_stream_reader");
            readerThread = t;
            t.start();
        }
    }

    @Override
    public void onCancel(Object o) {
        Log.d(TAG, "onCancel: voipEchoPath was " + useVoipEchoCapturePath);
        synchronized (recorderLock) {
            eventSink = null;
        }
        stopReaderAndJoin();
    }
}
