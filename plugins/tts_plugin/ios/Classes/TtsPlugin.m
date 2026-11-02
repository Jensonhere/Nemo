//
// TtsPlugin.m
// tts_plugin
//
// Created by tbolpcao on 2023/5/5
// Copyright (c) 2023 Tencent. All rights reserved.
//

#import "TtsPlugin.h"
#import "QCloudTTS/QCloudTTSEngine.h"

/**
  将OC中消息回调到Flutter
 */
@interface TTSObserver : NSObject <QCloudTTSEngineDelegate>

@end

@implementation TTSObserver

FlutterMethodChannel *_channel;

- (instancetype)init:(FlutterMethodChannel *)channel {
  _channel = channel;
  return self;
}

- (void)onSynthesizeData:(NSData *)data UtteranceId:(NSString *)utteranceId Text:(NSString *)text EngineType:(NSInteger)type RequestId:(NSString *)requestId RespJson:(NSString *)respJson {
    dispatch_async(dispatch_get_main_queue(), ^{
      NSDictionary *args = @{
        @"data" : [FlutterStandardTypedData typedDataWithBytes:data],
        @"text" : text,
        @"utteranceId" : utteranceId,
        @"resp": respJson,
      };
      [_channel invokeMethod:@"onSynthesizeData" arguments:args];
    });
}

- (void)onError:(TtsError * _Nullable)error UtteranceId:(NSString * _Nullable)utteranceId Text:(NSString * _Nullable)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *args;
      if(error.serviceError != nil) {
          args = @{@"code" : @(error.err_code), @"message" : error.msg, @"serverMessage": error.serviceError.respose};
      }else{
          args = @{@"code" : @(error.err_code), @"message" : error.msg};
      }
      [_channel invokeMethod:@"onError" arguments:args];
    });
}

- (void)onOfflineAuthInfo:(QCloudOfflineAuthInfo *_Nonnull)offlineAuthInfo {
}

@end

@implementation TtsPlugin

FlutterMethodChannel *_channel;
id<QCloudTTSEngineDelegate> _delegate;

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"tts_plugin"
                                  binaryMessenger:[registrar messenger]];
  TtsPlugin *instance = [[TtsPlugin alloc] init:channel];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)init:(FlutterMethodChannel *)channel {
  _channel = channel;
  _delegate = [[TTSObserver alloc] init:_channel];
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result {
  QCloudTTSEngine *ttsController = [QCloudTTSEngine getShareInstance];
  if ([@"TTSController.init" isEqualToString:call.method]) {
    [ttsController engineInit:TTS_MODE_ONLINE Delegate:_delegate];
    result(nil);
  } else if ([@"TTSController.config" isEqualToString:call.method]) {
    NSString *secretId = call.arguments[@"secretId"];
    NSString *secretKey = call.arguments[@"secretKey"];
    NSString *token = call.arguments[@"token"];
    float voiceSpeed = [call.arguments[@"voiceSpeed"] floatValue];
    float voiceVolume = [call.arguments[@"voiceVolume"] floatValue];
    int voiceType = [call.arguments[@"voiceType"] intValue];
    int voiceLanguage = [call.arguments[@"voiceLanguage"] intValue];
    NSString *codec = call.arguments[@"codec"];
    int connectTimeout = [call.arguments[@"connectTimeout"] intValue];
    int readTimeout = [call.arguments[@"readTimeout"] intValue];
    [ttsController setOnlineAuthParam:0
                             SecretId:secretId
                            SecretKey:secretKey
                                Token:nil];
    [ttsController setOnlineVoiceSpeed:voiceSpeed];
    [ttsController setOnlineVoiceVolume:voiceVolume];
    [ttsController setOnlineVoiceType:voiceType];
    [ttsController setOnlineVoiceLanguage:voiceLanguage];
    [ttsController setOnlineCodec:codec];
    [ttsController setTimeoutIntervalForRequest:connectTimeout];
    [ttsController setTimeoutIntervalForResource:readTimeout];
    result(nil);
  } else if ([@"TTSController.synthesize" isEqualToString:call.method]) {
    NSString *text = call.arguments[@"text"];
    NSString *utteranceId = call.arguments[@"utteranceId"];
    [ttsController synthesize:text UtteranceId:utteranceId];
    result(nil);
  } else if ([@"TTSController.cancel" isEqualToString:call.method]) {
    [ttsController cancel];
    result(nil);
  } else if ([@"TTSController.release" isEqualToString:call.method]) {
    [QCloudTTSEngine instanceRelease];
    result(nil);
  } else if ([@"TTSController.setApiParam" isEqualToString:call.method]) {
    NSString *key = call.arguments[@"key"];
    NSObject *value = call.arguments[@"value"];
    [[QCloudTTSEngine getShareInstance] setOnlineParam:key value:value];
    result(nil);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

@end
