/*****************************************************************************
 * avsamplebuffer.m: AVSampleBufferAudioRenderer audio output for macOS
 *****************************************************************************
 * Copyright (C) 2024 VLC authors, VideoLAN and VideoLABS
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#ifdef HAVE_CONFIG_H
# import "config.h"
#endif

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

#import <vlc_common.h>
#import <vlc_plugin.h>
#import <vlc_aout.h>

#define MIN_MACOS 11.3

static AudioChannelLabel
VlcChanToAudioChannelLabel(unsigned chan, bool swap_rear_surround)
{
    switch (chan)
    {
        case AOUT_CHAN_LEFT:
            return kAudioChannelLabel_Left;
        case AOUT_CHAN_RIGHT:
            return kAudioChannelLabel_Right;
        case AOUT_CHAN_CENTER:
            return kAudioChannelLabel_Center;
        case AOUT_CHAN_LFE:
            return kAudioChannelLabel_LFEScreen;
        case AOUT_CHAN_REARLEFT:
            return swap_rear_surround ? kAudioChannelLabel_RearSurroundLeft
                                      : kAudioChannelLabel_LeftSurround;
        case AOUT_CHAN_REARRIGHT:
            return swap_rear_surround ? kAudioChannelLabel_RearSurroundRight
                                      : kAudioChannelLabel_RightSurround;
        case AOUT_CHAN_MIDDLELEFT:
            return swap_rear_surround ? kAudioChannelLabel_LeftSurround
                                      : kAudioChannelLabel_RearSurroundLeft;
        case AOUT_CHAN_MIDDLERIGHT:
            return swap_rear_surround ? kAudioChannelLabel_RightSurround
                                      : kAudioChannelLabel_RearSurroundRight;
        case AOUT_CHAN_REARCENTER:
            return kAudioChannelLabel_CenterSurround;
        default:
            vlc_assert_unreachable();
    }
}

static int
MapChannelLayout(audio_output_t *aout, const audio_sample_format_t *fmt,
                 bool binaural, AudioChannelLayout **layoutp, size_t *sizep)
{
    const unsigned channels = aout_FormatNbChannels(fmt);

    if (channels <= 2)
    {
        AudioChannelLayout *layout = calloc(1, sizeof(*layout));
        if (layout == NULL)
            return VLC_ENOMEM;

        if (channels == 1)
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
        else
            layout->mChannelLayoutTag = binaural ? kAudioChannelLayoutTag_Binaural
                                                 : kAudioChannelLayoutTag_Stereo;
        *layoutp = layout;
        *sizep = sizeof(*layout);
        return VLC_SUCCESS;
    }

    const size_t size = sizeof(AudioChannelLayout)
                      + channels * sizeof(AudioChannelDescription);
    AudioChannelLayout *layout = calloc(1, size);
    if (layout == NULL)
        return VLC_ENOMEM;

    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    layout->mNumberChannelDescriptions = channels;

    const bool swap_rear_surround =
        (fmt->i_physical_channels & AOUT_CHANS_7_0) == AOUT_CHANS_7_0;
    unsigned chan_idx = 0;
    for (unsigned i = 0; i < AOUT_CHAN_MAX; ++i)
    {
        const uint32_t vlcchan = pi_vlc_chan_order_wg4[i];
        if ((vlcchan & fmt->i_physical_channels) == 0)
            continue;

        layout->mChannelDescriptions[chan_idx].mChannelLabel =
            VlcChanToAudioChannelLabel(vlcchan, swap_rear_surround);
        layout->mChannelDescriptions[chan_idx].mChannelFlags =
            kAudioChannelFlags_AllOff;
        chan_idx++;
    }

    msg_Dbg(aout, "keeping the %u channels input layout", channels);
    *layoutp = layout;
    *sizep = size;
    return VLC_SUCCESS;
}

API_AVAILABLE(macos(MIN_MACOS))
@interface VLCAVSample : NSObject
{
    audio_output_t *_aout;

    CMAudioFormatDescriptionRef _fmtDesc;
    AVSampleBufferAudioRenderer *_renderer;
    AVSampleBufferRenderSynchronizer *_sync;
    dispatch_queue_t _dataQueue;
    size_t _bytesPerFrame;
    unsigned _sampleRate;

    vlc_mutex_t _bufferLock;
    vlc_cond_t _bufferWait;

    block_t *_outChain;
    block_t **_outChainLast;

    int64_t _ptsSamples;
    int64_t _writtenSamples;
    vlc_tick_t _startDate;
    vlc_tick_t _pauseDate;
    BOOL _stopped;
    BOOL _scheduled;
    BOOL _paused;

    float _volume;
    BOOL _muted;
}
@end

@implementation VLCAVSample

- (instancetype)init:(audio_output_t *)aout volume:(float)volume muted:(BOOL)muted
{
    self = [super init];
    if (self == nil)
        return nil;

    _aout = aout;
    _volume = volume;
    _muted = muted;
    vlc_mutex_init(&_bufferLock);
    vlc_cond_init(&_bufferWait);
    _outChain = NULL;
    _outChainLast = &_outChain;

    _dataQueue = dispatch_queue_create("VLC AVSampleBuffer data queue",
                                       DISPATCH_QUEUE_SERIAL);
    if (_dataQueue == nil)
        return nil;

    /* The first CMAudioFormatDescriptionCreate() call takes 200-600 ms to load
     * its static context. Pay that here rather than in start(), where it would
     * skew playback timing. */
    static const AudioStreamBasicDescription dummyDesc = {
        .mSampleRate = 48000,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mChannelsPerFrame = 2,
        .mFramesPerPacket = 1,
        .mBitsPerChannel = 32,
    };
    CMAudioFormatDescriptionRef dummyFmtDesc;
    if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &dummyDesc, 0, nil,
                                       0, nil, nil, &dummyFmtDesc) == noErr)
        CFRelease(dummyFmtDesc);

    return self;
}

- (void)dealloc
{
    assert(_outChain == NULL);
    vlc_cond_destroy(&_bufferWait);
    vlc_mutex_destroy(&_bufferLock);
}

static void
customBlock_Free(void *refcon, void *doomedMemoryBlock, size_t sizeInBytes)
{
    block_t *block = refcon;

    assert(block->i_buffer == sizeInBytes);
    block_Release(block);

    (void) doomedMemoryBlock;
    (void) sizeInBytes;
}

- (CMSampleBufferRef)wrapBuffer:(block_t *)block pts:(int64_t)ptsSamples
{
    const CMBlockBufferCustomBlockSource blockSource = {
        .version = kCMBlockBufferCustomBlockSourceVersion,
        .FreeBlock = customBlock_Free,
        .refCon = block,
    };

    CMBlockBufferRef blockBuf;
    OSStatus status =
        CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                           block->p_buffer, block->i_buffer,
                                           NULL, &blockSource,
                                           0, block->i_buffer, 0, &blockBuf);
    if (status != noErr)
    {
        msg_Err(_aout, "CMBlockBufferRef creation failure %li", (long)status);
        block_Release(block);
        return nil;
    }

    const CMSampleTimingInfo timeInfo = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMake(ptsSamples, _sampleRate),
        .decodeTimeStamp = kCMTimeInvalid,
    };

    CMSampleBufferRef sampleBuf;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuf, _fmtDesc,
                                       block->i_nb_samples, 1, &timeInfo,
                                       1, &_bytesPerFrame, &sampleBuf);
    CFRelease(blockBuf);

    if (status != noErr)
    {
        msg_Warn(_aout, "CMSampleBufferRef creation failure %li", (long)status);
        return nil;
    }

    return sampleBuf;
}

- (void)applyVolume
{
    const float gain = _volume > 1.f ? _volume * _volume * _volume : 1.f;
    aout_GainRequest(_aout, gain);

    const float volume = __MIN(_volume, 1.f);
    _renderer.volume = volume * volume * volume;
    _renderer.muted = _muted;
}

- (void)setVolume:(float)volume
{
    _volume = volume;
    [self applyVolume];
    aout_VolumeReport(_aout, volume);

    if (var_InheritBool(_aout, "volume-save"))
        config_PutInt(_aout, "avsamplebuffer-volume",
                      lroundf(volume * AOUT_VOLUME_DEFAULT));
}

- (void)setMute:(BOOL)muted
{
    _muted = muted;
    _renderer.muted = muted;
    aout_MuteReport(_aout, muted);
}

+ (vlc_tick_t)CMTimeToTick:(CMTime)timestamp
{
    return CMTimeConvertScale(timestamp, CLOCK_FREQ,
                              kCMTimeRoundingMethod_Default).value;
}

- (vlc_tick_t)samplesToTicks:(int64_t)samples
{
    return samples * CLOCK_FREQ / _sampleRate;
}

static CMTime API_AVAILABLE(macos(MIN_MACOS))
HostTimeFromTick(vlc_tick_t date)
{
    const CMTime now = CMClockGetTime(CMClockGetHostTimeClock());
    return CMTimeAdd(now, CMTimeMake(date - mdate(), CLOCK_FREQ));
}

- (void)scheduleStartLocked
{
    msg_Dbg(_aout, "scheduling playback start in %"PRId64" us",
            _startDate - mdate());

    [_sync setRate:1.f time:kCMTimeZero atHostTime:HostTimeFromTick(_startDate)];
    _scheduled = YES;
}

- (vlc_tick_t)pendingTicksLocked
{
    const vlc_tick_t written = [self samplesToTicks:_writtenSamples];
    const vlc_tick_t played = [VLCAVSample CMTimeToTick:_sync.currentTime];
    const vlc_tick_t now = mdate();

    if (!_scheduled || (played == 0 && now < _startDate))
        return __MAX(_startDate - now, 0) + written;

    return written - played;
}

- (int)timeGet:(vlc_tick_t *)delay
{
    vlc_mutex_lock(&_bufferLock);
    if (_ptsSamples < 0 || _stopped)
    {
        vlc_mutex_unlock(&_bufferLock);
        return -1;
    }
    const vlc_tick_t pending = [self pendingTicksLocked];
    vlc_mutex_unlock(&_bufferLock);

    *delay = __MAX(pending, 0);
    return 0;
}

- (void)drain
{
    vlc_mutex_lock(&_bufferLock);
    if (_ptsSamples < 0)
    {
        vlc_mutex_unlock(&_bufferLock);
        return;
    }

    const vlc_tick_t deadline =
        mdate() + [self pendingTicksLocked] + VLC_TICK_FROM_MS(500);

    while (!_stopped && !_paused && mdate() < deadline)
    {
        const vlc_tick_t pending = [self pendingTicksLocked];
        if (pending <= 0)
            break;

        vlc_mutex_unlock(&_bufferLock);
        msleep(__MIN(pending, VLC_TICK_FROM_MS(50)));
        vlc_mutex_lock(&_bufferLock);
    }
    vlc_mutex_unlock(&_bufferLock);
}

- (void)flush
{
    if (_ptsSamples >= 0)
        [self stopSyncRenderer];

    _ptsSamples = -1;
    _writtenSamples = 0;
    _scheduled = NO;
    _startDate = VLC_TICK_INVALID;
}

- (void)pause:(BOOL)pause date:(vlc_tick_t)date
{
    vlc_mutex_lock(&_bufferLock);

    if (pause)
    {
        _pauseDate = date;
        if (_scheduled)
            _sync.rate = 0.f;
    }
    else if (_paused && _ptsSamples >= 0)
    {
        const BOOL clockStarted = _scheduled
            && [VLCAVSample CMTimeToTick:_sync.currentTime] != 0;
        if (clockStarted)
            _sync.rate = 1.f;
        else
        {
            _startDate += date - _pauseDate;
            [self scheduleStartLocked];
        }
    }

    _paused = pause;
    vlc_mutex_unlock(&_bufferLock);
}

- (void)enqueueNextBlockLocked
{
    block_t *block = _outChain;
    _outChain = block->p_next;
    if (_outChain == NULL)
        _outChainLast = &_outChain;
    block->p_next = NULL;

    const int64_t pts = _ptsSamples;
    _ptsSamples += block->i_nb_samples;

    /* The first enqueue after a start or flush blocks for ~150 ms while macOS
     * sets up spatialization and head tracking. Holding _bufferLock across it
     * stalls time_get() on the decoder thread, which makes the core flush,
     * which triggers the setup again, forever. */
    vlc_mutex_unlock(&_bufferLock);
    CMSampleBufferRef buffer = [self wrapBuffer:block pts:pts];
    if (buffer != nil)
    {
        [_renderer enqueueSampleBuffer:buffer];
        CFRelease(buffer);
    }
    vlc_mutex_lock(&_bufferLock);
}

- (void)whenDataReady
{
    vlc_mutex_lock(&_bufferLock);

    while (!_stopped)
    {
        if (_outChain == NULL)
        {
            vlc_cond_wait(&_bufferWait, &_bufferLock);
            continue;
        }

        if (!_renderer.readyForMoreMediaData)
            break;

        [self enqueueNextBlockLocked];
    }

    vlc_mutex_unlock(&_bufferLock);
}

- (void)play:(block_t *)block
{
    vlc_mutex_lock(&_bufferLock);

    if (_ptsSamples == -1)
    {
        _stopped = NO;
        _ptsSamples = 0;
        _writtenSamples = 0;
        _startDate = block->i_pts;
        if (!_paused)
            [self scheduleStartLocked];

        __weak typeof(self) weakSelf = self;
        [_renderer requestMediaDataWhenReadyOnQueue:_dataQueue usingBlock:^{
            [weakSelf whenDataReady];
        }];
    }

    _writtenSamples += block->i_nb_samples;
    block_ChainLastAppend(&_outChainLast, block);

    vlc_cond_signal(&_bufferWait);
    vlc_mutex_unlock(&_bufferLock);

    if (_renderer.status == AVQueuedSampleBufferRenderingStatusFailed)
    {
        NSString *reason = _renderer.error.localizedDescription ?: @"unknown error";
        msg_Err(_aout, "renderer failed (%s), restarting", reason.UTF8String);
        aout_RestartRequest(_aout, AOUT_RESTART_OUTPUT);
    }
}

- (void)stopSyncRenderer
{
    vlc_mutex_lock(&_bufferLock);
    _sync.rate = 0.f;

    [_renderer stopRequestingMediaData];

    _stopped = YES;

    block_ChainRelease(_outChain);
    _outChain = NULL;
    _outChainLast = &_outChain;

    vlc_cond_signal(&_bufferWait);
    vlc_mutex_unlock(&_bufferLock);

    /* stopRequestingMediaData doesn't wait for an in-flight whenDataReady
     * block. Flush only once it is done, so no stale enqueue lands after. */
    dispatch_sync(_dataQueue, ^{});
    [_renderer flush];
}

- (void)stop
{
    if (_ptsSamples >= 0)
        [self stopSyncRenderer];

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_sync removeRenderer:_renderer atTime:kCMTimeInvalid completionHandler:nil];
    _renderer = nil;
    _sync = nil;

    CFRelease(_fmtDesc);
    _fmtDesc = NULL;
}

- (void)flushedAutomatically:(NSNotification *)notification
{
    msg_Warn(_aout, "renderer flushed automatically, restarting");
    aout_RestartRequest(_aout, AOUT_RESTART_OUTPUT);
}

- (BOOL)start:(audio_sample_format_t *)fmt
{
    if (!AOUT_FMT_LINEAR(fmt))
        return NO;

    fmt->i_format = VLC_CODEC_FL32;
    fmt->channel_type = AUDIO_CHANNEL_TYPE_BITMAP;

    const bool binaural =
        var_GetInteger(_aout, "stereo-mode") == AOUT_VAR_CHAN_HEADPHONES;

    AudioChannelLayout *layout;
    size_t layoutSize;
    if (MapChannelLayout(_aout, fmt, binaural, &layout, &layoutSize) != VLC_SUCCESS)
        return NO;

    AudioStreamBasicDescription desc = {
        .mSampleRate = fmt->i_rate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mChannelsPerFrame = aout_FormatNbChannels(fmt),
        .mFramesPerPacket = 1,
        .mBitsPerChannel = 32,
    };
    desc.mBytesPerFrame = desc.mBitsPerChannel * desc.mChannelsPerFrame / 8;
    desc.mBytesPerPacket = desc.mBytesPerFrame * desc.mFramesPerPacket;

    OSStatus status =
        CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &desc,
                                       layoutSize, layout, 0, nil, nil,
                                       &_fmtDesc);
    free(layout);
    if (status != noErr)
    {
        msg_Err(_aout, "CMAudioFormatDescriptionRef creation failure %li",
                (long)status);
        return NO;
    }

    _renderer = [[AVSampleBufferAudioRenderer alloc] init];
    _sync = [[AVSampleBufferRenderSynchronizer alloc] init];
    if (_renderer == nil || _sync == nil)
    {
        _renderer = nil;
        _sync = nil;
        CFRelease(_fmtDesc);
        _fmtDesc = NULL;
        return NO;
    }

    const bool spatializeStereo =
        var_InheritBool(_aout, "avsamplebuffer-spatialize-stereo");
    if (@available(macOS 12.0, *))
        _renderer.allowedAudioSpatializationFormats = spatializeStereo
            ? AVAudioSpatializationFormatMonoStereoAndMultichannel
            : AVAudioSpatializationFormatMultichannel;

    _sync.delaysRateChangeUntilHasSufficientMediaData = NO;
    [_sync addRenderer:_renderer];
    [self applyVolume];

    _stopped = NO;
    _scheduled = NO;
    _paused = NO;
    _ptsSamples = -1;
    _writtenSamples = 0;
    _startDate = VLC_TICK_INVALID;
    _pauseDate = VLC_TICK_INVALID;
    _sampleRate = fmt->i_rate;
    _bytesPerFrame = desc.mBytesPerFrame;

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(flushedAutomatically:)
               name:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification
             object:_renderer];

    msg_Dbg(_aout, "rendering %u channels at %u Hz, %s layout, spatializing %s",
            desc.mChannelsPerFrame, fmt->i_rate,
            binaural ? "binaural" : "speaker",
            spatializeStereo ? "mono, stereo and multichannel" : "multichannel only");
    return YES;
}

@end

static int API_AVAILABLE(macos(MIN_MACOS))
TimeGet(audio_output_t *aout, vlc_tick_t *delay)
{
    VLCAVSample *sys = (__bridge VLCAVSample *)aout->sys;
    return [sys timeGet:delay];
}

static int API_AVAILABLE(macos(MIN_MACOS))
MuteSet(audio_output_t *aout, bool mute)
{
    VLCAVSample *sys = (__bridge VLCAVSample *)aout->sys;
    [sys setMute:mute];
    return VLC_SUCCESS;
}

static int API_AVAILABLE(macos(MIN_MACOS))
VolumeSet(audio_output_t *aout, float volume)
{
    VLCAVSample *sys = (__bridge VLCAVSample *)aout->sys;
    [sys setVolume:volume];
    return VLC_SUCCESS;
}

static void API_AVAILABLE(macos(MIN_MACOS))
Flush(audio_output_t *aout, bool wait)
{
    VLCAVSample *sys = (__bridge VLCAVSample *)aout->sys;
    if (wait)
        [sys drain];
    [sys flush];
}

static void API_AVAILABLE(macos(MIN_MACOS))
Pause(audio_output_t *aout, bool pause, vlc_tick_t date)
{
    VLCAVSample *sys = (__bridge VLCAVSample *)aout->sys;
    [sys pause:pause date:date];
}

static void API_AVAILABLE(macos(MIN_MACOS))
Play(audio_output_t *aout, block_t *block)
{
    VLCAVSample *sys = (__bridge VLCAVSample *)aout->sys;
    [sys play:block];
}

static void API_AVAILABLE(macos(MIN_MACOS))
Stop(audio_output_t *aout)
{
    VLCAVSample *sys = (__bridge VLCAVSample *)aout->sys;
    [sys stop];
}

static int API_AVAILABLE(macos(MIN_MACOS))
Start(audio_output_t *aout, audio_sample_format_t *restrict fmt)
{
    VLCAVSample *sys = (__bridge VLCAVSample *)aout->sys;
    return [sys start:fmt] ? VLC_SUCCESS : VLC_EGENERIC;
}

static void
Close(vlc_object_t *obj)
{
    if (@available(macOS MIN_MACOS, *))
    {
        audio_output_t *aout = (audio_output_t *)obj;
        VLCAVSample *sys = (__bridge_transfer VLCAVSample *)aout->sys;
        (void) sys;
    }
}

static int
Open(vlc_object_t *obj)
{
    if (@available(macOS MIN_MACOS, *))
    {
        audio_output_t *aout = (audio_output_t *)obj;

        const float volume = var_InheritInteger(aout, "avsamplebuffer-volume")
                           / (float)AOUT_VOLUME_DEFAULT;
        const bool muted = var_InheritBool(aout, "mute");

        VLCAVSample *sys = [[VLCAVSample alloc] init:aout volume:volume muted:muted];
        if (sys == nil)
            return VLC_EGENERIC;
        aout->sys = (__bridge_retained void *)sys;

        aout->start = Start;
        aout->stop = Stop;
        aout->time_get = TimeGet;
        aout->play = Play;
        aout->pause = Pause;
        aout->flush = Flush;
        aout->volume_set = VolumeSet;
        aout->mute_set = MuteSet;

        aout_VolumeReport(aout, volume);
        aout_MuteReport(aout, muted);
        return VLC_SUCCESS;
    }
    return VLC_EGENERIC;
}

#define VOLUME_TEXT N_("Audio volume")
#define VOLUME_LONGTEXT VOLUME_TEXT

#define SPATIALIZE_STEREO_TEXT N_("Spatialize mono and stereo audio")
#define SPATIALIZE_STEREO_LONGTEXT N_( \
    "Let macOS apply Spatial Audio to mono and stereo sources too, not only " \
    "to multichannel ones. Spatial Audio itself is switched on and off from " \
    "the Sound menu in Control Center.")

vlc_module_begin ()
    set_shortname("avsample")
    set_description(N_("AVSampleBufferAudioRenderer output (Spatial Audio)"))
    set_capability("audio output", 100)
    set_category(CAT_AUDIO)
    set_subcategory(SUBCAT_AUDIO_AOUT)
    add_integer("avsamplebuffer-volume", AOUT_VOLUME_DEFAULT,
                VOLUME_TEXT, VOLUME_LONGTEXT, true)
        change_integer_range(0, AOUT_VOLUME_MAX)
    add_bool("avsamplebuffer-spatialize-stereo", true,
             SPATIALIZE_STEREO_TEXT, SPATIALIZE_STEREO_LONGTEXT, false)
    set_callbacks(Open, Close)
vlc_module_end ()
