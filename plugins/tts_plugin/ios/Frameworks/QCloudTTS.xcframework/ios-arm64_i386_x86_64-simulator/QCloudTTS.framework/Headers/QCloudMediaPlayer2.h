//
//  QCloudMediaPlayer.h
//  cloud-tts-sdk-ios
//
//  Created by renqiu on 2022/1/11.
//

#import <Foundation/Foundation.h>
#import <QCloudTTS/QCPlayerError.h>
#import <QCloudTTS/QCloudMediaPlayer.h>

/// <#Description#>
@interface QCloudMediaPlayer2 : NSObject
@property (weak)id <QCloudPlayerDelegate> _Nullable playerDelegate;
//
/// 数据入队列
/// @param data 加入队列的音频
/// @param text 音频对应的文本
/// @param utteranceId 音频对应的ID
-(void)enqueueWithData:(NSData* _Nonnull )data Text:(NSString* _Nullable)text UtteranceId:(NSString* _Nullable)utteranceId;
/// 数据入队列
/// @param file 加入队列的音频文件
/// @param text 音频文件对应的文本
/// @param utteranceId 音频文件对应的ID
-(void)enqueueWithFile:(NSURL* _Nullable)file Text:(NSString* _Nullable)text UtteranceId:(NSString* _Nullable)utteranceId;
//
/// 停止播放
-(QCPlayerError* _Nullable)StopPlay;
/// 暂停播放
-(QCPlayerError* _Nullable)PausePlay;
/// 恢复播放
-(QCPlayerError* _Nullable)ResumePlay;
-(NSInteger)getAudioQueueSize;

@end
