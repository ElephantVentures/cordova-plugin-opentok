//
//  OpenTokPluginAudioDeviceIOS.m
//
//  Copyright (c) 2014 TokBox, Inc. All rights reserved.
//

#import "OpenTokPluginAudioDevice.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <mach/mach_time.h>

/*
 *  System Versioning Preprocessor Macros
 */

#define SYSTEM_VERSION_EQUAL_TO(v) \
([[[UIDevice currentDevice] systemVersion] compare:v \
options:NSNumericSearch] == NSOrderedSame)
#define SYSTEM_VERSION_GREATER_THAN(v) \
([[[UIDevice currentDevice] systemVersion] compare:v \
options:NSNumericSearch] == NSOrderedDescending)
#define SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(v) \
([[[UIDevice currentDevice] systemVersion] compare:v \
options:NSNumericSearch] != NSOrderedAscending)
#define SYSTEM_VERSION_LESS_THAN(v) \
([[[UIDevice currentDevice] systemVersion] compare:v \
options:NSNumericSearch] == NSOrderedAscending)
#define SYSTEM_VERSION_LESS_THAN_OR_EQUAL_TO(v) \
([[[UIDevice currentDevice] systemVersion] compare:v \
options:NSNumericSearch] != NSOrderedDescending)


// Simulator *must* run at 44.1 kHz in order to function properly.
#if (TARGET_IPHONE_SIMULATOR)
#define kSampleRate 44100
#else
#define kSampleRate 48000
#endif

#define OT_ENABLE_AUDIO_DEBUG 0

#if OT_ENABLE_AUDIO_DEBUG
#define OT_AUDIO_DEBUG(fmt, ...) NSLog(fmt, ##__VA_ARGS__)
#else
#define OT_AUDIO_DEBUG(fmt, ...)
#endif

static double kPreferredIOBufferDuration = 0.01;

static mach_timebase_info_data_t info;

static OSStatus recording_cb(void *ref_con,
                             AudioUnitRenderActionFlags *action_flags,
                             const AudioTimeStamp *time_stamp,
                             UInt32 bus_num,
                             UInt32 num_frames,
                             AudioBufferList *data);

static OSStatus playout_cb(void *ref_con,
                           AudioUnitRenderActionFlags *action_flags,
                           const AudioTimeStamp *time_stamp,
                           UInt32 bus_num,
                           UInt32 num_frames,
                           AudioBufferList *data);

@interface OpenTokPluginAudioDevice ()
- (BOOL) setupAudioUnit:(AudioUnit *)voice_unit playout:(BOOL)isPlayout;
- (void) setupListenerBlocks;
@end

@implementation OpenTokPluginAudioDevice
{
    OTAudioFormat *_audioFormat;

    AudioUnit recording_voice_unit;
    AudioUnit playout_voice_unit;
    BOOL playing;
    BOOL playout_initialized;
    BOOL recording;
    BOOL recording_initialized;
    BOOL interrupted_playback;
    NSString* _previousAVAudioSessionCategory;
    NSString* _avAudioSessionCategory;
    NSString* avAudioSessionMode;
    double avAudioSessionPreffSampleRate;
    NSInteger avAudioSessionChannels;
    BOOL isAudioSessionSetup;
    BOOL isRecorderInterrupted;
    BOOL isPlayerInterrupted;
    BOOL areListenerBlocksSetup;
    BOOL _isResetting;
    int _restartRetryCount;

    /* synchronize all access to the audio subsystem */
    dispatch_queue_t _safetyQueue;

@public
    id _audioBus;

    AudioBufferList *buffer_list;
    uint32_t buffer_num_frames;
    uint32_t buffer_size;
    uint32_t _recordingDelay;
    uint32_t _playoutDelay;
    uint32_t _playoutDelayMeasurementCounter;
    uint32_t _recordingDelayHWAndOS;
    uint32_t _recordingDelayMeasurementCounter;
    Float64 _playout_AudioUnitProperty_Latency;
    Float64 _recording_AudioUnitProperty_Latency;
}

#pragma mark - OTAudioDeviceImplementation

- (instancetype)init
{
    self = [super init];
    if (self) {
        _audioFormat = [[OTAudioFormat alloc] init];
        _audioFormat.sampleRate = kSampleRate;
        _audioFormat.numChannels = 1;
        _safetyQueue = dispatch_queue_create("ot-audio-driver",
                                             DISPATCH_QUEUE_SERIAL);
        _restartRetryCount = 0;
    }
    return self;
}

- (BOOL)setAudioBus:(id<OTAudioBus>)audioBus
{
    _audioBus = audioBus;
    _audioFormat = [[OTAudioFormat alloc] init];
    _audioFormat.sampleRate = kSampleRate;
    _audioFormat.numChannels = 1;

    return YES;
}

- (void)dealloc
{
    [self teardownAudio];
    _audioFormat = nil;
}

- (OTAudioFormat*)captureFormat
{
    return _audioFormat;
}

- (OTAudioFormat*)renderFormat
{
    return _audioFormat;
}

- (BOOL)renderingIsAvailable
{
    return YES;
}

// Audio Unit lifecycle is bound to start/stop cycles, so we don't have much
// to do here.
- (BOOL)initializeRendering
{
    if (playing) {
        return NO;
    }
    if (playout_initialized) {
        return YES;
    }
    playout_initialized = true;
    return YES;
}

- (BOOL)renderingIsInitialized
{
    return playout_initialized;
}

- (BOOL)captureIsAvailable
{
    return YES;
}

// Audio Unit lifecycle is bound to start/stop cycles, so we don't have much
// to do here.
- (BOOL)initializeCapture
{
    if (recording) {
        return NO;
    }
    if (recording_initialized) {
        return YES;
    }
    recording_initialized = true;
    return YES;
}

- (BOOL)captureIsInitialized
{
    return recording_initialized;
}

- (BOOL)startRendering
{
    @synchronized(self) {
        OT_AUDIO_DEBUG(@"startRendering");

        if (playing) {
            return YES;
        }

        playing = YES;
        // Initialize only when playout voice unit is already teardown
        if(playout_voice_unit == NULL)
        {
            if (NO == [self setupAudioUnit:&playout_voice_unit playout:YES]) {
                playing = NO;
                return NO;
            }
        }

        OSStatus result = AudioOutputUnitStart(playout_voice_unit);
        if (CheckError(result, @"startRendering.AudioOutputUnitStart")) {
            playing = NO;
        }

        return playing;
    }
}

- (BOOL)stopRendering
{
    @synchronized(self) {
        OT_AUDIO_DEBUG(@"stopRendering");

        if (!playing) {
            return YES;
        }

        playing = NO;

        OSStatus result = AudioOutputUnitStop(playout_voice_unit);
        if (CheckError(result, @"stopRendering.AudioOutputUnitStop")) {
            return NO;
        }

        // publisher is already closed
        if (!recording && !isPlayerInterrupted && !_isResetting)
        {
            [self teardownAudio];
        }

        return YES;
    }
}

- (BOOL)isRendering
{
    return playing;
}

- (BOOL)startCapture
{
    @synchronized(self) {
        OT_AUDIO_DEBUG(@"startCapture");

        if (recording) {
            return YES;
        }

        recording = YES;
        // Initialize only when recording voice unit is already teardown
        if(recording_voice_unit == NULL)
        {
            if (NO == [self setupAudioUnit:&recording_voice_unit playout:NO]) {
                recording = NO;
                return NO;
            }
        }

        OSStatus result = AudioOutputUnitStart(recording_voice_unit);
        if (CheckError(result, @"startCapture.AudioOutputUnitStart")) {
            recording = NO;
        }

        return recording;
    }
}

- (BOOL)stopCapture
{
    @synchronized(self) {
        OT_AUDIO_DEBUG(@"stopCapture");

        if (!recording) {
            return YES;
        }

        recording = NO;

        OSStatus result = AudioOutputUnitStop(recording_voice_unit);

        if (CheckError(result, @"stopCapture.AudioOutputUnitStop")) {
            return NO;
        }

        [self freeupAudioBuffers];

        // subscriber is already closed
        if (!playing && !isRecorderInterrupted && !_isResetting)
        {
            [self teardownAudio];
        }

        return YES;
    }
}

- (BOOL)isCapturing
{
    return recording;
}

- (uint16_t)estimatedRenderDelay
{
    return _playoutDelay;
}

- (uint16_t)estimatedCaptureDelay
{
    return _recordingDelay;
}

#pragma mark - AudioSession Setup

static NSString* FormatError(OSStatus error)
{
    uint32_t as_int = CFSwapInt32HostToLittle(error);
    uint8_t* as_char = (uint8_t*) &as_int;
    // see if it appears to be a 4-char-code
    if (isprint(as_char[0]) &&
        isprint(as_char[1]) &&
        isprint(as_char[2]) &&
        isprint(as_char[3]))
    {
        return [NSString stringWithFormat:@"%c%c%c%c",
                as_int >> 24, as_int >> 16, as_int >> 8, as_int];
    }
    else
    {
        // no, format it as an integer
        return [NSString stringWithFormat:@"%d", error];
    }
}

/**
 * @return YES if in error
 */
static bool CheckError(OSStatus error, NSString* function) {
    if (!error) return NO;

    NSString* error_string = FormatError(error);
    NSLog(@"ERROR[OpenTok]:Audio device error: %@ returned error: %@",
          function, error_string);

    return YES;
}

- (void)checkAndPrintError:(OSStatus)error function:(NSString *)function
{
    CheckError(error,function);
}

- (void)disposePlayoutUnit
{
    if (playout_voice_unit) {
        AudioUnitUninitialize(playout_voice_unit);
        AudioComponentInstanceDispose(playout_voice_unit);
        playout_voice_unit = NULL;
    }
}

- (void)disposeRecordUnit
{
    if (recording_voice_unit) {
        AudioUnitUninitialize(recording_voice_unit);
        AudioComponentInstanceDispose(recording_voice_unit);
        recording_voice_unit = NULL;
    }
}

- (void) teardownAudio
{
    [self disposePlayoutUnit];
    [self disposeRecordUnit];
    [self freeupAudioBuffers];
    [self removeObservers];

    AVAudioSession *mySession = [AVAudioSession sharedInstance];
    [mySession setCategory:_previousAVAudioSessionCategory error:nil];
    [mySession setMode:avAudioSessionMode error:nil];
    [mySession setPreferredSampleRate: avAudioSessionPreffSampleRate
                                error: nil];
    [mySession setPreferredInputNumberOfChannels:avAudioSessionChannels
                                           error:nil];

    isAudioSessionSetup = NO;
}

- (void)freeupAudioBuffers
{
    if (buffer_list && buffer_list->mBuffers[0].mData) {
        free(buffer_list->mBuffers[0].mData);
        buffer_list->mBuffers[0].mData = NULL;
    }

    if (buffer_list) {
        free(buffer_list);
        buffer_list = NULL;
        buffer_num_frames = 0;
    }
}
- (void) setupAudioSession
{
    AVAudioSession *mySession = [AVAudioSession sharedInstance];
    _previousAVAudioSessionCategory = mySession.category;
    avAudioSessionMode = mySession.mode;
    avAudioSessionPreffSampleRate = mySession.preferredSampleRate;
    avAudioSessionChannels = mySession.inputNumberOfChannels;

    if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"7.0")) {
        [mySession setMode:AVAudioSessionModeVideoChat error:nil];
    }
    else {
        [mySession setMode:AVAudioSessionModeVoiceChat error:nil];
    }

    [mySession setPreferredSampleRate: kSampleRate error: nil];
    [mySession setPreferredInputNumberOfChannels:1 error:nil];
    [mySession setPreferredIOBufferDuration:kPreferredIOBufferDuration
                                      error:nil];

    NSUInteger audioOptions = AVAudioSessionCategoryOptionMixWithOthers;
#if !(TARGET_OS_TV)
    audioOptions |= AVAudioSessionCategoryOptionAllowBluetooth ;
    audioOptions |= AVAudioSessionCategoryOptionDefaultToSpeaker;
    // Start out with MultiRoute category in case HDMI is already plugged in
    _avAudioSessionCategory = AVAudioSessionCategoryMultiRoute;
    [mySession setCategory:_avAudioSessionCategory
               withOptions:audioOptions
                     error:nil];
#else
    [mySession setCategory:AVAudioSessionCategoryPlayback
               withOptions:audioOptions
                     error:nil];
#endif


    [self setupListenerBlocks];
    [mySession setActive:YES error:nil];


}

- (void)setBluetoothAsPrefferedInputDevice
{
    // Apple's Bug(???) : Audio Interruption Ended notification won't be called
    // for bluetooth devices if we dont set preffered input as bluetooth.
    // Should work for non bluetooth routes/ports too. This makes both input
    // and output to bluetooth device if available.
    NSArray* bluetoothRoutes = @[AVAudioSessionPortBluetoothA2DP,
                                 AVAudioSessionPortBluetoothLE,
                                 AVAudioSessionPortBluetoothHFP];
    NSArray* routes = [[AVAudioSession sharedInstance] availableInputs];
    for (AVAudioSessionPortDescription* route in routes)
    {
        if ([bluetoothRoutes containsObject:route.portType])
        {
            [[AVAudioSession sharedInstance] setPreferredInput:route
                                                         error:nil];
            break;
        }
    }

}

- (void) onInterruptionEvent:(NSNotification *) notification
{
    NSDictionary *interruptionDict = notification.userInfo;
    NSInteger interruptionType =
    [[interruptionDict valueForKey:AVAudioSessionInterruptionTypeKey]
     integerValue];

    dispatch_async(_safetyQueue, ^() {
        [self handleInterruptionEvent:interruptionType];
    });
}

- (void) handleInterruptionEvent:(NSInteger) interruptionType
{
    switch (interruptionType) {
        case AVAudioSessionInterruptionTypeBegan:
        {
            OT_AUDIO_DEBUG(@"AVAudioSessionInterruptionTypeBegan");
            if(recording)
            {
                isRecorderInterrupted = YES;
                [self stopCapture];
            }
            if(playing)
            {
                isPlayerInterrupted = YES;
                [self stopRendering];
            }
        }
            break;

        case AVAudioSessionInterruptionTypeEnded:
        {
            OT_AUDIO_DEBUG(@"AVAudioSessionInterruptionTypeEnded");
            // Reconfigure audio session with highest priority device
            [self configureAudioSessionWithDesiredAudioRoute:
             AUDIO_DEVICE_BLUETOOTH];
            if(isRecorderInterrupted)
            {
                if([self startCapture] == YES)
                {
                    isRecorderInterrupted = NO;
                    _restartRetryCount = 0;
                } else
                {
                    _restartRetryCount++;
                    if(_restartRetryCount < 3)
                    {
                        dispatch_after(
                                       dispatch_time(
                                        DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC),
                                       _safetyQueue, ^{
                            [self handleInterruptionEvent:
                             AVAudioSessionInterruptionTypeEnded];
                        });
                    } else
                    {
                        // This shouldn't happen!
                        isRecorderInterrupted = NO;
                        isPlayerInterrupted = NO;
                        _restartRetryCount = 0;
                        NSLog(@"ERROR[OpenTok]:Unable to acquire audio session");
                    }
                    return;
                }
            }

            if(isPlayerInterrupted)
            {
                isPlayerInterrupted = NO;
                [self startRendering];
            }

        }
            break;

        default:
            OT_AUDIO_DEBUG(@"Audio Session Interruption Notification"
                           " case default.");
            break;
    }
}

- (void) onRouteChangeEvent:(NSNotification *) notification
{
    dispatch_async(_safetyQueue, ^() {
        [self handleRouteChangeEvent:notification];
    });
}

- (void) onMediaServicesResetEvent:(NSNotification *) notification
{

    dispatch_async(_safetyQueue, ^{
        [[AVAudioSession sharedInstance] setCategory: _avAudioSessionCategory
            withOptions: AVAudioSessionCategoryOptionAllowBluetooth |
                AVAudioSessionCategoryOptionMixWithOthers |
                AVAudioSessionCategoryOptionDefaultToSpeaker
            error: nil
        ];

        if (self.delegate) {
            NSDictionary * message = @ {
                @"category": [[AVAudioSession sharedInstance] category],
                @"sourceEvent": @"onMediaServicesResetEvent"
            };
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate onCategoryChange: message];
            });
        }

        [self resetAudio];
    });

    if (_delegate) {
        NSDictionary * message = @ {
            @"currentCategory": [[AVAudioSession sharedInstance] category]
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate onMediaServicesReset: message];
        });
    }

}

- (void) onMediaServicesLostEvent:(NSNotification *) notification
{
    if (_delegate) {
        NSDictionary * message = @ {
            @"currentCategory": [[AVAudioSession sharedInstance] category]
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate onMediaServicesLost: message];
        });
    }
}

- (void) resetAudio
{
    _isResetting = YES;

    if (recording)
    {
        [self stopCapture];
        [self disposeRecordUnit];
        [self startCapture];
    }

    if (playing)
    {
        [self stopRendering];
        [self disposePlayoutUnit];
        [self startRendering];
    }

    _isResetting = NO;
}

- (void) handleRouteChangeEvent:(NSNotification *) notification
{
    NSDictionary *interruptionDict = notification.userInfo;
    NSInteger routeChangeReason =
    [[interruptionDict valueForKey:AVAudioSessionRouteChangeReasonKey]
     integerValue];
    AVAudioSession* session = [AVAudioSession sharedInstance];
    BOOL (^isHDMIOutput)(AVAudioSessionPortDescription*, NSUInteger, BOOL*) = ^(AVAudioSessionPortDescription* port, NSUInteger index, BOOL* isDone) {
        return [AVAudioSessionPortHDMI isEqualToString: [port portType]];
    };


    // Debugging code start
    if (_delegate) {
        NSArray * outputs = [[session currentRoute] outputs];
        NSMutableArray * outputNames = [NSMutableArray arrayWithCapacity: [outputs count]];
        [outputs enumerateObjectsUsingBlock:^(id output, NSUInteger idx, BOOL *stop) {
            [outputNames addObject: [output portName]];
        }];
        NSDictionary * message = @ {
            @"routeChangeReason": [interruptionDict valueForKey: AVAudioSessionRouteChangeReasonKey],
            @"currentCategory": [session category],
            @"outputs": outputNames
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate onRouteChange: message];
        });
    }
    // Debugging code end


    NSUInteger audioOptions = AVAudioSessionCategoryOptionMixWithOthers |
        AVAudioSessionCategoryOptionAllowBluetooth |
        AVAudioSessionCategoryOptionDefaultToSpeaker;
    // We'll receive a routeChangedEvent when the audio unit starts; don't
    // process events we caused internally.
    switch ([[interruptionDict valueForKey:AVAudioSessionRouteChangeReasonKey] integerValue]) {
        case AVAudioSessionRouteChangeReasonRouteConfigurationChange:
            return;

        case AVAudioSessionRouteChangeReasonOverride:
        case AVAudioSessionRouteChangeReasonCategoryChange:
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable:
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable:
            //check if HDMI is plugged in during MultiRoute category
            //switch to PlayAndRecord category if HDMI is not detected (some other external display is connected)
            if ([[session category] isEqualToString: AVAudioSessionCategoryMultiRoute] && [[[session currentRoute] outputs] indexOfObjectPassingTest: isHDMIOutput] == NSNotFound) {
                _avAudioSessionCategory = AVAudioSessionCategoryPlayAndRecord;
                [session setCategory: _avAudioSessionCategory withOptions: audioOptions error: nil];

                if (_delegate) {
                    NSDictionary * message = @ {
                        @"category": [session category],
                        @"sourceEvent": @"routeChange"
                    };
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.delegate onCategoryChange: message];
                    });
                }
            }
    }

    // We've made it here, there's been a legit route change.
    // Restart the audio units with correct sample rate
    [self resetAudio];
}

/* When ringer is off, we dont get interruption ended callback
 as mentioned in apple doc : "There is no guarantee that a begin
 interruption will have an end interruption."
 The only caveat here is, some times we get two callbacks from interruption
 handler as well as from here which we handle synchronously with safteyQueue
 */
- (void) appDidBecomeActive:(NSNotification *) notification
{
    dispatch_async(_safetyQueue, ^{
        [self handleInterruptionEvent:AVAudioSessionInterruptionTypeEnded];
    });
}

- (void) setupListenerBlocks
{
    if(!areListenerBlocksSetup)
    {
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        //handlers for when an external screen is connected/disconnected (notified via UIKit instead of AVFramework)
        [center addObserver:self
                   selector:@selector(handleScreenDidConnectNotification:)
                       name:UIScreenDidConnectNotification object:nil];
        [center addObserver:self
                   selector:@selector(handleScreenDidDisconnectNotification:)
                       name:UIScreenDidDisconnectNotification object:nil];

        [center addObserver:self
                   selector:@selector(onInterruptionEvent:)
                       name:AVAudioSessionInterruptionNotification object:nil];

        [center addObserver:self
                   selector:@selector(onRouteChangeEvent:)
                       name:AVAudioSessionRouteChangeNotification object:nil];

        [center addObserver:self
                   selector:@selector(appDidBecomeActive:)
                       name:UIApplicationDidBecomeActiveNotification
                     object:nil];

        [center addObserver:self
                   selector:@selector(onMediaServicesResetEvent:)
                       name:AVAudioSessionMediaServicesWereResetNotification
                     object:nil];

        [center addObserver:self
                   selector:@selector(onMediaServicesLostEvent:)
                       name:AVAudioSessionMediaServicesWereLostNotification
                     object:nil];

        areListenerBlocksSetup = YES;
    }
}

- (void)handleScreenDidConnectNotification:(NSNotification*)aNotification
{

    // Debugging code start
    if (_delegate) {
        AVAudioSession * session = [AVAudioSession sharedInstance];
        NSArray * screens = [UIScreen screens];
        NSMutableArray * screenNames = [NSMutableArray arrayWithCapacity: [screens count]];
        [screens enumerateObjectsUsingBlock:^(id screen, NSUInteger idx, BOOL *stop) {
            [screenNames addObject: [screen description]];
        }];
        NSDictionary * message = @ {
            @"currentCategory": [session category],
            @"screens": screenNames
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate onScreenDidConnect: message];
        });
    }
    // Debugging code end


    //switch to MultiRoute category when an external display is connected
    //handleRouteChangeEvent: (AVAudioSessionRouteChangeNotification handler) will test if attached screen is HDMI
    _avAudioSessionCategory = AVAudioSessionCategoryMultiRoute;
    dispatch_async(_safetyQueue, ^{
        [[AVAudioSession sharedInstance] setCategory: _avAudioSessionCategory
            withOptions: AVAudioSessionCategoryOptionAllowBluetooth |
                AVAudioSessionCategoryOptionMixWithOthers |
                AVAudioSessionCategoryOptionDefaultToSpeaker
            error: nil
        ];

        if (self.delegate) {
            NSDictionary * message = @ {
                @"category": [[AVAudioSession sharedInstance] category],
                @"sourceEvent": @"screenDidConnect"
            };
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate onCategoryChange: message];
            });
        }

        [self resetAudio];
    });
}

- (void)handleScreenDidDisconnectNotification:(NSNotification*)aNotification
{
    // Debugging code start
    if (_delegate) {
        AVAudioSession * session = [AVAudioSession sharedInstance];
        NSArray * screens = [UIScreen screens];
        NSMutableArray * screenNames = [NSMutableArray arrayWithCapacity: [screens count]];
        [screens enumerateObjectsUsingBlock:^(id screen, NSUInteger idx, BOOL *stop) {
            [screenNames addObject: [screen description]];
        }];
        NSDictionary * message = @ {
            @"currentCategory": [session category],
            @"screens": screenNames
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate onScreenDidDisconnect: message];
        });
    }
    // Debugging code end

    //switch back to PlayAndRecord category when external display is disconnected
    _avAudioSessionCategory = AVAudioSessionCategoryPlayAndRecord;
    dispatch_async(_safetyQueue, ^{
        [[AVAudioSession sharedInstance] setCategory: _avAudioSessionCategory
            withOptions: AVAudioSessionCategoryOptionAllowBluetooth |
                AVAudioSessionCategoryOptionMixWithOthers |
                AVAudioSessionCategoryOptionDefaultToSpeaker
            error: nil
        ];

        if (self.delegate) {
            NSDictionary * message = @ {
                @"category": [[AVAudioSession sharedInstance] category],
                @"sourceEvent": @"screenDidDisconnect"
            };
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate onCategoryChange: message];
            });
        }

        [self resetAudio];
    });
}

- (void) removeObservers
{
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self];
    areListenerBlocksSetup = NO;
}

static void update_recording_delay(OpenTokPluginAudioDevice* device) {

    device->_recordingDelayMeasurementCounter++;

    if (device->_recordingDelayMeasurementCounter >= 100) {
        // Update HW and OS delay every second, unlikely to change

        device->_recordingDelayHWAndOS = 0;

        AVAudioSession *mySession = [AVAudioSession sharedInstance];

        // HW input latency
        NSTimeInterval interval = [mySession inputLatency];

        device->_recordingDelayHWAndOS += (int)(interval * 1000000);

        // HW buffer duration
        interval = [mySession IOBufferDuration];
        device->_recordingDelayHWAndOS += (int)(interval * 1000000);

        device->_recordingDelayHWAndOS += (int)(device->_recording_AudioUnitProperty_Latency * 1000000);

        // To ms
        device->_recordingDelayHWAndOS =
        (device->_recordingDelayHWAndOS - 500) / 1000;

        // Reset counter
        device->_recordingDelayMeasurementCounter = 0;
    }

    device->_recordingDelay = device->_recordingDelayHWAndOS;
}

static OSStatus recording_cb(void *ref_con,
                             AudioUnitRenderActionFlags *action_flags,
                             const AudioTimeStamp *time_stamp,
                             UInt32 bus_num,
                             UInt32 num_frames,
                             AudioBufferList *data)
{

    OpenTokPluginAudioDevice *dev = (__bridge OpenTokPluginAudioDevice*) ref_con;

    if (!dev->buffer_list || num_frames > dev->buffer_num_frames)
    {
        if (dev->buffer_list) {
            free(dev->buffer_list->mBuffers[0].mData);
            free(dev->buffer_list);
        }

        dev->buffer_list =
        (AudioBufferList*)malloc(sizeof(AudioBufferList) + sizeof(AudioBuffer));
        dev->buffer_list->mNumberBuffers = 1;
        dev->buffer_list->mBuffers[0].mNumberChannels = 1;

        dev->buffer_list->mBuffers[0].mDataByteSize = num_frames*sizeof(UInt16);
        dev->buffer_list->mBuffers[0].mData = malloc(num_frames*sizeof(UInt16));

        dev->buffer_num_frames = num_frames;
        dev->buffer_size = dev->buffer_list->mBuffers[0].mDataByteSize;
    }

    OSStatus status;

    uint64_t time = time_stamp->mHostTime;
    /* Convert to nanoseconds */
    time *= info.numer;
    time /= info.denom;

    status = AudioUnitRender(dev->recording_voice_unit,
                             action_flags,
                             time_stamp,
                             1,
                             num_frames,
                             dev->buffer_list);

    if (status != noErr) {
        CheckError(status, @"AudioUnitRender");
    }

    if (dev->recording) {

        // Some sample code to generate a sine wave instead of use the mic
        //        static double startingFrameCount = 0;
        //        double j = startingFrameCount;
        //        double cycleLength = kSampleRate. / 880.0;
        //        int frame = 0;
        //        for (frame = 0; frame < num_frames; ++frame)
        //        {
        //            int16_t* data = (int16_t*)dev->buffer_list->mBuffers[0].mData;
        //            Float32 sample = (Float32)sin (2 * M_PI * (j / cycleLength));
        //            (data)[frame] = (sample * 32767.0f);
        //            j += 1.0;
        //            if (j > cycleLength)
        //                j -= cycleLength;
        //        }
        //        startingFrameCount = j;
        [dev->_audioBus writeCaptureData:dev->buffer_list->mBuffers[0].mData
                         numberOfSamples:num_frames];
    }
    // some ocassions, AudioUnitRender only renders part of the buffer and then next
    // call to the AudioUnitRender fails with smaller buffer.
    if (dev->buffer_size != dev->buffer_list->mBuffers[0].mDataByteSize)
        dev->buffer_list->mBuffers[0].mDataByteSize = dev->buffer_size;

    update_recording_delay(dev);

    return noErr;
}

static void update_playout_delay(OpenTokPluginAudioDevice* device) {
    device->_playoutDelayMeasurementCounter++;

    if (device->_playoutDelayMeasurementCounter >= 100) {
        // Update HW and OS delay every second, unlikely to change

        device->_playoutDelay = 0;

        AVAudioSession *mySession = [AVAudioSession sharedInstance];

        // HW output latency
        NSTimeInterval interval = [mySession outputLatency];

        device->_playoutDelay += (int)(interval * 1000000);

        // HW buffer duration
        interval = [mySession IOBufferDuration];
        device->_playoutDelay += (int)(interval * 1000000);

        device->_playoutDelay += (int)(device->_playout_AudioUnitProperty_Latency * 1000000);

        // To ms
        device->_playoutDelay = (device->_playoutDelay - 500) / 1000;

        // Reset counter
        device->_playoutDelayMeasurementCounter = 0;
    }
}

static OSStatus playout_cb(void *ref_con,
                           AudioUnitRenderActionFlags *action_flags,
                           const AudioTimeStamp *time_stamp,
                           UInt32 bus_num,
                           UInt32 num_frames,
                           AudioBufferList *buffer_list)
{
    OpenTokPluginAudioDevice *dev = (__bridge OpenTokPluginAudioDevice*) ref_con;

    if (!dev->playing) { return 0; }

    uint32_t count =
    [dev->_audioBus readRenderData:buffer_list->mBuffers[0].mData
                   numberOfSamples:num_frames];

    if (count != num_frames) {
        //TODO: Not really an error, but conerning. Network issues?
    }

    update_playout_delay(dev);

    return 0;
}

#pragma mark BlueTooth

- (BOOL)isBluetoothDevice:(NSString*)portType {

    return ([portType isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
            [portType isEqualToString:AVAudioSessionPortBluetoothHFP]);
}


- (BOOL)detectCurrentRoute
{
    // called on startup to initialize the devices that are available...
    OT_AUDIO_DEBUG(@"detect current route");

    AVAudioSession *audioSession = [AVAudioSession sharedInstance];

    _headsetDeviceAvailable = _bluetoothDeviceAvailable = NO;

    //ios 8.0 complains about Deactivating an audio session that has running
    // I/O. All I/O should be stopped or paused prior to deactivating the audio
    // session. Looks like we can get away by not using the setActive call
    if (SYSTEM_VERSION_LESS_THAN_OR_EQUAL_TO(@"7.0")) {
        // close down our current session...
        [audioSession setActive:NO error:nil];

        // start a new audio session. Without activation, the default route will
        // always be (inputs: null, outputs: Speaker)
        [audioSession setActive:YES error:nil];
    }

    // Check for current route
    AVAudioSessionRouteDescription *currentRoute = [audioSession currentRoute];
    for (AVAudioSessionPortDescription *output in currentRoute.outputs) {
        if ([[output portType] isEqualToString:AVAudioSessionPortHeadphones]) {
            _headsetDeviceAvailable = YES;
        } else if ([self isBluetoothDevice:[output portType]]) {
            _bluetoothDeviceAvailable = YES;
        }
    }

    if (_headsetDeviceAvailable) {
        OT_AUDIO_DEBUG(@"Current route is Headset");
    }

    if (_bluetoothDeviceAvailable) {
        OT_AUDIO_DEBUG(@"Current route is Bluetooth");
    }

    if(!_bluetoothDeviceAvailable && !_headsetDeviceAvailable) {
        OT_AUDIO_DEBUG(@"Current route is device speaker");
    }

    return YES;
}

- (BOOL)configureAudioSessionWithDesiredAudioRoute:(NSString*)desiredAudioRoute
{
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSError *err;

    //ios 8.0 complains about Deactivating an audio session that has running
    // I/O. All I/O should be stopped or paused prior to deactivating the audio
    // session. Looks like we can get away by not using the setActive call
    if (SYSTEM_VERSION_LESS_THAN_OR_EQUAL_TO(@"7.0")) {
        // close down our current session...
        [audioSession setActive:NO error:nil];
    }

    if ([AUDIO_DEVICE_BLUETOOTH isEqualToString:desiredAudioRoute]) {
        [self setBluetoothAsPrefferedInputDevice];
    }

    if (SYSTEM_VERSION_LESS_THAN_OR_EQUAL_TO(@"7.0")) {
        // Set our session to active...
        if (![audioSession setActive:YES error:&err]) {
            NSLog(@"unable to set audio session active: %@", err);
            return NO;
        }
    }

    return YES;
}

- (BOOL)setupAudioUnit:(AudioUnit *)voice_unit playout:(BOOL)isPlayout;
{
    OSStatus result;

    mach_timebase_info(&info);

    if (!isAudioSessionSetup)
    {
        [self setupAudioSession];
        isAudioSessionSetup = YES;
    }

    UInt32 bytesPerSample = sizeof(SInt16);
    stream_format.mFormatID    = kAudioFormatLinearPCM;
    stream_format.mFormatFlags =
    kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    stream_format.mBytesPerPacket  = bytesPerSample;
    stream_format.mFramesPerPacket = 1;
    stream_format.mBytesPerFrame   = bytesPerSample;
    stream_format.mChannelsPerFrame= 1;
    stream_format.mBitsPerChannel  = 8 * bytesPerSample;
    stream_format.mSampleRate = (Float64) kSampleRate;

    AudioComponentDescription audio_unit_description;
    audio_unit_description.componentType = kAudioUnitType_Output;
#if !(TARGET_OS_TV)
    audio_unit_description.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
#else
    audio_unit_description.componentSubType = kAudioUnitSubType_RemoteIO;
#endif
    audio_unit_description.componentManufacturer = kAudioUnitManufacturer_Apple;
    audio_unit_description.componentFlags = 0;
    audio_unit_description.componentFlagsMask = 0;

    AudioComponent found_vpio_unit_ref =
    AudioComponentFindNext(NULL, &audio_unit_description);

    result = AudioComponentInstanceNew(found_vpio_unit_ref, voice_unit);

    if (CheckError(result, @"setupAudioUnit.AudioComponentInstanceNew")) {
        return NO;
    }

    if (!isPlayout)
    {
        UInt32 enable_input = 1;
        AudioUnitSetProperty(*voice_unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, kInputBus, &enable_input,
                             sizeof(enable_input));
        AudioUnitSetProperty(*voice_unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Output, kInputBus,
                             &stream_format, sizeof (stream_format));
        AURenderCallbackStruct input_callback;
        input_callback.inputProc = recording_cb;
        input_callback.inputProcRefCon = (__bridge void *)(self);

        AudioUnitSetProperty(*voice_unit,
                             kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global, kInputBus, &input_callback,
                             sizeof(input_callback));
        UInt32 flag = 0;
        AudioUnitSetProperty(*voice_unit, kAudioUnitProperty_ShouldAllocateBuffer,
                             kAudioUnitScope_Output, kInputBus, &flag,
                             sizeof(flag));

    } else
    {
        UInt32 enable_output = 1;
        AudioUnitSetProperty(*voice_unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, kOutputBus, &enable_output,
                             sizeof(enable_output));
        AudioUnitSetProperty(*voice_unit, kAudioUnitProperty_StreamFormat,
                             kAudioUnitScope_Input, kOutputBus,
                             &stream_format, sizeof (stream_format));
        [self setPlayOutRenderCallback:*voice_unit];
    }

    Float64 f64 = 0;
    UInt32 size = sizeof(f64);
    OSStatus latency_result = AudioUnitGetProperty(*voice_unit,
                                                   kAudioUnitProperty_Latency,
                                                   kAudioUnitScope_Global,
                                                   0, &f64, &size);
    if (!isPlayout)
    {
        _recording_AudioUnitProperty_Latency = (0 == latency_result) ? f64 : 0;
    }
    else
    {
        _playout_AudioUnitProperty_Latency = (0 == latency_result) ? f64 : 0;
    }

    // Initialize the Voice-Processing I/O unit instance.
    result = AudioUnitInitialize(*voice_unit);
    if (CheckError(result, @"setupAudioUnit.AudioUnitInitialize")) {
        return NO;
    }

    [self setBluetoothAsPrefferedInputDevice];
    return YES;
}

- (BOOL)setPlayOutRenderCallback:(AudioUnit)unit
{
    AURenderCallbackStruct render_callback;
    render_callback.inputProc = playout_cb;;
    render_callback.inputProcRefCon = (__bridge void *)(self);
    OSStatus result = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input, kOutputBus, &render_callback,
                                           sizeof(render_callback));
    return (result == 0);
}

@end
