/*
 * Showcase.m - Wireless CarPlay receiver application
 *
 * Self-contained orchestrator app with state machine, car management,
 * hotspot credential storage, receiver media, touch input, and lifecycle
 * recovery for jailbroken iPhones and iPads.
 *
 * Compile (on-device):
 *   clang -fobjc-arc -isysroot /tmp/iPhoneOS10.3.sdk \
 *         -o Showcase Showcase.m \
 *         -framework UIKit -framework AVFoundation -framework AudioToolbox \
 *         -framework CoreMedia -framework Foundation -framework Security \
 *         -Wl,-undefined,dynamic_lookup
 */

#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <Security/Security.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/sysctl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <float.h>
#include <math.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include "baa_broker.h"

extern char **environ;
extern BOOL iPlayPreparePrivateBluetooth(void);
extern BOOL iPlayStartLocalCarPlaySession(NSString *displayName, NSInteger port);
extern BOOL iPlayStartRemoteCarPlaySession(NSString *displayName, NSString *address, NSInteger port);
extern NSString *iPlayDiscoverRemoteCarPlayReceiver(NSTimeInterval timeout);
extern void iPlayStopRequestedCarPlaySession(void);
extern int iPlayCarPlayServiceMain(int argc, char *argv[]);
extern volatile int g_iPlayAirPlayServerReady;


/* ═══════════════════════════════════════════════════════════════
 * Application logger
 * ═══════════════════════════════════════════════════════════════ */

#define LOG_DIR     "/tmp"
#define APP_LOG     LOG_DIR "/iplay-app.log"
#define TCPDUMP_DIR  "/tmp"
#define TCPDUMP_LOG  TCPDUMP_DIR "/iplay-tcpdump.log"
#define TCPDUMP_MAX_SECONDS 300
#define DIAGNOSTICS_ENABLED_KEY @"diagnosticsEnabled"
static FILE *g_logfile = NULL;

static uint64_t monotonic_nanos_now(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (uint64_t)now.tv_sec * NSEC_PER_SEC + (uint64_t)now.tv_nsec;
}

static void ip_log(const char *fmt, ...) {
    if (!g_logfile) return;
    char ts[32];
    time_t t = time(NULL);
    struct tm tm; localtime_r(&t, &tm);
    strftime(ts, sizeof(ts), "%H:%M:%S", &tm);
    uint64_t monotonicNanos = monotonic_nanos_now();
    fprintf(g_logfile, "[%s mono=%llu.%06llu] ", ts,
            (unsigned long long)(monotonicNanos / NSEC_PER_SEC),
            (unsigned long long)((monotonicNanos % NSEC_PER_SEC) / 1000ULL));
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_logfile, fmt, ap);
    va_end(ap);
    fprintf(g_logfile, "\n");
    fflush(g_logfile);
}

static void ip_log_open(void) {
    mkdir("/var/mobile/Library/Showcase", 0755);
    mkdir(LOG_DIR, 0755);
    g_logfile = fopen(APP_LOG, "a");
    if (g_logfile) {
        fprintf(g_logfile, "\n══════════════ Showcase launch ══════════════\n");
        fflush(g_logfile);
    }
}


/* ═══════════════════════════════════════════════════════════════
 * Background audio keep-alive
 *
 * Mirrors StikDebug's proven pattern: a looping zero-filled PCM buffer
 * through AVAudioEngine, playback+mixWithOthers, interruption recovery,
 * and a 2-second health check. The CarPlay flow owns one lease.
 * ═══════════════════════════════════════════════════════════════ */

@interface IPlayBackgroundAudioKeeper : NSObject
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) AVAudioPlayerNode *player;
@property (nonatomic, strong) AVAudioPCMBuffer *silenceBuffer;
@property (nonatomic, strong) NSTimer *healthTimer;
@property (nonatomic, assign) BOOL requested;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTask;
+ (instancetype)shared;
- (void)requestStart;
- (void)requestStop;
@end

@implementation IPlayBackgroundAudioKeeper

+ (instancetype)shared {
    static IPlayBackgroundAudioKeeper *keeper;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ keeper = [[self alloc] init]; });
    return keeper;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _backgroundTask = UIBackgroundTaskInvalid;
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(handleAudioInterruption:)
            name:AVAudioSessionInterruptionNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(handleMediaServicesReset:)
            name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    }
    return self;
}

- (void)runOnMain:(dispatch_block_t)block {
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

- (void)requestStart {
    [self runOnMain:^{
        self.requested = YES;
        [self startOrRecover];
    }];
}

- (void)requestStop {
    [self runOnMain:^{
        self.requested = NO;
        self.running = NO;
        [self.healthTimer invalidate];
        self.healthTimer = nil;
        [self.player stop];
        [self.engine stop];
        self.player = nil;
        self.engine = nil;
        self.silenceBuffer = nil;

        if (self.backgroundTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
            self.backgroundTask = UIBackgroundTaskInvalid;
        }

        NSError *error = nil;
        [[AVAudioSession sharedInstance] setActive:NO
            withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
            error:&error];
        ip_log("background audio keep-alive stopped%s",
               error ? [[NSString stringWithFormat:@": %@", error.localizedDescription] UTF8String] : "");
    }];
}

- (void)startOrRecover {
    if (!self.requested) return;

    if (self.backgroundTask == UIBackgroundTaskInvalid) {
        __weak typeof(self) weakSelf = self;
        self.backgroundTask =
            [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"iPlayCarPlaySession"
                expirationHandler:^{
                    typeof(self) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    if (strongSelf.backgroundTask != UIBackgroundTaskInvalid) {
                        [[UIApplication sharedApplication] endBackgroundTask:strongSelf.backgroundTask];
                        strongSelf.backgroundTask = UIBackgroundTaskInvalid;
                    }
                    ip_log("background task expired; silent audio keep-alive remains active");
                }];
    }

    if (self.engine.isRunning && self.player.isPlaying) {
        self.running = YES;
        return;
    }

    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers
                   error:&error];
    if (!error) [session setActive:YES error:&error];
    if (error) {
        ip_log("background audio session activation failed: %s",
               error.localizedDescription.UTF8String);
        return;
    }

    self.engine = [[AVAudioEngine alloc] init];
    self.player = [[AVAudioPlayerNode alloc] init];
    [self.engine attachNode:self.player];

    AVAudioFormat *format = [self.engine.mainMixerNode outputFormatForBus:0];
    if (!format || format.sampleRate <= 0) {
        ip_log("background audio keep-alive: invalid mixer format");
        return;
    }
    [self.engine connect:self.player to:self.engine.mainMixerNode format:format];

    AVAudioFrameCount frames = (AVAudioFrameCount)MAX(1024.0, format.sampleRate);
    AVAudioPCMBuffer *buffer =
        [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frames];
    if (!buffer) {
        ip_log("background audio keep-alive: could not allocate silent buffer");
        return;
    }
    buffer.frameLength = frames;
    AudioBufferList *abl = buffer.mutableAudioBufferList;
    for (UInt32 i = 0; i < abl->mNumberBuffers; i++) {
        if (abl->mBuffers[i].mData && abl->mBuffers[i].mDataByteSize) {
            memset(abl->mBuffers[i].mData, 0, abl->mBuffers[i].mDataByteSize);
        }
    }
    self.silenceBuffer = buffer;
    [self.player scheduleBuffer:buffer atTime:nil
                        options:AVAudioPlayerNodeBufferLoops
              completionHandler:nil];

    if (![self.engine startAndReturnError:&error]) {
        ip_log("background audio engine start failed: %s",
               error.localizedDescription.UTF8String);
        return;
    }
    [self.player play];
    self.running = YES;

    if (!self.healthTimer) {
        self.healthTimer = [NSTimer timerWithTimeInterval:2.0
            repeats:YES block:^(__unused NSTimer *timer) {
                IPlayBackgroundAudioKeeper *keeper = [IPlayBackgroundAudioKeeper shared];
                if (keeper.requested &&
                    (!keeper.engine.isRunning || !keeper.player.isPlaying)) {
                    [keeper startOrRecover];
                }
            }];
        [[NSRunLoop mainRunLoop] addTimer:self.healthTimer forMode:NSRunLoopCommonModes];
    }
    ip_log("background audio keep-alive active (silent PCM loop)");
}

- (void)handleAudioInterruption:(NSNotification *)notification {
    NSNumber *value = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    if (!value || value.unsignedIntegerValue != AVAudioSessionInterruptionTypeEnded ||
        !self.requested) return;
    [self runOnMain:^{ [self startOrRecover]; }];
}

- (void)handleMediaServicesReset:(NSNotification *)notification {
    (void)notification;
    if (!self.requested) return;
    [self runOnMain:^{
        self.engine = nil;
        self.player = nil;
        self.silenceBuffer = nil;
        self.running = NO;
        [self startOrRecover];
    }];
}
@end

/* ═══════════════════════════════════════════════════════════════
 * Configuration
 * ═══════════════════════════════════════════════════════════════ */

#define APP_NAME          "iPlay"
#ifdef SHOWCASE_ROOTLESS
#define APP_VERSION       "1.0 beta 3-1 (skywalk)"
#else
#define APP_VERSION       "0.1 SideStore"

/* This target is built exclusively for stock SideStore-style sideloading.
 * Never infer jailbreak mode from UID: that caused legacy Showcase/Sileo
 * diagnostics and hotspot setup to leak into normal installs. */
static inline BOOL iPlayIsStockSideStoreBuild(void) { return YES; }

#endif
#define APP_AUTHOR        "NightVibes33 / Showcase core by Amine Rostane"
static const char *iplay_ipc_socket_path(void) {
    static char path[1024] = {0};
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *socketPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"iplay-carplay.sock"];
        strlcpy(path, socketPath.fileSystemRepresentation, sizeof(path));
    });
    return path;
}
#define SOCK_PATH         (iplay_ipc_socket_path())
#define BLUETOOTHD_PLIST  "/System/Library/LaunchDaemons/com.apple.bluetoothd.plist"
#define BT_READY_PATH     "/tmp/showcase_bt_ready"
#ifdef SHOWCASE_ROOTLESS
#define JB_PREFIX         "/var/jb"
#define BLUETOOL_PLIST    "/System/Library/LaunchDaemons/com.apple.BlueTool.plist"
#ifndef SHOWCASE_BTSTACK_PLIST
#define SHOWCASE_BTSTACK_PLIST JB_PATH("/Library/LaunchDaemons/ch.ringwald.BTstack.plist")
#endif
#ifndef SHOWCASE_BTSTACK_SOCKET
#define SHOWCASE_BTSTACK_SOCKET "/tmp/BTstack"
#endif
#else
#define JB_PREFIX         ""
#ifndef SHOWCASE_BTSTACK_PLIST
#define SHOWCASE_BTSTACK_PLIST "/Library/LaunchDaemons/ch.ringwald.BTstack.plist"
#endif
#ifndef SHOWCASE_BTSTACK_SOCKET
#define SHOWCASE_BTSTACK_SOCKET "/tmp/BTstack"
#endif
#endif
#define JB_PATH(path)     JB_PREFIX path
#define BTSTACK_PLIST     SHOWCASE_BTSTACK_PLIST
#define BTSTACK_SOCKET    SHOWCASE_BTSTACK_SOCKET
#ifndef SHOWCASE_BTDAEMON_PATH
#define SHOWCASE_BTDAEMON_PATH JB_PATH("/usr/bin/BTdaemon")
#endif
#define BTDAEMON_PATH     SHOWCASE_BTDAEMON_PATH
#ifndef SHOWCASE_BTSTACK_DYLIB_PATH
#define SHOWCASE_BTSTACK_DYLIB_PATH JB_PATH("/usr/lib/libBTstack.dylib")
#endif
#define BTSTACK_DYLIB_PATH SHOWCASE_BTSTACK_DYLIB_PATH
#ifndef SHOWCASE_BTSTACK_LOG_PATH
#define SHOWCASE_BTSTACK_LOG_PATH "/var/log/BTstack.log"
#endif
#ifdef SHOWCASE_ROOTLESS
#define BT_HELPER_NAME    "CarDisplaySim"
#define SVC_HELPER_NAME   "CarPlay Simulator"
#else
#define BT_HELPER_NAME    "carplay_bt"
#define SVC_HELPER_NAME   "carplay_services"
#endif
#define AP_INTERFACE      "bridge100"
#define PHONE_CANVAS_W    1024.0
#define PHONE_CANVAS_H    768.0
#define BTSTACK_PREFS_DIR "/var/mobile/Library/Preferences"
#define BTSTACK_PREFS     BTSTACK_PREFS_DIR "/ch.ringwald.btstack.plist"

/* IPC message types */
#define MSG_VIDEO_CONFIG  0x01
#define MSG_VIDEO_FRAME   0x02
#define MSG_TOUCH         0x03
#define MSG_STATUS        0x04   /* services → app, 1 byte status code */
#define MSG_APP_VISIBILITY 0x05  /* app → services, 1 while foreground */
#define MSG_VIDEO_TIMING  0x06   /* services → app, uint32 latency in ms */
#define MSG_VIDEO_RESYNC  0x07   /* app → services, renderer needs keyframe */
#define MSG_AUDIO_CONFIG  0x08   /* services → app, negotiated audio stream */
#define MSG_AUDIO_PACKET  0x09   /* services → app, decrypted RTP payload */
#define MSG_BT_HANDOFF    0x0A   /* services → app, end Bluetooth transport */
#define MSG_AUDIO_RENDER  0x0B   /* app → services, hardware render clock */
#define MSG_AUDIO_CONTROL 0x0C   /* services → app, buffered playback control */
#define VIDEO_FRAME_METADATA_SIZE 56
#define VIDEO_STALE_RECOVERY_MIN_MS 250.0

#define AUDIO_CONTROL_PAUSE  0
#define AUDIO_CONTROL_RESUME 1
#define AUDIO_CONTROL_FLUSH  2
#define AUDIO_CONTROL_STOP   3

#define STATUS_IPHONE_CONNECTED     0x01
#define STATUS_PAIR_SETUP_COMPLETE  0x02
#define STATUS_PAIR_VERIFY_COMPLETE 0x03
#define STATUS_STREAM_SETUP         0x04

#define TOUCH_DOWN  0
#define TOUCH_MOVE  1
#define TOUCH_UP    2
#define TOUCH_CANCEL 3

typedef NS_ENUM(NSInteger, ShowcaseState) {
    StateIdle = 0,
    StateAwaitingAP,
    StatePreparingBT,
    StatePreparingNet,
    StateAwaitingPhone,
    StateActive,
    StateStopping,
};

static const char *launchctl_path(void) {
#ifdef SHOWCASE_ROOTLESS
    static const char *paths[] = {
        "/var/jb/usr/bin/launchctl",
        "/var/jb/bin/launchctl",
        "/bin/launchctl",
        "/usr/bin/launchctl",
        NULL
    };
#else
    static const char *paths[] = {
        "/bin/launchctl",
        "/usr/bin/launchctl",
        "/var/jb/usr/bin/launchctl",
        "/var/jb/bin/launchctl",
        NULL
    };
#endif
    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], X_OK) == 0) return paths[i];
    }
    return NULL;
}

/* ═══════════════════════════════════════════════════════════════
 * Globals
 * ═══════════════════════════════════════════════════════════════ */

static volatile int g_touch_fd = -1;
static volatile uint32_t g_touch_epoch = 0;
static dispatch_queue_t g_touch_write_queue = NULL;
static volatile float g_carplay_w = 0;
static volatile float g_carplay_h = 0;
static volatile int32_t g_video_suspended = 0;
static volatile int32_t g_video_needs_resync = 0;
static volatile uint32_t g_video_target_latency_ms = 75;
static volatile int32_t g_video_respect_timestamps = 0;
static volatile double g_video_sender_to_host_offset = 0.0;
static volatile int32_t g_video_timing_offset_valid = 0;

/* ── Sender-timeline clock recovery and presentation scheduling ───
 * Every VideoFrame carries params[0]: a 32.32 fixed-point instant on the
 * sender's session timeline. Presenting a frame needs that instant expressed in
 * host time, which means an offset between the two clocks plus a budget for
 * transport jitter.
 *
 * Offset. Estimated from the minimum of (hostArrival - senderTime): the
 * fastest-delivered frame is the one that suffered least queueing, so it is the
 * best available view of the true offset. The minimum is taken over a trailing
 * window rather than the whole session, otherwise a single unusually fast frame
 * anchors the timeline forever and the budget silently erodes. The applied
 * offset slews toward that target instead of stepping, because a step moves
 * every future frame's slot and shows up as a hitch.
 *
 * Budget. Fixed at the sender's latencyMs, frames whose transport delay exceeds
 * it miss their slot. The budget therefore tracks recent jitter and grows up to
 * the 2x latency that the AccessorySDK itself treats as the late threshold.
 *
 * Pacing. A frame that has missed its slot must not simply be dumped at "now":
 * after a hiccup a whole burst arrives at once, every frame lands within a
 * millisecond or two, and the display shows only the last of them — the same
 * collapse that displaying on arrival caused. Late frames are instead paced off
 * the previous frame's presentation time at slightly under one frame interval,
 * so the backlog drains in order and slightly faster than real time until it
 * rejoins the grid. This also makes presentation timestamps monotonic by
 * construction.
 * ──────────────────────────────────────────────────────────────── */
#define VIDEO_CLOCK_WINDOW_SECONDS  8.0    /* trailing window for the offset   */
#define VIDEO_CLOCK_SLEW_PER_SEC    0.004  /* 4 ms/s, both directions          */
#define VIDEO_CLOCK_RESET_SECONDS   5.0    /* beyond this, a new timeline      */
/* Budget sizing. The AccessorySDK never adds latencyMs to the display time at
 * all — it maps the timestamp through the synchronised clock and presents at
 * exactly that instant, using latencyMs only to decide what counts as late.
 * Our anchor is a delay minimum rather than a true NTP clock, so some budget is
 * required, but latencyMs is the sender's statement of expected latency and so
 * belongs as the ceiling, never the floor. Buffering is the expensive way to
 * buy smoothness: every millisecond here is a millisecond of touch response.
 * Pacing absorbs the tail instead. */
#define VIDEO_BUDGET_FLOOR_FRAMES   2.0    /* two frames of slack, ~33 ms      */
#define VIDEO_JITTER_DEVIATIONS     3.0    /* budget = mean + 3 deviations     */
#define VIDEO_JITTER_EWMA_SHIFT     16.0   /* smoothing for mean and deviation */
#define VIDEO_CATCHUP_GAP_FRACTION  0.80   /* drain bursts 20% faster than 1x  */
#define VIDEO_FRAME_INTERVAL_MIN    (1.0 / 240.0)
#define VIDEO_FRAME_INTERVAL_MAX    (1.0 / 15.0)

static double g_video_clock_offset = 0.0;   /* hostTime - senderTime, seconds */
static double g_video_clock_last_update = 0.0;
static bool   g_video_clock_valid = false;
static double g_video_window_min = 0.0;     /* min delay, current window      */
static double g_video_window_prev_min = 0.0;/* min delay, previous window     */
static double g_video_window_start = 0.0;
static bool   g_video_window_has_sample = false;
static double g_video_jitter_mean = 0.0;    /* EWMA of delay above offset     */
static double g_video_jitter_dev = 0.0;     /* EWMA of deviation from mean    */
static double g_video_budget_seconds = 0.0; /* applied jitter budget          */
static double g_video_last_pts = 0.0;       /* last scheduled presentation    */
static bool   g_video_last_pts_valid = false;
static double g_video_last_sender = 0.0;
static bool   g_video_last_sender_valid = false;
static double g_video_frame_interval = 1.0 / 60.0;  /* sender's actual cadence */

static void video_clock_reset(void) {
    g_video_clock_valid = false;
    g_video_clock_offset = 0.0;
    g_video_clock_last_update = 0.0;
    g_video_window_min = 0.0;
    g_video_window_prev_min = 0.0;
    g_video_window_start = 0.0;
    g_video_window_has_sample = false;
    g_video_jitter_mean = 0.0;
    g_video_jitter_dev = 0.0;
    g_video_budget_seconds = 0.0;
    g_video_last_pts = 0.0;
    g_video_last_pts_valid = false;
    g_video_last_sender = 0.0;
    g_video_last_sender_valid = false;
    g_video_frame_interval = 1.0 / 60.0;
}

static CMVideoFormatDescriptionRef
iPlayCreateVideoFormatDescription(const uint8_t *config,
                                  size_t configLength,
                                  BOOL *outHEVC) {
    if (outHEVC) *outHEVC = NO;
    if (!config || configLength < 7) return NULL;

    /* AVCDecoderConfigurationRecord (avcC). */
    {
        size_t off = 5;
        const uint8_t *ps[2] = {NULL, NULL};
        size_t psSize[2] = {0, 0};
        int nSPS = config[off] & 0x1F;
        off++;
        if (nSPS > 0 && off + 2 <= configLength) {
            uint16_t length = ((uint16_t)config[off] << 8) | config[off + 1];
            off += 2;
            if (off + length <= configLength) {
                ps[0] = config + off;
                psSize[0] = length;
                off += length;
            }
        }
        if (off < configLength) {
            int nPPS = config[off++];
            if (nPPS > 0 && off + 2 <= configLength) {
                uint16_t length = ((uint16_t)config[off] << 8) | config[off + 1];
                off += 2;
                if (off + length <= configLength) {
                    ps[1] = config + off;
                    psSize[1] = length;
                }
            }
        }
        if (ps[0] && ps[1]) {
            CMVideoFormatDescriptionRef desc = NULL;
            OSStatus status =
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    NULL, 2, ps, psSize, 4, &desc);
            if (status == noErr && desc) return desc;
            if (desc) CFRelease(desc);
        }
    }

    /* HEVCDecoderConfigurationRecord (hvcC). */
    if (configLength >= 23) {
        const uint8_t *sets[3] = {NULL, NULL, NULL}; /* VPS, SPS, PPS */
        size_t sizes[3] = {0, 0, 0};
        size_t off = 23;
        uint8_t arrayCount = config[22];
        for (uint8_t arrayIndex = 0;
             arrayIndex < arrayCount && off + 3 <= configLength;
             arrayIndex++) {
            uint8_t nalType = config[off] & 0x3F;
            off++;
            uint16_t nalCount =
                ((uint16_t)config[off] << 8) | config[off + 1];
            off += 2;
            for (uint16_t n = 0; n < nalCount && off + 2 <= configLength; n++) {
                uint16_t length =
                    ((uint16_t)config[off] << 8) | config[off + 1];
                off += 2;
                if (off + length > configLength) return NULL;
                int slot = nalType == 32 ? 0 : (nalType == 33 ? 1 : (nalType == 34 ? 2 : -1));
                if (slot >= 0 && !sets[slot]) {
                    sets[slot] = config + off;
                    sizes[slot] = length;
                }
                off += length;
            }
        }
        if (sets[0] && sets[1] && sets[2]) {
            CMVideoFormatDescriptionRef desc = NULL;
            OSStatus status =
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    NULL, 3, sets, sizes, 4, NULL, &desc);
            if (status == noErr && desc) {
                if (outHEVC) *outHEVC = YES;
                return desc;
            }
            if (desc) CFRelease(desc);
        }
    }
    return NULL;
}

/* Computes the presentation host time for a frame. outMissedSlot reports that
 * the frame's own slot had already passed, i.e. transport exceeded the budget,
 * and outLatenessSeconds by how much.
 *
 * Magnitude is what matters, not the count. Apple's own receiver, measured on a
 * wired link, reports roughly half its frames past their slot — but never by
 * more than about 11 ms, and its headroom sits around 33 ms. A high late count
 * with small magnitudes is normal; large magnitudes are the defect. */
static double video_clock_schedule(uint64_t senderTimestamp,
                                   double hostArrival,
                                   bool *outMissedSlot,
                                   double *outLatenessSeconds) {
    double senderSeconds = (double)senderTimestamp / 4294967296.0;

    /*
     * Normal path: use the NTP mapping measured on the AirPlay timing socket.
     * This is what CarPlaySDK does through
     * AirTunesClock_GetUpTicksNearSynchronizedNTPTime. Arrival time is not a
     * clock sample; it includes Wi-Fi and TCP jitter, so it must never move a
     * correctly synchronized presentation timestamp.
     */
    if (g_video_timing_offset_valid) {
        double pts = senderSeconds + g_video_sender_to_host_offset;
        bool missed = pts <= hostArrival;
        if (outMissedSlot) *outMissedSlot = missed;
        if (outLatenessSeconds)
            *outLatenessSeconds = missed ? hostArrival - pts : 0.0;
        if (g_video_last_sender_valid) {
            double senderDelta = senderSeconds - g_video_last_sender;
            if (senderDelta >= VIDEO_FRAME_INTERVAL_MIN &&
                senderDelta <= VIDEO_FRAME_INTERVAL_MAX)
                g_video_frame_interval = senderDelta;
        }
        g_video_budget_seconds = 0.0;
        g_video_clock_offset = g_video_sender_to_host_offset;
        g_video_clock_valid = true;
        g_video_last_pts = pts;
        g_video_last_pts_valid = true;
        g_video_last_sender = senderSeconds;
        g_video_last_sender_valid = true;
        return pts;
    }

    double observed = hostArrival - senderSeconds;
    double latencySeconds = (double)g_video_target_latency_ms / 1000.0;

    if (!g_video_clock_valid ||
        fabs(observed - g_video_clock_offset) > VIDEO_CLOCK_RESET_SECONDS) {
        g_video_clock_valid = true;
        g_video_clock_offset = observed;
        g_video_clock_last_update = hostArrival;
        g_video_window_min = observed;
        g_video_window_prev_min = observed;
        g_video_window_start = hostArrival;
        g_video_window_has_sample = true;
        g_video_jitter_mean = 0.0;
        g_video_jitter_dev = 0.0;
        g_video_budget_seconds = 0.0;
        g_video_last_pts_valid = false;
        g_video_last_sender_valid = false;
    }

    /* Trailing-window minimum, kept as two half-windows so the estimate can
     * rise again when the path genuinely slows down. */
    if (!g_video_window_has_sample || observed < g_video_window_min)
        g_video_window_min = observed;
    g_video_window_has_sample = true;
    double jitter = observed - g_video_clock_offset;
    if (jitter < 0) jitter = 0;
    double deviation = fabs(jitter - g_video_jitter_mean);
    g_video_jitter_mean += (jitter - g_video_jitter_mean) / VIDEO_JITTER_EWMA_SHIFT;
    g_video_jitter_dev  += (deviation - g_video_jitter_dev) / VIDEO_JITTER_EWMA_SHIFT;

    if (hostArrival - g_video_window_start >= VIDEO_CLOCK_WINDOW_SECONDS) {
        g_video_window_prev_min = g_video_window_min;
        g_video_window_min = observed;
        g_video_window_start = hostArrival;
    }

    double target = g_video_window_min < g_video_window_prev_min
                  ? g_video_window_min : g_video_window_prev_min;
    double elapsed = hostArrival - g_video_clock_last_update;
    if (elapsed > 0) {
        double allowed = elapsed * VIDEO_CLOCK_SLEW_PER_SEC;
        double delta = target - g_video_clock_offset;
        if (delta > allowed) delta = allowed;
        else if (delta < -allowed) delta = -allowed;
        g_video_clock_offset += delta;
    }
    g_video_clock_last_update = hostArrival;

    /* Budget from the smoothed jitter estimate. A window maximum was pinned at
     * the ceiling by a single bad frame per window and never recovered, which
     * spent the whole allowance on latency without buying smoothness. */
    double wanted = g_video_jitter_mean +
                    VIDEO_JITTER_DEVIATIONS * g_video_jitter_dev;
    double floorBudget = g_video_frame_interval * VIDEO_BUDGET_FLOOR_FRAMES;
    if (wanted < floorBudget) wanted = floorBudget;
    if (wanted > latencySeconds) wanted = latencySeconds;
    if (g_video_budget_seconds <= 0.0) g_video_budget_seconds = wanted;
    else if (elapsed > 0) {
        /* Grow quickly to stop dropping frames, shrink slowly to hold latency
         * down without oscillating. */
        double rate = (wanted > g_video_budget_seconds) ? 0.050 : 0.005;
        double allowed = elapsed * rate;
        double delta = wanted - g_video_budget_seconds;
        if (delta > allowed) delta = allowed;
        else if (delta < -allowed) delta = -allowed;
        g_video_budget_seconds += delta;
    }

    double gridPTS = senderSeconds + g_video_clock_offset + g_video_budget_seconds;

    /* Pace anything that missed its slot instead of dumping it at "now". */
    double interval = g_video_frame_interval;
    if (g_video_last_sender_valid) {
        double senderDelta = senderSeconds - g_video_last_sender;
        if (senderDelta >= VIDEO_FRAME_INTERVAL_MIN &&
            senderDelta <= VIDEO_FRAME_INTERVAL_MAX) {
            interval = senderDelta;
            g_video_frame_interval = senderDelta;
        }
    }
    double floorPTS = hostArrival;
    if (g_video_last_pts_valid) {
        floorPTS = g_video_last_pts + interval * VIDEO_CATCHUP_GAP_FRACTION;
        if (floorPTS < hostArrival) floorPTS = hostArrival;
    }

    bool missed = (gridPTS <= hostArrival);
    double pts = (gridPTS > floorPTS) ? gridPTS : floorPTS;
    if (outLatenessSeconds)
        *outLatenessSeconds = missed ? (hostArrival - gridPTS) : 0.0;

    g_video_last_pts = pts;
    g_video_last_pts_valid = true;
    g_video_last_sender = senderSeconds;
    g_video_last_sender_valid = true;
    if (outMissedSlot) *outMissedSlot = missed;
    return pts;
}

static double video_host_now(void) {
    return CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
}

/* AVSampleBufferDisplayLayer ignores presentationTimeStamp unless a control
 * timebase is attached — without one it paints every buffer as soon as it is
 * enqueued, which is the behaviour we are removing. Running the timebase on the
 * host clock at rate 1.0 makes sample PTS values plain host-time seconds. */
static void video_install_timebase(AVSampleBufferDisplayLayer *layer) {
    if (!layer || layer.controlTimebase) return;
    CMTimebaseRef timebase = NULL;
    OSStatus status = CMTimebaseCreateWithMasterClock(
        kCFAllocatorDefault, CMClockGetHostTimeClock(), &timebase);
    if (status != noErr || !timebase) {
        ip_log("timebase create failed (%d); falling back to immediate display",
               (int)status);
        return;
    }
    CMTimebaseSetTime(timebase, CMClockGetTime(CMClockGetHostTimeClock()));
    CMTimebaseSetRate(timebase, 1.0);
    layer.controlTimebase = timebase;
    CFRelease(timebase);
}

typedef NS_ENUM(uint8_t, CarPlayWLANAttachment) {
    CarPlayWLANAttachmentUnknown = 0,
    CarPlayWLANAttachmentHSIC,
    CarPlayWLANAttachmentPCIe,
};

static const char *carplay_wlan_attachment_name(
    CarPlayWLANAttachment attachment) {
    switch (attachment) {
        case CarPlayWLANAttachmentHSIC: return "HSIC";
        case CarPlayWLANAttachmentPCIe: return "PCIe";
        default: return "unknown";
    }
}

typedef struct {
    uint16_t width;
    uint16_t height;
    uint16_t nativeLong;
    uint16_t nativeShort;
    uint64_t pixelBudget;
    uint64_t physicalMemory;
    NSUInteger activeProcessors;
    uint16_t framesPerSecond;
    CarPlayWLANAttachment wlanAttachment;
} CarPlayDisplayProfile;

static const char *first_existing_tool(const char *const paths[]);

static NSData *capture_process_output(const char *path, char *const argv[]) {
    int pipes[2];
    if (!path || pipe(pipes) != 0) return nil;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], 1);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addclose(&actions, pipes[0]);
    posix_spawn_file_actions_addclose(&actions, pipes[1]);

    pid_t pid = 0;
    int spawnError = posix_spawn(&pid, path, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipes[1]);
    if (spawnError != 0) {
        close(pipes[0]);
        return nil;
    }

    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[8192];
    for (;;) {
        ssize_t count = read(pipes[0], buffer, sizeof(buffer));
        if (count > 0) {
            [output appendBytes:buffer length:(NSUInteger)count];
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    close(pipes[0]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return output;
}

static NSString *wlan_ioreg_snapshot(BOOL fullTree) {
    const char *ioregPaths[] = { "/usr/sbin/ioreg", "/usr/bin/ioreg", NULL };
    const char *ioreg = first_existing_tool(ioregPaths);
    if (!ioreg) return nil;
    char *fullArgv[] = {
        (char *)"ioreg", (char *)"-l", (char *)"-w", (char *)"0", NULL
    };
    char *interfaceArgv[] = {
        (char *)"ioreg", (char *)"-r", (char *)"-c",
        (char *)"IO80211Interface", (char *)"-l", (char *)"-w",
        (char *)"0", NULL
    };
    NSData *data = capture_process_output(
        ioreg, fullTree ? fullArgv : interfaceArgv);
    if (!data.length) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

typedef NS_ENUM(NSInteger, BluetoothRegistryProbeState) {
    BluetoothRegistryProbeUnavailable = -1,
    BluetoothRegistryProbeMissing = 0,
    BluetoothRegistryProbeLegacyUART = 1,
    BluetoothRegistryProbeSkywalk = 2,
};

static BluetoothRegistryProbeState bluetooth_registry_probe(void) {
    @autoreleasepool {
        NSString *tree = wlan_ioreg_snapshot(YES);
        if (!tree.length) return BluetoothRegistryProbeUnavailable;

        BOOL uartService =
            [tree rangeOfString:@"<class AppleSimpleUARTSync"].location !=
                NSNotFound;
        BOOL bluetoothEndpoint =
            [tree rangeOfString:@"\"IOTTYBaseName\" = \"bluetooth\""].location !=
                NSNotFound ||
            [tree rangeOfString:@"\"device_type\" = <\"bluetooth\">"].location !=
                NSNotFound ||
            [tree rangeOfString:@"com.apple.uart.bluetooth"].location !=
                NSNotFound;
        BOOL convergedInterface =
            [tree rangeOfString:@"AppleConvergedIPCRTIInterface"].location !=
                NSNotFound ||
            [tree rangeOfString:@"AppleConvergedIPCInterface"].location !=
                NSNotFound;
        BOOL skywalkTransport =
            [tree rangeOfString:@"\"ACIPCInterfaceTransport\" = \"skywalk\""]
                    .location != NSNotFound;
        BOOL hciProtocol =
            [tree rangeOfString:@"\"ACIPCInterfaceProtocol\" = \"hci\""]
                    .location != NSNotFound;
        BOOL aclProtocol =
            [tree rangeOfString:@"\"ACIPCInterfaceProtocol\" = \"acl\""]
                    .location != NSNotFound;
        BOOL nexusUUID =
            [tree rangeOfString:@"IOSkywalkNexusUUID"].location != NSNotFound;
        if (convergedInterface && skywalkTransport && hciProtocol &&
            aclProtocol && nexusUUID) {
            return BluetoothRegistryProbeSkywalk;
        }
        return uartService && bluetoothEndpoint
            ? BluetoothRegistryProbeLegacyUART
            : BluetoothRegistryProbeMissing;
    }
}

static NSString *hardware_machine_identifier(void) {
    char machine[128] = {0};
    size_t length = sizeof(machine);
    if (sysctlbyname("hw.machine", machine, &length, NULL, 0) == 0 &&
        machine[0]) {
        machine[sizeof(machine) - 1] = '\0';
        return [NSString stringWithUTF8String:machine];
    }
    return @"unknown";
}

static NSString *bounded_log_tail(NSString *path, NSUInteger maxBytes,
                                  NSUInteger maxLines) {
    if (!path.length || maxBytes == 0 || maxLines == 0) return @"";
    @try {
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!handle) return @"";
        unsigned long long end = [handle seekToEndOfFile];
        unsigned long long start = end > maxBytes ? end - maxBytes : 0;
        [handle seekToFileOffset:start];
        NSData *data = [handle readDataToEndOfFile];
        [handle closeFile];
        if (!data.length) return @"";

        NSString *text = [[NSString alloc] initWithData:data
                                               encoding:NSUTF8StringEncoding];
        if (!text) {
            text = [[NSString alloc] initWithData:data
                                         encoding:NSISOLatin1StringEncoding];
        }
        if (!text.length) return @"";
        NSArray<NSString *> *lines =
            [text componentsSeparatedByCharactersInSet:
                [NSCharacterSet newlineCharacterSet]];
        NSUInteger first = lines.count > maxLines ? lines.count - maxLines : 0;
        NSArray<NSString *> *tail =
            [lines subarrayWithRange:NSMakeRange(first, lines.count - first)];
        return [tail componentsJoinedByString:@"\n"];
    } @catch (__unused NSException *exception) {
        return @"";
    }
}

static NSString *bluetooth_failure_class(NSString *reason,
                                          NSString *combinedLogs,
                                          BluetoothRegistryProbeState registry) {
    NSString *lower = [[NSString stringWithFormat:@"%@\n%@",
                        reason ?: @"", combinedLogs ?: @""] lowercaseString];
    NSString *reasonLower = [reason.lowercaseString copy] ?: @"";
    if ([reasonLower containsString:@"btstack daemon is missing"])
        return @"btstack-daemon-missing";
    if ([reasonLower containsString:@"btstack library is missing"])
        return @"btstack-library-missing";
    if ([reasonLower containsString:@"launch daemon configuration is missing"])
        return @"btstack-launch-configuration-missing";
    if (registry == BluetoothRegistryProbeMissing)
        return @"supported-bluetooth-transport-not-present";
    if ([lower containsString:@"skywalk is present"] &&
        [lower containsString:@"userspace api is unavailable"])
        return @"converged-skywalk-api-unavailable";
    if ([lower containsString:@"skywalk:"] &&
        [lower containsString:@"channel create failed"])
        return @"converged-skywalk-channel-open-failed";
    if ([lower containsString:@"h4_open: ioctl failed"])
        return @"private-uart-endpoint-unavailable";
    if ([lower containsString:@"h4_open: socket failed"])
        return @"netgraph-control-socket-unavailable";
    if ([lower containsString:@"h4_open: connect failed"])
        return @"bluetooth-uart-connect-failed";
    if ([lower containsString:@"h4_open: getsockopt failed"] ||
        [lower containsString:@"h4_open: setsockopt failed"])
        return @"bluetooth-uart-configuration-failed";
    if ([lower containsString:@"btstack_event_poweron_failed"] ||
        [lower containsString:@"poweron_failed"])
        return @"controller-power-on-failed";
    if ([lower containsString:@"ioregisterforsystempower failed"])
        return @"bluetooth-power-registration-failed";
    if ([lower containsString:@"socket not available"])
        return @"btstack-daemon-socket-unavailable";
    if ([lower containsString:@"launch daemon failed"])
        return @"btstack-launch-failed";
    if ([lower containsString:@"ready sentinel"])
        return @"no-hci-events-before-timeout";
    return @"bluetooth-takeover-failed";
}

static NSString *bluetooth_diagnostic_report(
    NSString *reason, BOOL retryAttempted,
    BluetoothRegistryProbeState registry) {
    NSString *initial = bounded_log_tail(
        @LOG_DIR "/carplay_bt.log", 8192, 18);
    NSString *retry = retryAttempted
        ? bounded_log_tail(@LOG_DIR "/carplay_bt-retry.log", 8192, 18)
        : @"";
    NSString *daemon = bounded_log_tail(@SHOWCASE_BTSTACK_LOG_PATH, 8192, 18);
    NSString *combined = [NSString stringWithFormat:@"%@\n%@\n%@",
                          initial ?: @"", retry ?: @"", daemon ?: @""];
    NSString *failureClass =
        bluetooth_failure_class(reason, combined, registry);
    NSString *registryText = registry == BluetoothRegistryProbeLegacyUART
        ? @"legacy-uart-present"
        : (registry == BluetoothRegistryProbeSkywalk
            ? @"converged-skywalk-present"
            : (registry == BluetoothRegistryProbeMissing
                ? @"supported-transport-missing" : @"unavailable"));
#ifdef SHOWCASE_ROOTLESS
    NSString *layout = @"rootless";
#else
    NSString *layout = @"rootful";
#endif

    NSMutableString *report = [NSMutableString string];
    [report appendString:@"Showcase Bluetooth compatibility report\n"];
    [report appendFormat:@"version=%s\n", APP_VERSION];
    [report appendFormat:@"device=%@\n", hardware_machine_identifier()];
    [report appendFormat:@"ios=%@\n", [UIDevice currentDevice].systemVersion];
    [report appendFormat:@"layout=%@ (diagnostic only)\n", layout];
    [report appendFormat:@"failure_class=%@\n", failureClass];
    [report appendFormat:@"stage=%@\n", reason ?: @"unknown"];
    [report appendFormat:@"euid=%u\n", geteuid()];
    [report appendFormat:@"registry=%@\n", registryText];
    [report appendFormat:@"helper=%s executable=%s\n", BT_HELPER_NAME,
        access([[[[NSBundle mainBundle] bundlePath]
            stringByAppendingPathComponent:@BT_HELPER_NAME] UTF8String],
            X_OK) == 0 ? "yes" : "no"];
    [report appendFormat:@"btdaemon=%s executable=%s\n", BTDAEMON_PATH,
        access(BTDAEMON_PATH, X_OK) == 0 ? "yes" : "no"];
    [report appendFormat:@"libbtstack=%s readable=%s\n", BTSTACK_DYLIB_PATH,
        access(BTSTACK_DYLIB_PATH, R_OK) == 0 ? "yes" : "no"];
    [report appendFormat:@"launch_plist=%s readable=%s\n", BTSTACK_PLIST,
        access(BTSTACK_PLIST, R_OK) == 0 ? "yes" : "no"];
    [report appendFormat:@"retry=%@\n", retryAttempted ? @"yes" : @"no"];
    if (initial.length)
        [report appendFormat:@"\ncarplay_bt tail:\n%@\n", initial];
    if (retry.length)
        [report appendFormat:@"\ncarplay_bt retry tail:\n%@\n", retry];
    if (daemon.length)
        [report appendFormat:@"\nBTstack daemon tail:\n%@\n", daemon];
    return report;
}

static CarPlayWLANAttachment wlan_attachment_class(void) {
    @autoreleasepool {
        NSString *tree = wlan_ioreg_snapshot(YES);
        if (!tree.length) return CarPlayWLANAttachmentUnknown;

        /*
         * Match instantiated transport services and device-tree compatibility
         * strings. Do not use the IOKitDiagnostics class table: a driver class
         * may be present with zero live instances on unrelated hardware.
         */
        NSArray<NSString *> *hsicMarkers = @[
            @"<class AppleBCMWLANBusInterfaceHSIC",
            @"<class AppleBCMWLANChipManagerHSIC",
            @"AppleBCMWLANBusInterfaceHSICShim",
            @"wlan-hsic"
        ];
        for (NSString *marker in hsicMarkers) {
            if ([tree rangeOfString:marker].location != NSNotFound)
                return CarPlayWLANAttachmentHSIC;
        }

        NSArray<NSString *> *pcieMarkers = @[
            @"<class AppleBCMWLANBusInterfacePCIe",
            @"<class AppleBCMWLANPCIe",
            @"wlan-pcie"
        ];
        for (NSString *marker in pcieMarkers) {
            if ([tree rangeOfString:marker].location != NSNotFound)
                return CarPlayWLANAttachmentPCIe;
        }
        return CarPlayWLANAttachmentUnknown;
    }
}

static CarPlayDisplayProfile preferred_carplay_display_profile(void) {
    UIScreen *screen = [UIScreen mainScreen];
    CGSize nativeSize = [screen respondsToSelector:@selector(nativeBounds)]
        ? screen.nativeBounds.size
        : CGSizeMake(screen.bounds.size.width * screen.scale,
                     screen.bounds.size.height * screen.scale);
    double nativeLong = MAX(nativeSize.width, nativeSize.height);
    double nativeShort = MIN(nativeSize.width, nativeSize.height);
    double aspect = nativeShort > 0 ? nativeLong / nativeShort : (5.0 / 3.0);

    NSProcessInfo *process = [NSProcessInfo processInfo];
    uint64_t memory = process.physicalMemory;
    NSUInteger processors = process.activeProcessorCount;
    NSInteger screenFPS = [screen respondsToSelector:
        @selector(maximumFramesPerSecond)] ? screen.maximumFramesPerSecond : 60;
    NSInteger requestedFPS = [[NSUserDefaults standardUserDefaults] integerForKey:@"iPlayFrameRate"];
    if (requestedFPS < 30 || requestedFPS > 60)
        requestedFPS = 60;
    requestedFPS = 30 + (NSInteger)llround((requestedFPS - 30) / 5.0) * 5;
    uint16_t framesPerSecond =
        (uint16_t)MAX(30, MIN(requestedFPS, MIN(60, screenFPS)));
    CarPlayWLANAttachment wlanAttachment = wlan_attachment_class();
    if (wlanAttachment == CarPlayWLANAttachmentHSIC)
        framesPerSecond = MIN(framesPerSecond, 30);

    /* Size the stream from runtime hardware capability, never jailbreak
     * layout. One-gigabyte devices share memory bandwidth between UIKit,
     * VideoToolbox, the CarPlay service, and the hotspot; a 960x720-class
     * budget limits the shared memory and wireless working set.
     * Two-gigabyte devices and above retain a 720p-class floor. */
    uint64_t pixelBudget = 960ULL * 720ULL;
    if (memory >= 1536ULL * 1024ULL * 1024ULL)
        pixelBudget = 1280ULL * 720ULL;
    if (memory >= 3ULL * 1024ULL * 1024ULL * 1024ULL && processors >= 4)
        pixelBudget = 1600ULL * 900ULL;
    if (memory >= 4ULL * 1024ULL * 1024ULL * 1024ULL && processors >= 6)
        pixelBudget = 1920ULL * 1080ULL;
    NSInteger scaleTenths = [[NSUserDefaults standardUserDefaults] integerForKey:@"iPlayDisplayScaleTenths"];
    if (scaleTenths < 3 || scaleTenths > 10) scaleTenths = 10;
    if (scaleTenths != 10) {
        double scale = scaleTenths / 10.0;
        pixelBudget = (uint64_t)((double)pixelBudget * scale * scale);
    }
    uint64_t nativePixels = (uint64_t)nativeLong * (uint64_t)nativeShort;
    if (nativePixels > 0 && pixelBudget > nativePixels)
        pixelBudget = nativePixels;

    /* Search codec-friendly 16-pixel dimensions. The score rewards using
     * the available decode budget but penalizes aspect error heavily, so the
     * selected stream fills the physical display without stretching. */
    uint16_t bestWidth = 800;
    uint16_t bestHeight = 480;
    double bestScore = -DBL_MAX;
    uint16_t maxWidth = (uint16_t)(floor(MIN(nativeLong, 1920.0) / 16.0) * 16.0);
    for (uint16_t candidateWidth = 640;
         candidateWidth <= maxWidth;
         candidateWidth = (uint16_t)(candidateWidth + 16)) {
        uint16_t candidateHeight = (uint16_t)(
            floor(((candidateWidth / aspect) / 16.0) + 0.5) * 16.0);
        if (candidateHeight < 360 || candidateHeight > nativeShort) continue;
        uint64_t pixels = (uint64_t)candidateWidth * candidateHeight;
        if (pixels > pixelBudget) continue;
        double candidateAspect =
            (double)candidateWidth / (double)candidateHeight;
        double aspectError = fabs(candidateAspect - aspect) / aspect;
        double budgetUse = pixelBudget > 0
            ? (double)pixels / (double)pixelBudget : 0;
        double score = budgetUse - (aspectError * 10.0);
        if (score > bestScore) {
            bestScore = score;
            bestWidth = candidateWidth;
            bestHeight = candidateHeight;
        }
    }

    CarPlayDisplayProfile profile = {
        .width = bestWidth,
        .height = bestHeight,
        .nativeLong = (uint16_t)nativeLong,
        .nativeShort = (uint16_t)nativeShort,
        .pixelBudget = pixelBudget,
        .physicalMemory = memory,
        .activeProcessors = processors,
        .framesPerSecond = framesPerSecond,
        .wlanAttachment = wlanAttachment,
    };
    return profile;
}

/* ═══════════════════════════════════════════════════════════════
 * Touch IPC
 * ═══════════════════════════════════════════════════════════════ */

static dispatch_queue_t touch_write_queue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_touch_write_queue = dispatch_queue_create(
            "com.rostane.showcase.touch-writer", DISPATCH_QUEUE_SERIAL);
    });
    return g_touch_write_queue;
}

static void send_ipc_payload(uint8_t type, const void *payload,
                             uint32_t payloadLength) {
    int fd = g_touch_fd;
    uint32_t epoch = g_touch_epoch;
    if (fd < 0) return;

    NSMutableData *message =
        [NSMutableData dataWithLength:(NSUInteger)payloadLength + 5];
    uint8_t *bytes = message.mutableBytes;
    bytes[0] = payloadLength & 0xff;
    bytes[1] = (payloadLength >> 8) & 0xff;
    bytes[2] = (payloadLength >> 16) & 0xff;
    bytes[3] = (payloadLength >> 24) & 0xff;
    bytes[4] = type;
    if (payloadLength) memcpy(bytes + 5, payload, payloadLength);

    dispatch_async(touch_write_queue(), ^{
        if (g_touch_fd != fd || g_touch_epoch != epoch) return;
        const uint8_t *cursor = message.bytes;
        size_t remaining = message.length;
        while (remaining > 0) {
            ssize_t written = write(fd, cursor, remaining);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                ip_log("IPC write failed type=0x%02x: %s",
                       type, strerror(errno));
                return;
            }
            cursor += written;
            remaining -= (size_t)written;
        }
    });
}

/* Each record keeps the UIKit sample time even though the current single
 * touch HID report has no timestamp field. Keeping it in IPC makes ordering
 * measurable and leaves the transport ready for a richer HID descriptor.
 * [phase][contact][x LE16][y LE16][timestampNs LE64] */
static void send_touch_records(NSData *records) {
    if (records.length == 0 || records.length > UINT32_MAX) return;
    send_ipc_payload(MSG_TOUCH, records.bytes, (uint32_t)records.length);
}

static void send_app_visibility(uint8_t visible) {
    uint8_t payload = visible ? 1 : 0;
    send_ipc_payload(MSG_APP_VISIBILITY, &payload, sizeof(payload));
}

static void send_video_resync_request(void) {
    uint8_t payload = 1;
    send_ipc_payload(MSG_VIDEO_RESYNC, &payload, sizeof(payload));
}

/* ═══════════════════════════════════════════════════════════════
 * AP detection
 * ═══════════════════════════════════════════════════════════════ */

static BOOL is_ap_up(void) {
    struct ifaddrs *ifa = NULL, *cur;
    if (getifaddrs(&ifa) != 0) return NO;
    BOOL up = NO;
    for (cur = ifa; cur != NULL; cur = cur->ifa_next) {
        if (cur->ifa_name && strcmp(cur->ifa_name, AP_INTERFACE) == 0
            && (cur->ifa_flags & IFF_UP)) { up = YES; break; }
    }
    freeifaddrs(ifa);
    return up;
}

/* ═══════════════════════════════════════════════════════════════
 * AWDL suppression during an active session
 *
 * AWDL is the radio Apple uses for AirDrop, Handoff and Continuity. It shares
 * the single Wi-Fi radio with the Personal Hotspot that carries CarPlay, and it
 * periodically pulls that radio onto its own social channels — 6 in the 2.4 GHz
 * band, which is where this receiver's low-latency interface was observed
 * sitting. While the radio is away, nothing is received, and the screen stream
 * arrives as a late burst afterwards. The published symptom of AWDL contention
 * is 50-200 ms stalls, which matches the residual lateness spikes measured here.
 *
 * This touches no part of pairing, iAP2, BAA or the RTSP negotiation. It is
 * applied only once a session is fully established and streaming, and undone
 * when the session ends, so the protocol phase is never affected. Bringing the
 * interface down costs AirDrop and Handoff for the duration — an acceptable
 * trade on a device dedicated to being a head unit.
 * ═══════════════════════════════════════════════════════════════ */

/* llw0 does not exist before iOS 13 — verified absent on the iOS 12 receiver
 * and present on the iOS 15 one — so every entry is probed, never assumed. */
static const char *const kAWDLInterfaces[] = { "awdl0", "llw0" };
#define AWDL_INTERFACE_COUNT (sizeof(kAWDLInterfaces) / sizeof(kAWDLInterfaces[0]))
#define AWDL_REASSERT_SECONDS  10.0

/* Only interfaces this code actually took down are brought back, so a receiver
 * where the user had already disabled AirDrop is left as it was found. */
static BOOL g_awdl_was_up[AWDL_INTERFACE_COUNT];

static BOOL interface_exists(const char *name) {
    return if_nametoindex(name) != 0;
}

/* Returns YES when the interface ended up in the requested state. */
static BOOL set_interface_up(const char *name, BOOL up) {
    if (!name || !interface_exists(name)) return NO;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return NO;

    struct ifreq request;
    memset(&request, 0, sizeof(request));
    strncpy(request.ifr_name, name, IFNAMSIZ - 1);

    BOOL ok = NO;
    if (ioctl(fd, SIOCGIFFLAGS, &request) == 0) {
        short current = request.ifr_flags;
        short wanted = up ? (current | IFF_UP) : (current & (short)~IFF_UP);
        if (wanted == current) {
            ok = YES;
        } else {
            request.ifr_flags = wanted;
            ok = (ioctl(fd, SIOCSIFFLAGS, &request) == 0);
            if (!ok)
                ip_log("AWDL: %s %s failed: %s", name,
                       up ? "up" : "down", strerror(errno));
        }
    }
    close(fd);
    return ok;
}

static BOOL interface_is_up(const char *name) {
    if (!name || !interface_exists(name)) return NO;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return NO;
    struct ifreq request;
    memset(&request, 0, sizeof(request));
    strncpy(request.ifr_name, name, IFNAMSIZ - 1);
    BOOL up = NO;
    if (ioctl(fd, SIOCGIFFLAGS, &request) == 0)
        up = (request.ifr_flags & IFF_UP) != 0;
    close(fd);
    return up;
}

/* iOS brings AWDL back on its own whenever a Continuity service wants it, so
 * the suppression is re-asserted on a slow timer rather than set once. */
static volatile int32_t g_awdl_suppressed = 0;

static void awdl_suppress(BOOL logEachInterface) {
    for (size_t i = 0; i < AWDL_INTERFACE_COUNT; i++) {
        const char *name = kAWDLInterfaces[i];
        if (!interface_exists(name)) { g_awdl_was_up[i] = NO; continue; }
        if (!interface_is_up(name)) continue;   /* already down; leave it */
        g_awdl_was_up[i] = YES;
        if (set_interface_up(name, NO) && logEachInterface)
            ip_log("AWDL: %s -> down", name);
    }
}

static void awdl_restore(BOOL logEachInterface) {
    for (size_t i = 0; i < AWDL_INTERFACE_COUNT; i++) {
        if (!g_awdl_was_up[i]) continue;
        const char *name = kAWDLInterfaces[i];
        g_awdl_was_up[i] = NO;
        if (!interface_exists(name) || interface_is_up(name)) continue;
        if (set_interface_up(name, YES) && logEachInterface)
            ip_log("AWDL: %s -> up", name);
    }
}

static const char *first_existing_tool(const char *const paths[]) {
    for (int i = 0; paths[i]; i++) {
        if (access(paths[i], X_OK) == 0) return paths[i];
    }
    return NULL;
}

static const char *tcpdump_tool_path(void) {
    const char *paths[] = {
        "/var/jb/usr/sbin/tcpdump",
        "/var/jb/usr/bin/tcpdump",
        "/usr/sbin/tcpdump",
        "/usr/bin/tcpdump",
        NULL
    };
    return first_existing_tool(paths);
}

static void enable_btstack_hci_logging(void) {
    mkdir("/var/mobile/Library", 0755);
    mkdir(BTSTACK_PREFS_DIR, 0755);
    const char *plist =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
        "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        "<plist version=\"1.0\">\n"
        "<dict>\n"
        "    <key>Logging</key>\n"
        "    <true/>\n"
        "</dict>\n"
        "</plist>\n";
    int fd = open(BTSTACK_PREFS, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        ip_log("BTstack logging prefs write failed: %s", strerror(errno));
        return;
    }
    ssize_t want = (ssize_t)strlen(plist);
    ssize_t wrote = write(fd, plist, (size_t)want);
    close(fd);
    chmod(BTSTACK_PREFS, 0644);
    ip_log("BTstack HCI logging %s at %s",
           wrote == want ? "enabled" : "partially written", BTSTACK_PREFS);
}

static void disable_btstack_hci_logging(void) {
    unlink(BTSTACK_PREFS);
    ip_log("BTstack HCI logging disabled");
}

/* ═══════════════════════════════════════════════════════════════
 * Process spawn helpers
 * ═══════════════════════════════════════════════════════════════ */

static int run_blocking(const char *path, char *const argv[]) {
    pid_t pid;
    int status;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);

    NSMutableString *cmdline = [NSMutableString stringWithUTF8String:path];
    for (int i = 1; argv[i] != NULL; i++) {
        BOOL redacted = (i > 1 &&
            (!strcmp(argv[i - 1], "--pass") || !strcmp(argv[i - 1], "-p")));
        [cmdline appendFormat:@" %s", redacted ? "******" : argv[i]];
    }
    ip_log("run_blocking: %s (uid=%u euid=%u)", [cmdline UTF8String], getuid(), geteuid());

    int err = posix_spawn(&pid, path, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (err != 0) { ip_log("  posix_spawn FAIL: %s", strerror(err)); return -1; }
    if (waitpid(pid, &status, 0) < 0) { ip_log("  waitpid FAIL: %s", strerror(errno)); return -1; }
    int rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    ip_log("  exit=%d", rc);
    return rc;
}

static int run_capture(const char *path, char *const argv[], const char *outfile) {
    if (!path || access(path, X_OK) != 0) return -1;
    pid_t pid;
    int status;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, outfile, O_WRONLY|O_CREAT|O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&actions, 1, 2);
    int err = posix_spawn(&pid, path, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (err != 0) return -1;
    if (waitpid(pid, &status, 0) < 0) return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static pid_t spawn_daemon(const char *path, char *const argv[], const char *logfile) {
    mkdir("/var/mobile/Library/Showcase", 0755);
    mkdir(LOG_DIR, 0755);

    if (access(path, X_OK) != 0) {
        ip_log("spawn_daemon: %s NOT EXECUTABLE (%s)", path, strerror(errno));
        return 0;
    }

    NSMutableString *cmdline = [NSMutableString stringWithUTF8String:path];
    for (int i = 1; argv[i] != NULL; i++) [cmdline appendFormat:@" %s", argv[i]];
    ip_log("spawn_daemon: %s", [cmdline UTF8String]);

    pid_t pid = 0;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, logfile, O_WRONLY|O_CREAT|O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&actions, 1, 2);
    int err = posix_spawn(&pid, path, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (err != 0) {
        ip_log("  posix_spawn FAIL: %s", strerror(err));
        return 0;
    }
    ip_log("  pid=%d log=%s", pid, logfile);

    usleep(200000);
    if (kill(pid, 0) != 0) {
        ip_log("  CHILD ALREADY DEAD — check %s", logfile);
    } else {
        ip_log("  child still alive ✓");
    }
    return pid;
}

static BOOL pid_alive(pid_t pid) { return pid > 0 && kill(pid, 0) == 0; }

static BOOL wait_for_bt_ready_or_exit(pid_t pid, int seconds) {
    int loops = seconds * 10;
    for (int i = 0; i < loops; i++) {
        if (access(BT_READY_PATH, F_OK) == 0) {
            ip_log("[BT] ready sentinel observed at %s", BT_READY_PATH);
            return YES;
        }

        int status = 0;
        pid_t done = waitpid(pid, &status, WNOHANG);
        if (done == pid) {
            if (WIFEXITED(status) && WEXITSTATUS(status) == 62) {
                ip_log("[BT] helper exited with BTSTACK_EVENT_POWERON_FAILED (62)");
            } else if (WIFEXITED(status)) {
                ip_log("[BT] helper exited before ready sentinel exit=%d", WEXITSTATUS(status));
            } else if (WIFSIGNALED(status)) {
                ip_log("[BT] helper exited before ready sentinel signal=%d", WTERMSIG(status));
            } else {
                ip_log("[BT] helper exited before ready sentinel status=0x%x", status);
            }
            return NO;
        }
        if (done < 0 && errno != EINTR) {
            if (errno == ECHILD && !pid_alive(pid)) {
                ip_log("[BT] helper vanished before ready sentinel");
                return NO;
            }
            ip_log("[BT] waitpid while waiting for ready sentinel failed: %s", strerror(errno));
        }
        usleep(100000);
    }

    ip_log("[BT] ready sentinel timeout after %d seconds path=%s", seconds, BT_READY_PATH);
    return NO;
}

static BOOL wait_for_pid_alive(pid_t pid, int seconds, const char *name) {
    for (int i = 0; i < seconds; i++) {
        if (!pid_alive(pid)) {
            ip_log("%s exited during startup wait at %d/%d sec", name, i, seconds);
            return NO;
        }
        sleep(1);
    }
    return YES;
}

static BOOL wait_for_path(const char *path, int seconds, const char *name) {
    for (int i = 0; i < seconds * 10; i++) {
        if (access(path, F_OK) == 0) {
            ip_log("%s ready at %s", name, path);
            return YES;
        }
        usleep(100000);
    }
    ip_log("%s not ready at %s after %d sec", name, path, seconds);
    return NO;
}

static void kill_pid(pid_t pid) {
    if (!pid_alive(pid)) return;
    kill(pid, SIGTERM);
    for (int i = 0; i < 20; i++) {
        usleep(100000);
        if (!pid_alive(pid)) return;
    }
    kill(pid, SIGKILL);
    int status; waitpid(pid, &status, WNOHANG);
}

static void signal_processes_named(const char *name, int sig, pid_t preservedPid) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return;

    struct kinfo_proc *procs = malloc(len);
    if (!procs) return;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) {
        free(procs);
        return;
    }

    pid_t self = getpid();
    int count = (int)(len / sizeof(struct kinfo_proc));
    for (int i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        const char *comm = procs[i].kp_proc.p_comm;
        if (pid <= 0 || pid == self || pid == preservedPid) continue;
        if (strcmp(comm, name) != 0) continue;
        ip_log("reap stale helper: kill -%d %s pid=%d", sig, name, pid);
        kill(pid, sig);
    }
    free(procs);
}

static void reap_stale_helpers(pid_t preservedPid) {
    const char *names[] = {
        "carplay_services",
        "carplay_bt",
        "CarDisplaySim",
        "CarPlay Simulator",
        "CarPlay Simulato",
        "BTdaemon"
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        signal_processes_named(names[i], SIGTERM, preservedPid);
    usleep(700000);
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
        signal_processes_named(names[i], SIGKILL, preservedPid);
    if (preservedPid <= 0)
        unlink(BAA_BROKER_PATH);
    unlink(SOCK_PATH);
#ifdef SHOWCASE_ROOTLESS
    unlink(BTSTACK_SOCKET);
#endif
}

/* ═══════════════════════════════════════════════════════════════
 * Data model + persistence
 *
 *   Car        = { name }                — display label CarPlay advertises
 *   APCreds    = { ssid, password }       — global, set once, used by all cars
 *
 * NSUserDefaults schema:
 *   "cars"            => NSArray of NSDictionary { name }
 *   "selectedCarName" => NSString
 *   "apSSID"          => NSString          (the iPad's hotspot SSID)
 *   "apPassword"      => NSString          (the iPad's hotspot password)
 *
 * On first run we seed one car ("Miata"). AP creds start empty;
 * the user must set them before Start CarPlay enables.
 *
 * Migration: if loaded cars carry legacy ssid/password fields and
 * apSSID is empty, promote the first non-empty pair to global creds.
 * ═══════════════════════════════════════════════════════════════ */

@interface Car : NSObject
@property (nonatomic, copy) NSString *name;
- (NSDictionary *)toDict;
+ (Car *)fromDict:(NSDictionary *)d;
@end

@implementation Car
- (NSDictionary *)toDict { return @{ @"name": self.name ?: @"" }; }
+ (Car *)fromDict:(NSDictionary *)d {
    Car *c = [[Car alloc] init];
    c.name = d[@"name"] ?: @"";
    return c;
}
@end

/* ─── Validation ───────────────────────────────────────────────
 * iOS 26 rejects auto-joining hotspots whose SSID:
 *  - is shorter than ~6 chars (default iPad name "iPad" doesn't work)
 *  - contains an Apple device name substring (iPad/iPhone/iPod/Mac)
 *
 * Returns nil if valid, otherwise human-readable error message.
 * ────────────────────────────────────────────────────────────── */
static NSString *validateSSID(NSString *ssid) {
    if (ssid.length == 0) return @"Wi-Fi network is required.";
    if (ssid.length < 6) {
        return @"Wi-Fi name must be at least 6 characters. iOS rejects shorter names for CarPlay.";
    }
    NSString *lower = [ssid lowercaseString];
    NSArray *forbidden = @[@"ipad", @"iphone", @"ipod"];
    for (NSString *bad in forbidden) {
        if ([lower rangeOfString:bad].location != NSNotFound) {
            return [NSString stringWithFormat:
                @"Wi-Fi name cannot contain \"%@\". Rename your iPad in Settings › General › About › Name.",
                bad];
        }
    }
    return nil;
}

@interface CarStore : NSObject
@property (nonatomic, strong) NSMutableArray<Car *> *cars;
@property (nonatomic, strong) Car *selected;
@property (nonatomic, copy)   NSString *apSSID;
@property (nonatomic, copy)   NSString *apPassword;
- (void)load;
- (void)save;
- (void)addCar:(Car *)car;
- (void)deleteCarAtIndex:(NSInteger)idx;
- (void)selectCar:(Car *)car;
- (BOOL)apReady;
- (void)setAPSSID:(NSString *)ssid password:(NSString *)pw;
@end

@implementation CarStore
- (instancetype)init {
    if ((self = [super init])) [self load];
    return self;
}
- (BOOL)apReady {
    return self.apSSID.length > 0 && self.apPassword.length > 0
        && validateSSID(self.apSSID) == nil;
}
- (void)load {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *raw = [d arrayForKey:@"cars"];
    self.cars = [NSMutableArray array];
    NSString *legacySSID = nil, *legacyPass = nil;
    for (NSDictionary *dict in raw) {
        Car *c = [Car fromDict:dict];
        [self.cars addObject:c];
        /* Migration: capture first non-empty embedded creds */
        if (!legacySSID) {
            NSString *s = dict[@"ssid"], *p = dict[@"password"];
            if (s.length > 0 && p.length > 0) { legacySSID = s; legacyPass = p; }
        }
    }
    if (self.cars.count == 0) {
        Car *miata = [[Car alloc] init];
        miata.name = @"Miata";
        [self.cars addObject:miata];
    }

    self.apSSID     = [d stringForKey:@"apSSID"]     ?: @"";
    self.apPassword = [d stringForKey:@"apPassword"] ?: @"";
    /* Promote legacy creds if global is empty */
    if (self.apSSID.length == 0 && legacySSID.length > 0) {
        self.apSSID = legacySSID;
        self.apPassword = legacyPass;
        ip_log("migrated legacy AP creds from car embedded fields");
    }

    NSString *selName = [d stringForKey:@"selectedCarName"];
    self.selected = nil;
    for (Car *c in self.cars) {
        if ([c.name isEqualToString:selName]) { self.selected = c; break; }
    }
    if (!self.selected) self.selected = self.cars.firstObject;

    [self save]; /* persist any migration */
}
- (void)save {
    NSMutableArray *raw = [NSMutableArray array];
    for (Car *c in self.cars) [raw addObject:[c toDict]];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:raw forKey:@"cars"];
    [d setObject:(self.selected.name ?: @"") forKey:@"selectedCarName"];
    [d setObject:(self.apSSID ?: @"")        forKey:@"apSSID"];
    [d setObject:(self.apPassword ?: @"")    forKey:@"apPassword"];
    [d synchronize];
}
- (void)addCar:(Car *)car {
    [self.cars addObject:car];
    if (!self.selected) self.selected = car;
    [self save];
}
- (void)deleteCarAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.cars.count) return;
    Car *c = self.cars[idx];
    [self.cars removeObjectAtIndex:idx];
    if (self.selected == c) self.selected = self.cars.firstObject;
    [self save];
}
- (void)selectCar:(Car *)car { self.selected = car; [self save]; }
- (void)setAPSSID:(NSString *)ssid password:(NSString *)pw {
    self.apSSID = ssid ?: @"";
    self.apPassword = pw ?: @"";
    [self save];
}
@end

/* ═══════════════════════════════════════════════════════════════
 * VideoView — UIView backed by AVSampleBufferDisplayLayer
 * ═══════════════════════════════════════════════════════════════ */

@interface VideoView : UIView
@end

@implementation VideoView
+ (Class)layerClass { return [AVSampleBufferDisplayLayer class]; }
@end

/* ═══════════════════════════════════════════════════════════════
 * CarPlayAudioPlayer — one Audio Queue per negotiated CarPlay stream
 *
 * Wireless CarPlay supplies codec packets rather than an audio file.
 * Audio Queue accepts AAC/AAC-ELD/Opus packets directly and uses the system
 * codec, avoiding an extra PCM copy and keeping decoding off the IPC path.
 * ═══════════════════════════════════════════════════════════════ */

@interface CarPlayAudioPlayer : NSObject {
    AudioQueueRef _audioQueue;
    AudioConverterRef _audioConverter;
    uint32_t _streamType;
    uint64_t _formatMask;
    uint32_t _framesPerPacket;
    uint32_t _latencyMs;
    Float64 _sampleRate;
    UInt32 _channels;
    UInt32 _decodedBytesPerFrame;
    uint64_t _decodedPackets;
    NSUInteger _queuedPackets;
    NSUInteger _requiredStartPackets;
    volatile int32_t _outstandingBuffers;
    uint64_t _queueDrainCount;
    BOOL _started;
    BOOL _paused;
    BOOL _isPCM;
    BOOL _decodeAACToPCM;
    BOOL _haveSequence;
    uint16_t _lastSequence;
    uint64_t _lastRenderReportNanos;
}
- (instancetype)initWithStreamType:(uint32_t)streamType;
- (BOOL)configureFormat:(uint64_t)formatMask
        framesPerPacket:(uint32_t)framesPerPacket
               latency:(uint32_t)latencyMs;
- (void)enqueuePacket:(const uint8_t *)bytes
               length:(uint32_t)length
             sequence:(uint16_t)sequence;
- (void)completedBuffer:(AudioQueueBufferRef)buffer
               forQueue:(AudioQueueRef)queue;
- (void)reportPlaybackTimeForQueue:(AudioQueueRef)queue;
- (void)setPlaybackPaused:(BOOL)paused;
- (void)flushBufferedAudio;
- (void)stop;
@end

static void carplay_audio_queue_callback(void *userData, AudioQueueRef queue,
                                         AudioQueueBufferRef buffer) {
    CarPlayAudioPlayer *player =
        (__bridge CarPlayAudioPlayer *)userData;
    [player completedBuffer:buffer forQueue:queue];
}

typedef struct {
    const uint8_t *bytes;
    UInt32 length;
    UInt32 channels;
    BOOL consumed;
    AudioStreamPacketDescription packet;
} CarPlayAACInputContext;

static OSStatus carplay_aac_input_callback(
    AudioConverterRef converter,
    UInt32 *ioNumberDataPackets,
    AudioBufferList *ioData,
    AudioStreamPacketDescription **outPacketDescription,
    void *userData) {
    (void)converter;
    CarPlayAACInputContext *input =
        (CarPlayAACInputContext *)userData;
    if (!input || input->consumed || !input->bytes || input->length == 0) {
        *ioNumberDataPackets = 0;
        return noErr;
    }

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = input->channels;
    ioData->mBuffers[0].mDataByteSize = input->length;
    ioData->mBuffers[0].mData = (void *)input->bytes;
    input->packet.mStartOffset = 0;
    input->packet.mVariableFramesInPacket = 0;
    input->packet.mDataByteSize = input->length;
    if (outPacketDescription)
        *outPacketDescription = &input->packet;
    *ioNumberDataPackets = 1;
    input->consumed = YES;
    return noErr;
}

@implementation CarPlayAudioPlayer

- (instancetype)initWithStreamType:(uint32_t)streamType {
    if ((self = [super init])) _streamType = streamType;
    return self;
}

- (BOOL)configureFormat:(uint64_t)formatMask
        framesPerPacket:(uint32_t)framesPerPacket
               latency:(uint32_t)latencyMs {
    [self stop];

    Float64 sampleRate = 0;
    UInt32 channels = 0;
    AudioFormatID formatID = 0;
    uint32_t defaultFrames = 0;
    BOOL isPCM = NO;
    switch (formatMask) {
        case 0x00000004ULL: /* PCM 8 kHz, 16-bit mono */
            sampleRate = 8000; channels = 1;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00000010ULL: /* PCM 16 kHz, 16-bit mono */
            sampleRate = 16000; channels = 1;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00000040ULL: /* PCM 24 kHz, 16-bit mono */
            sampleRate = 24000; channels = 1;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00000800ULL: /* PCM 44.1 kHz, 16-bit stereo */
            sampleRate = 44100; channels = 2;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00008000ULL: /* PCM 48 kHz, 16-bit stereo */
            sampleRate = 48000; channels = 2;
            formatID = kAudioFormatLinearPCM; defaultFrames = 1;
            isPCM = YES; break;
        case 0x00400000ULL: /* AAC-LC 44.1 kHz stereo */
            sampleRate = 44100; channels = 2;
            formatID = kAudioFormatMPEG4AAC; defaultFrames = 1024; break;
        case 0x00800000ULL: /* AAC-LC 48 kHz stereo */
            sampleRate = 48000; channels = 2;
            formatID = kAudioFormatMPEG4AAC; defaultFrames = 1024; break;
        case 0x01000000ULL: /* AAC-ELD 44.1 kHz stereo */
            sampleRate = 44100; channels = 2;
            formatID = kAudioFormatMPEG4AAC_ELD; defaultFrames = 512; break;
        case 0x02000000ULL: /* AAC-ELD 48 kHz stereo */
            sampleRate = 48000; channels = 2;
            formatID = kAudioFormatMPEG4AAC_ELD; defaultFrames = 512; break;
        case 0x04000000ULL: /* AAC-ELD 16 kHz mono */
            sampleRate = 16000; channels = 1;
            formatID = kAudioFormatMPEG4AAC_ELD; defaultFrames = 512; break;
        case 0x08000000ULL: /* AAC-ELD 24 kHz mono */
            sampleRate = 24000; channels = 1;
            formatID = kAudioFormatMPEG4AAC_ELD; defaultFrames = 512; break;
        case 0x10000000ULL: /* Opus 16 kHz mono, 20 ms */
            sampleRate = 16000; channels = 1;
            formatID = (AudioFormatID)0x6f707573U; defaultFrames = 320; break;
        case 0x20000000ULL: /* Opus 24 kHz mono, 20 ms */
            sampleRate = 24000; channels = 1;
            formatID = (AudioFormatID)0x6f707573U; defaultFrames = 480; break;
        case 0x40000000ULL: /* Opus 48 kHz mono, 20 ms */
            sampleRate = 48000; channels = 1;
            formatID = (AudioFormatID)0x6f707573U; defaultFrames = 960; break;
        default:
            ip_log("audio stream %u unsupported format=0x%llx",
                   _streamType, (unsigned long long)formatMask);
            return NO;
    }

    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    BOOL audioFocus = [[NSUserDefaults standardUserDefaults] objectForKey:@"iPlayAudioFocus"] == nil
        ? YES : [[NSUserDefaults standardUserDefaults] boolForKey:@"iPlayAudioFocus"];
    AVAudioSessionCategoryOptions audioOptions =
        audioFocus ? 0 : AVAudioSessionCategoryOptionMixWithOthers;
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:audioOptions error:&sessionError];
    if (!sessionError) [session setActive:YES error:&sessionError];
    if (sessionError) {
        ip_log("audio session activation failed: %s",
               sessionError.localizedDescription.UTF8String);
    }

    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    asbd.mSampleRate = sampleRate;
    asbd.mFormatID = formatID;
    asbd.mChannelsPerFrame = channels;
    if (isPCM) {
        /* AirPlay PCM is signed, packed, 16-bit network byte order. */
        asbd.mFormatFlags =
            kLinearPCMFormatFlagIsSignedInteger |
            kLinearPCMFormatFlagIsPacked |
            kLinearPCMFormatFlagIsBigEndian;
        asbd.mBitsPerChannel = 16;
        asbd.mBytesPerFrame = channels * 2;
        asbd.mFramesPerPacket = 1;
        asbd.mBytesPerPacket = asbd.mBytesPerFrame;
    } else {
        asbd.mFramesPerPacket =
            framesPerPacket > 0 ? framesPerPacket : defaultFrames;
    }

    /*
     * MainHighAudio (type 102) is a one-second-latency UDP media stream.
     * Apple's receiver decodes its AAC access units to PCM before handing
     * them to the platform audio device. Keep MainBuffered type 103 on the
     * proven direct AudioQueue path, but mirror Apple's decode boundary for
     * type 102. The PCM meter then distinguishes encoded-data problems from
     * output routing problems in the same run.
     */
    AudioStreamBasicDescription queueASBD = asbd;
    _decodeAACToPCM =
        _streamType == 102 &&
        (formatMask == 0x00400000ULL ||
         formatMask == 0x00800000ULL);
    if (_decodeAACToPCM) {
        memset(&queueASBD, 0, sizeof(queueASBD));
        queueASBD.mSampleRate = sampleRate;
        queueASBD.mFormatID = kAudioFormatLinearPCM;
        queueASBD.mFormatFlags =
            kLinearPCMFormatFlagIsSignedInteger |
            kLinearPCMFormatFlagIsPacked;
        queueASBD.mChannelsPerFrame = channels;
        queueASBD.mBitsPerChannel = 16;
        queueASBD.mBytesPerFrame = channels * 2;
        queueASBD.mFramesPerPacket = 1;
        queueASBD.mBytesPerPacket = queueASBD.mBytesPerFrame;
        OSStatus converterStatus =
            AudioConverterNew(&asbd, &queueASBD, &_audioConverter);
        if (converterStatus != noErr || !_audioConverter) {
            ip_log("audio stream %u AAC converter create failed status=%d",
                   _streamType, (int)converterStatus);
            _audioConverter = NULL;
            return NO;
        }
    }

    OSStatus status = AudioQueueNewOutput(
        &queueASBD, carplay_audio_queue_callback, (__bridge void *)self,
        NULL, NULL, 0,
        &_audioQueue);
    if (status != noErr || !_audioQueue) {
        ip_log("audio stream %u queue create failed status=%d",
               _streamType, (int)status);
        _audioQueue = NULL;
        if (_audioConverter) {
            AudioConverterDispose(_audioConverter);
            _audioConverter = NULL;
        }
        return NO;
    }
    AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, 1.0f);
    _formatMask = formatMask;
    _framesPerPacket = asbd.mFramesPerPacket;
    if (_streamType == 102) {
        NSInteger configuredBuffer =
            [[NSUserDefaults standardUserDefaults] integerForKey:@"iPlayMusicBufferMs"];
        if (configuredBuffer == 300 || configuredBuffer == 500 ||
            configuredBuffer == 1000) {
            latencyMs = (uint32_t)configuredBuffer;
        }
    }
    _latencyMs = latencyMs;
    _sampleRate = sampleRate;
    _channels = channels;
    _decodedBytesPerFrame = queueASBD.mBytesPerFrame;
    _decodedPackets = 0;
    _isPCM = isPCM || _decodeAACToPCM;
    _queuedPackets = 0;
    /*
     * MainHighAudio is a jitter-buffered media stream. The sender asked for
     * one second of latency in every observed Spotify SETUP, but starting
     * after the old six-packet floor left only 139 ms at 44.1 kHz. Video
     * bursts on the shared IPC path routinely exceed that and drained the
     * queue. Other stream types retain the proven six-packet start.
     */
    _requiredStartPackets = 6;
    if (_streamType == 102 && latencyMs > 0 &&
        sampleRate > 0 && _framesPerPacket > 0) {
        double requestedPackets =
            ((double)latencyMs * sampleRate) /
            (1000.0 * (double)_framesPerPacket);
        _requiredStartPackets =
            MAX((NSUInteger)6, (NSUInteger)ceil(requestedPackets));
    }
    _outstandingBuffers = 0;
    _queueDrainCount = 0;
    _started = NO;
    _paused = NO;
    _haveSequence = NO;
    _lastRenderReportNanos = 0;
    ip_log("audio stream %u configured format=0x%llx %.0fHz/%uch "
           "framesPerPacket=%u latency=%ums startPackets=%lu output=%s",
           _streamType, (unsigned long long)_formatMask, sampleRate,
           (unsigned)channels, _framesPerPacket, _latencyMs,
           (unsigned long)_requiredStartPackets,
           _decodeAACToPCM ? "decoded-pcm" : "direct");
    return YES;
}

- (void)enqueuePacket:(const uint8_t *)bytes
               length:(uint32_t)length
             sequence:(uint16_t)sequence {
    if (!_audioQueue || !bytes || length == 0) return;
    if (_haveSequence && sequence != (uint16_t)(_lastSequence + 1)) {
        ip_log("audio stream %u RTP gap expected=%u got=%u",
               _streamType, (uint16_t)(_lastSequence + 1), sequence);
    }
    _lastSequence = sequence;
    _haveSequence = YES;

    UInt32 queueLength = _decodeAACToPCM
        ? _framesPerPacket * _decodedBytesPerFrame : length;
    AudioQueueBufferRef buffer = NULL;
    OSStatus status =
        AudioQueueAllocateBuffer(_audioQueue, queueLength, &buffer);
    if (status != noErr || !buffer) {
        ip_log("audio stream %u buffer allocation failed status=%d",
               _streamType, (int)status);
        return;
    }

    if (_decodeAACToPCM) {
        CarPlayAACInputContext input = {
            .bytes = bytes,
            .length = length,
            .channels = _channels,
            .consumed = NO
        };
        AudioBufferList output;
        memset(&output, 0, sizeof(output));
        output.mNumberBuffers = 1;
        output.mBuffers[0].mNumberChannels = _channels;
        output.mBuffers[0].mDataByteSize = queueLength;
        output.mBuffers[0].mData = buffer->mAudioData;
        UInt32 outputPackets = _framesPerPacket;
        status = AudioConverterFillComplexBuffer(
            _audioConverter, carplay_aac_input_callback, &input,
            &outputPackets, &output, NULL);
        if (status != noErr || output.mBuffers[0].mDataByteSize == 0) {
            AudioQueueFreeBuffer(_audioQueue, buffer);
            ip_log("audio stream %u AAC decode failed status=%d bytes=%u",
                   _streamType, (int)status, length);
            return;
        }
        buffer->mAudioDataByteSize =
            output.mBuffers[0].mDataByteSize;
        _decodedPackets++;
        if (_decodedPackets <= 3 || (_decodedPackets % 250) == 0) {
            const int16_t *samples =
                (const int16_t *)buffer->mAudioData;
            size_t sampleCount =
                buffer->mAudioDataByteSize / sizeof(int16_t);
            double squareSum = 0.0;
            for (size_t index = 0; index < sampleCount; index++) {
                double value = (double)samples[index] / 32768.0;
                squareSum += value * value;
            }
            double rms = sampleCount > 0
                ? sqrt(squareSum / (double)sampleCount) : 0.0;
            ip_log("audio stream %u decoded #%llu in=%u out=%u "
                   "frames=%u rms=%.6f",
                   _streamType,
                   (unsigned long long)_decodedPackets,
                   length, buffer->mAudioDataByteSize,
                   outputPackets, rms);
        }
    } else {
        memcpy(buffer->mAudioData, bytes, length);
        buffer->mAudioDataByteSize = length;
    }
    if (_isPCM) {
        status = AudioQueueEnqueueBuffer(_audioQueue, buffer, 0, NULL);
    } else {
        AudioStreamPacketDescription packet = {
            .mStartOffset = 0,
            .mVariableFramesInPacket = _framesPerPacket,
            .mDataByteSize = length
        };
        status = AudioQueueEnqueueBuffer(_audioQueue, buffer, 1, &packet);
    }
    if (status != noErr) {
        AudioQueueFreeBuffer(_audioQueue, buffer);
        ip_log("audio stream %u enqueue failed status=%d",
               _streamType, (int)status);
        return;
    }

    int32_t outstanding =
        __sync_add_and_fetch(&_outstandingBuffers, 1);
    _queuedPackets++;
    if (!_started && !_paused &&
        outstanding >= (int32_t)_requiredStartPackets) {
        UInt32 preparedFrames = 0;
        AudioQueuePrime(_audioQueue, 0, &preparedFrames);
        status = AudioQueueStart(_audioQueue, NULL);
        _started = status == noErr;
        if (_started) _paused = NO;
        ip_log("audio stream %u playback start status=%d primed=%u "
               "buffered=%d/%lu",
               _streamType, (int)status, preparedFrames, outstanding,
               (unsigned long)_requiredStartPackets);
    }
    if ((_queuedPackets % 500) == 0) {
        ip_log("audio stream %u live packets=%lu",
               _streamType, (unsigned long)_queuedPackets);
    }
}

- (void)completedBuffer:(AudioQueueBufferRef)buffer
               forQueue:(AudioQueueRef)queue {
    [self reportPlaybackTimeForQueue:queue];
    int32_t outstanding =
        __sync_sub_and_fetch(&_outstandingBuffers, 1);
    if (_started && !_paused && outstanding == 0) {
        _queueDrainCount++;
        ip_log("audio stream %u queue drained #%llu packets=%lu",
               _streamType, (unsigned long long)_queueDrainCount,
               (unsigned long)_queuedPackets);
    }
    AudioQueueFreeBuffer(queue, buffer);
}

- (void)setPlaybackPaused:(BOOL)paused {
    if (!_audioQueue) return;

    if (paused) {
        _paused = YES;
        OSStatus status = _started
            ? AudioQueuePause(_audioQueue) : noErr;
        ip_log("audio stream %u pause status=%d started=%d queued=%lu",
               _streamType, (int)status, (int)_started,
               (unsigned long)_queuedPackets);
        return;
    }

    _paused = NO;
    OSStatus status = noErr;
    UInt32 preparedFrames = 0;
    if (_started) {
        status = AudioQueueStart(_audioQueue, NULL);
    } else if (_outstandingBuffers >= (int32_t)_requiredStartPackets) {
        AudioQueuePrime(_audioQueue, 0, &preparedFrames);
        status = AudioQueueStart(_audioQueue, NULL);
        _started = status == noErr;
    }
    ip_log("audio stream %u resume status=%d started=%d queued=%lu primed=%u",
           _streamType, (int)status, (int)_started,
           (unsigned long)_queuedPackets, preparedFrames);
}

- (void)flushBufferedAudio {
    if (!_audioQueue) return;

    /*
     * AudioQueueFlush drains already-enqueued buffers, which is the opposite
     * of AirPlay's FLUSHBUFFERED transition. Reset returns those buffers
     * immediately and preserves the queue's negotiated format. Keep the
     * paused state established by SETRATEANCHORTIME rate=0; the new RTP epoch
     * will not start until the following rate=1 command.
     */
    BOOL wasPaused = _paused;
    _started = NO;
    _queuedPackets = 0;
    _haveSequence = NO;
    _lastRenderReportNanos = 0;
    OSStatus status = AudioQueueReset(_audioQueue);
    _outstandingBuffers = 0;
    if (_audioConverter) AudioConverterReset(_audioConverter);
    _paused = wasPaused;
    ip_log("audio stream %u buffered flush status=%d paused=%d",
           _streamType, (int)status, (int)_paused);
}

- (void)reportPlaybackTimeForQueue:(AudioQueueRef)queue {
    if (!queue || queue != _audioQueue || !_started) return;

    uint64_t nowNanos = monotonic_nanos_now();
    if (_lastRenderReportNanos != 0 &&
        nowNanos - _lastRenderReportNanos < 250 * NSEC_PER_MSEC) {
        return;
    }

    AudioTimeStamp audioTime;
    memset(&audioTime, 0, sizeof(audioTime));
    Boolean discontinuity = false;
    OSStatus status = AudioQueueGetCurrentTime(
        queue, NULL, &audioTime, &discontinuity);
    if (status != noErr ||
        !(audioTime.mFlags & kAudioTimeStampSampleTimeValid)) {
        return;
    }

    int64_t sampleTime = (int64_t)llround(audioTime.mSampleTime);
    uint64_t hostTicks =
        (audioTime.mFlags & kAudioTimeStampHostTimeValid)
            ? audioTime.mHostTime : mach_absolute_time();
    uint8_t payload[20] = {0};
    memcpy(payload, &_streamType, 4);
    memcpy(payload + 4, &sampleTime, 8);
    memcpy(payload + 12, &hostTicks, 8);
    send_ipc_payload(MSG_AUDIO_RENDER, payload, sizeof(payload));
    _lastRenderReportNanos = nowNanos;

    if (discontinuity) {
        ip_log("audio stream %u render clock discontinuity sample=%lld",
               _streamType, (long long)sampleTime);
    }
}

- (void)stop {
    if (_audioQueue) {
        AudioQueueStop(_audioQueue, true);
        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
    }
    if (_audioConverter) {
        AudioConverterDispose(_audioConverter);
        _audioConverter = NULL;
    }
    _decodeAACToPCM = NO;
    _decodedPackets = 0;
    _sampleRate = 0;
    _latencyMs = 0;
    _requiredStartPackets = 6;
    _outstandingBuffers = 0;
    _queueDrainCount = 0;
    _started = NO;
    _paused = NO;
    _queuedPackets = 0;
    _haveSequence = NO;
    _lastRenderReportNanos = 0;
}

- (void)dealloc {
    [self stop];
}
@end

/* A bounded, scrollable compatibility report. Bluetooth failures used to
 * return the state machine to Idle with no user-visible explanation; a long
 * raw daemon log also does not belong in a UIAlertController message. */
@interface CompatibilityErrorViewController : UIViewController
@property (nonatomic, copy) NSString *errorTitle;
@property (nonatomic, copy) NSString *explanation;
@property (nonatomic, copy) NSString *diagnostic;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *explanationLabel;
@property (nonatomic, strong) UITextView *diagnosticView;
@property (nonatomic, strong) UIButton *diagnosticCopyButton;
@property (nonatomic, strong) UIButton *closeButton;
@end

@implementation CompatibilityErrorViewController

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    root.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    self.view = root;

    self.panel = [[UIView alloc] init];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1.0];
    self.panel.layer.cornerRadius = 16;
    self.panel.layer.masksToBounds = YES;
    [root addSubview:self.panel];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.font =
        [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.panel addSubview:self.titleLabel];

    self.explanationLabel = [[UILabel alloc] init];
    self.explanationLabel.textColor =
        [UIColor colorWithWhite:1.0 alpha:0.72];
    self.explanationLabel.font = [UIFont systemFontOfSize:14];
    self.explanationLabel.numberOfLines = 3;
    self.explanationLabel.textAlignment = NSTextAlignmentCenter;
    [self.panel addSubview:self.explanationLabel];

    self.diagnosticView = [[UITextView alloc] init];
    self.diagnosticView.editable = NO;
    self.diagnosticView.selectable = YES;
    self.diagnosticView.alwaysBounceVertical = YES;
    self.diagnosticView.backgroundColor =
        [UIColor colorWithWhite:0 alpha:0.38];
    self.diagnosticView.textColor =
        [UIColor colorWithWhite:1.0 alpha:0.88];
    self.diagnosticView.font =
        [UIFont fontWithName:@"Menlo-Regular" size:11] ?:
            [UIFont systemFontOfSize:11];
    self.diagnosticView.layer.cornerRadius = 8;
    self.diagnosticView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    [self.panel addSubview:self.diagnosticView];

    self.diagnosticCopyButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.diagnosticCopyButton.backgroundColor = [UIColor whiteColor];
    [self.diagnosticCopyButton setTitleColor:[UIColor blackColor]
                                    forState:UIControlStateNormal];
    [self.diagnosticCopyButton setTitle:@"Copy Diagnostic"
                               forState:UIControlStateNormal];
    self.diagnosticCopyButton.titleLabel.font =
        [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.diagnosticCopyButton.layer.cornerRadius = 9;
    [self.diagnosticCopyButton addTarget:self action:@selector(copyDiagnostic)
                        forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.diagnosticCopyButton];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.closeButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.13];
    [self.closeButton setTitleColor:[UIColor whiteColor]
                           forState:UIControlStateNormal];
    [self.closeButton setTitle:@"Close" forState:UIControlStateNormal];
    self.closeButton.titleLabel.font =
        [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.closeButton.layer.cornerRadius = 9;
    [self.closeButton addTarget:self action:@selector(close)
               forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:self.closeButton];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.titleLabel.text = self.errorTitle;
    self.explanationLabel.text = self.explanation;
    self.diagnosticView.text = self.diagnostic;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    CGFloat panelWidth = MIN(size.width - 32.0, 720.0);
    CGFloat panelHeight = MIN(size.height - 24.0, 520.0);
    self.panel.frame = CGRectMake((size.width - panelWidth) / 2.0,
                                  (size.height - panelHeight) / 2.0,
                                  panelWidth, panelHeight);
    CGFloat inset = 18.0;
    self.titleLabel.frame = CGRectMake(inset, 14, panelWidth - inset * 2, 32);
    self.explanationLabel.frame =
        CGRectMake(inset, 48, panelWidth - inset * 2, 58);
    CGFloat buttonsY = panelHeight - 56;
    self.diagnosticView.frame =
        CGRectMake(inset, 112, panelWidth - inset * 2,
                   MAX(56, buttonsY - 122));
    CGFloat gap = 12;
    CGFloat buttonWidth = (panelWidth - inset * 2 - gap) / 2.0;
    self.diagnosticCopyButton.frame =
        CGRectMake(inset, buttonsY, buttonWidth, 40);
    self.closeButton.frame =
        CGRectMake(inset + buttonWidth + gap, buttonsY, buttonWidth, 40);
}

- (void)copyDiagnostic {
    [UIPasteboard generalPasteboard].string = self.diagnostic ?: @"";
    [self.diagnosticCopyButton setTitle:@"Copied"
                               forState:UIControlStateNormal];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

/* The interface-orientation names describe the content rotation, not the
 * physical device rotation. LandscapeLeft therefore places the top edge
 * (and a notch or Dynamic Island) on the right side of the display. Long
 * phone panels are used as the hardware signal so this remains independent
 * of model identifier, OS version, and jailbreak layout. */
static BOOL showcase_phone_has_landscape_cutout(void) {
    if (UI_USER_INTERFACE_IDIOM() != UIUserInterfaceIdiomPhone) return NO;
    CGSize pixels = [UIScreen mainScreen].nativeBounds.size;
    CGFloat shortEdge = MIN(pixels.width, pixels.height);
    CGFloat longEdge = MAX(pixels.width, pixels.height);
    return shortEdge > 0.0 && (longEdge / shortEdge) > 2.0;
}

static UIInterfaceOrientationMask showcase_orientation_mask(void) {
    return showcase_phone_has_landscape_cutout()
        ? UIInterfaceOrientationMaskLandscapeLeft
        : UIInterfaceOrientationMaskLandscape;
}

static UIInterfaceOrientation showcase_preferred_orientation(void) {
    return UIInterfaceOrientationLandscapeLeft;
}

/* ═══════════════════════════════════════════════════════════════
 * RootViewController — landscape-only touch routing
 * ═══════════════════════════════════════════════════════════════ */

@class AppDelegate;

@interface RootViewController : UIViewController
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, weak) VideoView *videoView;
@property (nonatomic, weak) AppDelegate *appDelegate;
@property (nonatomic, assign) BOOL fullscreenMode; /* iPhone Active bypass of the 1024x768 canvas */
@property (nonatomic, strong) NSMapTable<UITouch *, NSNumber *> *touchSlots;
@end

@implementation RootViewController
- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    root.backgroundColor = [UIColor blackColor];
    /* Preserve upstream two-contact CarPlay input and the three-finger
     * settings gesture instead of collapsing UIKit to one touch. */
    root.multipleTouchEnabled = YES;
    self.touchSlots = [NSMapTable weakToStrongObjectsMapTable];
    self.view = root;
    self.contentView = root;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.contentView == self.view) {
        self.contentView.frame = self.view.bounds;
        self.contentView.transform = CGAffineTransformIdentity;
        return;
    }

    if (self.fullscreenMode) {
        /* iPhone Active: drop the 1024x768 canvas; let video fill the screen. */
        self.contentView.transform = CGAffineTransformIdentity;
        self.contentView.bounds = self.view.bounds;
        self.contentView.center = CGPointMake(self.view.bounds.size.width / 2.0,
                                              self.view.bounds.size.height / 2.0);
        return;
    }

    CGSize s = self.view.bounds.size;
    CGFloat scale = MIN(s.width / PHONE_CANVAS_W, s.height / PHONE_CANVAS_H);
    self.contentView.bounds = CGRectMake(0, 0, PHONE_CANVAS_W, PHONE_CANVAS_H);
    self.contentView.center = CGPointMake(s.width / 2.0, s.height / 2.0);
    self.contentView.transform = CGAffineTransformMakeScale(scale, scale);
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return showcase_orientation_mask();
}
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return showcase_preferred_orientation();
}

- (BOOL)mapTouch:(UITouch *)touch toX:(uint16_t *)outX y:(uint16_t *)outY {
    if (g_carplay_w <= 0 || g_carplay_h <= 0) return NO;
    CGPoint pt = [touch locationInView:self.videoView];
    CGSize vs = self.videoView.bounds.size;
    float vw = vs.width, vh = vs.height;
    float cw = g_carplay_w, ch = g_carplay_h;
    float va = cw / ch, vva = vw / vh;
    float rw, rh, rx, ry;
    if (va > vva) { rw = vw; rh = vw / va; rx = 0; ry = (vh - rh) / 2.0f; }
    else          { rh = vh; rw = vh * va; rx = (vw - rw) / 2.0f; ry = 0; }
    float nx = (pt.x - rx) / rw, ny = (pt.y - ry) / rh;
    /*
     * Upstream clamps normalized coordinates instead of dropping contacts.
     * Never drop UP/CANCEL outside the rendered rectangle or a HID slot can
     * remain logically pressed.
     */
    nx = fmaxf(0.0f, fminf(1.0f, nx));
    ny = fmaxf(0.0f, fminf(1.0f, ny));
    *outX = (uint16_t)lrintf(nx * cw);
    *outY = (uint16_t)lrintf(ny * ch);
    return YES;
}
- (NSNumber *)slotForTouch:(UITouch *)touch create:(BOOL)create {
    NSNumber *existing = [self.touchSlots objectForKey:touch];
    if (existing || !create) return existing;

    NSArray<NSNumber *> *used = self.touchSlots.objectEnumerator.allObjects;
    for (NSInteger slot = 0; slot < 2; slot++) {
        NSNumber *candidate = @(slot);
        if (![used containsObject:candidate]) {
            [self.touchSlots setObject:candidate forKey:touch];
            return candidate;
        }
    }
    return nil;
}

- (void)handleTouches:(NSSet<UITouch *> *)touches
                event:(UIEvent *)event
                phase:(uint8_t)phase {
    /*
     * Upstream CarPlayTouchMapper exposes exactly two contacts. Keep stable
     * UIKit touch -> HID slots 0/1; any third contact belongs to the
     * three-finger settings recognizer and is never advertised to CarPlay.
     */
    NSMutableData *records = [NSMutableData data];
    for (UITouch *touch in touches) {
        NSNumber *slotNumber = [self slotForTouch:touch create:(phase == TOUCH_DOWN)];
        if (!slotNumber) continue;
        uint8_t contact = (uint8_t)slotNumber.unsignedIntegerValue;

        NSArray<UITouch *> *samples = nil;
        if (phase == TOUCH_MOVE) {
            samples = [event coalescedTouchesForTouch:touch];
        }
        if (samples.count == 0) samples = @[touch];

        for (UITouch *sample in samples) {
            uint16_t x = 0, y = 0;
            if (![self mapTouch:sample toX:&x y:&y]) continue;
            uint64_t timestampNs =
                (uint64_t)llround(sample.timestamp * (double)NSEC_PER_SEC);
            uint8_t record[14] = { phase, contact };
            record[2] = x & 0xff;
            record[3] = x >> 8;
            record[4] = y & 0xff;
            record[5] = y >> 8;
            memcpy(record + 6, &timestampNs, sizeof(timestampNs));
            [records appendBytes:record length:sizeof(record)];
        }

        if (phase == TOUCH_UP || phase == TOUCH_CANCEL) {
            [self.touchSlots removeObjectForKey:touch];
        }
    }
    send_touch_records(records);
}
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [self handleTouches:t event:e phase:TOUCH_DOWN];
}
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [self handleTouches:t event:e phase:TOUCH_MOVE];
}
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [self handleTouches:t event:e phase:TOUCH_UP];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)e {
    [self handleTouches:t event:e phase:TOUCH_CANCEL];
}
@end


/* Exact UIKit equivalent of upstream CarPlayHostActivity's three-finger
 * swipe-down settings gesture. It consumes the sequence the instant the
 * third finger lands, before CarPlay can interpret that sequence. */
@interface ThreeFingerSwipeDownGestureRecognizer : UIGestureRecognizer
@property (nonatomic, strong) NSMutableSet<UITouch *> *trackedTouches;
@property (nonatomic, assign) CGPoint startCentroid;
@property (nonatomic, assign) BOOL trackingThree;
@end

@implementation ThreeFingerSwipeDownGestureRecognizer

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithTarget:target action:action];
    if (self) {
        _trackedTouches = [NSMutableSet setWithCapacity:3];
        self.cancelsTouchesInView = YES;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}

- (CGPoint)centroidInView:(UIView *)view {
    if (self.trackedTouches.count == 0) return CGPointZero;
    CGFloat x = 0.0, y = 0.0;
    for (UITouch *touch in self.trackedTouches) {
        CGPoint point = [touch locationInView:view];
        x += point.x;
        y += point.y;
    }
    CGFloat count = (CGFloat)self.trackedTouches.count;
    return CGPointMake(x / count, y / count);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    [self.trackedTouches unionSet:touches];
    if (self.trackedTouches.count > 3) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    if (self.trackedTouches.count == 3 && !self.trackingThree) {
        self.trackingThree = YES;
        self.startCentroid = [self centroidInView:self.view];
        /* Entering Began makes UIKit cancel the already-forwarded contacts
         * to RootViewController, equivalent to upstream sendTouch(emptyList()). */
        self.state = UIGestureRecognizerStateBegan;
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    if (!self.trackingThree || self.trackedTouches.count != 3) return;

    CGPoint now = [self centroidInView:self.view];
    CGFloat dx = fabs(now.x - self.startCentroid.x);
    CGFloat dy = now.y - self.startCentroid.y;
    if (dy >= 72.0 && dy >= dx * 1.15) {
        self.state = UIGestureRecognizerStateEnded;
    } else if (self.state == UIGestureRecognizerStateBegan ||
               self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateChanged;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    [self.trackedTouches minusSet:touches];
    if (self.state == UIGestureRecognizerStateEnded) return;
    if (self.trackingThree) {
        self.state = UIGestureRecognizerStateCancelled;
    } else if (self.trackedTouches.count == 0) {
        self.state = UIGestureRecognizerStateFailed;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    [self.trackedTouches minusSet:touches];
    self.state = UIGestureRecognizerStateCancelled;
}

- (void)reset {
    [super reset];
    [self.trackedTouches removeAllObjects];
    self.trackingThree = NO;
    self.startCentroid = CGPointZero;
}

@end

/* ═══════════════════════════════════════════════════════════════
 * AppDelegate — state machine, UI, IPC
 * ═══════════════════════════════════════════════════════════════ */

@class CarsViewController;

@interface AppDelegate : UIResponder <UIApplicationDelegate, PHPickerViewControllerDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) RootViewController *vc;
@property (nonatomic, strong) VideoView *videoView;
@property (nonatomic, strong)
    NSMutableDictionary<NSNumber *, CarPlayAudioPlayer *> *audioPlayers;

/* Setup overlay */
@property (nonatomic, strong) UIView   *setupOverlay;
@property (nonatomic, strong) UILabel  *titleLabel;
@property (nonatomic, strong) UILabel  *headlineLabel;
@property (nonatomic, strong) UILabel  *subtitleLabel;
@property (nonatomic, strong) UILabel  *carHintLabel;       /* "Currently using: Miata" */
@property (nonatomic, strong) UIButton *primaryButton;     /* Start CarPlay / Open Settings */
@property (nonatomic, strong) UIButton *secondaryButton;   /* My Cars / Cancel */
@property (nonatomic, strong) UIButton *tertiaryButton;    /* Wi-Fi (idle only) */
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
/* Upstream DiPlay home hierarchy, ported from DiPlayActivity.kt. */
@property (nonatomic, strong) UIButton *receiverButton;    /* upstream USB-column equivalent: A -> B receiver */
@property (nonatomic, strong) UILabel *upstreamEyebrowLabel;
@property (nonatomic, strong) UILabel *upstreamHeroTitleLabel;
@property (nonatomic, strong) UILabel *upstreamHeroBodyLabel;
@property (nonatomic, strong) UILabel *upstreamWirelessLabel;
@property (nonatomic, strong) UILabel *upstreamReceiverHintLabel;
@property (nonatomic, strong) UILabel *upstreamSettingsHintLabel;
@property (nonatomic, strong) UILabel *upstreamPreviewLabel;
@property (nonatomic, strong) UIImageView *upstreamHeaderIcon;
@property (nonatomic, strong) UIImageView *upstreamBrandIcon;
@property (nonatomic, strong) UIView *upstreamWirelessCard;
@property (nonatomic, weak) UIImageView *airPlayIconPreview;

/* Upstream DiPlay gesture: three-finger swipe down opens the real
 * in-CarPlay settings surface while normal touches continue to CarPlay. */
@property (nonatomic, strong) ThreeFingerSwipeDownGestureRecognizer *controlsGesture;

/* Upstream DiPlay UIKit surface is implemented in upstream_ui.inc. */
- (void)buildUpstreamHomeReal;
- (void)layoutUpstreamHomeReal;
- (void)showUpstreamSettingsReal;

/* Lifecycle */
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;

/* State */
@property (nonatomic, assign) ShowcaseState state;

/* Children */
@property (nonatomic, assign) pid_t btdaemonPid;
@property (nonatomic, assign) pid_t carplayBtPid;
@property (nonatomic, assign) pid_t carplayServicesPid;
@property (nonatomic, assign) pid_t baaBrokerPid;

/* bridge100 tcpdump capture */
@property (nonatomic, assign) pid_t tcpdumpPid;
@property (nonatomic, copy)   NSString *currentTcpdumpPath;
@property (nonatomic, strong) NSTimer *tcpdumpStopTimer;
@property (nonatomic, assign) BOOL tcpdumpMissingPromptShown;
@property (nonatomic, assign) BOOL diagnosticsEnabled;
@property (nonatomic, assign) BOOL helpersLoggedThisRun;
@property (nonatomic, assign) BOOL bluetoothHandedOff;
@property (nonatomic, assign) BOOL bluetoothRetryAttempted;
@property (nonatomic, assign) NSInteger sideStoreMode; /* 0 local A->A, 1 receiver B, 2 source A->B */
@property (nonatomic, assign) BOOL inProcessServiceStarted;
@property (nonatomic, copy) NSString *pendingBluetoothErrorTitle;
@property (nonatomic, copy) NSString *pendingBluetoothErrorExplanation;
@property (nonatomic, copy) NSString *pendingBluetoothDiagnostic;

/* Networking */
@property (nonatomic, assign) int listenFd;
@property (nonatomic, assign) int clientFd;
@property (nonatomic, strong) dispatch_queue_t bgQueue;
@property (nonatomic, strong) dispatch_queue_t videoQueue;

/* BAA preheater and local signing broker */
@property (nonatomic, assign) BOOL baaReady;
@property (nonatomic, assign) BOOL baaLoading;
@property (nonatomic, copy) NSString *baaError;

/* AP polling */
@property (nonatomic, strong) NSTimer *apPollTimer;
@property (nonatomic, strong) dispatch_source_t awdlReassertTimer;

/* Cars */
@property (nonatomic, strong) CarStore *cars;
@end

/* Forward — defined later */
@interface CarsViewController : UIViewController
@property (nonatomic, weak) AppDelegate *appDelegate;
@end

@interface WifiSetupViewController : UIViewController
@property (nonatomic, weak) AppDelegate *appDelegate;
@end

@implementation AppDelegate

- (UIInterfaceOrientationMask)application:(UIApplication *)application
        supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    (void)application;
    (void)window;
    return showcase_orientation_mask();
}

- (UIView *)rootContentView {
    return self.vc.contentView ?: self.vc.view;
}

- (BOOL)application:(UIApplication *)app
    didFinishLaunchingWithOptions:(NSDictionary *)opts {

    self.bgQueue = dispatch_queue_create("com.reng.showcase.bg", DISPATCH_QUEUE_SERIAL);
    self.videoQueue = dispatch_queue_create(
        "com.reng.showcase.video", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(self.videoQueue,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    self.audioPlayers = [NSMutableDictionary dictionary];
    /* No crash-recovery pass is needed here: iOS re-enables AWDL by itself
     * whenever a Continuity service wants it, which is exactly why the
     * suppression below has to be re-asserted on a timer. A run killed
     * mid-session therefore heals on its own. */
    self.state = StateIdle;
    self.listenFd = -1;
    self.clientFd = -1;
    self.bgTask = UIBackgroundTaskInvalid;
    self.tcpdumpPid = 0;
    self.tcpdumpMissingPromptShown = NO;
    _diagnosticsEnabled = (!iPlayIsStockSideStoreBuild())
        ? [[NSUserDefaults standardUserDefaults] boolForKey:DIAGNOSTICS_ENABLED_KEY]
        : NO;
    self.cars = [[CarStore alloc] init];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor blackColor];

    self.vc = [[RootViewController alloc] init];
    self.vc.view.backgroundColor = [UIColor blackColor];
    self.vc.appDelegate = self;

    UIView *content = [self rootContentView];

    self.videoView = [[VideoView alloc] initWithFrame:content.bounds];
    self.videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.videoView.backgroundColor = [UIColor blackColor];
    self.videoView.multipleTouchEnabled = YES;
    ((AVSampleBufferDisplayLayer *)self.videoView.layer).videoGravity = AVLayerVideoGravityResizeAspect;
    [content addSubview:self.videoView];
    self.vc.videoView = self.videoView;

    [self buildUpstreamHomeReal];
    [self buildChrome];

    self.window.rootViewController = self.vc;
    [self.window makeKeyAndVisible];

    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleBackground)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleForeground)
        name:UIApplicationWillEnterForegroundNotification object:nil];

    [self transitionTo:StateIdle];
    if (iPlayIsStockSideStoreBuild()) {
        self.baaReady = YES;
        self.baaLoading = NO;
        self.baaError = nil;
        NSInteger savedMode =
            [[NSUserDefaults standardUserDefaults] integerForKey:@"iPlayLastMode"];
        self.sideStoreMode = (savedMode == 1) ? 1 : 0;
        ip_log("[SIDESTORE] Using in-process CarPlay receiver/authentication");
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"iPlayAutoConnect"]) {
            ip_log("[SIDESTORE] Auto Connect scheduled for saved mode=%ld",
                   (long)self.sideStoreMode);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.65 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self.state == StateIdle) [self attemptStart];
            });
        }
    } else if (![self startBAABroker]) {
        self.baaError = @"The local authentication broker could not start.";
        ip_log("BAA broker failed to start");
    } else {
        [self preheatBAA];
    }
    return YES;
}

- (BOOL)startBAABroker {
    reap_stale_helpers(0);
    NSString *helper = [[[NSBundle mainBundle] bundlePath]
        stringByAppendingPathComponent:@SVC_HELPER_NAME];
    char *argv[] = {
        (char *)SVC_HELPER_NAME,
        (char *)"--baa-broker",
        NULL
    };
    self.baaBrokerPid = spawn_daemon([helper UTF8String], argv,
                                     LOG_DIR "/baa_broker.log");
    if (self.baaBrokerPid <= 0) return NO;
    ip_log("BAA preheat helper pid=%d", self.baaBrokerPid);
    return YES;
}

- (void)preheatBAA {
    if (self.baaLoading || self.baaReady || self.baaBrokerPid <= 0) return;
    self.baaLoading = YES;
    self.baaError = nil;
    [self renderState];
    ip_log("BAA preheat started before hotspot");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int rc = -1;
        uint8_t *leaf = NULL, *intermediate = NULL;
        int leafLength = 0, intermediateLength = 0;
        for (int attempt = 0; attempt < 450; attempt++) {
            if (!pid_alive(self.baaBrokerPid)) {
                rc = -1;
                break;
            }
            rc = baa_broker_get_certs(&leaf, &leafLength,
                                      &intermediate, &intermediateLength);
            if (rc == 0) break;
            usleep(100000);
        }
        uint8_t *signature = NULL;
        int signatureLength = 0;
        static const uint8_t probe[] = "Showcase BAA preheat";
        if (rc == 0) {
            rc = baa_broker_sign(probe, (uint32_t)(sizeof(probe) - 1),
                                 &signature, &signatureLength);
        }
        BOOL success = rc == 0 && signatureLength > 0;
        free(leaf);
        free(intermediate);
        free(signature);
        if (success) {
            ip_log("BAA preheat helper ready: leaf=%d intermediate=%d signature=%d",
                   leafLength, intermediateLength, signatureLength);
        } else {
            ip_log("BAA preheat helper failed rc=%d", rc);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.baaLoading = NO;
            self.baaReady = success;
            self.baaError = success ? nil :
                @"Unable to prepare CarPlay authentication. Check the internet connection.";
            [self renderState];
        });
    });
}

- (void)handleBackground {
    if (self.state != StateIdle && self.state != StateStopping) {
        ip_log("backgrounded — preserving CarPlay session");
        g_video_suspended = 1;
        g_video_needs_resync = 1;
        send_app_visibility(0);
        dispatch_async(self.videoQueue, ^{
            AVSampleBufferDisplayLayer *layer =
                (AVSampleBufferDisplayLayer *)self.videoView.layer;
            [layer flushAndRemoveImage];
        });
    }
}

- (void)handleForeground {
    [self endBackgroundTask];
    ip_log("foregrounded — continuing state=%ld", (long)self.state);
    if (self.state == StateActive || self.state == StateAwaitingPhone) {
        g_video_needs_resync = 1;
        g_video_suspended = 0;
        dispatch_async(self.videoQueue, ^{
            AVSampleBufferDisplayLayer *layer =
                (AVSampleBufferDisplayLayer *)self.videoView.layer;
            [layer flush];
        });
        send_app_visibility(1);
        ip_log("foreground video resync requested");
    }
    if (self.state == StateAwaitingAP) [self pollAP];
    if (self.state == StateIdle &&
        [[NSUserDefaults standardUserDefaults] boolForKey:@"iPlayAutoForeground"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self.state == StateIdle) [self attemptStart];
        });
    }
    [self renderState];
    [self presentPendingBluetoothCompatibilityError];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    (void)application;
    [[IPlayBackgroundAudioKeeper shared] requestStop];
    [self endAWDLSuppression];
    [self stopNetworkDumpCaptureWithReason:@"app terminating"];
    kill_pid(self.baaBrokerPid);
    self.baaBrokerPid = 0;
    unlink(BAA_BROKER_PATH);
}

- (void)endBackgroundTask {
    if (self.bgTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }
}

/* ─── UI construction ──────────────────────────────────────── */

- (UILabel *)upstreamLabel:(NSString *)text
                         size:(CGFloat)size
                        color:(UIColor *)color
                         bold:(BOOL)bold {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.textColor = color;
    label.font = [UIFont systemFontOfSize:size
                                   weight:bold ? UIFontWeightMedium : UIFontWeightRegular];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentLeft;
    return label;
}

- (void)styleUpstreamButton:(UIButton *)button primary:(BOOL)primary {
    UIColor *bg = [UIColor colorWithRed:(primary ? 166.0 : 21.0)/255.0
                                  green:(primary ? 200.0 : 30.0)/255.0
                                   blue:(primary ? 255.0 : 44.0)/255.0
                                  alpha:1.0];
    UIColor *fg = primary
        ? [UIColor colorWithRed:12/255.0 green:17/255.0 blue:27/255.0 alpha:1]
        : [UIColor colorWithRed:241/255.0 green:245/255.0 blue:252/255.0 alpha:1];
    UIColor *border = primary
        ? [UIColor colorWithRed:166/255.0 green:200/255.0 blue:255/255.0 alpha:1]
        : [UIColor colorWithRed:42/255.0 green:56/255.0 blue:75/255.0 alpha:1];

    button.backgroundColor = bg;
    [button setTitleColor:fg forState:UIControlStateNormal];
    [button setTitleColor:[fg colorWithAlphaComponent:0.55] forState:UIControlStateHighlighted];
    button.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
    button.titleLabel.numberOfLines = 1;
    button.layer.cornerRadius = 20;
    button.layer.borderWidth = 1;
    button.layer.borderColor = border.CGColor;
    button.clipsToBounds = YES;
}

- (void)upstreamHomeTapped {
    /*
     * Upstream DiPlay sends the Android head unit to HOME. On iOS there is no
     * public equivalent, so use UIApplication's existing private suspend
     * selector when available; terminating is the last-resort sideload fallback.
     * This button must never be a visual no-op.
     */
    UIApplication *app = [UIApplication sharedApplication];
    SEL suspendSelector = NSSelectorFromString(@"suspend");
    if ([app respondsToSelector:suspendSelector]) {
        IMP implementation = [app methodForSelector:suspendSelector];
        if (implementation) {
            ((void (*)(id, SEL))implementation)(app, suspendSelector);
            return;
        }
    }
    exit(0);
}

- (void)receiverTapped {
    if (self.state != StateIdle) return;
    self.sideStoreMode = 1;
    [self attemptStart];
}

- (NSString *)airPlayCustomIconPath {
    NSArray<NSString *> *paths =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = paths.firstObject ?: NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:@"airplay-icon.png"];
}

- (UIImage *)currentAirPlayIconImage {
    UIImage *custom = [UIImage imageWithContentsOfFile:[self airPlayCustomIconPath]];
    return custom ?: [UIImage imageNamed:@"ic_car_home.png"];
}

- (UIImage *)squareAirPlayIconFromImage:(UIImage *)source {
    if (!source || source.size.width <= 0 || source.size.height <= 0) return nil;
    CGSize target = CGSizeMake(256, 256);
    CGFloat scale = MAX(target.width / source.size.width,
                        target.height / source.size.height);
    CGSize drawn = CGSizeMake(source.size.width * scale, source.size.height * scale);
    CGRect rect = CGRectMake((target.width - drawn.width) / 2.0,
                             (target.height - drawn.height) / 2.0,
                             drawn.width, drawn.height);
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:target];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context;
        [source drawInRect:rect];
    }];
}

- (void)chooseAirPlayIconForPreview:(UIImageView *)preview {
    PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
    configuration.selectionLimit = 1;
    configuration.filter = [PHPickerFilter imagesFilter];
    PHPickerViewController *picker =
        [[PHPickerViewController alloc] initWithConfiguration:configuration];
    picker.delegate = self;
    self.airPlayIconPreview = preview;
    [[self topPresenter] presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results {
    PHPickerResult *result = results.firstObject;
    if (!result) {
        [picker dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    NSItemProvider *provider = result.itemProvider;
    if (![provider canLoadObjectOfClass:[UIImage class]]) {
        [picker dismissViewControllerAnimated:YES completion:nil];
        return;
    }

    /*
     * Keep the picker modal until the asynchronous image load and atomic file
     * write finish. Otherwise the host Settings X/Disconnect rollback can run
     * first and a late provider callback can overwrite the restored baseline.
     */
    __weak typeof(self) weakSelf = self;
    [provider loadObjectOfClass:[UIImage class]
              completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!error && strongSelf && [object isKindOfClass:[UIImage class]]) {
                UIImage *picked = (UIImage *)object;
                UIImage *square = [strongSelf squareAirPlayIconFromImage:picked];
                NSData *png = square ? UIImagePNGRepresentation(square) : nil;
                if (png.length &&
                    [png writeToFile:[strongSelf airPlayCustomIconPath] atomically:YES]) {
                    strongSelf.airPlayIconPreview.image = square;
                    ip_log("[UI] custom AirPlay icon saved (%lu bytes)",
                           (unsigned long)png.length);
                }
            }
            [picker dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

- (void)restoreDefaultAirPlayIconForPreview:(UIImageView *)preview {
    [[NSFileManager defaultManager] removeItemAtPath:[self airPlayCustomIconPath]
                                               error:nil];
    preview.image = [UIImage imageNamed:@"ic_car_home.png"];
    ip_log("[UI] custom AirPlay icon cleared");
}

- (UIView *)upstreamSettingsCardWithTitle:(NSString *)title
                                    stack:(UIStackView **)outStack {
    UIColor *SURFACE = [UIColor colorWithRed:21/255.0 green:30/255.0 blue:44/255.0 alpha:1];
    UIColor *BORDER = [UIColor colorWithRed:42/255.0 green:56/255.0 blue:75/255.0 alpha:1];
    UIColor *TEXT = [UIColor colorWithRed:241/255.0 green:245/255.0 blue:252/255.0 alpha:1];
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = SURFACE;
    card.layer.cornerRadius = 20;
    card.layer.borderWidth = 1;
    card.layer.borderColor = BORDER.CGColor;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:22],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-22]
    ]];
    UILabel *heading = [self upstreamLabel:title size:22 color:TEXT bold:YES];
    [stack addArrangedSubview:heading];
    if (outStack) *outStack = stack;
    return card;
}

- (void)restartWhenIdleForMode:(NSInteger)mode attemptsRemaining:(NSInteger)attempts {
    if (attempts <= 0) {
        ip_log("[UI] Save/reconnect timed out waiting for Idle");
        return;
    }
    if (self.state == StateIdle) {
        self.sideStoreMode = mode;
        [self attemptStart];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self restartWhenIdleForMode:mode attemptsRemaining:attempts - 1];
    });
}

- (void)showUpstreamSettings {
    /*
     * Native UIKit translation of upstream CarPlayHostActivity.buildSettingsMenu().
     * Only settings backed by the iOS runtime are exposed here; Android/BYD-only
     * controls are intentionally omitted instead of presenting no-op UI.
     */
    UIColor *PANEL = [UIColor colorWithRed:12/255.0 green:16/255.0 blue:19/255.0 alpha:1];
    UIColor *SECONDARY = [UIColor colorWithRed:170/255.0 green:180/255.0 blue:190/255.0 alpha:1];
    UIColor *ACCENT = [UIColor colorWithRed:127/255.0 green:205/255.0 blue:154/255.0 alpha:1];
    UIColor *TEXT = [UIColor whiteColor];
    UIColor *DANGER = [UIColor colorWithRed:190/255.0 green:45/255.0 blue:45/255.0 alpha:1];

    NSUserDefaults *settingsDefaults = [NSUserDefaults standardUserDefaults];
    NSArray<NSString *> *trackedKeys = @[
        @"iPlayLastMode", @"iPlayAutoConnect", @"iPlayAutoForeground",
        @"iPlayPhysicalWidthMm", @"iPlayPhysicalSizeBasis",
        @"iPlayDisplayScaleTenths", @"iPlayFrameRate",
        @"iPlayMusicBufferMs", @"iPlayHEVC", @"iPlayRightHandDrive",
        @"iPlayFullScreen", @"iPlayAudioFocus", @"iPlayLocationReport",
        @"iPlayManufacturer", @"iPlayModel", @"iPlayOEMLabel"
    ];
    NSMutableDictionary<NSString *, id> *baseline = [NSMutableDictionary dictionary];
    for (NSString *key in trackedKeys) {
        id value = [settingsDefaults objectForKey:key];
        baseline[key] = value ?: [NSNull null];
    }
    NSInteger baselineMode = self.sideStoreMode;
    NSString *baselineIconPath = [self airPlayCustomIconPath];
    NSData *baselineIconData = [NSData dataWithContentsOfFile:baselineIconPath];
    BOOL baselineFullscreen = [settingsDefaults objectForKey:@"iPlayFullScreen"] == nil
        ? YES : [settingsDefaults boolForKey:@"iPlayFullScreen"];
    void (^restoreBaseline)(void) = ^{
        for (NSString *key in trackedKeys) {
            id value = baseline[key];
            if (value == [NSNull null]) [settingsDefaults removeObjectForKey:key];
            else [settingsDefaults setObject:value forKey:key];
        }
        self.sideStoreMode = baselineMode;
        if (baselineIconData.length > 0)
            [baselineIconData writeToFile:baselineIconPath atomically:YES];
        else
            [[NSFileManager defaultManager] removeItemAtPath:baselineIconPath error:nil];
        if (self.state == StateActive && [self isPhone]) {
            self.vc.fullscreenMode = baselineFullscreen;
            [self.vc.view setNeedsLayout];
            [self.vc.view layoutIfNeeded];
        }
    };

    UIViewController *settings = [[UIViewController alloc] init];
    settings.modalPresentationStyle = UIModalPresentationFullScreen;
    settings.view.backgroundColor = [UIColor blackColor];

    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = PANEL;
    [settings.view addSubview:panel];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [panel addSubview:scroll];

    UIStackView *root = [[UIStackView alloc] init];
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 18;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:root];

    CGFloat maxWidth = MIN(UIScreen.mainScreen.bounds.size.width, 1200.0);
    [NSLayoutConstraint activateConstraints:@[
        [panel.centerXAnchor constraintEqualToAnchor:settings.view.centerXAnchor],
        [panel.topAnchor constraintEqualToAnchor:settings.view.topAnchor],
        [panel.bottomAnchor constraintEqualToAnchor:settings.view.bottomAnchor],
        [panel.widthAnchor constraintEqualToConstant:maxWidth],
        [scroll.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],
        [root.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:48],
        [root.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-48],
        [root.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:36],
        [root.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-36],
        [root.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-96]
    ]];

    UIStackView *titleRow = [[UIStackView alloc] init];
    titleRow.axis = UILayoutConstraintAxisHorizontal;
    titleRow.alignment = UIStackViewAlignmentCenter;
    titleRow.spacing = 12;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    [close setTitle:@"×" forState:UIControlStateNormal];
    [close setTitleColor:TEXT forState:UIControlStateNormal];
    close.backgroundColor = [UIColor colorWithRed:64/255.0 green:74/255.0 blue:80/255.0 alpha:1];
    close.layer.cornerRadius = 14;
    close.titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightRegular];
    [close.widthAnchor constraintEqualToConstant:48].active = YES;
    [close.heightAnchor constraintEqualToConstant:48].active = YES;
    __weak UIViewController *weakSettings = settings;
    [close addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        restoreBaseline();
        [weakSettings dismissViewControllerAnimated:YES completion:nil];
    }] forControlEvents:UIControlEventTouchUpInside];
    [titleRow addArrangedSubview:close];

    UILabel *menuTitle = [self upstreamLabel:@"CarPlay settings" size:32 color:TEXT bold:YES];
    [titleRow addArrangedSubview:menuTitle];
    [root addArrangedSubview:titleRow];

    UILabel *(^categoryLabel)(NSString *) = ^UILabel *(NSString *text) {
        UILabel *label = [self upstreamLabel:text.uppercaseString size:13 color:SECONDARY bold:YES];
        label.accessibilityLabel = text;
        return label;
    };

    [root addArrangedSubview:categoryLabel(@"Connection")];

    UIStackView *connectionStack = nil;
    UIView *connection = [self upstreamSettingsCardWithTitle:@"Connection mode" stack:&connectionStack];
    connection.backgroundColor = PANEL;
    connection.layer.borderColor = [UIColor colorWithRed:64/255.0 green:74/255.0 blue:80/255.0 alpha:1].CGColor;

    UISegmentedControl *modeSelector = [[UISegmentedControl alloc]
        initWithItems:@[@"This iPhone · A → A", @"Receive · A → B"]];
    modeSelector.selectedSegmentIndex = self.sideStoreMode == 1 ? 1 : 0;
    modeSelector.selectedSegmentTintColor = ACCENT;
    __weak UISegmentedControl *weakModeSelector = modeSelector;
    [modeSelector addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        NSInteger mode = weakModeSelector.selectedSegmentIndex == 1 ? 1 : 0;
        self.sideStoreMode = mode;
        [settingsDefaults setInteger:mode forKey:@"iPlayLastMode"];
    }] forControlEvents:UIControlEventValueChanged];
    [connectionStack addArrangedSubview:modeSelector];
    [root addArrangedSubview:connection];

    UIStackView *autoStack = nil;
    UIView *automatic = [self upstreamSettingsCardWithTitle:@"Startup" stack:&autoStack];
    automatic.backgroundColor = PANEL;
    automatic.layer.borderColor = [UIColor colorWithRed:64/255.0 green:74/255.0 blue:80/255.0 alpha:1].CGColor;
    UIStackView *autoRow = [[UIStackView alloc] init];
    autoRow.axis = UILayoutConstraintAxisHorizontal;
    autoRow.alignment = UIStackViewAlignmentCenter;
    autoRow.spacing = 16;
    UIStackView *autoText = [[UIStackView alloc] init];
    autoText.axis = UILayoutConstraintAxisVertical;
    autoText.spacing = 5;
    [autoText addArrangedSubview:[self upstreamLabel:@"Connect when iPlay opens" size:20 color:SECONDARY bold:NO]];
    [autoText addArrangedSubview:[self upstreamLabel:@"Use the last selected A → A / A → B receiver mode." size:14 color:SECONDARY bold:NO]];
    [autoRow addArrangedSubview:autoText];
    UISwitch *autoSwitch = [[UISwitch alloc] init];
    autoSwitch.onTintColor = ACCENT;
    autoSwitch.on = [settingsDefaults boolForKey:@"iPlayAutoConnect"];
    __weak UISwitch *weakAutoSwitch = autoSwitch;
    [autoSwitch addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        [settingsDefaults setBool:weakAutoSwitch.isOn forKey:@"iPlayAutoConnect"];
    }] forControlEvents:UIControlEventValueChanged];
    [autoRow addArrangedSubview:autoSwitch];
    [autoStack addArrangedSubview:autoRow];

    UIStackView *foregroundRow = [[UIStackView alloc] init];
    foregroundRow.axis = UILayoutConstraintAxisHorizontal;
    foregroundRow.alignment = UIStackViewAlignmentCenter;
    foregroundRow.spacing = 16;
    UIStackView *foregroundText = [[UIStackView alloc] init];
    foregroundText.axis = UILayoutConstraintAxisVertical;
    foregroundText.spacing = 5;
    [foregroundText addArrangedSubview:[self upstreamLabel:@"Reconnect when iPlay returns"
                                                     size:20 color:SECONDARY bold:NO]];
    [foregroundText addArrangedSubview:[self upstreamLabel:
        @"If the session has stopped, returning to iPlay starts the saved connection mode."
        size:14 color:SECONDARY bold:NO]];
    [foregroundRow addArrangedSubview:foregroundText];
    UISwitch *foregroundSwitch = [[UISwitch alloc] init];
    foregroundSwitch.onTintColor = ACCENT;
    foregroundSwitch.on =
        [settingsDefaults boolForKey:@"iPlayAutoForeground"];
    __weak UISwitch *weakForegroundSwitch = foregroundSwitch;
    [foregroundSwitch addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        [settingsDefaults setBool:weakForegroundSwitch.isOn forKey:@"iPlayAutoForeground"];
    }] forControlEvents:UIControlEventValueChanged];
    [foregroundRow addArrangedSubview:foregroundSwitch];
    [autoStack addArrangedSubview:foregroundRow];
    [root addArrangedSubview:automatic];

    [root addArrangedSubview:categoryLabel(@"Identity & appearance")];
    UIStackView *identityStack = nil;
    UIView *identityCard =
        [self upstreamSettingsCardWithTitle:@"Receiver identity" stack:&identityStack];
    identityCard.backgroundColor = PANEL;
    identityCard.layer.borderColor =
        [UIColor colorWithRed:64/255.0 green:74/255.0 blue:80/255.0 alpha:1].CGColor;

    NSString *savedManufacturer = [settingsDefaults stringForKey:@"iPlayManufacturer"];
    NSString *savedModel = [settingsDefaults stringForKey:@"iPlayModel"];
    if (savedManufacturer.length == 0) savedManufacturer = @"DiPlay";
    if (savedModel.length == 0) savedModel = @"DiPlay";

    [identityStack addArrangedSubview:
        [self upstreamLabel:@"Manufacturer" size:18 color:SECONDARY bold:NO]];
    UITextField *manufacturerField = [[UITextField alloc] init];
    manufacturerField.text = savedManufacturer;
    manufacturerField.textColor = TEXT;
    manufacturerField.backgroundColor =
        [UIColor colorWithRed:28/255.0 green:36/255.0 blue:42/255.0 alpha:1];
    manufacturerField.layer.cornerRadius = 12;
    manufacturerField.font = [UIFont systemFontOfSize:17];
    manufacturerField.autocorrectionType = UITextAutocorrectionTypeNo;
    manufacturerField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    manufacturerField.clearButtonMode = UITextFieldViewModeWhileEditing;
    manufacturerField.leftView =
        [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 1)];
    manufacturerField.leftViewMode = UITextFieldViewModeAlways;
    [manufacturerField.heightAnchor constraintEqualToConstant:52].active = YES;
    __weak UITextField *weakManufacturerField = manufacturerField;
    [manufacturerField addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        NSString *value =
            [weakManufacturerField.text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (value.length > 0)
            [settingsDefaults setObject:value forKey:@"iPlayManufacturer"];
        else
            [settingsDefaults removeObjectForKey:@"iPlayManufacturer"];
    }] forControlEvents:UIControlEventEditingChanged];
    [identityStack addArrangedSubview:manufacturerField];

    [identityStack addArrangedSubview:
        [self upstreamLabel:@"Model" size:18 color:SECONDARY bold:NO]];
    UITextField *modelField = [[UITextField alloc] init];
    modelField.text = savedModel;
    modelField.textColor = TEXT;
    modelField.backgroundColor =
        [UIColor colorWithRed:28/255.0 green:36/255.0 blue:42/255.0 alpha:1];
    modelField.layer.cornerRadius = 12;
    modelField.font = [UIFont systemFontOfSize:17];
    modelField.autocorrectionType = UITextAutocorrectionTypeNo;
    modelField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    modelField.clearButtonMode = UITextFieldViewModeWhileEditing;
    modelField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 1)];
    modelField.leftViewMode = UITextFieldViewModeAlways;
    [modelField.heightAnchor constraintEqualToConstant:52].active = YES;
    __weak UITextField *weakModelField = modelField;
    [modelField addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        NSString *value =
            [weakModelField.text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (value.length > 0)
            [settingsDefaults setObject:value forKey:@"iPlayModel"];
        else
            [settingsDefaults removeObjectForKey:@"iPlayModel"];
    }] forControlEvents:UIControlEventEditingChanged];
    [identityStack addArrangedSubview:modelField];

    [identityStack addArrangedSubview:
        [self upstreamLabel:@"OEM label" size:18 color:SECONDARY bold:NO]];
    UITextField *oemLabelField = [[UITextField alloc] init];
    NSString *savedOEMLabel = [settingsDefaults stringForKey:@"iPlayOEMLabel"];
    if (savedOEMLabel.length == 0) savedOEMLabel = @"BYD";
    oemLabelField.text = savedOEMLabel;
    oemLabelField.textColor = TEXT;
    oemLabelField.backgroundColor =
        [UIColor colorWithRed:28/255.0 green:36/255.0 blue:42/255.0 alpha:1];
    oemLabelField.layer.cornerRadius = 12;
    oemLabelField.font = [UIFont systemFontOfSize:17];
    oemLabelField.autocorrectionType = UITextAutocorrectionTypeNo;
    oemLabelField.autocapitalizationType = UITextAutocapitalizationTypeWords;
    oemLabelField.clearButtonMode = UITextFieldViewModeWhileEditing;
    oemLabelField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 1)];
    oemLabelField.leftViewMode = UITextFieldViewModeAlways;
    [oemLabelField.heightAnchor constraintEqualToConstant:52].active = YES;
    __weak UITextField *weakOEMLabelField = oemLabelField;
    [oemLabelField addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        NSString *value =
            [weakOEMLabelField.text stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (value.length > 0)
            [settingsDefaults setObject:value forKey:@"iPlayOEMLabel"];
        else
            [settingsDefaults removeObjectForKey:@"iPlayOEMLabel"];
    }] forControlEvents:UIControlEventEditingChanged];
    [identityStack addArrangedSubview:oemLabelField];

    [identityStack addArrangedSubview:
        [self upstreamLabel:@"AirPlay icon" size:20 color:SECONDARY bold:NO]];
    UIStackView *iconRow = [[UIStackView alloc] init];
    iconRow.axis = UILayoutConstraintAxisHorizontal;
    iconRow.alignment = UIStackViewAlignmentCenter;
    iconRow.spacing = 16;

    UIImageView *iconPreview = [[UIImageView alloc] initWithImage:[self currentAirPlayIconImage]];
    iconPreview.contentMode = UIViewContentModeScaleAspectFill;
    iconPreview.clipsToBounds = YES;
    iconPreview.layer.cornerRadius = 8;
    iconPreview.backgroundColor =
        [UIColor colorWithRed:64/255.0 green:74/255.0 blue:80/255.0 alpha:1];
    [iconPreview.widthAnchor constraintEqualToConstant:72].active = YES;
    [iconPreview.heightAnchor constraintEqualToConstant:72].active = YES;
    [iconRow addArrangedSubview:iconPreview];

    UIStackView *iconActions = [[UIStackView alloc] init];
    iconActions.axis = UILayoutConstraintAxisVertical;
    iconActions.spacing = 8;
    UIButton *chooseIcon = [UIButton buttonWithType:UIButtonTypeCustom];
    [chooseIcon setTitle:@"Choose image" forState:UIControlStateNormal];
    [self styleUpstreamButton:chooseIcon primary:NO];
    [chooseIcon.heightAnchor constraintEqualToConstant:52].active = YES;
    [chooseIcon addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        [self chooseAirPlayIconForPreview:iconPreview];
    }] forControlEvents:UIControlEventTouchUpInside];
    [iconActions addArrangedSubview:chooseIcon];

    UIButton *defaultIcon = [UIButton buttonWithType:UIButtonTypeCustom];
    [defaultIcon setTitle:@"Default icon" forState:UIControlStateNormal];
    [self styleUpstreamButton:defaultIcon primary:NO];
    [defaultIcon.heightAnchor constraintEqualToConstant:52].active = YES;
    [defaultIcon addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        [self restoreDefaultAirPlayIconForPreview:iconPreview];
    }] forControlEvents:UIControlEventTouchUpInside];
    [iconActions addArrangedSubview:defaultIcon];
    [iconRow addArrangedSubview:iconActions];
    [identityStack addArrangedSubview:iconRow];

    [identityStack addArrangedSubview:[self upstreamLabel:
        @"Manufacturer, model, OEM label and the square AirPlay icon are published by the real receiver after Save and reconnect."
        size:14 color:SECONDARY bold:NO]];
    [root addArrangedSubview:identityCard];

    [root addArrangedSubview:categoryLabel(@"Display & video")];

    UIStackView *displayStack = nil;
    UIView *display = [self upstreamSettingsCardWithTitle:@"Active CarPlay display" stack:&displayStack];
    display.backgroundColor = PANEL;
    display.layer.borderColor = [UIColor colorWithRed:64/255.0 green:74/255.0 blue:80/255.0 alpha:1].CGColor;

    [displayStack addArrangedSubview:
        [self upstreamLabel:@"Physical size basis" size:20 color:SECONDARY bold:NO]];
    UISegmentedControl *physicalBasis = [[UISegmentedControl alloc]
        initWithItems:@[@"Widest width", @"Longest height"]];
    NSInteger physicalBasisValue =
        [settingsDefaults integerForKey:@"iPlayPhysicalSizeBasis"] == 1 ? 1 : 0;
    physicalBasis.selectedSegmentIndex = physicalBasisValue;
    physicalBasis.selectedSegmentTintColor = ACCENT;
    __weak UISegmentedControl *weakPhysicalBasis = physicalBasis;
    [physicalBasis addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        [settingsDefaults setInteger:(weakPhysicalBasis.selectedSegmentIndex == 1 ? 1 : 0)
                              forKey:@"iPlayPhysicalSizeBasis"];
    }] forControlEvents:UIControlEventValueChanged];
    [displayStack addArrangedSubview:physicalBasis];

    UIStackView *physicalHeader = [[UIStackView alloc] init];
    physicalHeader.axis = UILayoutConstraintAxisHorizontal;
    physicalHeader.alignment = UIStackViewAlignmentCenter;
    [physicalHeader addArrangedSubview:[self upstreamLabel:@"Physical length"
                                                      size:20 color:SECONDARY bold:NO]];
    UILabel *physicalValue = [self upstreamLabel:@"" size:24 color:ACCENT bold:YES];
    [physicalHeader addArrangedSubview:[[UIView alloc] init]];
    [physicalHeader addArrangedSubview:physicalValue];
    [displayStack addArrangedSubview:physicalHeader];

    NSInteger widthPhysical = [settingsDefaults integerForKey:@"iPlayPhysicalWidthMm"];
    if (widthPhysical < 100 || widthPhysical > 400) widthPhysical = 200;
    widthPhysical = 100 + (NSInteger)llround((widthPhysical - 100) / 50.0) * 50;
    physicalValue.text = [NSString stringWithFormat:@"%ld mm", (long)widthPhysical];

    UISlider *physicalSlider = [[UISlider alloc] init];
    physicalSlider.minimumValue = 0;
    physicalSlider.maximumValue = 6;
    physicalSlider.value = (widthPhysical - 100) / 50.0;
    physicalSlider.minimumTrackTintColor = ACCENT;
    physicalSlider.maximumTrackTintColor =
        [UIColor colorWithRed:64/255.0 green:74/255.0 blue:80/255.0 alpha:1];
    __weak UISlider *weakPhysicalSlider = physicalSlider;
    __weak UILabel *weakPhysicalValue = physicalValue;
    [physicalSlider addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        NSInteger step = (NSInteger)llround(weakPhysicalSlider.value);
        weakPhysicalSlider.value = step;
        NSInteger value = 100 + step * 50;
        weakPhysicalValue.text = [NSString stringWithFormat:@"%ld mm", (long)value];
        [settingsDefaults setInteger:value forKey:@"iPlayPhysicalWidthMm"];
    }] forControlEvents:UIControlEventValueChanged];
    [displayStack addArrangedSubview:physicalSlider];

    UIStackView *physicalRange = [[UIStackView alloc] init];
    physicalRange.axis = UILayoutConstraintAxisHorizontal;
    [physicalRange addArrangedSubview:[self upstreamLabel:@"100 mm" size:15 color:SECONDARY bold:NO]];
    [physicalRange addArrangedSubview:[[UIView alloc] init]];
    [physicalRange addArrangedSubview:[self upstreamLabel:@"400 mm" size:15 color:SECONDARY bold:NO]];
    [displayStack addArrangedSubview:physicalRange];

    UIStackView *resolutionHeader = [[UIStackView alloc] init];
    resolutionHeader.axis = UILayoutConstraintAxisHorizontal;
    resolutionHeader.alignment = UIStackViewAlignmentCenter;
    [resolutionHeader addArrangedSubview:[self upstreamLabel:@"Resolution"
                                                        size:20 color:SECONDARY bold:NO]];
    UILabel *resolutionValue = [self upstreamLabel:@"" size:24 color:ACCENT bold:YES];
    [resolutionHeader addArrangedSubview:[[UIView alloc] init]];
    [resolutionHeader addArrangedSubview:resolutionValue];
    [displayStack addArrangedSubview:resolutionHeader];

    NSInteger scale = [settingsDefaults integerForKey:@"iPlayDisplayScaleTenths"];
    if (scale < 3 || scale > 10) scale = 10;
    resolutionValue.text =
        [NSString stringWithFormat:@"%ld.%ldx", (long)(scale / 10), (long)(scale % 10)];

    UISlider *resolutionSlider = [[UISlider alloc] init];
    resolutionSlider.minimumValue = 3;
    resolutionSlider.maximumValue = 10;
    resolutionSlider.value = scale;
    resolutionSlider.minimumTrackTintColor = ACCENT;
    resolutionSlider.maximumTrackTintColor =
        [UIColor colorWithRed:64/255.0 green:74/255.0 blue:80/255.0 alpha:1];
    __weak UISlider *weakResolutionSlider = resolutionSlider;
    __weak UILabel *weakResolutionValue = resolutionValue;
    [resolutionSlider addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        NSInteger value = (NSInteger)llround(weakResolutionSlider.value);
        value = MAX(3, MIN(10, value));
        weakResolutionSlider.value = value;
        weakResolutionValue.text =
            [NSString stringWithFormat:@"%ld.%ldx", (long)(value / 10), (long)(value % 10)];
        [settingsDefaults setInteger:value forKey:@"iPlayDisplayScaleTenths"];
    }] forControlEvents:UIControlEventValueChanged];
    [displayStack addArrangedSubview:resolutionSlider];

    UIStackView *resolutionRange = [[UIStackView alloc] init];
    resolutionRange.axis = UILayoutConstraintAxisHorizontal;
    [resolutionRange addArrangedSubview:[self upstreamLabel:@"0.3x" size:15 color:SECONDARY bold:NO]];
    [resolutionRange addArrangedSubview:[[UIView alloc] init]];
    [resolutionRange addArrangedSubview:[self upstreamLabel:@"1.0x" size:15 color:SECONDARY bold:NO]];
    [displayStack addArrangedSubview:resolutionRange];

    UIStackView *fpsHeader = [[UIStackView alloc] init];
    fpsHeader.axis = UILayoutConstraintAxisHorizontal;
    fpsHeader.alignment = UIStackViewAlignmentCenter;
    [fpsHeader addArrangedSubview:[self upstreamLabel:@"Frame rate"
                                                 size:20 color:SECONDARY bold:NO]];
    UILabel *fpsValueLabel = [self upstreamLabel:@"" size:24 color:ACCENT bold:YES];
    [fpsHeader addArrangedSubview:[[UIView alloc] init]];
    [fpsHeader addArrangedSubview:fpsValueLabel];
    [displayStack addArrangedSubview:fpsHeader];

    NSInteger fpsValue = [settingsDefaults integerForKey:@"iPlayFrameRate"];
    if (fpsValue < 30 || fpsValue > 60) fpsValue = 60;
    fpsValue = 30 + (NSInteger)llround((fpsValue - 30) / 5.0) * 5;
    fpsValueLabel.text = [NSString stringWithFormat:@"%ld fps", (long)fpsValue];

    UISlider *fpsSlider = [[UISlider alloc] init];
    fpsSlider.minimumValue = 0;
    fpsSlider.maximumValue = 6;
    fpsSlider.value = (fpsValue - 30) / 5.0;
    fpsSlider.minimumTrackTintColor = ACCENT;
    fpsSlider.maximumTrackTintColor =
        [UIColor colorWithRed:64/255.0 green:74/255.0 blue:80/255.0 alpha:1];
    __weak UISlider *weakFPSSlider = fpsSlider;
    __weak UILabel *weakFPSValueLabel = fpsValueLabel;
    [fpsSlider addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        NSInteger step = (NSInteger)llround(weakFPSSlider.value);
        weakFPSSlider.value = step;
        NSInteger value = 30 + step * 5;
        weakFPSValueLabel.text = [NSString stringWithFormat:@"%ld fps", (long)value];
        [settingsDefaults setInteger:value forKey:@"iPlayFrameRate"];
    }] forControlEvents:UIControlEventValueChanged];
    [displayStack addArrangedSubview:fpsSlider];

    [displayStack addArrangedSubview:[self upstreamLabel:@"Music buffer" size:20 color:SECONDARY bold:NO]];
    UISegmentedControl *musicBuffer = [[UISegmentedControl alloc]
        initWithItems:@[@"300 ms", @"500 ms", @"1000 ms"]];
    NSInteger musicBufferMs =
        [[NSUserDefaults standardUserDefaults] integerForKey:@"iPlayMusicBufferMs"];
    if (musicBufferMs != 300 && musicBufferMs != 500 && musicBufferMs != 1000)
        musicBufferMs = 300;
    musicBuffer.selectedSegmentIndex =
        musicBufferMs == 300 ? 0 : (musicBufferMs == 500 ? 1 : 2);
    musicBuffer.selectedSegmentTintColor = ACCENT;
    __weak UISegmentedControl *weakMusicBuffer = musicBuffer;
    [musicBuffer addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        NSInteger index = weakMusicBuffer.selectedSegmentIndex;
        NSInteger value = index == 0 ? 300 : (index == 1 ? 500 : 1000);
        [[NSUserDefaults standardUserDefaults]
            setInteger:value forKey:@"iPlayMusicBufferMs"];
    }] forControlEvents:UIControlEventValueChanged];
    [displayStack addArrangedSubview:musicBuffer];

    UIStackView *hevcRow = [[UIStackView alloc] init];
    hevcRow.axis = UILayoutConstraintAxisHorizontal;
    hevcRow.alignment = UIStackViewAlignmentCenter;
    hevcRow.spacing = 16;
    UIStackView *hevcText = [[UIStackView alloc] init];
    hevcText.axis = UILayoutConstraintAxisVertical;
    hevcText.spacing = 5;
    [hevcText addArrangedSubview:[self upstreamLabel:@"Efficient video · HEVC (H.265)"
                                               size:20 color:SECONDARY bold:NO]];
    [hevcText addArrangedSubview:[self upstreamLabel:
        @"Advertise HEVC for the CarPlay screen stream. Applies after reconnect."
        size:14 color:SECONDARY bold:NO]];
    [hevcRow addArrangedSubview:hevcText];
    UISwitch *hevcSwitch = [[UISwitch alloc] init];
    hevcSwitch.onTintColor = ACCENT;
    hevcSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:@"iPlayHEVC"];
    __weak UISwitch *weakHevcSwitch = hevcSwitch;
    [hevcSwitch addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        [[NSUserDefaults standardUserDefaults]
            setBool:weakHevcSwitch.isOn forKey:@"iPlayHEVC"];
    }] forControlEvents:UIControlEventValueChanged];
    [hevcRow addArrangedSubview:hevcSwitch];
    [displayStack addArrangedSubview:hevcRow];

    UIStackView *rhdRow = [[UIStackView alloc] init];
    rhdRow.axis = UILayoutConstraintAxisHorizontal;
    rhdRow.alignment = UIStackViewAlignmentCenter;
    rhdRow.spacing = 16;
    UIStackView *rhdText = [[UIStackView alloc] init];
    rhdText.axis = UILayoutConstraintAxisVertical;
    rhdText.spacing = 5;
    [rhdText addArrangedSubview:[self upstreamLabel:@"Right-hand drive"
                                              size:20 color:SECONDARY bold:NO]];
    [rhdText addArrangedSubview:[self upstreamLabel:
        @"Report right-hand-drive layout so CarPlay places driver-side controls correctly."
        size:14 color:SECONDARY bold:NO]];
    [rhdRow addArrangedSubview:rhdText];
    UISwitch *rhdSwitch = [[UISwitch alloc] init];
    rhdSwitch.onTintColor = ACCENT;
    rhdSwitch.on =
        [[NSUserDefaults standardUserDefaults] boolForKey:@"iPlayRightHandDrive"];
    __weak UISwitch *weakRhdSwitch = rhdSwitch;
    [rhdSwitch addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        [[NSUserDefaults standardUserDefaults]
            setBool:weakRhdSwitch.isOn forKey:@"iPlayRightHandDrive"];
    }] forControlEvents:UIControlEventValueChanged];
    [rhdRow addArrangedSubview:rhdSwitch];
    [displayStack addArrangedSubview:rhdRow];

    UIStackView *fullRow = [[UIStackView alloc] init];
    fullRow.axis = UILayoutConstraintAxisHorizontal;
    fullRow.alignment = UIStackViewAlignmentCenter;
    UIStackView *fullText = [[UIStackView alloc] init];
    fullText.axis = UILayoutConstraintAxisVertical;
    fullText.spacing = 5;
    [fullText addArrangedSubview:[self upstreamLabel:@"Full screen" size:20 color:SECONDARY bold:NO]];
    [fullText addArrangedSubview:[self upstreamLabel:@"Fill the iPhone display while CarPlay is open." size:14 color:SECONDARY bold:NO]];
    [fullRow addArrangedSubview:fullText];
    UISwitch *fullSwitch = [[UISwitch alloc] init];
    fullSwitch.onTintColor = ACCENT;
    if ([[NSUserDefaults standardUserDefaults] objectForKey:@"iPlayFullScreen"] == nil)
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"iPlayFullScreen"];
    fullSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:@"iPlayFullScreen"];
    __weak UISwitch *weakFullSwitch = fullSwitch;
    [fullSwitch addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        [[NSUserDefaults standardUserDefaults] setBool:weakFullSwitch.isOn forKey:@"iPlayFullScreen"];
        if (self.state == StateActive && [self isPhone]) {
            self.vc.fullscreenMode = weakFullSwitch.isOn;
            [self.vc.view setNeedsLayout];
            [self.vc.view layoutIfNeeded];
        }
    }] forControlEvents:UIControlEventValueChanged];
    [fullRow addArrangedSubview:fullSwitch];
    [displayStack addArrangedSubview:fullRow];
    [root addArrangedSubview:display];

    [root addArrangedSubview:categoryLabel(@"Audio")];
    UIStackView *audioStack = nil;
    UIView *audioCard = [self upstreamSettingsCardWithTitle:@"Audio routing" stack:&audioStack];
    audioCard.backgroundColor = PANEL;
    audioCard.layer.borderColor =
        [UIColor colorWithRed:64/255.0 green:74/255.0 blue:80/255.0 alpha:1].CGColor;

    UIStackView *audioFocusRow = [[UIStackView alloc] init];
    audioFocusRow.axis = UILayoutConstraintAxisHorizontal;
    audioFocusRow.alignment = UIStackViewAlignmentCenter;
    audioFocusRow.spacing = 16;
    UIStackView *audioFocusText = [[UIStackView alloc] init];
    audioFocusText.axis = UILayoutConstraintAxisVertical;
    audioFocusText.spacing = 5;
    [audioFocusText addArrangedSubview:[self upstreamLabel:@"Audio focus"
                                                     size:20 color:SECONDARY bold:NO]];
    [audioFocusText addArrangedSubview:[self upstreamLabel:
        @"When enabled, CarPlay owns playback focus. Disable it to mix with other iPhone audio."
        size:14 color:SECONDARY bold:NO]];
    [audioFocusRow addArrangedSubview:audioFocusText];
    UISwitch *audioFocusSwitch = [[UISwitch alloc] init];
    audioFocusSwitch.onTintColor = ACCENT;
    BOOL audioFocusEnabled =
        [[NSUserDefaults standardUserDefaults] objectForKey:@"iPlayAudioFocus"] == nil
            ? YES
            : [[NSUserDefaults standardUserDefaults] boolForKey:@"iPlayAudioFocus"];
    audioFocusSwitch.on = audioFocusEnabled;
    __weak UISwitch *weakAudioFocusSwitch = audioFocusSwitch;
    [audioFocusSwitch addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        [[NSUserDefaults standardUserDefaults]
            setBool:weakAudioFocusSwitch.isOn forKey:@"iPlayAudioFocus"];
    }] forControlEvents:UIControlEventValueChanged];
    [audioFocusRow addArrangedSubview:audioFocusSwitch];
    [audioStack addArrangedSubview:audioFocusRow];
    [root addArrangedSubview:audioCard];

    [root addArrangedSubview:categoryLabel(@"Location")];
    UIStackView *locationStack = nil;
    UIView *locationCard =
        [self upstreamSettingsCardWithTitle:@"Report location to iPhone" stack:&locationStack];
    locationCard.backgroundColor = PANEL;
    locationCard.layer.borderColor =
        [UIColor colorWithRed:64/255.0 green:74/255.0 blue:80/255.0 alpha:1].CGColor;

    UIStackView *locationRow = [[UIStackView alloc] init];
    locationRow.axis = UILayoutConstraintAxisHorizontal;
    locationRow.alignment = UIStackViewAlignmentCenter;
    locationRow.spacing = 16;
    UIStackView *locationText = [[UIStackView alloc] init];
    locationText.axis = UILayoutConstraintAxisVertical;
    locationText.spacing = 5;
    [locationText addArrangedSubview:
        [self upstreamLabel:@"LocationInformation" size:20 color:SECONDARY bold:NO]];
    [locationText addArrangedSubview:[self upstreamLabel:
        @"A → A only. CarPlay requests the stream over iAP2; iPlay then sends the current GPS fix once per second."
        size:14 color:SECONDARY bold:NO]];
    [locationRow addArrangedSubview:locationText];

    UISwitch *locationSwitch = [[UISwitch alloc] init];
    locationSwitch.onTintColor = ACCENT;
    locationSwitch.on = [settingsDefaults boolForKey:@"iPlayLocationReport"];
    __weak UISwitch *weakLocationSwitch = locationSwitch;
    [locationSwitch addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        [settingsDefaults setBool:weakLocationSwitch.isOn forKey:@"iPlayLocationReport"];
    }] forControlEvents:UIControlEventValueChanged];
    [locationRow addArrangedSubview:locationSwitch];
    [locationStack addArrangedSubview:locationRow];
    [root addArrangedSubview:locationCard];

    [root addArrangedSubview:categoryLabel(@"Diagnostics")];
    UIStackView *diagnosticStack = nil;
    UIView *diagnosticCard =
        [self upstreamSettingsCardWithTitle:@"Receiver logs" stack:&diagnosticStack];
    diagnosticCard.backgroundColor = PANEL;
    diagnosticCard.layer.borderColor =
        [UIColor colorWithRed:64/255.0 green:74/255.0 blue:80/255.0 alpha:1].CGColor;
    [diagnosticStack addArrangedSubview:[self upstreamLabel:
        @"Export the live iPlay application and receiver log as a local text report."
        size:15 color:SECONDARY bold:NO]];
    UIButton *exportLogs = [UIButton buttonWithType:UIButtonTypeCustom];
    [exportLogs setTitle:@"Save diagnostic report" forState:UIControlStateNormal];
    [self styleUpstreamButton:exportLogs primary:NO];
    [exportLogs.heightAnchor constraintEqualToConstant:56].active = YES;
    [exportLogs addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        [self exportDiagnostics];
    }] forControlEvents:UIControlEventTouchUpInside];
    [diagnosticStack addArrangedSubview:exportLogs];
    [root addArrangedSubview:diagnosticCard];

    [root addArrangedSubview:categoryLabel(@"Local connection")];
    UIStackView *localStack = nil;
    UIView *localCard = [self upstreamSettingsCardWithTitle:@"A → A transport" stack:&localStack];
    localCard.backgroundColor = PANEL;
    localCard.layer.borderColor = [UIColor colorWithRed:64/255.0 green:74/255.0 blue:80/255.0 alpha:1].CGColor;
    [localStack addArrangedSubview:[self upstreamLabel:
        @"LocalDevVPN + trusted Remote Pairing/RSD CarKit carries the real local CarPlay session."
        size:16 color:SECONDARY bold:NO]];
    UIButton *iosSettings = [UIButton buttonWithType:UIButtonTypeCustom];
    [iosSettings setTitle:@"Open iOS Settings" forState:UIControlStateNormal];
    [self styleUpstreamButton:iosSettings primary:NO];
    [iosSettings.heightAnchor constraintEqualToConstant:56].active = YES;
    [iosSettings addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }] forControlEvents:UIControlEventTouchUpInside];
    [localStack addArrangedSubview:iosSettings];
    [root addArrangedSubview:localCard];

    UILabel *applyHint = [self upstreamLabel:
        @"Physical size, resolution, frame rate, HEVC, driving side, music buffer and audio routing are applied by the real receiver runtime when the CarPlay session reconnects."
        size:15 color:SECONDARY bold:NO];
    [root addArrangedSubview:applyHint];

    UIButton *save = [UIButton buttonWithType:UIButtonTypeCustom];
    [save setTitle:(self.state == StateActive ? @"Save and reconnect" : @"Save") forState:UIControlStateNormal];
    [save setTitleColor:[UIColor colorWithRed:8/255.0 green:17/255.0 blue:11/255.0 alpha:1]
               forState:UIControlStateNormal];
    save.backgroundColor = ACCENT;
    save.layer.cornerRadius = 14;
    save.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [save.heightAnchor constraintEqualToConstant:54].active = YES;
    [save addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        BOOL reconnect = (self.state == StateActive);
        NSInteger mode = self.sideStoreMode;
        [settingsDefaults setInteger:mode forKey:@"iPlayLastMode"];
        [weakSettings dismissViewControllerAnimated:YES completion:^{
            if (reconnect) {
                [self stopFlow];
                [self restartWhenIdleForMode:mode attemptsRemaining:100];
            } else {
                [self renderState];
            }
        }];
    }] forControlEvents:UIControlEventTouchUpInside];
    [root addArrangedSubview:save];

    UIButton *disconnect = [UIButton buttonWithType:UIButtonTypeCustom];
    [disconnect setTitle:@"Disconnect CarPlay" forState:UIControlStateNormal];
    [disconnect setTitleColor:TEXT forState:UIControlStateNormal];
    disconnect.backgroundColor = DANGER;
    disconnect.layer.cornerRadius = 14;
    disconnect.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [disconnect.heightAnchor constraintEqualToConstant:54].active = YES;
    disconnect.hidden = (self.state != StateActive && self.state != StateAwaitingPhone);
    [disconnect addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        (void)action;
        restoreBaseline();
        [weakSettings dismissViewControllerAnimated:YES completion:^{
            [self stopFlow];
        }];
    }] forControlEvents:UIControlEventTouchUpInside];
    [root addArrangedSubview:disconnect];

    [self.vc presentViewController:settings animated:YES completion:nil];
}

#include "upstream_ui.inc"

- (void)buildChrome {
    /*
     * Match upstream CarPlayHostActivity.onHostTouch(): no permanent fake
     * overlay or pause chrome. A three-finger downward swipe opens the
     * functional settings surface; ordinary one/two-finger input remains
     * owned by the CarPlay touch path.
     */
    UIView *content = [self rootContentView];

    self.controlsGesture = [[ThreeFingerSwipeDownGestureRecognizer alloc]
        initWithTarget:self action:@selector(toggleChrome:)];
    self.controlsGesture.enabled = NO;
    [content addGestureRecognizer:self.controlsGesture];
}

- (BOOL)isPhone {
    return UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone;
}

/* ─── State machine ────────────────────────────────────────── */

- (void)transitionTo:(ShowcaseState)s {
    ShowcaseState old = self.state;
    self.state = s;

    if (s == StateAwaitingPhone && old != StateAwaitingPhone) {
        ip_log("[HANDOFF] Awaiting sender; CarPlay should perform Wi-Fi association through iAP2 handoff");
        if (self.diagnosticsEnabled)
            ip_log("diagnostics active; tcpdump remains off unless requested manually");
    } else if ((s == StateStopping || s == StateIdle) && old != s) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopNetworkDumpCaptureWithReason:@"flow stopped"];
        });
    }

    dispatch_async(dispatch_get_main_queue(), ^{ [self renderState]; });
}

- (void)renderState {
    [self layoutUpstreamHomeReal];

    self.setupOverlay.hidden = NO;
    self.controlsGesture.enabled = (self.state == StateActive);
    if (self.state != StateActive) {
        /* Restore the 1024x768 canvas in every non-Active state. */
        if ([self isPhone] && self.vc.fullscreenMode) {
            self.vc.fullscreenMode = NO;
            [self.vc.view setNeedsLayout];
        }
        self.videoView.transform = CGAffineTransformIdentity;
    }
    self.spinner.hidden = YES; [self.spinner stopAnimating];
    self.primaryButton.hidden = YES;
    self.primaryButton.enabled = YES;
    self.primaryButton.alpha = 1.0;
    self.secondaryButton.hidden = YES;
    self.tertiaryButton.hidden = YES;
    self.receiverButton.hidden = YES;
    self.carHintLabel.hidden = YES;

    Car *sel = self.cars.selected;

    switch (self.state) {
        case StateIdle: {
            self.primaryButton.hidden = NO;
            self.primaryButton.enabled = YES;
            self.primaryButton.alpha = 1.0;

            if (iPlayIsStockSideStoreBuild()) {
                /* Stock / SideStore build: no hotspot, jailbreak tooling, or saved-car
                 * setup is required before choosing a mode. */
                self.headlineLabel.text = @"Ready when you are";
                self.subtitleLabel.text = @"Keep LocalDevVPN enabled. First run pairs iPlay with this iPhone through Developer Mode.";
                [self.primaryButton setTitle:@"Connect phone" forState:UIControlStateNormal];
                [self.secondaryButton setTitle:@"Connection mode" forState:UIControlStateNormal];
                [self.tertiaryButton setTitle:@"Settings" forState:UIControlStateNormal];
                [self.receiverButton setTitle:@"Receive from another iPhone" forState:UIControlStateNormal];
                self.secondaryButton.hidden = NO;
                self.tertiaryButton.hidden = NO;
                self.receiverButton.hidden = NO;
                self.carHintLabel.text = @"A → A uses LocalDevVPN + trusted Remote Pairing.";
                self.carHintLabel.hidden = NO;
                break;
            }

            BOOL apReady = [self.cars apReady];
            if (!apReady) {
                /* Jailbreak legacy receiver mode only. */
                self.headlineLabel.text = @"Welcome";
                self.subtitleLabel.text = @"Before connecting your iPhone, we need to know\nyour iPad's hotspot details.";
                [self.primaryButton setTitle:@"Set Up Wi-Fi" forState:UIControlStateNormal];
                [self.tertiaryButton setTitle:@"My Cars  ›" forState:UIControlStateNormal];
                self.tertiaryButton.hidden = NO;
                self.carHintLabel.text = @"";
                self.carHintLabel.hidden = YES;
            } else {
                if (self.baaLoading) {
                    self.headlineLabel.text = @"Preparing secure authentication";
                    self.subtitleLabel.text = @"Keep this device online for a moment.\nThis happens before Personal Hotspot starts.";
                    [self.primaryButton setTitle:@"Preparing…" forState:UIControlStateNormal];
                    self.primaryButton.enabled = NO;
                    self.primaryButton.alpha = 0.55;
                    self.spinner.hidden = NO;
                    [self.spinner startAnimating];
                } else if (!self.baaReady) {
                    self.headlineLabel.text = @"Internet connection required";
                    self.subtitleLabel.text = self.baaError.length
                        ? @"iPlay could not prepare CarPlay authentication.\nConnect to the internet, then retry."
                        : @"iPlay needs internet once before Personal Hotspot starts.";
                    [self.primaryButton setTitle:@"Retry Authentication"
                                       forState:UIControlStateNormal];
                } else {
                    self.headlineLabel.text = @"Wireless CarPlay";
                    self.subtitleLabel.text = @"Connect your iPhone wirelessly\nto this device as a CarPlay screen.";
                    [self.primaryButton setTitle:@"Start CarPlay"
                                       forState:UIControlStateNormal];
                }

                NSString *wifiTitle = [NSString stringWithFormat:@"Wi-Fi: %@", self.cars.apSSID];
                [self.secondaryButton setTitle:wifiTitle forState:UIControlStateNormal];
                self.secondaryButton.hidden = NO;
                [self.tertiaryButton setTitle:@"My Cars  ›" forState:UIControlStateNormal];
                self.tertiaryButton.hidden = NO;
                self.carHintLabel.text = sel
                    ? [NSString stringWithFormat:@"Currently using: %@", sel.name]
                    : @"";
                self.carHintLabel.hidden = NO;
            }
            break;
        }

        case StateAwaitingAP:
            self.headlineLabel.text = @"Turn on Personal Hotspot";
            self.subtitleLabel.text = @"Settings › Personal Hotspot\nAllow Others to Join";
            [self.primaryButton setTitle:@"Open Settings" forState:UIControlStateNormal];
            self.primaryButton.hidden = NO;
            [self.secondaryButton setTitle:@"Cancel" forState:UIControlStateNormal];
            self.secondaryButton.hidden = NO;
            break;

        case StatePreparingBT:
            self.headlineLabel.text = @"Preparing Bluetooth";
            self.subtitleLabel.text = @"Starting Bluetooth daemon…";
            self.spinner.hidden = NO; [self.spinner startAnimating];
            break;

        case StatePreparingNet:
            self.headlineLabel.text = @"Starting CarPlay services";
            self.subtitleLabel.text = @"Almost ready…";
            self.spinner.hidden = NO; [self.spinner startAnimating];
            break;

        case StateAwaitingPhone:
            if (iPlayIsStockSideStoreBuild() && self.sideStoreMode == 0) {
                self.headlineLabel.text = @"Starting CarPlay on this iPhone";
                self.subtitleLabel.text = @"Keep LocalDevVPN enabled. If this is the first run, approve iPlay under Settings › Privacy & Security › Developer Mode when prompted.";
            } else {
                self.headlineLabel.text = @"Connect from your iPhone";
                /* A → B receiver mode behaves like an external head unit. */
                if (self.subtitleLabel.text.length == 0 ||
                    ![self.subtitleLabel.text containsString:@"\n"]) {
                    self.subtitleLabel.text = sel
                        ? [NSString stringWithFormat:@"Settings › General › CarPlay\nSelect %@", sel.name]
                        : @"Settings › General › CarPlay";
                }
            }
            self.spinner.hidden = NO; [self.spinner startAnimating];
            [self.secondaryButton setTitle:@"Cancel" forState:UIControlStateNormal];
            self.secondaryButton.hidden = NO;
            break;

        case StateActive:
            self.setupOverlay.hidden = YES;
            if ([self isPhone]) {
                BOOL fullScreen = [[NSUserDefaults standardUserDefaults] objectForKey:@"iPlayFullScreen"] == nil
                    ? YES : [[NSUserDefaults standardUserDefaults] boolForKey:@"iPlayFullScreen"];
                self.vc.fullscreenMode = fullScreen;
                [self.vc.view setNeedsLayout];
            }
            self.videoView.transform = CGAffineTransformIdentity;
                break;

        case StateStopping:
            self.headlineLabel.text = @"Stopping";
            self.subtitleLabel.text = @"";
            self.spinner.hidden = NO; [self.spinner startAnimating];
            break;
    }
}

- (void)showSideStoreModePicker {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"iPlay CarPlay"
        message:@"For A → A, keep LocalDevVPN enabled. iPlay pairs with this iPhone through Developer Mode and starts CarPlay locally; it does not require a vehicle to appear first in Settings › General › CarPlay."
        preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"CarPlay on This iPhone (A → A)"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            self.sideStoreMode = 0;
            [self attemptStart];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Receive from Another iPhone (A → B)"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            self.sideStoreMode = 1;
            [self attemptStart];
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Connect This iPhone to Another iPlay (A → B)"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            self.sideStoreMode = 2;
            self.headlineLabel.text = @"Finding iPlay";
            self.subtitleLabel.text = @"Looking for a receiver on the local network…";
            dispatch_async(self.bgQueue, ^{
                NSString *host = iPlayDiscoverRemoteCarPlayReceiver(5.0);
                BOOL ok = host.length ? iPlayStartRemoteCarPlaySession(@"iPlay", host, 7000) : NO;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ok) {
                        self.headlineLabel.text = @"Starting CarPlay";
                        self.subtitleLabel.text = [NSString stringWithFormat:@"Connecting to %@", host];
                        return;
                    }

                    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"Receiver Not Found"
                        message:@"Make sure the other iPhone is running iPlay in Receive mode on the same network, or enter its IPv6/local hostname manually."
                        preferredStyle:UIAlertControllerStyleAlert];
                    [prompt addTextFieldWithConfigurationHandler:^(UITextField *f) {
                        f.placeholder = @"fe80::…%en0 or receiver.local";
                        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
                        f.autocorrectionType = UITextAutocorrectionTypeNo;
                    }];
                    [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                    [prompt addAction:[UIAlertAction actionWithTitle:@"Connect" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *x) {
                        NSString *manualHost = prompt.textFields.firstObject.text;
                        BOOL manualOK = iPlayStartRemoteCarPlaySession(@"iPlay", manualHost, 7000);
                        self.headlineLabel.text = manualOK ? @"Starting CarPlay" : @"Could not start CarPlay";
                        self.subtitleLabel.text = manualOK ? [NSString stringWithFormat:@"Connecting to %@", manualHost] : @"CarKit session request was unavailable.";
                    }]];
                    [self.vc presentViewController:prompt animated:YES completion:nil];
                });
            });
        }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.primaryButton;
        sheet.popoverPresentationController.sourceRect = self.primaryButton.bounds;
    }
    [self.vc presentViewController:sheet animated:YES completion:nil];
}

- (void)primaryTapped {
    switch (self.state) {
        case StateIdle:
            if (iPlayIsStockSideStoreBuild()) {
                self.sideStoreMode = 0;
                [self attemptStart];
            } else if ([self.cars apReady]) [self attemptStart];
            else [self showWifiSetup];
            break;
        case StateAwaitingAP:
            [self openHotspotSettings];
            break;
        default:
            break;
    }
}

- (void)secondaryTapped {
    if (self.state == StateIdle) {
        if (iPlayIsStockSideStoreBuild()) [self showSideStoreModePicker];
        else [self showWifiSetup];
    } else if (self.state != StateStopping) {
        [self stopFlow];
    }
}
- (void)tertiaryTapped {
    if (self.state != StateIdle) return;
    if (iPlayIsStockSideStoreBuild()) [self showUpstreamSettingsReal];
    else [self showCars];
}

- (void)closeTapped { [self stopFlow]; }
- (void)infoTapped  { [self showAbout]; }

- (void)toggleChrome:(ThreeFingerSwipeDownGestureRecognizer *)gesture {
    if (self.state != StateActive) return;
    if (gesture.state == UIGestureRecognizerStateEnded) {
        ip_log("[UI] upstream three-finger swipe-down opened CarPlay settings");
        [self showUpstreamSettings];
    }
}

/* ─── Action helpers ───────────────────────────────────────── */

- (void)attemptStart {
    /* Jailbreak mode still needs the receiver hotspot. SideStore modes do not. */
    if (!iPlayIsStockSideStoreBuild() && ![self.cars apReady]) { [self showWifiSetup]; return; }
    /* A SideStore A->A receiver is this app itself; it must not require a
     * legacy saved vehicle entry before the local source stack can start. */
    if (!iPlayIsStockSideStoreBuild() && self.cars.cars.count == 0) return;
    if (!self.baaReady) {
        [self preheatBAA];
        return;
    }
    [self startFlow];
}

- (void)startFlow {
    [[IPlayBackgroundAudioKeeper shared] requestStart];
    NSString *flowName = self.cars.selected.name ?: @"iPlay";
    NSString *flowSSID = self.cars.apSSID ?: @"";
    ip_log("startFlow: car='%s' ssid='%s'",
           flowName.UTF8String,
           flowSSID.UTF8String);
    self.bluetoothHandedOff = NO;
    if (iPlayIsStockSideStoreBuild() &&
        (self.sideStoreMode == 0 || self.sideStoreMode == 1)) {
        [[NSUserDefaults standardUserDefaults] setInteger:self.sideStoreMode
                                                  forKey:@"iPlayLastMode"];
    }
    if (iPlayIsStockSideStoreBuild()) {
        if (self.sideStoreMode == 0) {
            /* A -> A is local: there is no physical Bluetooth bootstrap. */
            [self transitionTo:StatePreparingNet];
            dispatch_async(self.bgQueue, ^{ [self bgPrepareNet]; });
        } else {
            [self transitionTo:StatePreparingBT];
            dispatch_async(self.bgQueue, ^{ [self bgPrepareBT]; });
        }
        return;
    }
    [self transitionTo:StateAwaitingAP];
    [self.apPollTimer invalidate];
    self.apPollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
        target:self selector:@selector(pollAP) userInfo:nil repeats:YES];
    [self pollAP];
}

- (void)beginAWDLSuppression {
    if (__sync_bool_compare_and_swap(&g_awdl_suppressed, 0, 1)) {
        awdl_suppress(YES);
        ip_log("AWDL suppressed for the duration of the session");
    }
    if (self.awdlReassertTimer) return;
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    if (!timer) return;
    dispatch_source_set_timer(
        timer,
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(AWDL_REASSERT_SECONDS * NSEC_PER_SEC)),
        (uint64_t)(AWDL_REASSERT_SECONDS * NSEC_PER_SEC),
        (uint64_t)(NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        if (g_awdl_suppressed) awdl_suppress(NO);
    });
    dispatch_resume(timer);
    self.awdlReassertTimer = timer;
}

- (void)endAWDLSuppression {
    if (self.awdlReassertTimer) {
        dispatch_source_cancel(self.awdlReassertTimer);
        self.awdlReassertTimer = nil;
    }
    if (__sync_bool_compare_and_swap(&g_awdl_suppressed, 1, 0)) {
        awdl_restore(YES);
        ip_log("AWDL restored");
    }
}

- (void)pollAP {
    if (self.state != StateAwaitingAP) {
        [self.apPollTimer invalidate]; self.apPollTimer = nil;
        return;
    }
    if (is_ap_up()) {
        ip_log("AP detected — advancing");
        [self.apPollTimer invalidate]; self.apPollTimer = nil;
        [self transitionTo:StatePreparingBT];
        dispatch_async(self.bgQueue, ^{ [self bgPrepareBT]; });
    }
}

- (void)bgPrepareBT {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *btPath = [bundlePath stringByAppendingPathComponent:@BT_HELPER_NAME];
    Car *sel = self.cars.selected;
    NSString *receiverName = sel.name ?: @"iPlay";
    NSString *receiverSSID = self.cars.apSSID ?: @"";
    ip_log("bgPrepareBT: euid=%u, name='%s' ssid='%s'",
           geteuid(), receiverName.UTF8String, receiverSSID.UTF8String);
    self.bluetoothRetryAttempted = NO;

    if (iPlayIsStockSideStoreBuild()) {
        BOOL privateBluetooth = iPlayPreparePrivateBluetooth();
        ip_log("[SIDESTORE] private Bluetooth bootstrap available=%d", privateBluetooth ? 1 : 0);
        [self transitionTo:StatePreparingNet];
        [self bgPrepareNet];
        return;
    }
    if (access([btPath fileSystemRepresentation], X_OK) != 0) {
        [self failBluetoothWithReason:
            @"The bundled Bluetooth helper is missing or is not executable."
                             unsupported:NO];
        return;
    }
    if (access(BTDAEMON_PATH, X_OK) != 0) {
        [self failBluetoothWithReason:
            @"The BTstack daemon is missing or is not executable."
                             unsupported:NO];
        return;
    }
    if (access(BTSTACK_DYLIB_PATH, R_OK) != 0) {
        [self failBluetoothWithReason:
            @"The bundled BTstack library is missing or is not readable."
                             unsupported:NO];
        return;
    }
    if (access(BTSTACK_PLIST, R_OK) != 0) {
        [self failBluetoothWithReason:
            @"The BTstack launch daemon configuration is missing or unreadable."
                             unsupported:NO];
        return;
    }

    BluetoothRegistryProbeState registry = bluetooth_registry_probe();
    ip_log("[BT-COMPAT] registry probe=%s",
           registry == BluetoothRegistryProbeLegacyUART
               ? "legacy-uart-present"
               : (registry == BluetoothRegistryProbeSkywalk
                   ? "converged-skywalk-present"
                   : (registry == BluetoothRegistryProbeMissing
                       ? "supported-transport-missing" : "unavailable")));
    if (registry == BluetoothRegistryProbeMissing) {
        [self failBluetoothWithReason:
            @"The Bluetooth transport required by Showcase is not present in IOKit."
                             unsupported:YES];
        return;
    }
    if (registry == BluetoothRegistryProbeUnavailable) {
        /* A missing ioreg utility must not create a false rejection. The
         * controller takeover below is the authoritative runtime probe. */
        ip_log("[BT-COMPAT] static probe unavailable; continuing to runtime HCI probe");
    }

    if (self.diagnosticsEnabled) {
        enable_btstack_hci_logging();
    } else {
        disable_btstack_hci_logging();
    }
    self.helpersLoggedThisRun = self.diagnosticsEnabled;
    unlink(BT_READY_PATH);

    reap_stale_helpers(self.baaBrokerPid);

    /* 1. Unload bluetoothd */
    const char *launchctl = launchctl_path();
    if (!launchctl) {
        [self failBluetoothWithReason:@"launchctl was not found."
                             unsupported:NO];
        return;
    }
    ip_log("launchctl path: %s", launchctl);
    char *unloadArgv[] = { (char*)"launchctl", (char*)"unload",
                           (char*)BLUETOOTHD_PLIST, NULL };
    int rc = run_blocking(launchctl, unloadArgv);
    if (rc != 0) ip_log("  WARNING: launchctl unload returned %d", rc);
#ifdef SHOWCASE_ROOTLESS
    char *unloadBlueToolArgv[] = { (char*)"launchctl", (char*)"unload",
                                   (char*)BLUETOOL_PLIST, NULL };
    rc = run_blocking(launchctl, unloadBlueToolArgv);
    if (rc != 0) ip_log("  WARNING: BlueTool unload returned %d", rc);
#endif
    sleep(2);

    /* 2. Start bundled BTstack through launchd so the advertised socket exists. */
    char *unloadBTstackArgv[] = { (char*)"launchctl", (char*)"unload",
                                  (char*)BTSTACK_PLIST, NULL };
    run_blocking(launchctl, unloadBTstackArgv);
    unlink(BTSTACK_SOCKET);

    char *loadBTstackArgv[] = { (char*)"launchctl", (char*)"load",
                                (char*)BTSTACK_PLIST, NULL };
    rc = run_blocking(launchctl, loadBTstackArgv);
    if (rc != 0) {
        [self failBluetoothWithReason:
            @"The BTstack launch daemon failed to load."
                             unsupported:NO];
        return;
    }
    if (!wait_for_path(BTSTACK_SOCKET, 8, "BTstack socket")) {
        [self failBluetoothWithReason:
            @"The BTstack daemon did not create its control socket."
                             unsupported:NO];
        return;
    }
    self.btdaemonPid = 0;

    /* 3. Spawn carplay_bt with car name + global AP creds */
    char nameBuf[64], ssidBuf[128], passBuf[128];
    snprintf(nameBuf, sizeof(nameBuf), "%s", receiverName.UTF8String);
    snprintf(ssidBuf, sizeof(ssidBuf), "%s", [self.cars.apSSID UTF8String]);
    snprintf(passBuf, sizeof(passBuf), "%s", [self.cars.apPassword UTF8String]);
    char *btArgv[] = {
        (char*)BT_HELPER_NAME,
        (char*)"--name", nameBuf,
        (char*)"--ssid", ssidBuf,
        (char*)"--pass", passBuf,
        NULL
    };
    self.carplayBtPid = spawn_daemon([btPath UTF8String], btArgv,
                                     LOG_DIR "/carplay_bt.log");
    if (self.carplayBtPid <= 0) {
        [self failBluetoothWithReason:
            @"The Bluetooth helper could not be started."
                             unsupported:NO];
        return;
    }
    if (!wait_for_pid_alive(self.carplayBtPid, 8, "carplay_bt")) {
        [self failBluetoothWithReason:
            @"The Bluetooth helper exited during setup."
                             unsupported:YES];
        return;
    }
    if (!wait_for_bt_ready_or_exit(self.carplayBtPid, 12)) {
        /* On some rootless boots BlueTool releases the controller after its
         * launchd job has already exited. BTstack then accepts a client and
         * its power command, but emits no HCI events. A complete daemon/client
         * restart is deterministic and preserves pairing data. */
        ip_log("[BT] first controller takeover produced no events; "
               "performing one clean retry");
        self.bluetoothRetryAttempted = YES;
        kill_pid(self.carplayBtPid);
        self.carplayBtPid = 0;
        run_blocking(launchctl, unloadBTstackArgv);
        unlink(BTSTACK_SOCKET);
        sleep(2);
        rc = run_blocking(launchctl, loadBTstackArgv);
        if (rc == 0 &&
            wait_for_path(BTSTACK_SOCKET, 8, "BTstack retry socket")) {
            unlink(BT_READY_PATH);
            self.carplayBtPid =
                spawn_daemon([btPath UTF8String], btArgv,
                             LOG_DIR "/carplay_bt-retry.log");
        }
        if (self.carplayBtPid <= 0 ||
            !wait_for_bt_ready_or_exit(self.carplayBtPid, 20)) {
            [self failBluetoothWithReason:
                @"Bluetooth takeover failed after one clean retry; no HCI "
                 "controller-ready event was received."
                                 unsupported:YES];
            return;
        }
    }

    [self transitionTo:StatePreparingNet];
    [self bgPrepareNet];
}

- (void)bgPrepareNet {
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *svcPath = [bundlePath stringByAppendingPathComponent:@SVC_HELPER_NAME];
    Car *sel = self.cars.selected;
    NSString *receiverName = sel.name ?: @"iPlay";
    NSUserDefaults *runtimeDefaults = [NSUserDefaults standardUserDefaults];
    NSString *manufacturer = [runtimeDefaults stringForKey:@"iPlayManufacturer"];
    NSString *modelName = [runtimeDefaults stringForKey:@"iPlayModel"];
    NSString *oemLabel = [runtimeDefaults stringForKey:@"iPlayOEMLabel"];
    if (manufacturer.length == 0) manufacturer = @"DiPlay";
    if (modelName.length == 0) modelName = @"DiPlay";
    if (oemLabel.length == 0) oemLabel = @"BYD";
    ip_log("bgPrepareNet: receiver='%s' mode=%ld identity='%s/%s/%s'",
           receiverName.UTF8String, (long)self.sideStoreMode,
           manufacturer.UTF8String, modelName.UTF8String, oemLabel.UTF8String);

    if (![self startIPCListener]) { [self failWith:@"IPC listener failed"]; return; }

    char nameBuf[64], manufacturerBuf[64], modelBuf[64], oemLabelBuf[64];
    char widthBuf[16], heightBuf[16], fpsBuf[16], receiveBufferBuf[16];
    char widthPhysicalBuf[16], heightPhysicalBuf[16], rightHandDriveBuf[8], hevcBuf[8];
    char safeLeftBuf[16], safeTopBuf[16], safeRightBuf[16], safeBottomBuf[16],
         safeDrawOutsideBuf[8];
    CarPlayDisplayProfile display = preferred_carplay_display_profile();
    uint16_t displayWidth = display.width;
    uint16_t displayHeight = display.height;
    /*
     * Older HSIC-attached WLAN chips need enough TCP headroom to absorb the
     * iPhone encoder's burst rate during brief loss recovery. Faster radios
     * retain a shallower window to avoid unnecessary queueing latency. A
     * 30-Hz non-HSIC display gets the middle tier, covering devices whose
     * screen refresh—not WLAN transport—sets the frame-rate ceiling.
     */
    int screenReceiveBuffer =
        display.wlanAttachment == CarPlayWLANAttachmentHSIC
            ? 2 * 1024 * 1024
            : (display.framesPerSecond <= 30 ? 1024 * 1024 : 512 * 1024);
    snprintf(nameBuf, sizeof(nameBuf), "%s", receiverName.UTF8String);
    snprintf(widthBuf, sizeof(widthBuf), "%u", displayWidth);
    snprintf(heightBuf, sizeof(heightBuf), "%u", displayHeight);
    snprintf(fpsBuf, sizeof(fpsBuf), "%u", display.framesPerSecond);
    snprintf(receiveBufferBuf, sizeof(receiveBufferBuf), "%d",
             screenReceiveBuffer);
    NSInteger referencePhysicalMm =
        [runtimeDefaults integerForKey:@"iPlayPhysicalWidthMm"];
    if (referencePhysicalMm < 100 || referencePhysicalMm > 400)
        referencePhysicalMm = 200;
    referencePhysicalMm =
        100 + (NSInteger)llround((referencePhysicalMm - 100) / 50.0) * 50;
    referencePhysicalMm = MAX(100, MIN(400, referencePhysicalMm));

    NSInteger physicalSizeBasis =
        [runtimeDefaults integerForKey:@"iPlayPhysicalSizeBasis"] == 1 ? 1 : 0;
    double maximumWidthPixels = MAX(1.0, (double)display.nativeLong);
    double maximumHeightPixels = MAX(1.0, (double)display.nativeShort);
    double currentWidthPixels = MAX(1.0, (double)displayWidth);
    double currentHeightPixels = MAX(1.0, (double)displayHeight);
    double referencePixels = physicalSizeBasis == 1
        ? currentHeightPixels / maximumHeightPixels
        : currentWidthPixels / maximumWidthPixels;
    double scaledReferenceMm = MAX(1.0, (double)referencePhysicalMm * referencePixels);
    NSInteger widthPhysicalMm = 1;
    NSInteger heightPhysicalMm = 1;
    if (physicalSizeBasis == 1) {
        heightPhysicalMm = (NSInteger)llround(scaledReferenceMm);
        widthPhysicalMm = (NSInteger)llround(
            scaledReferenceMm * currentWidthPixels / currentHeightPixels);
    } else {
        widthPhysicalMm = (NSInteger)llround(scaledReferenceMm);
        heightPhysicalMm = (NSInteger)llround(
            scaledReferenceMm * currentHeightPixels / currentWidthPixels);
    }
    widthPhysicalMm = MAX(1, MIN(2000, widthPhysicalMm));
    heightPhysicalMm = MAX(1, MIN(2000, heightPhysicalMm));

    BOOL rightHandDrive =
        [runtimeDefaults boolForKey:@"iPlayRightHandDrive"];
    BOOL hevcEnabled = [runtimeDefaults boolForKey:@"iPlayHEVC"];

    NSInteger safeLeftPm = [runtimeDefaults objectForKey:@"iPlaySafeLeftPm"]
        ? [runtimeDefaults integerForKey:@"iPlaySafeLeftPm"] : 0;
    NSInteger safeTopPm = [runtimeDefaults objectForKey:@"iPlaySafeTopPm"]
        ? [runtimeDefaults integerForKey:@"iPlaySafeTopPm"] : 0;
    NSInteger safeRightPm = [runtimeDefaults objectForKey:@"iPlaySafeRightPm"]
        ? [runtimeDefaults integerForKey:@"iPlaySafeRightPm"] : 1000;
    NSInteger safeBottomPm = [runtimeDefaults objectForKey:@"iPlaySafeBottomPm"]
        ? [runtimeDefaults integerForKey:@"iPlaySafeBottomPm"] : 1000;
    safeLeftPm = MAX(0, MIN(999, safeLeftPm));
    safeTopPm = MAX(0, MIN(999, safeTopPm));
    safeRightPm = MAX(safeLeftPm + 1, MIN(1000, safeRightPm));
    safeBottomPm = MAX(safeTopPm + 1, MIN(1000, safeBottomPm));

    NSInteger safeLeft = (NSInteger)llround(
        (double)safeLeftPm * displayWidth / 1000.0);
    NSInteger safeTop = (NSInteger)llround(
        (double)safeTopPm * displayHeight / 1000.0);
    NSInteger safeRight = (NSInteger)llround(
        (double)(1000 - safeRightPm) * displayWidth / 1000.0);
    NSInteger safeBottom = (NSInteger)llround(
        (double)(1000 - safeBottomPm) * displayHeight / 1000.0);
    safeLeft = MAX(0, MIN((NSInteger)displayWidth - 1, safeLeft));
    safeTop = MAX(0, MIN((NSInteger)displayHeight - 1, safeTop));
    safeRight = MAX(0, MIN((NSInteger)displayWidth - safeLeft - 1, safeRight));
    safeBottom = MAX(0, MIN((NSInteger)displayHeight - safeTop - 1, safeBottom));

    /* Upstream AirPlaySafeArea aligns the negotiated safe-area dimensions
     * to even pixels so the display mapping stays codec-friendly. */
    if ((((NSInteger)displayWidth - safeLeft - safeRight) & 1) != 0) {
        if (safeRight < (NSInteger)displayWidth - safeLeft - 1) safeRight++;
        else if (safeLeft > 0) safeLeft--;
    }
    if ((((NSInteger)displayHeight - safeTop - safeBottom) & 1) != 0) {
        if (safeBottom < (NSInteger)displayHeight - safeTop - 1) safeBottom++;
        else if (safeTop > 0) safeTop--;
    }

    BOOL safeDrawOutside = [runtimeDefaults objectForKey:@"iPlaySafeDrawOutside"] == nil
        ? YES : [runtimeDefaults boolForKey:@"iPlaySafeDrawOutside"];
    snprintf(manufacturerBuf, sizeof(manufacturerBuf), "%s", manufacturer.UTF8String);
    snprintf(modelBuf, sizeof(modelBuf), "%s", modelName.UTF8String);
    snprintf(oemLabelBuf, sizeof(oemLabelBuf), "%s", oemLabel.UTF8String);
    snprintf(widthPhysicalBuf, sizeof(widthPhysicalBuf), "%ld", (long)widthPhysicalMm);
    snprintf(heightPhysicalBuf, sizeof(heightPhysicalBuf), "%ld", (long)heightPhysicalMm);
    snprintf(rightHandDriveBuf, sizeof(rightHandDriveBuf), "%d", rightHandDrive ? 1 : 0);
    snprintf(hevcBuf, sizeof(hevcBuf), "%d", hevcEnabled ? 1 : 0);
    snprintf(safeLeftBuf, sizeof(safeLeftBuf), "%ld", (long)safeLeft);
    snprintf(safeTopBuf, sizeof(safeTopBuf), "%ld", (long)safeTop);
    snprintf(safeRightBuf, sizeof(safeRightBuf), "%ld", (long)safeRight);
    snprintf(safeBottomBuf, sizeof(safeBottomBuf), "%ld", (long)safeBottom);
    snprintf(safeDrawOutsideBuf, sizeof(safeDrawOutsideBuf), "%d",
             safeDrawOutside ? 1 : 0);
    ip_log("display profile: native=%ux%u memory=%lluMB cores=%lu "
           "budget=%llu pixels selected=%ux%u@%u physical=%ldx%ldmm basis=%s "
           "safe=%ld,%ld,%ld,%ld drawOutside=%d "
           "wlan=%s rcvbuf=%d policy=hardware-only",
           display.nativeLong, display.nativeShort,
           (unsigned long long)(display.physicalMemory / (1024ULL * 1024ULL)),
           (unsigned long)display.activeProcessors,
           (unsigned long long)display.pixelBudget,
           displayWidth, displayHeight, display.framesPerSecond,
           (long)widthPhysicalMm, (long)heightPhysicalMm,
           physicalSizeBasis == 1 ? "height" : "width",
           (long)safeLeft, (long)safeTop, (long)safeRight, (long)safeBottom,
           safeDrawOutside ? 1 : 0,
           carplay_wlan_attachment_name(display.wlanAttachment),
           screenReceiveBuffer);
    char *svcArgv[] = {
        (char*)SVC_HELPER_NAME,
        (char*)"--name", nameBuf,
        (char*)"--manufacturer", manufacturerBuf,
        (char*)"--model", modelBuf,
        (char*)"--oem-label", oemLabelBuf,
        (char*)"--width", widthBuf,
        (char*)"--height", heightBuf,
        (char*)"--fps", fpsBuf,
        (char*)"--screen-rcvbuf", receiveBufferBuf,
        (char*)"--width-physical-mm", widthPhysicalBuf,
        (char*)"--height-physical-mm", heightPhysicalBuf,
        (char*)"--right-hand-drive", rightHandDriveBuf,
        (char*)"--hevc", hevcBuf,
        (char*)"--safe-left", safeLeftBuf,
        (char*)"--safe-top", safeTopBuf,
        (char*)"--safe-right", safeRightBuf,
        (char*)"--safe-bottom", safeBottomBuf,
        (char*)"--safe-draw-outside", safeDrawOutsideBuf,
        NULL
    };
    /*
     * The service log is the only record of encrypted RTSP negotiation and
     * transport arrival. Keep it for every run; spawn_daemon truncates the
     * file at launch, so this has bounded storage cost and cannot silently
     * erase the evidence needed to diagnose a failed session.
     */
    if (iPlayIsStockSideStoreBuild()) {
        if (!self.inProcessServiceStarted) {
            self.inProcessServiceStarted = YES;
            NSString *nameCopy = [receiverName copy];
            NSString *manufacturerCopy = [manufacturer copy];
            NSString *modelCopy = [modelName copy];
            NSString *oemLabelCopy = [oemLabel copy];
            uint16_t widthCopy = displayWidth, heightCopy = displayHeight, fpsCopy = display.framesPerSecond;
            int bufferCopy = screenReceiveBuffer;
            NSInteger widthPhysicalCopy = widthPhysicalMm;
            NSInteger heightPhysicalCopy = heightPhysicalMm;
            BOOL rightHandDriveCopy = rightHandDrive;
            BOOL hevcEnabledCopy = hevcEnabled;
            NSInteger safeLeftCopy = safeLeft, safeTopCopy = safeTop;
            NSInteger safeRightCopy = safeRight, safeBottomCopy = safeBottom;
            BOOL safeDrawOutsideCopy = safeDrawOutside;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @autoreleasepool {
                    char nameArg[64], manufacturerArg[64], modelArg[64], oemLabelArg[64];
                    char widthArg[16], heightArg[16], fpsArg[16], bufferArg[16];
                    char widthPhysicalArg[16], heightPhysicalArg[16], rightHandDriveArg[8], hevcArg[8];
                    char safeLeftArg[16], safeTopArg[16], safeRightArg[16],
                         safeBottomArg[16], safeDrawOutsideArg[8];
                    snprintf(nameArg, sizeof(nameArg), "%s", nameCopy.UTF8String);
                    snprintf(manufacturerArg, sizeof(manufacturerArg), "%s", manufacturerCopy.UTF8String);
                    snprintf(modelArg, sizeof(modelArg), "%s", modelCopy.UTF8String);
                    snprintf(oemLabelArg, sizeof(oemLabelArg), "%s", oemLabelCopy.UTF8String);
                    snprintf(widthArg, sizeof(widthArg), "%u", widthCopy);
                    snprintf(heightArg, sizeof(heightArg), "%u", heightCopy);
                    snprintf(fpsArg, sizeof(fpsArg), "%u", fpsCopy);
                    snprintf(bufferArg, sizeof(bufferArg), "%d", bufferCopy);
                    snprintf(widthPhysicalArg, sizeof(widthPhysicalArg), "%ld",
                             (long)widthPhysicalCopy);
                    snprintf(heightPhysicalArg, sizeof(heightPhysicalArg), "%ld",
                             (long)heightPhysicalCopy);
                    snprintf(rightHandDriveArg, sizeof(rightHandDriveArg), "%d",
                             rightHandDriveCopy ? 1 : 0);
                    snprintf(hevcArg, sizeof(hevcArg), "%d",
                             hevcEnabledCopy ? 1 : 0);
                    snprintf(safeLeftArg, sizeof(safeLeftArg), "%ld", (long)safeLeftCopy);
                    snprintf(safeTopArg, sizeof(safeTopArg), "%ld", (long)safeTopCopy);
                    snprintf(safeRightArg, sizeof(safeRightArg), "%ld", (long)safeRightCopy);
                    snprintf(safeBottomArg, sizeof(safeBottomArg), "%ld", (long)safeBottomCopy);
                    snprintf(safeDrawOutsideArg, sizeof(safeDrawOutsideArg), "%d",
                             safeDrawOutsideCopy ? 1 : 0);
                    /*
                     * A->A runs over an already trusted Remote-Pairing/RSD
                     * CarKit relationship. Do not advertise AirPlay MFi-SAP
                     * for that local session: a normal SideStore app cannot
                     * mint DeviceIdentity BAA certificates, and the trusted
                     * RSD path is designed to advance without physical MFi.
                     *
                     * A->B keeps the normal receiver/MFi feature profile.
                     */
                    char *argsTrusted[] = {
                        (char *)"iPlay-CarPlay-Service",
                        (char *)"--name", nameArg,
                        (char *)"--manufacturer", manufacturerArg,
                        (char *)"--model", modelArg,
                        (char *)"--oem-label", oemLabelArg,
                        (char *)"--width", widthArg,
                        (char *)"--height", heightArg,
                        (char *)"--fps", fpsArg,
                        (char *)"--screen-rcvbuf", bufferArg,
                        (char *)"--width-physical-mm", widthPhysicalArg,
                        (char *)"--height-physical-mm", heightPhysicalArg,
                        (char *)"--right-hand-drive", rightHandDriveArg,
                        (char *)"--hevc", hevcArg,
                        (char *)"--safe-left", safeLeftArg,
                        (char *)"--safe-top", safeTopArg,
                        (char *)"--safe-right", safeRightArg,
                        (char *)"--safe-bottom", safeBottomArg,
                        (char *)"--safe-draw-outside", safeDrawOutsideArg,
                        (char *)"--local-simulator",
                        NULL
                    };
                    char *argsNormal[] = {
                        (char *)"iPlay-CarPlay-Service",
                        (char *)"--name", nameArg,
                        (char *)"--manufacturer", manufacturerArg,
                        (char *)"--model", modelArg,
                        (char *)"--oem-label", oemLabelArg,
                        (char *)"--width", widthArg,
                        (char *)"--height", heightArg,
                        (char *)"--fps", fpsArg,
                        (char *)"--screen-rcvbuf", bufferArg,
                        (char *)"--width-physical-mm", widthPhysicalArg,
                        (char *)"--height-physical-mm", heightPhysicalArg,
                        (char *)"--right-hand-drive", rightHandDriveArg,
                        (char *)"--hevc", hevcArg,
                        (char *)"--safe-left", safeLeftArg,
                        (char *)"--safe-top", safeTopArg,
                        (char *)"--safe-right", safeRightArg,
                        (char *)"--safe-bottom", safeBottomArg,
                        (char *)"--safe-draw-outside", safeDrawOutsideArg,
                        NULL
                    };
                    BOOL trustedAtoA = (self.sideStoreMode == 0);
                    int rc = iPlayCarPlayServiceMain(
                        trustedAtoA ? 36 : 35,
                        trustedAtoA ? argsTrusted : argsNormal);
                    ip_log("[SIDESTORE] in-process receiver exited rc=%d", rc);
                    self.inProcessServiceStarted = NO;
                }
            });
            /* Wait for the linked receiver to publish deterministic readiness.
             * This avoids racing AirPlaySender against port 7000 / mDNS setup. */
            for (int attempt = 0;
                 attempt < 100 && !g_iPlayAirPlayServerReady;
                 attempt++) {
                usleep(50000);
            }
            ip_log("[SIDESTORE] receiver readiness=%d",
                   g_iPlayAirPlayServerReady ? 1 : 0);
        }
        if (self.sideStoreMode == 0) {
            if (!g_iPlayAirPlayServerReady) {
                [self failWith:@"Local CarPlay receiver did not become ready"];
                return;
            }
            BOOL requested = iPlayStartLocalCarPlaySession(receiverName, 7000);
            ip_log("[SIDESTORE] local A->A AirPlaySender/APTransport source=%d", requested ? 1 : 0);
            if (!requested) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.headlineLabel.text = @"Local CarPlay unavailable";
                    self.subtitleLabel.text = @"Could not initialize the on-device CarPlay sender stack.";
                });
            }
        }
    } else {
        self.carplayServicesPid = spawn_daemon(
            [svcPath UTF8String], svcArgv, LOG_DIR "/carplay_services.log");
        if (self.carplayServicesPid <= 0) { [self failWith:@"carplay_services failed to start"]; return; }
        if (!wait_for_pid_alive(self.carplayServicesPid, 4, "carplay_services")) {
            [self failWith:@"carplay_services exited during setup"];
            return;
        }
    }

    /* A paired phone can resume quickly enough to deliver video while the
     * helper-alive check above is still running. Do not overwrite Active
     * with the older setup state when that happens. */
    if (self.state != StateActive) {
        [self transitionTo:StateAwaitingPhone];
    } else {
        ip_log("[HANDOFF] Existing paired session resumed during startup");
    }
}

- (void)completeBluetoothHandoff {
    dispatch_async(self.bgQueue, ^{
        if (self.bluetoothHandedOff ||
            self.state == StateStopping || self.state == StateIdle) {
            return;
        }

        /*
         * The controller has completed Bluetooth discovery and moved the
         * CarPlay session onto Wi-Fi. Own teardown here, outside BTstack's
         * callback and signal contexts. Leaving BTstack active forces the
         * combo radio to arbitrate 2.4 GHz airtime while the H.264 TCP stream
         * is running, which turns individual Wi-Fi losses into visible
         * head-of-line stalls.
         */
        ip_log("[HANDOFF] Wi-Fi session established; stopping Bluetooth helper");
        kill_pid(self.carplayBtPid);
        self.carplayBtPid = 0;

        const char *launchctl = launchctl_path();
        int rc = -1;
        if (launchctl) {
            char *unloadBTstackArgv[] = {
                (char *)"launchctl", (char *)"unload",
                (char *)BTSTACK_PLIST, NULL
            };
            rc = run_blocking(launchctl, unloadBTstackArgv);
        }
        unlink(BTSTACK_SOCKET);

        self.bluetoothHandedOff = YES;
        ip_log("[HANDOFF] Bluetooth transport stopped (BTstack unload=%d); "
               "system Bluetooth remains disabled until CarPlay stops", rc);
    });
}

- (void)stopFlow {
    [[IPlayBackgroundAudioKeeper shared] requestStop];
    if (iPlayIsStockSideStoreBuild()) iPlayStopRequestedCarPlaySession();
    [self endAWDLSuppression];
    [self stopNetworkDumpCaptureWithReason:@"user cancelled / stopping flow"];
    [self endBackgroundTask];
    [self.apPollTimer invalidate]; self.apPollTimer = nil;
    [self transitionTo:StateStopping];
    dispatch_async(self.bgQueue, ^{
        if (self.clientFd >= 0) { close(self.clientFd); self.clientFd = -1; }
        if (self.listenFd >= 0) { close(self.listenFd); self.listenFd = -1; }
        unlink(SOCK_PATH);
        g_touch_fd = -1;
        __sync_add_and_fetch(&g_touch_epoch, 1);
        g_carplay_w = 0; g_carplay_h = 0;
        g_video_suspended = 0;
        g_video_needs_resync = 0;

        kill_pid(self.carplayServicesPid); self.carplayServicesPid = 0;
        kill_pid(self.carplayBtPid);       self.carplayBtPid = 0;
        self.btdaemonPid = 0;
        self.bluetoothHandedOff = NO;

        const char *launchctl = launchctl_path();
        if (launchctl) {
            char *unloadBTstackArgv[] = { (char*)"launchctl", (char*)"unload",
                                          (char*)BTSTACK_PLIST, NULL };
            run_blocking(launchctl, unloadBTstackArgv);
            unlink(BTSTACK_SOCKET);
            char *loadArgv[] = { (char*)"launchctl", (char*)"load",
                                 (char*)BLUETOOTHD_PLIST, NULL };
            run_blocking(launchctl, loadArgv);
#ifdef SHOWCASE_ROOTLESS
            char *loadBlueToolArgv[] = { (char*)"launchctl", (char*)"load",
                                         (char*)BLUETOOL_PLIST, NULL };
            run_blocking(launchctl, loadBlueToolArgv);
#endif
        } else {
            ip_log("WARNING: launchctl not found while restoring bluetoothd");
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)self.videoView.layer;
            [layer flushAndRemoveImage];
        });

        [self transitionTo:StateIdle];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentPendingBluetoothCompatibilityError];
        });
    });
}

- (void)failBluetoothWithReason:(NSString *)reason
                    unsupported:(BOOL)unsupported {
    BluetoothRegistryProbeState registry = bluetooth_registry_probe();
    NSString *report = bluetooth_diagnostic_report(
        reason, self.bluetoothRetryAttempted, registry);
    NSString *failureClass =
        bluetooth_failure_class(reason, report, registry);
    ip_log("[BT-COMPAT] failure class=%s reason=%s\n%s",
           [failureClass UTF8String], [reason UTF8String],
           [report UTF8String]);

    self.pendingBluetoothErrorTitle = unsupported
        ? @"Bluetooth Hardware Not Supported"
        : @"Bluetooth Setup Failed";
    self.pendingBluetoothErrorExplanation = unsupported
        ? @"iPlay could not take over this device's Bluetooth controller. "
          "Tell the developer or community that this model is not yet supported "
          "and include the diagnostic below."
        : @"iPlay's Bluetooth components are incomplete or could not start. "
          "Copy the diagnostic below before reinstalling or reporting the problem.";
    self.pendingBluetoothDiagnostic = report;
    [self stopFlow];
}

- (void)presentPendingBluetoothCompatibilityError {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentPendingBluetoothCompatibilityError];
        });
        return;
    }
    if (!self.pendingBluetoothDiagnostic.length ||
        [UIApplication sharedApplication].applicationState !=
            UIApplicationStateActive ||
        self.vc.presentedViewController) {
        return;
    }

    CompatibilityErrorViewController *error =
        [[CompatibilityErrorViewController alloc] init];
    error.errorTitle = self.pendingBluetoothErrorTitle;
    error.explanation = self.pendingBluetoothErrorExplanation;
    error.diagnostic = self.pendingBluetoothDiagnostic;
    error.modalPresentationStyle = UIModalPresentationOverFullScreen;
    error.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

    self.pendingBluetoothErrorTitle = nil;
    self.pendingBluetoothErrorExplanation = nil;
    self.pendingBluetoothDiagnostic = nil;
    [self.vc presentViewController:error animated:YES completion:nil];
}

- (void)failWith:(NSString *)reason {
    ip_log("FAIL: %s", [reason UTF8String]);
    [self stopFlow];
}

- (void)openHotspotSettings {
    NSURL *u = [NSURL URLWithString:@"App-Prefs:root=INTERNET_TETHERING"];
    UIApplication *a = [UIApplication sharedApplication];
    if ([a canOpenURL:u]) {
        [a openURL:u options:@{} completionHandler:nil];
    } else {
        u = [NSURL URLWithString:@"prefs:root=INTERNET_TETHERING"];
        [a openURL:u options:@{} completionHandler:nil];
    }
}

/* ─── Cars + About ─────────────────────────────────────────── */

- (void)showCars {
    CarsViewController *vc = [[CarsViewController alloc] init];
    vc.appDelegate = self;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    [self.vc presentViewController:vc animated:YES completion:nil];
}

- (void)editCar:(Car *)existing completion:(void (^)(Car *saved))completion {
    NSString *title = existing ? @"Rename Car" : @"New Car";
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
        message:@"This is the name iPhone will show in CarPlay settings."
        preferredStyle:UIAlertControllerStyleAlert];

    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Car name (e.g. Miata)";
        tf.text = existing.name ?: @"";
        tf.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];

    [ac addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_a) {
            Car *c = existing ?: [[Car alloc] init];
            NSString *newName = ac.textFields[0].text;
            c.name = newName.length ? newName : @"My Car";
            if (!existing) {
                [self.cars addCar:c];
                [self.cars selectCar:c];
            } else {
                [self.cars save];
            }
            [self renderState];
            if (completion) completion(c);
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *_a) {
            if (completion) completion(nil);
        }]];

    UIViewController *presenter = self.vc.presentedViewController ?: self.vc;
    [presenter presentViewController:ac animated:YES completion:nil];
}

/* ─── Wi-Fi setup ───────────────────────────────────────────────
 * Two-step flow surfaced through WifiSetupViewController.
 *   Step 1: instructional content asking the user to rename the iPad
 *           in iOS Settings (the iPad's name IS the hotspot SSID).
 *   Step 2: a focused credentials prompt for the SSID and password.
 * ─────────────────────────────────────────────────────────────── */

- (void)showWifiSetup {
    WifiSetupViewController *vc = [[WifiSetupViewController alloc] init];
    vc.appDelegate = self;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    [self.vc presentViewController:vc animated:YES completion:nil];
}

/* Called by WifiSetupViewController when the user taps "Set credentials".
 * This is a focused alert prompt for SSID + password. */
- (void)promptForCredentialsFromController:(UIViewController *)host {
    NSString *currentSSID = self.cars.apSSID ?: @"";
    NSString *currentPass = self.cars.apPassword ?: @"";

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Hotspot Credentials"
                         message:@"Enter your iPad's name and the Personal Hotspot password."
                  preferredStyle:UIAlertControllerStyleAlert];

    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"iPad name (Wi-Fi network)";
        tf.text = currentSSID;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Hotspot password";
        tf.text = currentPass;
        tf.secureTextEntry = YES;
    }];

    __weak UIViewController *weakHost = host;
    [ac addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_a) {
            NSString *ssid = ac.textFields[0].text ?: @"";
            NSString *pass = ac.textFields[1].text ?: @"";
            NSString *err = validateSSID(ssid);
            if (!err && pass.length < 8) {
                err = @"Hotspot passwords must be at least 8 characters.";
            }
            if (err) {
                UIAlertController *e = [UIAlertController
                    alertControllerWithTitle:@"Try Again"
                                     message:err
                              preferredStyle:UIAlertControllerStyleAlert];
                [e addAction:[UIAlertAction actionWithTitle:@"OK"
                    style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *_b) {
                        [self promptForCredentialsFromController:weakHost];
                    }]];
                [weakHost presentViewController:e animated:YES completion:nil];
                return;
            }
            [self.cars setAPSSID:ssid password:pass];
            [weakHost dismissViewControllerAnimated:YES completion:^{
                [self renderState];
            }];
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];

    [host presentViewController:ac animated:YES completion:nil];
}

/* ─── bridge100 tcpdump capture ────────────────────────────── */

- (UIViewController *)topPresenter {
    UIViewController *p = self.vc ?: self.window.rootViewController;
    while (p.presentedViewController) p = p.presentedViewController;
    return p ?: self.window.rootViewController;
}

- (void)presentAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [[self topPresenter] presentViewController:ac animated:YES completion:nil];
}

- (void)presentExportSavedAlertForPath:(NSString *)path reason:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *msg = [NSString stringWithFormat:@"%@\n\nSaved to:\n%@",
                         reason ?: @"The share sheet could not be shown.", path ?: @"(unknown)"];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Export Saved"
            message:msg preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"Copy Path"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                if (path.length) [UIPasteboard generalPasteboard].string = path;
            }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK"
            style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *presenter = [self topPresenter];
        if ([presenter isKindOfClass:[UIAlertController class]] && presenter.presentingViewController) {
            presenter = presenter.presentingViewController;
        }
        [presenter presentViewController:ac animated:YES completion:nil];
    });
}

- (void)presentShareForURL:(NSURL *)url {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *path = url.path;
        NSFileManager *fm = [NSFileManager defaultManager];
        if (!url || ![fm fileExistsAtPath:path] || ![fm isReadableFileAtPath:path]) {
            ip_log("[SHARE] file missing/unreadable path=%s", path ? [path UTF8String] : "(nil)");
            [self presentAlertWithTitle:@"File Missing" message:@"The export file could not be found or read."];
            return;
        }

        UIActivityViewController *avc =
            [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                              applicationActivities:nil];
        avc.excludedActivityTypes = @[ UIActivityTypeAirDrop ];

        UIViewController *presenter = [self topPresenter];
        if (!presenter) {
            ip_log("[SHARE] share failed: no presenter path=%s", [path UTF8String]);
            [self presentExportSavedAlertForPath:path reason:@"The share sheet could not be shown."];
            return;
        }
        if ([presenter isKindOfClass:[UIAlertController class]]) {
            ip_log("[SHARE] share delayed: top presenter is alert");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self presentShareForURL:url];
            });
            return;
        }

        if (avc.popoverPresentationController) {
            UIView *source = presenter.view ?: self.vc.contentView ?: self.vc.view;
            if (!source || CGRectIsEmpty(source.bounds)) {
                ip_log("[SHARE] share failed: no stable source view path=%s", [path UTF8String]);
                [self presentExportSavedAlertForPath:path reason:@"The export was created, but the share sheet had no valid presentation view."];
                return;
            }
            avc.popoverPresentationController.sourceView = source;
            avc.popoverPresentationController.sourceRect =
                CGRectMake(CGRectGetMidX(source.bounds), CGRectGetMidY(source.bounds), 1, 1);
            avc.popoverPresentationController.permittedArrowDirections = 0;
        }

        ip_log("[SHARE] presenting share sheet path=%s airdrop=excluded", [path UTF8String]);
        [presenter presentViewController:avc animated:YES completion:nil];
    });
}

- (void)applyDiagnosticsEnabled:(BOOL)enabled {
    if (iPlayIsStockSideStoreBuild()) {
        _diagnosticsEnabled = NO;
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:DIAGNOSTICS_ENABLED_KEY];
        [[NSUserDefaults standardUserDefaults] synchronize];
        ip_log("[SIDESTORE] jailbreak-only diagnostics are unavailable");
        return;
    }
    _diagnosticsEnabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:DIAGNOSTICS_ENABLED_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ip_log("diagnostics %s", enabled ? "enabled" : "disabled");

    if (enabled) {
        enable_btstack_hci_logging();
        if (self.state == StateAwaitingPhone || self.state == StateActive) {
            [self presentAlertWithTitle:@"Diagnostics Enabled"
                                message:@"Diagnostics will apply on next start. Stop and start Showcase again to capture full helper logs."];
        }
    } else {
        [self stopNetworkDumpCaptureWithReason:@"diagnostics disabled"];
        disable_btstack_hci_logging();
    }
}

- (void)clearLogsAndDumps {
    [self stopNetworkDumpCaptureWithReason:@"clearing logs and dumps"];

    if (g_logfile) {
        fclose(g_logfile);
        g_logfile = NULL;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *paths = @[
        @LOG_DIR,
        @TCPDUMP_DIR,
        @"/var/mobile/Library/Showcase/diagnostics",
        @"/tmp/hci_dump.pklg",
        @SHOWCASE_BTSTACK_LOG_PATH
    ];
    for (NSString *path in paths) {
        [fm removeItemAtPath:path error:nil];
    }
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"latestTcpdumpPath"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"hasEverStartedTcpdump"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    ip_log_open();
    ip_log("logs and dumps cleared");
    [self presentAlertWithTitle:@"Logs Cleared"
                        message:@"Showcase logs, diagnostics archives, network dumps, and HCI dumps were removed."];
}

- (NSString *)timestampStringForFilename {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    return [fmt stringFromDate:[NSDate date]];
}

- (NSString *)latestNetworkDumpPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:@"latestTcpdumpPath"];
    if (stored.length > 0 && [fm fileExistsAtPath:stored]) return stored;

    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:@TCPDUMP_DIR error:nil];
    NSString *best = nil;
    NSDate *bestDate = nil;
    for (NSString *f in files) {
        if (![f hasSuffix:@".pcap"]) continue;
        NSString *path = [@TCPDUMP_DIR stringByAppendingPathComponent:f];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        NSDate *mtime = attrs[NSFileModificationDate];
        if (!best || [mtime compare:bestDate] == NSOrderedDescending) {
            best = path;
            bestDate = mtime;
        }
    }
    if (best) {
        [[NSUserDefaults standardUserDefaults] setObject:best forKey:@"latestTcpdumpPath"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    return best;
}

- (BOOL)spawnTcpdumpAtPath:(NSString *)pcapPath useSelfTimeout:(BOOL)useSelfTimeout {
    const char *tcpdump = tcpdump_tool_path();
    if (!tcpdump) return NO;

    mkdir("/var/mobile/Library/Showcase", 0755);
    mkdir(TCPDUMP_DIR, 0755);

    pid_t pid = 0;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, TCPDUMP_LOG, O_WRONLY|O_CREAT|O_APPEND, 0644);
    posix_spawn_file_actions_adddup2(&actions, 1, 2);

    /* Diagnostics must not become part of the performance problem. Full
     * screen packets plus -U forced hundreds of pcap writes per second on
     * older flash. A 256-byte snap length retains Ethernet/IP/TCP/UDP
     * headers and enough protocol prefix for flow, ACK, retransmission, and
     * RTP timing analysis. The larger capture buffer is flushed normally
     * when SIGINT stops tcpdump. */
    char *argvTimed[] = {
        (char*)"tcpdump", (char*)"-i", (char*)AP_INTERFACE,
        (char*)"-B", (char*)"4096", (char*)"-s", (char*)"256",
        (char*)"-G", (char*)"300", (char*)"-W", (char*)"1",
        (char*)"-w", (char*)[pcapPath UTF8String], NULL
    };
    char *argvPlain[] = {
        (char*)"tcpdump", (char*)"-i", (char*)AP_INTERFACE,
        (char*)"-B", (char*)"4096", (char*)"-s", (char*)"256",
        (char*)"-w", (char*)[pcapPath UTF8String], NULL
    };

    char **argv = useSelfTimeout ? argvPlain : argvTimed;
    ip_log("tcpdump spawn: %s -i %s -B 4096 -s 256 %s-w %s",
           tcpdump, AP_INTERFACE, useSelfTimeout ? "" : "-G 300 -W 1 ",
           [pcapPath UTF8String]);

    int err = posix_spawn(&pid, tcpdump, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (err != 0) {
        ip_log("tcpdump posix_spawn FAIL: %s", strerror(err));
        return NO;
    }

    usleep(250000);
    int status = 0;
    pid_t done = waitpid(pid, &status, WNOHANG);
    if (done == pid) {
        ip_log("tcpdump exited immediately status=%d", status);
        return NO;
    }

    self.tcpdumpPid = pid;
    self.currentTcpdumpPath = pcapPath;
    [[NSUserDefaults standardUserDefaults] setObject:pcapPath forKey:@"latestTcpdumpPath"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hasEverStartedTcpdump"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    ip_log("tcpdump running pid=%d path=%s", pid, [pcapPath UTF8String]);
    return YES;
}

- (void)promptInstallTcpdumpIfNeeded {
    /* Stock SideStore build: no package-manager dependency, no Sileo prompt,
     * no jailbreak diagnostic installation flow. */
    self.tcpdumpMissingPromptShown = YES;
    self.diagnosticsEnabled = NO;
    ip_log("[SIDESTORE] packet capture diagnostics disabled in stock build");
}

- (void)startNetworkDumpCapture {
    if (!self.diagnosticsEnabled) {
        ip_log("tcpdump not started; diagnostics disabled");
        return;
    }
    if (self.tcpdumpPid > 0 && pid_alive(self.tcpdumpPid)) return;

    const char *tcpdump = tcpdump_tool_path();
    if (!tcpdump) {
        ip_log("tcpdump missing; cannot capture bridge100");
        [self promptInstallTcpdumpIfNeeded];
        return;
    }

    if (!is_ap_up()) {
        ip_log("tcpdump warning: %s is not up yet; capture may exit", AP_INTERFACE);
    }

    NSString *stamp = [self timestampStringForFilename];
    NSString *path = [NSString stringWithFormat:@"%s/iplay_bridge100_%@.pcap", TCPDUMP_DIR, stamp];

    /* First try tcpdump's own 5-minute rotation stop, so the child exits even
     * if the app crashes. Older builds that dislike -G/-W fall back to an app
     * timer below. */
    if (![self spawnTcpdumpAtPath:path useSelfTimeout:NO]) {
        ip_log("tcpdump timed mode failed; retrying plain mode with app timer");
        if (![self spawnTcpdumpAtPath:path useSelfTimeout:YES]) {
            [self promptInstallTcpdumpIfNeeded];
            return;
        }
    }

    [self.tcpdumpStopTimer invalidate];
    self.tcpdumpStopTimer = [NSTimer scheduledTimerWithTimeInterval:TCPDUMP_MAX_SECONDS
        target:self selector:@selector(tcpdumpTimedOut) userInfo:nil repeats:NO];
}

- (void)tcpdumpTimedOut {
    [self stopNetworkDumpCaptureWithReason:@"5 minute limit reached"];
}

- (void)stopNetworkDumpCaptureWithReason:(NSString *)reason {
    [self.tcpdumpStopTimer invalidate]; self.tcpdumpStopTimer = nil;
    pid_t pid = self.tcpdumpPid;
    if (pid <= 0) return;

    ip_log("stopping tcpdump pid=%d reason=%s", pid, [reason UTF8String]);
    kill(pid, SIGINT); /* lets tcpdump flush pcap footer/stats */
    for (int i = 0; i < 30; i++) {
        int status = 0;
        pid_t done = waitpid(pid, &status, WNOHANG);
        if (done == pid) {
            ip_log("tcpdump stopped status=%d", status);
            self.tcpdumpPid = 0;
            return;
        }
        usleep(100000);
    }
    kill(pid, SIGTERM);
    usleep(300000);
    if (pid_alive(pid)) kill(pid, SIGKILL);
    int status = 0; waitpid(pid, &status, WNOHANG);
    self.tcpdumpPid = 0;
}

- (void)exportNetworkDump {
    if (self.tcpdumpPid > 0 && pid_alive(self.tcpdumpPid)) {
        [self stopNetworkDumpCaptureWithReason:@"user requested export"];
    }

    NSString *dump = [self latestNetworkDumpPath];
    if (!dump) {
        if (!tcpdump_tool_path()) {
            [self promptInstallTcpdumpIfNeeded];
            return;
        }
        [self startNetworkDumpCapture];
        [self presentAlertWithTitle:@"Network Capture Started"
                            message:@"Reproduce the issue, then return here and choose Stop & Send Network Dump. Performance tests should leave this capture off."];
        return;
    }

    NSURL *url = [NSURL fileURLWithPath:dump];
    [self presentShareForURL:url];
}

- (void)copyPath:(NSString *)src toDiagnosticsDir:(NSString *)dir name:(NSString *)name {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:src]) return;
    NSString *dst = [dir stringByAppendingPathComponent:name ?: [src lastPathComponent]];
    [fm removeItemAtPath:dst error:nil];
    NSError *err = nil;
    if (![fm copyItemAtPath:src toPath:dst error:&err]) {
        ip_log("diagnostics copy failed: %s -> %s (%s)",
               [src UTF8String], [dst UTF8String],
               [[err localizedDescription] UTF8String]);
    }
}

- (void)copyLogDirectoryToDiagnosticsDir:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:@LOG_DIR error:nil];
    NSString *logsDir = [dir stringByAppendingPathComponent:@"logs"];
    [fm createDirectoryAtPath:logsDir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in files) {
        if (![name hasSuffix:@".log"]) continue;
        [self copyPath:[@LOG_DIR stringByAppendingPathComponent:name]
      toDiagnosticsDir:logsDir
                  name:name];
    }
}

- (NSString *)createDiagnosticsArchive {
    if (self.diagnosticsEnabled) {
        enable_btstack_hci_logging();
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *base = @"/var/mobile/Library/Showcase/diagnostics";
    [fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *work = [base stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ShowcaseDiagnostics-%@", stamp]];
    NSString *archive = [base stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ShowcaseDiagnostics-%@.tar", stamp]];
    [fm removeItemAtPath:work error:nil];
    [fm removeItemAtPath:archive error:nil];
    [fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *commandsDir = [work stringByAppendingPathComponent:@"commands"];
    [fm createDirectoryAtPath:commandsDir withIntermediateDirectories:YES attributes:nil error:nil];

    const char *tarPaths[] = {
        "/var/jb/usr/bin/tar", "/var/jb/bin/tar", "/usr/bin/tar", "/bin/tar", NULL
    };
    const char *dpkgPaths[] = {
        "/var/jb/usr/bin/dpkg", "/var/jb/bin/dpkg", "/usr/bin/dpkg", "/bin/dpkg", NULL
    };
    const char *dpkgQueryPaths[] = {
        "/var/jb/usr/bin/dpkg-query", "/var/jb/bin/dpkg-query",
        "/usr/bin/dpkg-query", "/bin/dpkg-query", NULL
    };
    const char *unamePaths[] = {
        "/var/jb/usr/bin/uname", "/usr/bin/uname", "/bin/uname", NULL
    };
    const char *ifconfigPaths[] = {
        "/var/jb/sbin/ifconfig", "/sbin/ifconfig", "/usr/sbin/ifconfig", NULL
    };
    const char *psPaths[] = {
        "/var/jb/bin/ps", "/bin/ps", "/usr/bin/ps", NULL
    };
    const char *lsPaths[] = {
        "/var/jb/bin/ls", "/bin/ls", "/usr/bin/ls", NULL
    };

    const char *tarPath = first_existing_tool(tarPaths);
    const char *launchctl = launchctl_path();
    const char *dpkgPath = first_existing_tool(dpkgPaths);
    const char *dpkgQueryPath = first_existing_tool(dpkgQueryPaths);
    const char *unamePath = first_existing_tool(unamePaths);
    const char *ifconfigPath = first_existing_tool(ifconfigPaths);
    const char *psPath = first_existing_tool(psPaths);
    const char *lsPath = first_existing_tool(lsPaths);

    NSMutableString *env = [NSMutableString string];
    [env appendFormat:@"Showcase diagnostics\n"];
    [env appendFormat:@"version=%s\n", APP_VERSION];
#ifdef SHOWCASE_ROOTLESS
    [env appendString:@"layout=rootless\n"];
#else
    [env appendString:@"layout=rootful\n"];
#endif
    [env appendFormat:@"uid=%u\n", getuid()];
    [env appendFormat:@"euid=%u\n", geteuid()];
    [env appendFormat:@"bundle=%@\n", [[NSBundle mainBundle] bundlePath]];
    [env appendFormat:@"state=%ld\n", (long)self.state];
    [env appendFormat:@"selected_car=%@\n", self.cars.selected.name ?: @""];
    [env appendFormat:@"hotspot_ssid=%@\n", self.cars.apSSID ?: @""];
    [env appendFormat:@"launchctl=%s\n", launchctl ?: "(missing)"];
    [env appendFormat:@"tar=%s\n", tarPath ?: "(missing)"];
    [env appendFormat:@"dpkg=%s\n", dpkgPath ?: "(missing)"];
    [env appendFormat:@"dpkg_query=%s\n", dpkgQueryPath ?: "(missing)"];
    [env appendFormat:@"btdaemon=%s\n", BTDAEMON_PATH];
    [env appendFormat:@"btstack_plist=%s\n", BTSTACK_PLIST];
    [env appendFormat:@"btstack_socket=%s exists=%s\n",
                      BTSTACK_SOCKET, access(BTSTACK_SOCKET, F_OK) == 0 ? "yes" : "no"];
    [env appendFormat:@"hci_dump=/tmp/hci_dump.pklg exists=%s\n",
                      access("/tmp/hci_dump.pklg", F_OK) == 0 ? "yes" : "no"];
    [env appendFormat:@"tcpdump=%s\n", tcpdump_tool_path() ?: "(missing)"];
    [env appendFormat:@"latest_tcpdump=%@\n", [self latestNetworkDumpPath] ?: @"(none)"];
    [env appendFormat:@"diagnostics_enabled=%@\n", self.diagnosticsEnabled ? @"yes" : @"no"];
    [env appendFormat:@"helpers_full_logging_this_run=%@\n", self.helpersLoggedThisRun ? @"yes" : @"no"];
    [env appendFormat:@"bt_ready_sentinel=%s exists=%s\n",
                      BT_READY_PATH, access(BT_READY_PATH, F_OK) == 0 ? "yes" : "no"];
    [env writeToFile:[work stringByAppendingPathComponent:@"environment.txt"]
          atomically:YES encoding:NSUTF8StringEncoding error:nil];

    if (!self.helpersLoggedThisRun) {
        NSString *warning = @"Diagnostics were enabled after this run or were disabled when helpers launched. Helper logs may be missing or limited. Reproduce once with diagnostics enabled before pressing Start.\n";
        [warning writeToFile:[work stringByAppendingPathComponent:@"WARNING.txt"]
                  atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    [self copyLogDirectoryToDiagnosticsDir:work];
    [self copyPath:@"/tmp/hci_dump.pklg" toDiagnosticsDir:work name:@"hci_dump.pklg"];
    [self copyPath:@SHOWCASE_BTSTACK_LOG_PATH toDiagnosticsDir:work name:@"BTstack.log"];
    [self copyPath:@TCPDUMP_LOG toDiagnosticsDir:work name:@"tcpdump.log"];
    [self copyPath:[NSString stringWithUTF8String:BTSTACK_PREFS]
  toDiagnosticsDir:work name:@"ch.ringwald.btstack.plist"];
    [self copyPath:[NSString stringWithUTF8String:BTSTACK_PLIST]
  toDiagnosticsDir:work name:@"BTstack-launchdaemon.plist"];
    [self copyPath:[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Info.plist"]
  toDiagnosticsDir:work name:@"Showcase-Info.plist"];

    if (unamePath) {
        char *argv[] = { (char*)"uname", (char*)"-a", NULL };
        run_capture(unamePath, argv, [[commandsDir stringByAppendingPathComponent:@"uname-a.txt"] UTF8String]);
    }
    if (ifconfigPath) {
        char *argv[] = { (char*)"ifconfig", (char*)"-a", NULL };
        run_capture(ifconfigPath, argv, [[commandsDir stringByAppendingPathComponent:@"ifconfig-a.txt"] UTF8String]);
    }
    if (psPath) {
        char *argv[] = { (char*)"ps", (char*)"aux", NULL };
        run_capture(psPath, argv, [[commandsDir stringByAppendingPathComponent:@"ps-aux.txt"] UTF8String]);
    }
    if (dpkgPath) {
        char *argv2[] = { (char*)"dpkg", (char*)"-l", NULL };
        run_capture(dpkgPath, argv2, [[commandsDir stringByAppendingPathComponent:@"dpkg-l.txt"] UTF8String]);
    }
    if (dpkgQueryPath) {
        char *argv1[] = { (char*)"dpkg-query", (char*)"-s", (char*)"com.rostane.showcase", NULL };
        run_capture(dpkgQueryPath, argv1, [[commandsDir stringByAppendingPathComponent:@"dpkg-showcase.txt"] UTF8String]);
        char *argv2[] = { (char*)"dpkg-query", (char*)"-W", NULL };
        run_capture(dpkgQueryPath, argv2, [[commandsDir stringByAppendingPathComponent:@"dpkg-query-W.txt"] UTF8String]);
    }
    if (launchctl) {
        char *argv[] = { (char*)"launchctl", (char*)"list", NULL };
        run_capture(launchctl, argv, [[commandsDir stringByAppendingPathComponent:@"launchctl-list.txt"] UTF8String]);
    }
    if (lsPath) {
        char *argv1[] = { (char*)"ls", (char*)"-la", (char*)"/tmp", NULL };
        run_capture(lsPath, argv1, [[commandsDir stringByAppendingPathComponent:@"ls-tmp.txt"] UTF8String]);
        char *argv2[] = { (char*)"ls", (char*)"-la", (char*)BTDAEMON_PATH, NULL };
        run_capture(lsPath, argv2, [[commandsDir stringByAppendingPathComponent:@"ls-btdaemon.txt"] UTF8String]);
        char *argv3[] = { (char*)"ls", (char*)"-la", (char*)[[[NSBundle mainBundle] bundlePath] UTF8String], NULL };
        run_capture(lsPath, argv3, [[commandsDir stringByAppendingPathComponent:@"ls-app.txt"] UTF8String]);
    }

    if (!tarPath) {
        ip_log("diagnostics export failed: tar not found");
        return nil;
    }

    char *tarArgv[] = {
        (char*)"tar", (char*)"-cf", (char*)[archive UTF8String],
        (char*)"-C", (char*)[work UTF8String], (char*)".", NULL
    };
    int rc = run_blocking(tarPath, tarArgv);
    ip_log("diagnostics tar rc=%d path=%s", rc, [archive UTF8String]);
    return rc == 0 ? archive : nil;
}


- (NSString *)createTextLogExport {
    if (g_logfile) fflush(g_logfile);

    NSMutableString *text = [NSMutableString string];
    [text appendString:@"iPlay SideStore diagnostic log\n"];
    [text appendString:@"========================================\n"];
    [text appendFormat:@"Exported: %@\n", [NSDate date]];
    [text appendFormat:@"App version: %s\n", APP_VERSION];
    [text appendFormat:@"iOS: %@\n", [UIDevice currentDevice].systemVersion];
    [text appendFormat:@"Device: %@\n", [UIDevice currentDevice].model];
    [text appendFormat:@"State: %ld\n", (long)self.state];
    [text appendFormat:@"SideStore mode: %ld (0=A->A, 1=Receive A->B, 2=Send A->B)\n",
                       (long)self.sideStoreMode];
    [text appendFormat:@"Background audio keep-alive requested: %@\n",
                       [IPlayBackgroundAudioKeeper shared].requested ? @"yes" : @"no"];
    [text appendFormat:@"AirPlay receiver ready: %d\n", g_iPlayAirPlayServerReady ? 1 : 0];

    NSArray<NSDictionary *> *sources = @[
        @{@"title": @"APP LOG", @"path": @APP_LOG},
        @{@"title": @"CARPLAY SERVICE LOG", @"path": @"/tmp/iplay-service.log"},
        @{@"title": @"LOCALDEVVPN / RSD LOG", @"path": @"/tmp/iplay-localdevvpn.log"},
    ];

    for (NSDictionary *source in sources) {
        NSString *title = source[@"title"];
        NSString *path = source[@"path"];
        [text appendFormat:@"\n\n===== %@ =====\n", title];
        NSError *error = nil;
        NSString *body = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
        if (body.length) {
            [text appendString:body];
            if (![body hasSuffix:@"\n"]) [text appendString:@"\n"];
        } else {
            [text appendFormat:@"(no log file at %@%@)\n", path,
                               error ? [NSString stringWithFormat:@": %@", error.localizedDescription] : @""];
        }
    }

    NSString *name = [NSString stringWithFormat:@"iPlay-logs-%@.txt",
                      [self timestampStringForFilename]];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    NSError *error = nil;
    BOOL ok = [text writeToFile:path atomically:YES
                       encoding:NSUTF8StringEncoding error:&error];
    if (!ok) {
        ip_log("text log export failed: %s",
               error.localizedDescription.UTF8String ?: "unknown");
        return nil;
    }
    ip_log("text log export ready path=%s", path.UTF8String);
    return path;
}

- (void)exportDiagnostics {
    UIAlertController *busy = [UIAlertController
        alertControllerWithTitle:@"Preparing Logs"
        message:(iPlayIsStockSideStoreBuild()
                 ? @"Creating iPlay .txt log..."
                 : @"Collecting iPlay logs...")
        preferredStyle:UIAlertControllerStyleAlert];
    UIViewController *presenter = self.vc.presentedViewController ?: self.vc;
    [presenter presentViewController:busy animated:YES completion:nil];

    dispatch_async(self.bgQueue, ^{
        NSString *exportPath = iPlayIsStockSideStoreBuild()
            ? [self createTextLogExport]
            : [self createDiagnosticsArchive];
        dispatch_async(dispatch_get_main_queue(), ^{
            [busy dismissViewControllerAnimated:YES completion:^{
                if (!exportPath) {
                    [self presentAlertWithTitle:@"Could Not Export Logs"
                                        message:(iPlayIsStockSideStoreBuild()
                                                 ? @"The text log could not be created."
                                                 : @"The diagnostics archive could not be created.")];
                    return;
                }
                [self presentShareForURL:[NSURL fileURLWithPath:exportPath]];
            }];
        });
    });
}

- (void)showAbout {
    if (iPlayIsStockSideStoreBuild()) {
        NSString *msg = [NSString stringWithFormat:
            @"Version %s\nby %s\n\nSideStore build\nA → A: LocalDevVPN + Developer Mode pairing\nA → B: wireless receiver/source modes\n\nDuring CarPlay, swipe down with three fingers to open CarPlay settings.",
            APP_VERSION, APP_AUTHOR];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@APP_NAME
            message:msg preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"Export Logs (.txt)"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                [self exportDiagnostics];
            }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Done"
            style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *p = self.vc.presentedViewController ?: self.vc;
        [p presentViewController:ac animated:YES completion:nil];
        return;
    }

    NSString *msg = [NSString stringWithFormat:@"Version %s\nby %s\n\nDuring CarPlay, swipe down with three fingers to open CarPlay settings.\nDiagnostics: %@",
                     APP_VERSION, APP_AUTHOR,
                     self.diagnosticsEnabled ? @"On" : @"Off"];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@APP_NAME
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:(self.diagnosticsEnabled ? @"Disable Diagnostics" : @"Enable Diagnostics")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            [self applyDiagnosticsEnabled:!self.diagnosticsEnabled];
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Send Log"
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            [self exportDiagnostics];
        }]];

    /* Stock SideStore target intentionally omits unsupported packet-capture actions. */
    [ac addAction:[UIAlertAction actionWithTitle:@"Clear Logs"
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
            [self clearLogsAndDumps];
        }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Done"
        style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *p = self.vc.presentedViewController ?: self.vc;
    [p presentViewController:ac animated:YES completion:nil];
}
/* ─── IPC listener ─────────────────────────────────────────── */

- (BOOL)startIPCListener {
    unlink(SOCK_PATH);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCK_PATH, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        ip_log("bind: %s", strerror(errno));
        close(fd); return NO;
    }
    chmod(SOCK_PATH, 0777);
    listen(fd, 1);
    self.listenFd = fd;
    ip_log("IPC listening on %s", SOCK_PATH);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ [self ipcAcceptLoop]; });
    return YES;
}

- (void)ipcAcceptLoop {
    while (self.listenFd >= 0) {
        int c = accept(self.listenFd, NULL, NULL);
        if (c < 0) { if (errno == EINTR) continue; break; }
        int noSigPipe = 1;
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE,
                   &noSigPipe, sizeof(noSigPipe));
        ip_log("services connected");
        self.clientFd = c;
        __sync_add_and_fetch(&g_touch_epoch, 1);
        g_touch_fd = c;
        [self ipcHandleConnection:c];
        g_touch_fd = -1;
        __sync_add_and_fetch(&g_touch_epoch, 1);
        close(c);
        self.clientFd = -1;
        ip_log("services disconnected");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self endAWDLSuppression];
        });
        if (self.state == StateActive || self.state == StateAwaitingPhone) {
            [self stopFlow]; break;
        }
    }
}

static bool read_exact(int fd, uint8_t *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, buf + got, len - got);
        if (n <= 0) return false;
        got += n;
    }
    return true;
}

- (void)ipcHandleConnection:(int)fd {
    CMFormatDescriptionRef fmtDesc = NULL;
    bool gotFirstFrame = false;
    uint64_t receivedFrameCount = 0;
    uint64_t lateFrameCount = 0;      /* slot already passed on arrival */
    uint64_t lateFrameCountAtReport = 0;
    double   latenessSumMs = 0;       /* magnitude is the metric, not count */
    double   latenessMaxMs = 0;
    uint64_t previousSenderTimestamp = 0;
    bool decodeOnlyCatchupActive = false;

    while (1) {
        uint8_t hdr[5];
        if (!read_exact(fd, hdr, 5)) break;
        uint32_t len = hdr[0] | (hdr[1]<<8) | (hdr[2]<<16) | (hdr[3]<<24);
        uint8_t type = hdr[4];
        if (len == 0 || len > 4*1024*1024) break;

        uint8_t *payload = malloc(len);
        if (!read_exact(fd, payload, len)) { free(payload); break; }

        if (type == MSG_VIDEO_CONFIG) {
            if (len < 9) { free(payload); continue; }
            float w, h;
            memcpy(&w, payload, 4); memcpy(&h, payload + 4, 4);
            g_carplay_w = w; g_carplay_h = h;
            ip_log("VideoConfig: %.0fx%.0f", w, h);

            const uint8_t *codecConfig = payload + 8;
            size_t codecConfigLength = len - 8;
            BOOL usingHEVC = NO;
            CMVideoFormatDescriptionRef nextFormat =
                iPlayCreateVideoFormatDescription(codecConfig,
                                                  codecConfigLength,
                                                  &usingHEVC);
            if (nextFormat) {
                if (fmtDesc) CFRelease(fmtDesc);
                fmtDesc = nextFormat;
                ip_log("VideoConfig codec=%s bytes=%zu",
                       usingHEVC ? "HEVC" : "H.264",
                       codecConfigLength);
                video_clock_reset();
                dispatch_async(self.videoQueue, ^{
                    AVSampleBufferDisplayLayer *layer =
                        (AVSampleBufferDisplayLayer *)self.videoView.layer;
                    [layer flush];
                    if (g_video_respect_timestamps)
                        video_install_timebase(layer);
                    else
                        layer.controlTimebase = NULL;
                });
                gotFirstFrame = false;
                g_video_needs_resync = 1;
                previousSenderTimestamp = 0;
            } else {
                ip_log("VideoConfig unsupported codec configuration bytes=%zu",
                       codecConfigLength);
            }
            free(payload);

        } else if (type == MSG_VIDEO_FRAME) {
            if (!fmtDesc || len <= VIDEO_FRAME_METADATA_SIZE) {
                free(payload);
                continue;
            }
            uint64_t senderTimestamp = 0;
            memcpy(&senderTimestamp, payload, sizeof(senderTimestamp));
            BOOL isIDR = payload[8] != 0;
            uint32_t serviceSequence = 0;
            uint64_t serviceArrivalNanos = 0;
            uint32_t arrivalGapMicros = 0;
            uint32_t tcpPendingBytes = 0;
            uint32_t tcpReceiveWindow = 0;
            uint32_t tcpSmoothedRTT = 0;
            uint32_t tcpCurrentRTT = 0;
            uint32_t tcpFlags = 0;
            uint32_t decryptMicros = 0;
            memcpy(&serviceSequence, payload + 12, sizeof(serviceSequence));
            memcpy(&serviceArrivalNanos, payload + 16,
                   sizeof(serviceArrivalNanos));
            memcpy(&arrivalGapMicros, payload + 24,
                   sizeof(arrivalGapMicros));
            memcpy(&tcpPendingBytes, payload + 28,
                   sizeof(tcpPendingBytes));
            memcpy(&tcpReceiveWindow, payload + 32,
                   sizeof(tcpReceiveWindow));
            memcpy(&tcpSmoothedRTT, payload + 36,
                   sizeof(tcpSmoothedRTT));
            memcpy(&tcpCurrentRTT, payload + 40,
                   sizeof(tcpCurrentRTT));
            memcpy(&tcpFlags, payload + 44, sizeof(tcpFlags));
            memcpy(&decryptMicros, payload + 48, sizeof(decryptMicros));
            uint64_t appReadNanos = monotonic_nanos_now();
            double serviceToAppMs = serviceArrivalNanos > 0 &&
                appReadNanos >= serviceArrivalNanos
                ? (double)(appReadNanos - serviceArrivalNanos) / 1000000.0
                : -1.0;
            double senderSeconds =
                (double)senderTimestamp / 4294967296.0;
            double senderDeltaMs = NAN;
            if (previousSenderTimestamp != 0 &&
                senderTimestamp >= previousSenderTimestamp) {
                senderDeltaMs =
                    (double)(senderTimestamp - previousSenderTimestamp) /
                    4294967.296;
            }
            previousSenderTimestamp = senderTimestamp;
            double hostAtRead = video_host_now();
            double presentationAgeMs = NAN;
            if (senderTimestamp != 0 && g_video_timing_offset_valid) {
                presentationAgeMs =
                    (hostAtRead -
                     (senderSeconds + g_video_sender_to_host_offset)) * 1000.0;
            }
            if (arrivalGapMicros > 50000 || serviceSequence % 300 == 0 ||
                serviceToAppMs > 20.0) {
                ip_log("[VIDEO-TL] seq=%u gap=%.1fms serviceToApp=%.2fms "
                       "decrypt=%.2fms pending=%u rcvWnd=%u srtt=%ums "
                       "rtt=%ums tcpFlags=0x%x sender=%.6fs "
                       "senderDelta=%.1fms host=%.6fs ptsAge=%.1fms "
                       "timing=%d idr=%d",
                       serviceSequence,
                       (double)arrivalGapMicros / 1000.0, serviceToAppMs,
                       (double)decryptMicros / 1000.0, tcpPendingBytes,
                       tcpReceiveWindow, tcpSmoothedRTT, tcpCurrentRTT,
                       tcpFlags, senderSeconds, senderDeltaMs, hostAtRead,
                       presentationAgeMs,
                       (int)g_video_timing_offset_valid, isIDR ? 1 : 0);
            }
            const uint8_t *frameBytes =
                payload + VIDEO_FRAME_METADATA_SIZE;
            size_t frameLength = len - VIDEO_FRAME_METADATA_SIZE;

            if (g_video_suspended) {
                free(payload);
                continue;
            }

            if (g_video_needs_resync) {
                if (!isIDR) {
                    free(payload);
                    continue;
                }
                g_video_needs_resync = 0;
                decodeOnlyCatchupActive = false;
                ip_log("video resynchronized on IDR frame age=%.1fms",
                       presentationAgeMs);
            }

            /*
             * TCP preserves the H.264 dependency chain but can release it
             * hundreds of milliseconds late after a missing segment. Do not
             * flush that valid chain or request another large IDR over the
             * same congested path. AVSampleBufferDisplayLayer documents that
             * DoNotDisplay still decodes the sample, so feed stale frames to
             * the decoder without presenting them. The last current image
             * remains visible until the chain catches up.
             */
            double staleThresholdMs =
                MAX(VIDEO_STALE_RECOVERY_MIN_MS,
                    (double)g_video_target_latency_ms * 2.0);
            BOOL decodeOnlyCatchup =
                g_video_timing_offset_valid &&
                isfinite(presentationAgeMs) &&
                presentationAgeMs > staleThresholdMs &&
                isfinite(senderDeltaMs) &&
                senderDeltaMs <= 100.0;
            if (decodeOnlyCatchup && !decodeOnlyCatchupActive) {
                decodeOnlyCatchupActive = true;
                ip_log("video decode-only catch-up started seq=%u age=%.1fms "
                       "arrivalGap=%.1fms senderDelta=%.1fms",
                       serviceSequence, presentationAgeMs,
                       (double)arrivalGapMicros / 1000.0, senderDeltaMs);
            } else if (!decodeOnlyCatchup && decodeOnlyCatchupActive) {
                decodeOnlyCatchupActive = false;
                ip_log("video decode-only catch-up complete seq=%u age=%.1fms",
                       serviceSequence, presentationAgeMs);
            }

            if (!gotFirstFrame) {
                gotFirstFrame = true;
                [self transitionTo:StateActive];
                ip_log("first video frame");
                /* Deferred to here on purpose: pairing, iAP2 handoff and the
                 * whole RTSP negotiation have already completed, so radio
                 * suppression cannot influence them. */
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self beginAWDLSuppression];
                });
            }

            CMBlockBufferRef block = NULL;
            OSStatus st = CMBlockBufferCreateWithMemoryBlock(
                NULL, NULL, frameLength, kCFAllocatorDefault, NULL, 0,
                frameLength,
                kCMBlockBufferAssureMemoryNowFlag, &block);
            if (st == noErr) {
                CMBlockBufferReplaceDataBytes(frameBytes, block, 0,
                                              frameLength);
            }
            free(payload); payload = NULL;
            if (st != noErr || !block) continue;

            /* Schedule on the sender's timeline when it says its timestamps are
             * authoritative. A frame whose slot has already passed is still
             * enqueued, just immediately: dropping it would break the H.264
             * reference chain and corrupt every frame up to the next IDR. */
            BOOL scheduled = (g_video_respect_timestamps && senderTimestamp != 0);
            double displayHost = 0.0;
            if (scheduled) {
                bool missedSlot = false;
                double latenessSeconds = 0.0;
                displayHost = video_clock_schedule(senderTimestamp,
                                                   video_host_now(),
                                                   &missedSlot,
                                                   &latenessSeconds);
                if (missedSlot) {
                    lateFrameCount++;
                    double latenessMs = latenessSeconds * 1000.0;
                    latenessSumMs += latenessMs;
                    if (latenessMs > latenessMaxMs) latenessMaxMs = latenessMs;
                }
            }

            CMSampleTimingInfo timing;
            /* Follow the sender's real cadence — it drops to 30 Hz on
             * link-limited receivers, and a hardcoded 1/60 would retire each
             * frame half an interval early. */
            timing.duration = scheduled
                ? CMTimeMakeWithSeconds(g_video_frame_interval, 1000000)
                : CMTimeMake(1, 60);
            timing.presentationTimeStamp = scheduled
                ? CMTimeMakeWithSeconds(displayHost, 1000000)
                : kCMTimeInvalid;
            timing.decodeTimeStamp = kCMTimeInvalid;

            CMSampleBufferRef sample = NULL;
            const size_t sz = frameLength;
            st = CMSampleBufferCreateReady(NULL, block, fmtDesc, 1,
                                           1, &timing, 1, &sz, &sample);
            CFRelease(block);
            if (st != noErr || !sample) continue;

            CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sample, true);
            if (att && CFArrayGetCount(att) > 0) {
                CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(att, 0);
                CFDictionarySetValue(d, kCMSampleAttachmentKey_NotSync,
                                     isIDR ? kCFBooleanFalse : kCFBooleanTrue);
                if (decodeOnlyCatchup)
                    CFDictionarySetValue(
                        d, kCMSampleAttachmentKey_DoNotDisplay,
                        kCFBooleanTrue);
                /* DisplayImmediately overrides the timebase, so it is only
                 * correct on the unscheduled path. */
                if (!scheduled)
                    CFDictionarySetValue(
                        d, kCMSampleAttachmentKey_DisplayImmediately,
                        kCFBooleanTrue);
            }

            uint64_t frameNumber = ++receivedFrameCount;
            uint64_t lateSoFar = lateFrameCount;
            uint64_t lateSinceReport = lateFrameCount - lateFrameCountAtReport;
            double lateMeanMs = lateSinceReport
                ? (latenessSumMs / (double)lateSinceReport) : 0.0;
            double lateMaxMs = latenessMaxMs;
            if (frameNumber % 300 == 0) {
                lateFrameCountAtReport = lateFrameCount;
                latenessSumMs = 0;
                latenessMaxMs = 0;
            }
            double clockOffset = g_video_clock_offset;
            double budgetMs = g_video_budget_seconds * 1000.0;
            BOOL scheduledFrame = scheduled;
            CFAbsoluteTime receivedAt = CFAbsoluteTimeGetCurrent();
            dispatch_async(self.videoQueue, ^{
                AVSampleBufferDisplayLayer *layer =
                    (AVSampleBufferDisplayLayer *)self.videoView.layer;
                if (layer.status ==
                    AVQueuedSampleBufferRenderingStatusFailed) {
                    ip_log("video renderer failed: %@",
                           layer.error.localizedDescription ?: @"unknown");
                    g_video_needs_resync = 1;
                    [layer flushAndRemoveImage];
                    send_video_resync_request();
                    CFRelease(sample);
                    return;
                }
                /* The timing message can arrive after the parameter sets, so
                 * confirm the timebase on the first scheduled frame too. */
                if (scheduledFrame && !layer.controlTimebase)
                    video_install_timebase(layer);
                [layer enqueueSampleBuffer:sample];
                if (frameNumber % 300 == 0) {
                    double queueDelayMs =
                        (CFAbsoluteTimeGetCurrent() - receivedAt) * 1000.0;
                    ip_log("video live #%llu: IPC→enqueue %.1fms ready=%d status=%ld "
                           "mode=%s late=%llu(+%llu/300 mean %.1fms max %.1fms) "
                           "budget=%.1fms offset=%.3fs",
                           frameNumber, queueDelayMs,
                           layer.readyForMoreMediaData,
                           (long)layer.status,
                           scheduledFrame ? "scheduled" : "immediate",
                           lateSoFar, lateSinceReport, lateMeanMs, lateMaxMs,
                           budgetMs, clockOffset);
                }
                CFRelease(sample);
            });
            continue;
        } else if (type == MSG_VIDEO_TIMING) {
            if (len >= sizeof(uint32_t)) {
                uint32_t latencyMs = 0;
                memcpy(&latencyMs, payload, sizeof(latencyMs));
                if (latencyMs >= 20 && latencyMs <= 500)
                    g_video_target_latency_ms = latencyMs;

                int32_t respect = g_video_respect_timestamps;
                if (len >= 5) respect = payload[4] ? 1 : 0;
                int32_t offsetValid = 0;
                double senderToHostOffset = 0.0;
                if (len >= 14) {
                    memcpy(&senderToHostOffset, payload + 5,
                           sizeof(senderToHostOffset));
                    offsetValid = payload[13] ? 1 : 0;
                }
                if (offsetValid != g_video_timing_offset_valid ||
                    (offsetValid &&
                     fabs(senderToHostOffset -
                          g_video_sender_to_host_offset) > 0.000001)) {
                    g_video_sender_to_host_offset = senderToHostOffset;
                    g_video_timing_offset_valid = offsetValid;
                    video_clock_reset();
                }
                if (respect != g_video_respect_timestamps) {
                    g_video_respect_timestamps = respect;
                    video_clock_reset();
                    dispatch_async(self.videoQueue, ^{
                        AVSampleBufferDisplayLayer *layer =
                            (AVSampleBufferDisplayLayer *)self.videoView.layer;
                        if (respect) video_install_timebase(layer);
                        else layer.controlTimebase = NULL;
                    });
                }
                ip_log("screen presentation: latency=%u ms respectTimestamps=%d "
                       "timingOffset=%s%.3fms (%s)",
                       g_video_target_latency_ms,
                       (int)g_video_respect_timestamps,
                       g_video_timing_offset_valid ? "" : "unavailable/",
                       g_video_sender_to_host_offset * 1000.0,
                       g_video_respect_timestamps
                           ? (g_video_timing_offset_valid
                               ? "frames scheduled with synchronized NTP"
                               : "frames scheduled with arrival-clock fallback")
                           : "frames displayed on arrival");
            }
            free(payload);
        } else if (type == MSG_AUDIO_CONFIG) {
            if (len >= 20) {
                uint32_t streamType = 0;
                uint64_t formatMask = 0;
                uint32_t framesPerPacket = 0;
                uint32_t latencyMs = 0;
                memcpy(&streamType, payload, 4);
                memcpy(&formatMask, payload + 4, 8);
                memcpy(&framesPerPacket, payload + 12, 4);
                memcpy(&latencyMs, payload + 16, 4);
                NSNumber *key = @(streamType);
                CarPlayAudioPlayer *player = self.audioPlayers[key];
                if (!player) {
                    player = [[CarPlayAudioPlayer alloc]
                        initWithStreamType:streamType];
                    self.audioPlayers[key] = player;
                }
                ip_log("AudioConfig: stream=%u format=0x%llx "
                       "framesPerPacket=%u latency=%ums",
                       streamType, (unsigned long long)formatMask,
                       framesPerPacket, latencyMs);
                [player configureFormat:formatMask
                        framesPerPacket:framesPerPacket
                               latency:latencyMs];
            }
            free(payload);
        } else if (type == MSG_AUDIO_PACKET) {
            if (len > 12) {
                uint32_t streamType = 0;
                uint16_t sequence = 0;
                memcpy(&streamType, payload, 4);
                memcpy(&sequence, payload + 4, 2);
                CarPlayAudioPlayer *player = self.audioPlayers[@(streamType)];
                [player enqueuePacket:payload + 12
                               length:len - 12
                             sequence:sequence];
            }
            free(payload);
        } else if (type == MSG_AUDIO_CONTROL) {
            if (len >= 5) {
                uint32_t streamType = 0;
                memcpy(&streamType, payload, 4);
                uint8_t action = payload[4];
                CarPlayAudioPlayer *player =
                    self.audioPlayers[@(streamType)];
                if (action == AUDIO_CONTROL_PAUSE) {
                    [player setPlaybackPaused:YES];
                } else if (action == AUDIO_CONTROL_RESUME) {
                    [player setPlaybackPaused:NO];
                } else if (action == AUDIO_CONTROL_FLUSH) {
                    [player flushBufferedAudio];
                } else if (action == AUDIO_CONTROL_STOP) {
                    [player stop];
                    [self.audioPlayers removeObjectForKey:@(streamType)];
                    ip_log("audio stream %u stopped by sender teardown",
                           streamType);
                } else {
                    ip_log("audio stream %u unknown control=%u",
                           streamType, action);
                }
            }
            free(payload);
        } else if (type == MSG_BT_HANDOFF) {
            ip_log("[HANDOFF] services requested app-owned Bluetooth teardown");
            [self completeBluetoothHandoff];
            free(payload);
        } else if (type == MSG_STATUS) {
            if (len >= 1) {
                uint8_t code = payload[0];
                ip_log("MSG_STATUS code=0x%02X", code);
                NSString *text = nil;
                switch (code) {
                    case STATUS_IPHONE_CONNECTED:
                        text = @"iPhone connected\nPairing…";
                        break;
                    case STATUS_PAIR_SETUP_COMPLETE:
                        text = @"Pairing…\nVerifying…";
                        break;
                    case STATUS_PAIR_VERIFY_COMPLETE:
                        text = @"Authenticated ✓\nPreparing stream…";
                        break;
                    case STATUS_STREAM_SETUP:
                        text = @"Stream ready ✓\nReceiving video…";
                        break;
                }
                if (text) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (self.state == StateAwaitingPhone) {
                            self.subtitleLabel.text = text;
                        }
                    });
                }
            }
            free(payload);
        } else {
            free(payload);
        }
    }
    if (fmtDesc) CFRelease(fmtDesc);
    for (CarPlayAudioPlayer *player in self.audioPlayers.allValues) {
        [player stop];
    }
    [self.audioPlayers removeAllObjects];
}

@end

/* ═══════════════════════════════════════════════════════════════
 * CarsViewController — modal sheet listing/managing cars
 * ═══════════════════════════════════════════════════════════════ */

@interface CarsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@end

@implementation CarsViewController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return showcase_orientation_mask();
}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return showcase_preferred_orientation();
}
- (BOOL)prefersStatusBarHidden { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    CGFloat W = self.view.bounds.size.width;

    /* Top bar: Done + title + Add */
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 64)];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    bar.backgroundColor = [UIColor blackColor];
    [self.view addSubview:bar];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.frame = CGRectMake(20, 16, 80, 32);
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.tintColor = [UIColor whiteColor];
    done.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    [done addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:done];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 16, W, 32)];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    title.text = @"My Cars";
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [bar addSubview:title];

    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    add.frame = CGRectMake(W - 60, 16, 40, 32);
    add.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [add setTitle:@"+" forState:UIControlStateNormal];
    add.tintColor = [UIColor whiteColor];
    add.titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightLight];
    [add addTarget:self action:@selector(addTapped) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:add];

    /* Table */
    self.table = [[UITableView alloc] initWithFrame:
        CGRectMake(0, 64, W, self.view.bounds.size.height - 64)
        style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.backgroundColor = [UIColor blackColor];
    self.table.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.table.rowHeight = 70;
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.view addSubview:self.table];
}

- (void)doneTapped {
    [self dismissViewControllerAnimated:YES completion:^{
        [self.appDelegate renderState];
    }];
}
- (void)addTapped {
    [self.appDelegate editCar:nil completion:^(Car *saved) {
        [self.table reloadData];
    }];
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return self.appDelegate.cars.cars.count;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *kID = @"car";
    UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:kID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kID];
        cell.backgroundColor = [UIColor blackColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        UIView *sel = [[UIView alloc] init];
        sel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
        cell.selectedBackgroundView = sel;
    }
    Car *car = self.appDelegate.cars.cars[ip.row];
    cell.textLabel.text = car.name;
    cell.detailTextLabel.text = (car == self.appDelegate.cars.selected)
        ? @"Active"
        : @"";
    cell.accessoryType = (car == self.appDelegate.cars.selected)
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    cell.tintColor = [UIColor whiteColor];
    return cell;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    Car *car = self.appDelegate.cars.cars[ip.row];
    BOOL isSelected = (car == self.appDelegate.cars.selected);
    BOOL canDelete = self.appDelegate.cars.cars.count > 1;

    NSString *subtitle = isSelected ? @"Currently active" : @"";
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:car.name
                         message:subtitle
                  preferredStyle:UIAlertControllerStyleAlert];

    if (!isSelected) {
        [ac addAction:[UIAlertAction actionWithTitle:@"Use This Car"
            style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *_a) {
                [self.appDelegate.cars selectCar:car];
                [t reloadData];
            }]];
    }

    [ac addAction:[UIAlertAction actionWithTitle:@"Edit Car"
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_a) {
            [self.appDelegate editCar:car completion:^(Car *saved) {
                [t reloadData];
            }];
        }]];

    if (canDelete) {
        [ac addAction:[UIAlertAction actionWithTitle:@"Delete Car"
            style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *_a) {
                NSInteger row = [self.appDelegate.cars.cars indexOfObject:car];
                if (row == NSNotFound) return;
                /* Confirm before destroying */
                UIAlertController *confirm = [UIAlertController
                    alertControllerWithTitle:[NSString stringWithFormat:@"Delete %@?", car.name]
                                     message:@"This will remove the car and its Wi-Fi credentials."
                              preferredStyle:UIAlertControllerStyleAlert];
                [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                    style:UIAlertActionStyleDestructive
                    handler:^(UIAlertAction *_b) {
                        [self.appDelegate.cars deleteCarAtIndex:row];
                        [t reloadData];
                    }]];
                [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                    style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:confirm animated:YES completion:nil];
            }]];
    }

    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];

    [self presentViewController:ac animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)t canEditRowAtIndexPath:(NSIndexPath *)ip {
    /* Swipe-to-delete remains as a power-user shortcut, only when >1 cars */
    return self.appDelegate.cars.cars.count > 1;
}
- (NSArray<UITableViewRowAction *> *)tableView:(UITableView *)t
    editActionsForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewRowAction *del = [UITableViewRowAction
        rowActionWithStyle:UITableViewRowActionStyleDestructive title:@"Delete"
        handler:^(UITableViewRowAction *a, NSIndexPath *p) {
            [self.appDelegate.cars deleteCarAtIndex:p.row];
            [t reloadData];
        }];
    return @[del];
}

@end

/* ═══════════════════════════════════════════════════════════════
 * WifiSetupViewController — sleek two-step setup modal
 *
 * Step 1: Rename your iPad. Body explains why, shows a tappable
 *         example name that copies to the clipboard, plus a button
 *         that deep-links to Settings › General › About.
 *
 * Step 2: Enter hotspot details. Tap opens a focused alert prompt.
 *
 * Layout: single centered column, plenty of breathing room. Designed
 * to feel like a focused Apple onboarding screen.
 * ═══════════════════════════════════════════════════════════════ */

@interface WifiSetupViewController ()
@property (nonatomic, weak) UILabel *pillHintLabel;
@property (nonatomic, weak) UIView  *pillView;
@property (nonatomic, strong) UIView *contentView;
@end

@implementation WifiSetupViewController

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    root.backgroundColor = [UIColor blackColor];
    self.view = root;
    self.contentView = root;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (self.contentView == self.view) {
        self.contentView.frame = self.view.bounds;
        self.contentView.transform = CGAffineTransformIdentity;
        return;
    }

    CGSize s = self.view.bounds.size;
    CGFloat scale = MIN(s.width / PHONE_CANVAS_W, s.height / PHONE_CANVAS_H);
    self.contentView.bounds = CGRectMake(0, 0, PHONE_CANVAS_W, PHONE_CANVAS_H);
    self.contentView.center = CGPointMake(s.width / 2.0, s.height / 2.0);
    self.contentView.transform = CGAffineTransformMakeScale(scale, scale);
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return showcase_orientation_mask();
}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return showcase_preferred_orientation();
}
- (BOOL)prefersStatusBarHidden { return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    [self buildUI];
}

- (void)buildUI {
    UIView *root = self.contentView ?: self.view;
    CGFloat W = root.bounds.size.width;
    CGFloat H = root.bounds.size.height;
    BOOL phone = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone);

    /* ── Close button (top-right) ── */
    CGFloat closeSz = phone ? 34 : 40;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(W - closeSz - (phone ? 14 : 22),
                             phone ? 14 : 22, closeSz, closeSz);
    close.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    close.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    close.layer.cornerRadius = closeSz / 2.0;
    [close setTitle:@"×" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightLight];
    close.titleEdgeInsets = UIEdgeInsetsMake(-2, 0, 0, 0);
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:close];

    UIScrollView *scroll = nil;
    if (phone) {
        scroll = [[UIScrollView alloc] initWithFrame:root.bounds];
        scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        scroll.backgroundColor = [UIColor blackColor];
        scroll.alwaysBounceVertical = YES;
        scroll.showsVerticalScrollIndicator = NO;
        [root insertSubview:scroll belowSubview:close];
        root = scroll;
    }

    /* ── Header ── */
    UILabel *eyebrow = [[UILabel alloc] init];
    eyebrow.text = @"SHOWCASE";
    eyebrow.textAlignment = NSTextAlignmentCenter;
    eyebrow.textColor = [UIColor colorWithWhite:1 alpha:0.35];
    eyebrow.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    eyebrow.frame = CGRectMake(0, phone ? 20 : 56, W, 16);
    eyebrow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    /* letterspacing simulated via attributed string */
    eyebrow.attributedText = [[NSAttributedString alloc]
        initWithString:@"SHOWCASE"
            attributes:@{ NSKernAttributeName: @(3.0),
                          NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.35],
                          NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] }];
    [root addSubview:eyebrow];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Wi-Fi Setup";
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:(phone ? 34 : 44) weight:UIFontWeightUltraLight];
    title.frame = CGRectMake(0, phone ? 40 : 80, W, phone ? 44 : 56);
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [root addSubview:title];

    /* ── Single centered column ── */
    CGFloat colW = phone ? MIN(560, W - 56) : MIN(620, W - 120);
    CGFloat colX = (W - colW) / 2.0;
    CGFloat y = phone ? 100 : 168;

    /* ─────── STEP 1 ─────── */
    [root addSubview:[self stepEyebrowAt:CGRectMake(colX, y, colW, 14) text:@"STEP 1"]];
    y += 22;

    UILabel *step1H = [self headlineLabel:@"Rename your iPad"
                                     rect:CGRectMake(colX, y, colW, 30)];
    [root addSubview:step1H];
    y += 38;

    NSString *step1Body = @"iOS uses your iPad's name as the Personal Hotspot network. CarPlay needs this name to be at least 6 characters and to not contain words like iPad, iPhone, or iPod. You can change it in the iPad Settings app.";
    CGFloat body1H = [self heightForText:step1Body width:colW
                                    font:[UIFont systemFontOfSize:15 weight:UIFontWeightRegular]];
    UILabel *body1 = [self bodyLabel:step1Body
                                rect:CGRectMake(colX, y, colW, body1H)];
    [root addSubview:body1];
    y += body1H + 22;

    /* Tappable example name pill */
    UILabel *exampleEyebrow = [[UILabel alloc] init];
    exampleEyebrow.attributedText = [[NSAttributedString alloc]
        initWithString:@"SUGGESTED NAME"
            attributes:@{ NSKernAttributeName: @(2.0),
                          NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.4],
                          NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold] }];
    exampleEyebrow.frame = CGRectMake(colX, y, colW, 14);
    [root addSubview:exampleEyebrow];
    y += 20;

    UIView *pill = [self buildCopyPillWithText:@"Carplay-Receiver"
                                          rect:CGRectMake(colX, y, colW, 56)];
    [root addSubview:pill];
    y += 72;

    /* Open Settings button */
    UIButton *openBtn = [self primaryButton:@"Open Settings"
                                        rect:CGRectMake(colX, y, colW, 50)
                                      action:@selector(openSettingsTapped)];
    [root addSubview:openBtn];
    y += 70;

    /* Divider */
    UIView *div = [[UIView alloc] init];
    div.frame = CGRectMake(colX, y, colW, 1);
    div.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    [root addSubview:div];
    y += 32;

    /* ─────── STEP 2 ─────── */
    [root addSubview:[self stepEyebrowAt:CGRectMake(colX, y, colW, 14) text:@"STEP 2"]];
    y += 22;

    UILabel *step2H = [self headlineLabel:@"Set your credentials"
                                     rect:CGRectMake(colX, y, colW, 30)];
    [root addSubview:step2H];
    y += 38;

    NSString *step2Body = @"After renaming your iPad and turning on Personal Hotspot, enter the hotspot name and password here. Showcase saves them and reuses them for every car.";
    CGFloat body2H = [self heightForText:step2Body width:colW
                                    font:[UIFont systemFontOfSize:15 weight:UIFontWeightRegular]];
    UILabel *body2 = [self bodyLabel:step2Body
                                rect:CGRectMake(colX, y, colW, body2H)];
    [root addSubview:body2];
    y += body2H + 22;

    UIButton *credsBtn = [self primaryButton:@"Set Credentials"
                                        rect:CGRectMake(colX, y, colW, 50)
                                      action:@selector(credsTapped)];
    [root addSubview:credsBtn];

    if (scroll) {
        scroll.contentSize = CGSizeMake(W, y + 74);
    }
}

/* ─── helpers ─── */

- (UILabel *)stepEyebrowAt:(CGRect)rect text:(NSString *)text {
    UILabel *l = [[UILabel alloc] initWithFrame:rect];
    l.attributedText = [[NSAttributedString alloc]
        initWithString:text
            attributes:@{ NSKernAttributeName: @(2.5),
                          NSForegroundColorAttributeName: [UIColor whiteColor],
                          NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold] }];
    return l;
}

- (UILabel *)headlineLabel:(NSString *)text rect:(CGRect)rect {
    UILabel *l = [[UILabel alloc] initWithFrame:rect];
    l.text = text;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:24 weight:UIFontWeightSemibold];
    return l;
}

- (UILabel *)bodyLabel:(NSString *)text rect:(CGRect)rect {
    UILabel *l = [[UILabel alloc] initWithFrame:rect];
    l.text = text;
    l.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    l.numberOfLines = 0;
    return l;
}

- (CGFloat)heightForText:(NSString *)text width:(CGFloat)width font:(UIFont *)font {
    CGSize bound = CGSizeMake(width, CGFLOAT_MAX);
    CGRect r = [text boundingRectWithSize:bound
                                  options:NSStringDrawingUsesLineFragmentOrigin
                               attributes:@{NSFontAttributeName: font}
                                  context:nil];
    return ceilf(r.size.height);
}

- (UIButton *)primaryButton:(NSString *)title rect:(CGRect)rect action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = rect;
    b.backgroundColor = [UIColor whiteColor];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [b setTitleColor:[UIColor colorWithWhite:0 alpha:0.45] forState:UIControlStateHighlighted];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    b.layer.cornerRadius = rect.size.height / 2.0;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIView *)buildCopyPillWithText:(NSString *)text rect:(CGRect)rect {
    UIView *container = [[UIView alloc] initWithFrame:rect];
    container.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    container.layer.cornerRadius = 14;
    container.layer.borderWidth = 1;
    container.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;

    UILabel *txt = [[UILabel alloc] init];
    txt.text = text;
    txt.textColor = [UIColor whiteColor];
    UIFont *mono = [UIFont fontWithName:@"Menlo-Regular" size:18];
    if (!mono) mono = [UIFont systemFontOfSize:18 weight:UIFontWeightRegular];
    txt.font = mono;
    txt.frame = CGRectMake(20, 0, rect.size.width - 130, rect.size.height);
    [container addSubview:txt];

    UILabel *hint = [[UILabel alloc] init];
    hint.text = @"Tap to copy";
    hint.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    hint.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    hint.textAlignment = NSTextAlignmentRight;
    hint.frame = CGRectMake(rect.size.width - 110, 0, 90, rect.size.height);
    [container addSubview:hint];
    self.pillHintLabel = hint;
    self.pillView = container;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(copyExampleTapped:)];
    [container addGestureRecognizer:tap];

    return container;
}

- (void)copyExampleTapped:(UITapGestureRecognizer *)gr {
    [UIPasteboard generalPasteboard].string = @"Carplay-Receiver";
    self.pillHintLabel.text = @"Copied ✓";
    self.pillHintLabel.textColor = [UIColor whiteColor];
    UIView *pill = self.pillView;
    [UIView animateWithDuration:0.12 animations:^{
        pill.transform = CGAffineTransformMakeScale(1.02, 1.02);
        pill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    } completion:^(BOOL d) {
        [UIView animateWithDuration:0.18 animations:^{
            pill.transform = CGAffineTransformIdentity;
        }];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if ([self.pillHintLabel.text isEqualToString:@"Copied ✓"]) {
            self.pillHintLabel.text = @"Tap to copy";
            self.pillHintLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];
            [UIView animateWithDuration:0.25 animations:^{
                pill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
            }];
        }
    });
}

- (void)openSettingsTapped {
    NSURL *u = [NSURL URLWithString:@"App-Prefs:root=General&path=About"];
    UIApplication *app = [UIApplication sharedApplication];
    if (![app canOpenURL:u]) u = [NSURL URLWithString:@"prefs:root=General&path=About"];
    [app openURL:u options:@{} completionHandler:nil];
}

- (void)credsTapped {
    [self.appDelegate promptForCredentialsFromController:self];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:^{
        [self.appDelegate renderState];
    }];
}

@end

/* ═══════════════════════════════════════════════════════════════ */

int main(int argc, char *argv[]) {
    signal(SIGPIPE, SIG_IGN);

    /* SideStore build: remain in the normal app sandbox. */

    ip_log_open();
    ip_log("main: ruid=%u euid=%u argc=%d", getuid(), geteuid(), argc);
    ip_log("bundle: %s", [[[NSBundle mainBundle] bundlePath] UTF8String]);
#ifdef SHOWCASE_ROOTLESS
    ip_log("build: %s rootless", APP_VERSION);
#else
    ip_log("build: %s rootful", APP_VERSION);
#endif

    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([AppDelegate class]));
    }
}
