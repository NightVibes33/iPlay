#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dns_sd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <errno.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <pthread.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>

typedef void (*ALLogCallback)(void *ctx, const char *msg);
typedef void (*ALPairReadyCb)(void *ctx, const char *service_id, uint16_t port,
                              const char *const *txt_keys, const char *const *txt_vals,
                              size_t txt_count);
typedef void (*ALPairPinCb)(const char *pin, void *ctx);

typedef struct {
    char *error;
    char *device_name;
    char *device_model;
    char *device_udid;
    char *pairing_file_path;
    char *host_alt_irk_hex;
} ALPairResult;

extern int32_t al_pairing_run_host(const char *bind_addr, uint16_t port,
                                   const char *name, const char *model,
                                   const char *out_path, const char *host_alt_irk_hex,
                                   ALPairReadyCb ready_cb, ALPairPinCb pin_cb,
                                   void *ctx, ALPairResult *out);
extern void al_pairing_result_free(ALPairResult *r);
extern int32_t al_carkit_proxy_run(const char *pairing_path, uint16_t local_port,
                                   ALLogCallback log_cb, void *ctx, char **out_error);
extern void al_string_free(char *p);

extern int iPlayBAAGetCertificateChain(uint8_t **leaf, size_t *leafLength,
                                       uint8_t **intermediate, size_t *intermediateLength);
extern int iPlayBAASignChallenge(const uint8_t *challenge, size_t challengeLength,
                                 uint8_t **signature, size_t *signatureLength);
extern void iPlayLocalDevVPNCarPlayDidFail(const char *reason);

#define IAP2_SESSION_CONTROL 10
#define IAP2_SYN 0x80
#define IAP2_ACK 0x40
#define IAP2_RST 0x10
#define IAP2_MAX_MESSAGE 65525
#define IPLAY_DEVICE_ID "90:B9:31:AC:86:A0"
#define IPLAY_PUBLIC_KEY "1b15f0ad62c894721c4097651801e62845451a183c8df8af7d6b20430823586f"
#define IPLAY_SOURCE_VERSION "509.0"

static atomic_bool g_local_running = false;
static atomic_bool g_local_stop = false;
static atomic_bool g_local_failure_reported = false;
static int g_control_fd = -1;
static int g_listener_fd = -1;
static DNSServiceRef g_pair_service = NULL;

static pthread_mutex_t g_local_log_lock = PTHREAD_MUTEX_INITIALIZER;

static void local_report_failure_once(const char *reason) {
    bool expected = false;
    if (atomic_compare_exchange_strong(&g_local_failure_reported, &expected, true)) {
        iPlayLocalDevVPNCarPlayDidFail(reason ?: "LocalDevVPN A-to-A failed");
    }
}

static void local_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    va_list copy;
    va_copy(copy, ap);

    char rendered[4096];
    vsnprintf(rendered, sizeof(rendered), fmt, copy);
    va_end(copy);

    fprintf(stderr, "[iPlay:LocalDevVPN] %s\n", rendered);

    pthread_mutex_lock(&g_local_log_lock);
    FILE *file = fopen("/tmp/iplay-localdevvpn.log", "a");
    if (file) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        fprintf(file, "[%lld.%06lld] %s\n",
                (long long)now.tv_sec,
                (long long)(now.tv_nsec / 1000),
                rendered);
        fclose(file);
    }
    pthread_mutex_unlock(&g_local_log_lock);
    va_end(ap);
}

static NSString *pairing_path(void) {
    NSArray<NSString *> *paths =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documents = paths.firstObject ?: NSTemporaryDirectory();
    return [documents stringByAppendingPathComponent:@"aircard_pairing.plist"];
}

static NSString *alt_irk(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"iPlayPairingHostAltIRK"] ?: @"";
}

static BOOL pairing_exists(NSString *path) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return [attrs[NSFileSize] unsignedLongLongValue] > 0;
}

static UIViewController *top_controller(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        if (window) break;
    }
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]])
        vc = ((UINavigationController *)vc).visibleViewController;
    if ([vc isKindOfClass:[UITabBarController class]])
        vc = ((UITabBarController *)vc).selectedViewController;
    return vc;
}

static void show_pairing_pin(NSString *pin) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = top_controller();
        if (!vc) return;
        NSString *message = [NSString stringWithFormat:
            @"Keep LocalDevVPN enabled. Open Settings › Privacy & Security › Developer Mode › Pair with iPlay, approve the pairing request, and enter PIN %@ if iOS asks.\n\n"
             "Then return to iPlay. A → A starts CarPlay directly over the trusted local tunnel; you do not need to add a vehicle first in Settings › General › CarPlay.", pin];
        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Pair iPlay with this iPhone"
                                                message:message
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Open Settings"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
            if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

static void DNSSD_API pairing_register_cb(DNSServiceRef sdRef, DNSServiceFlags flags,
                                           DNSServiceErrorType errorCode, const char *name,
                                           const char *regtype, const char *domain, void *context) {
    (void)sdRef; (void)flags; (void)regtype; (void)domain; (void)context;
    local_log("pairing Bonjour registered name=%s status=%d", name ?: "?", errorCode);
}

static void pair_ready_cb(void *ctx, const char *service_id, uint16_t port,
                          const char *const *txt_keys, const char *const *txt_vals,
                          size_t txt_count) {
    (void)ctx;
    if (g_pair_service) {
        DNSServiceRefDeallocate(g_pair_service);
        g_pair_service = NULL;
    }

    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);
    for (size_t i = 0; i < txt_count; i++) {
        if (!txt_keys[i] || !txt_vals[i]) continue;
        size_t rawLen = strlen(txt_vals[i]);
        uint8_t len = (uint8_t)(rawLen > 255 ? 255 : rawLen);
        TXTRecordSetValue(&txt, txt_keys[i], len, txt_vals[i]);
    }

    DNSServiceErrorType rc = DNSServiceRegister(
        &g_pair_service, 0, 0,
        service_id ?: "iPlay",
        "_remotepairing-pairable-host._tcp.",
        NULL, NULL, htons(port),
        TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
        pairing_register_cb, NULL);
    TXTRecordDeallocate(&txt);
    local_log("pairing host ready port=%u dns=%d", port, rc);
}

static void pair_pin_cb(const char *pin, void *ctx) {
    (void)ctx;
    NSString *value = pin ? [NSString stringWithUTF8String:pin] : @"";
    local_log("pairing PIN issued");
    show_pairing_pin(value);
}

static BOOL ensure_pairing(void) {
    NSString *path = pairing_path();
    if (pairing_exists(path)) return YES;

    local_log("no pairing record; starting NFCARD/AirCard RPPairing host");
    ALPairResult result = {0};
    NSString *irk = alt_irk();
    int32_t rc = al_pairing_run_host(
        "0.0.0.0", 0, "iPlay", "Mac17,7",
        path.fileSystemRepresentation, irk.UTF8String,
        pair_ready_cb, pair_pin_cb, NULL, &result);

    if (g_pair_service) {
        DNSServiceRefDeallocate(g_pair_service);
        g_pair_service = NULL;
    }

    if (rc == 0 && result.host_alt_irk_hex) {
        NSString *saved = [NSString stringWithUTF8String:result.host_alt_irk_hex];
        [[NSUserDefaults standardUserDefaults] setObject:saved forKey:@"iPlayPairingHostAltIRK"];
    }
    if (rc != 0) {
        local_log("pairing failed: %s", result.error ?: "unknown");
    } else {
        local_log("pairing completed device=%s", result.device_name ?: "iPhone");
    }
    al_pairing_result_free(&result);
    return rc == 0 && pairing_exists(path);
}

typedef struct {
    uint8_t *bytes;
    size_t length;
    size_t capacity;
} Buffer;

static void buf_init(Buffer *b, size_t capacity) {
    b->bytes = malloc(capacity ? capacity : 64);
    b->length = 0;
    b->capacity = capacity ? capacity : 64;
}
static void buf_free(Buffer *b) {
    free(b->bytes);
    b->bytes = NULL;
    b->length = b->capacity = 0;
}
static BOOL buf_reserve(Buffer *b, size_t extra) {
    if (extra > SIZE_MAX - b->length) return NO;
    size_t need = b->length + extra;
    if (need <= b->capacity) return YES;
    size_t cap = b->capacity;
    while (cap < need) {
        if (cap > SIZE_MAX / 2) { cap = need; break; }
        cap *= 2;
    }
    uint8_t *p = realloc(b->bytes, cap);
    if (!p) return NO;
    b->bytes = p;
    b->capacity = cap;
    return YES;
}
static BOOL buf_put(Buffer *b, const void *src, size_t len) {
    if (!buf_reserve(b, len)) return NO;
    if (len) memcpy(b->bytes + b->length, src, len);
    b->length += len;
    return YES;
}
static BOOL buf_u8(Buffer *b, uint8_t v) { return buf_put(b, &v, 1); }
static BOOL buf_u16be(Buffer *b, uint16_t v) {
    uint8_t x[2] = {(uint8_t)(v >> 8), (uint8_t)v};
    return buf_put(b, x, 2);
}
static BOOL param_raw(Buffer *b, uint16_t id, const void *data, size_t len) {
    if (len > UINT16_MAX - 4) return NO;
    return buf_u16be(b, (uint16_t)(len + 4)) &&
           buf_u16be(b, id) &&
           buf_put(b, data, len);
}
static BOOL param_void(Buffer *b, uint16_t id) { return param_raw(b, id, NULL, 0); }
static BOOL param_u8(Buffer *b, uint16_t id, uint8_t v) { return param_raw(b, id, &v, 1); }
static BOOL param_u16(Buffer *b, uint16_t id, uint16_t v) {
    uint8_t x[2] = {(uint8_t)(v >> 8), (uint8_t)v};
    return param_raw(b, id, x, 2);
}
static BOOL param_u32(Buffer *b, uint16_t id, uint32_t v) {
    uint8_t x[4] = {(uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v};
    return param_raw(b, id, x, 4);
}
static BOOL param_string(Buffer *b, uint16_t id, const char *s) {
    return param_raw(b, id, s, strlen(s) + 1);
}
static BOOL param_group(Buffer *b, uint16_t id, const Buffer *group) {
    return param_raw(b, id, group->bytes, group->length);
}
static BOOL param_u16_list(Buffer *b, uint16_t id, const uint16_t *values, size_t count) {
    Buffer x; buf_init(&x, count * 2 + 8);
    for (size_t i = 0; i < count; i++) buf_u16be(&x, values[i]);
    BOOL ok = param_raw(b, id, x.bytes, x.length);
    buf_free(&x);
    return ok;
}

static uint8_t iap_checksum(const uint8_t *bytes, size_t len) {
    uint8_t sum = 0;
    for (size_t i = 0; i < len; i++) sum = (uint8_t)(sum + bytes[i]);
    return (uint8_t)(0 - sum);
}
static BOOL write_all(int fd, const void *data, size_t len) {
    const uint8_t *p = data;
    while (len) {
        ssize_t n = send(fd, p, len, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        p += n; len -= (size_t)n;
    }
    return YES;
}
static BOOL read_all(int fd, void *data, size_t len) {
    uint8_t *p = data;
    while (len) {
        ssize_t n = recv(fd, p, len, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        p += n; len -= (size_t)n;
    }
    return YES;
}

typedef struct {
    uint8_t flags, sequence, acknowledgement, session;
    uint8_t *payload;
    size_t payloadLength;
} IapFrame;

static void frame_free(IapFrame *f) {
    free(f->payload);
    memset(f, 0, sizeof(*f));
}
static BOOL send_frame(int fd, uint8_t flags, uint8_t sequence,
                       uint8_t acknowledgement, uint8_t session,
                       const uint8_t *payload, size_t payloadLength) {
    size_t total = 9 + payloadLength + (payloadLength ? 1 : 0);
    if (total > UINT16_MAX) return NO;
    uint8_t *wire = calloc(1, total);
    if (!wire) return NO;
    wire[0] = 0xff; wire[1] = 0x5a;
    wire[2] = (uint8_t)(total >> 8); wire[3] = (uint8_t)total;
    wire[4] = flags; wire[5] = sequence; wire[6] = acknowledgement; wire[7] = session;
    wire[8] = iap_checksum(wire, 8);
    if (payloadLength) {
        memcpy(wire + 9, payload, payloadLength);
        wire[9 + payloadLength] = iap_checksum(payload, payloadLength);
    }
    BOOL ok = write_all(fd, wire, total);
    free(wire);
    return ok;
}
static BOOL read_frame(int fd, IapFrame *out) {
    memset(out, 0, sizeof(*out));
    uint8_t first2[2];
    if (!read_all(fd, first2, 2)) return NO;
    if (first2[0] == 0xff && first2[1] == 0x55) {
        uint8_t rest[4];
        static const uint8_t expected[4] = {0x02, 0x00, 0xee, 0x10};
        if (!read_all(fd, rest, sizeof(rest)) || memcmp(rest, expected, 4) != 0) return NO;
        if (!read_all(fd, first2, 2)) return NO;
    }
    if (first2[0] != 0xff || first2[1] != 0x5a) return NO;
    uint8_t restHeader[7];
    if (!read_all(fd, restHeader, sizeof(restHeader))) return NO;
    uint8_t header[9] = {first2[0], first2[1],
        restHeader[0], restHeader[1], restHeader[2], restHeader[3],
        restHeader[4], restHeader[5], restHeader[6]};
    uint16_t total = ((uint16_t)header[2] << 8) | header[3];
    if (total < 9 || total == 10 || iap_checksum(header, 9) != 0) return NO;
    size_t tail = total - 9;
    uint8_t *body = tail ? malloc(tail) : NULL;
    if (tail && (!body || !read_all(fd, body, tail))) { free(body); return NO; }
    size_t payloadLen = tail ? tail - 1 : 0;
    if (tail && iap_checksum(body, tail) != 0) { free(body); return NO; }
    out->flags = header[4];
    out->sequence = header[5];
    out->acknowledgement = header[6];
    out->session = header[7];
    out->payloadLength = payloadLen;
    if (payloadLen) {
        out->payload = malloc(payloadLen);
        if (!out->payload) { free(body); return NO; }
        memcpy(out->payload, body, payloadLen);
    }
    free(body);
    if (out->flags & IAP2_RST) { frame_free(out); return NO; }
    return YES;
}

typedef struct {
    int fd;
    uint8_t sent;
    uint8_t received;
    size_t maxFrame;
    Buffer csm;
} Control;

static BOOL control_sync(Control *c) {
    static const uint8_t detect[6] = {0xff,0x55,0x02,0x00,0xee,0x10};
    uint8_t sync[13] = {1,4,0xff,0xff,0,0,0,0,0,0, IAP2_SESSION_CONTROL,0,2};
    if (!write_all(c->fd, detect, sizeof(detect))) return NO;
    if (!send_frame(c->fd, IAP2_SYN, c->sent, 0, 0, sync, sizeof(sync))) return NO;
    BOOL gotSyn = NO;
    for (int i = 0; i < 12; i++) {
        IapFrame f;
        if (!read_frame(c->fd, &f)) return NO;
        if (f.session != 0) { frame_free(&f); return NO; }
        if (f.flags & IAP2_SYN) {
            if (f.payloadLength < 13 || f.payload[0] != 1) { frame_free(&f); return NO; }
            c->maxFrame = ((size_t)f.payload[2] << 8) | f.payload[3];
            if (c->maxFrame < 64) { frame_free(&f); return NO; }
            c->received = f.sequence;
            gotSyn = YES;
            if (!send_frame(c->fd, IAP2_ACK, c->sent, c->received, 0, NULL, 0)) {
                frame_free(&f); return NO;
            }
        }
        BOOL complete = (f.flags & IAP2_ACK) && gotSyn && f.acknowledgement == c->sent;
        frame_free(&f);
        if (complete) {
            local_log("iAP2 wired link synchronized maxFrame=%zu", c->maxFrame);
            return YES;
        }
    }
    return NO;
}
static BOOL control_send_csm(Control *c, uint16_t messageId, const Buffer *params) {
    Buffer msg; buf_init(&msg, params->length + 16);
    buf_u8(&msg, 0x40); buf_u8(&msg, 0x40);
    buf_u16be(&msg, (uint16_t)(params->length + 6));
    buf_u16be(&msg, messageId);
    buf_put(&msg, params->bytes, params->length);
    size_t maxPayload = c->maxFrame > 10 ? c->maxFrame - 10 : 0;
    if (!maxPayload) { buf_free(&msg); return NO; }
    size_t offset = 0;
    while (offset < msg.length) {
        size_t chunk = maxPayload < (msg.length - offset) ? maxPayload : (msg.length - offset);
        c->sent++;
        if (!send_frame(c->fd, IAP2_ACK, c->sent, c->received,
                        IAP2_SESSION_CONTROL, msg.bytes + offset, chunk)) {
            buf_free(&msg); return NO;
        }
        offset += chunk;
    }
    local_log("iAP2 tx=0x%04x bytes=%zu", messageId, msg.length);
    buf_free(&msg);
    return YES;
}
static BOOL control_recv_csm(Control *c, uint16_t *messageId, Buffer *params) {
    for (;;) {
        if (c->csm.length >= 6) {
            if (c->csm.bytes[0] != 0x40 || c->csm.bytes[1] != 0x40) return NO;
            size_t length = ((size_t)c->csm.bytes[2] << 8) | c->csm.bytes[3];
            if (length < 6 || length > IAP2_MAX_MESSAGE) return NO;
            if (c->csm.length >= length) {
                *messageId = ((uint16_t)c->csm.bytes[4] << 8) | c->csm.bytes[5];
                buf_init(params, length - 6 + 1);
                buf_put(params, c->csm.bytes + 6, length - 6);
                size_t remaining = c->csm.length - length;
                memmove(c->csm.bytes, c->csm.bytes + length, remaining);
                c->csm.length = remaining;
                local_log("iAP2 rx=0x%04x bytes=%zu", *messageId, length);
                return YES;
            }
        }
        IapFrame f;
        if (!read_frame(c->fd, &f)) return NO;
        if (f.flags != IAP2_ACK) { frame_free(&f); return NO; }
        if (!f.payloadLength) { frame_free(&f); continue; }
        if (f.session != IAP2_SESSION_CONTROL) { frame_free(&f); continue; }
        if (f.sequence == c->received) { frame_free(&f); continue; }
        if (f.sequence != (uint8_t)(c->received + 1)) { frame_free(&f); return NO; }
        c->received = f.sequence;
        if (!buf_put(&c->csm, f.payload, f.payloadLength)) { frame_free(&f); return NO; }
        frame_free(&f);
    }
}
static BOOL get_param(const Buffer *params, uint16_t target, const uint8_t **data, size_t *length) {
    size_t off = 0;
    while (off + 4 <= params->length) {
        uint16_t plen = ((uint16_t)params->bytes[off] << 8) | params->bytes[off+1];
        uint16_t pid = ((uint16_t)params->bytes[off+2] << 8) | params->bytes[off+3];
        if (plen < 4 || off + plen > params->length) return NO;
        if (pid == target) {
            *data = params->bytes + off + 4;
            *length = plen - 4;
            return YES;
        }
        off += plen;
    }
    return NO;
}

static BOOL send_identification(Control *c, NSString *displayName) {
    Buffer p; buf_init(&p, 1024);
    const char *name = displayName.length ? displayName.UTF8String : "iPlay";
    param_string(&p, 0, name);
    param_string(&p, 1, "iPlay-A2A");
    param_string(&p, 2, "NightVibes33");
    param_string(&p, 3, "IPL-A2A-0001");
    param_string(&p, 4, "0.1");
    param_string(&p, 5, "1.0");
    /*
     * Match DiPlay's real wired head-unit identity. Remote Pairing/RSD gives
     * us the trusted transport into this same iPhone, but CarKit still uses
     * the accessory's iAP2 identity/authentication capabilities to construct
     * its messaging vehicle and normal pairing lifecycle. Advertising the
     * complete AA00..AA05 exchange lets carkitd persist the vehicle that
     * Settings -> General -> CarPlay reads. authenticate_or_trusted() still
     * accepts iOS builds that advance directly on the trusted RSD shim.
     */
    static const uint16_t sent[] = {
        0xaa01,0xaa03,
        0x5000,0x5002,0x5200,0x5203,0xae00,0xae02,
        0x4157,0x4159,0x4154,0x4156,0xae03,0x4301
    };
    static const uint16_t recv[] = {
        0xaa00,0xaa02,0xaa04,0xaa05,
        0xea00,0xea01,0x5001,0x5201,0x5202,0xae01,
        0x4158,0x4155,0x4300,0x4e0e
    };
    param_u16_list(&p, 6, sent, sizeof(sent)/sizeof(sent[0]));
    param_u16_list(&p, 7, recv, sizeof(recv)/sizeof(recv[0]));
    param_u8(&p, 8, 2);
    param_u16(&p, 9, 20);
    Buffer ea; buf_init(&ea, 64);
    param_u8(&ea, 0, 1); param_string(&ea, 1, "com.nightvibes33.iplay"); param_u8(&ea, 2, 0);
    param_group(&p, 10, &ea); buf_free(&ea);
    param_string(&p, 12, "en");
    param_string(&p, 13, "en");
    Buffer usb; buf_init(&usb, 96);
    param_u16(&usb, 0, 0);
    param_string(&usb, 1, "USBHostTransport");
    param_void(&usb, 2);
    param_u8(&usb, 3, 0);
    param_void(&usb, 4);
    param_group(&p, 16, &usb); buf_free(&usb);
    Buffer route; buf_init(&route, 96);
    param_u16(&route, 0, 42);
    param_string(&route, 1, "RouteGuidance");
    param_u16(&route, 2, 64); param_u16(&route, 4, 64); param_u16(&route, 6, 8);
    param_group(&p, 30, &route); buf_free(&route);
    BOOL ok = control_send_csm(c, 0x1d01, &p);
    buf_free(&p);
    return ok;
}
static BOOL send_baa_certificate(Control *c) {
    uint8_t *leaf = NULL, *inter = NULL;
    size_t leafLen = 0, interLen = 0;
    if (iPlayBAAGetCertificateChain(&leaf, &leafLen, &inter, &interLen) != 0) {
        local_log("BAA certificate chain unavailable");
        return NO;
    }
    Buffer p; buf_init(&p, leafLen + interLen + 32);
    param_raw(&p, 0, leaf, leafLen);
    param_u8(&p, 1, 1);
    param_raw(&p, 2, inter, interLen);
    free(leaf); free(inter);
    BOOL ok = control_send_csm(c, 0xaa01, &p);
    buf_free(&p);
    return ok;
}
static BOOL send_baa_signature(Control *c, const uint8_t *challenge, size_t challengeLen) {
    uint8_t *sig = NULL; size_t sigLen = 0;
    if (iPlayBAASignChallenge(challenge, challengeLen, &sig, &sigLen) != 0) {
        local_log("BAA challenge signing failed");
        return NO;
    }
    Buffer p; buf_init(&p, sigLen + 16);
    param_raw(&p, 0, sig, sigLen);
    free(sig);
    BOOL ok = control_send_csm(c, 0xaa03, &p);
    buf_free(&p);
    return ok;
}
typedef struct {
    BOOL present;
    uint16_t id;
    Buffer params;
} PendingControlMessage;

/*
 * A physical wired accessory normally gets AA00 -> AA02 -> AA05 here.
 * The trusted Remote-Pairing/RSD CarKit shim used by LocalDevVPN can already
 * represent an authenticated device relationship and may advance directly to
 * power/session traffic. Preserve that first non-auth message instead of
 * throwing it away so both behaviours are supported by the same controller.
 */
static BOOL authenticate_or_trusted(Control *c, PendingControlMessage *pending) {
    memset(pending, 0, sizeof(*pending));
    BOOL authStarted = NO;
    BOOL certSent = NO;
    BOOL sigSent = NO;

    for (int i = 0; i < 20; i++) {
        uint16_t id = 0;
        Buffer p;
        if (!control_recv_csm(c, &id, &p)) return NO;

        BOOL ok = YES;
        if (id == 0xaa00) {
            authStarted = YES;
            ok = send_baa_certificate(c);
            certSent = ok;
        } else if (id == 0xaa02) {
            authStarted = YES;
            const uint8_t *challenge = NULL;
            size_t challengeLen = 0;
            ok = get_param(&p, 0, &challenge, &challengeLen) &&
                 challengeLen > 0 && challengeLen <= 128 &&
                 send_baa_signature(c, challenge, challengeLen);
            sigSent = ok;
        } else if (id == 0xaa05) {
            buf_free(&p);
            local_log("iAP2 BAA authentication accepted cert=%d sig=%d",
                      certSent, sigSent);
            return certSent && sigSent;
        } else if (id == 0xaa04 || id == 0x1d03) {
            ok = NO;
        } else if (!authStarted) {
            pending->present = YES;
            pending->id = id;
            pending->params = p; /* transfer Buffer ownership to caller */
            local_log(
                "trusted RSD advanced without physical MFi auth; pending=0x%04x",
                id);
            return YES;
        } else {
            /*
             * Once AA00 has started, keep the authentication transaction
             * strict. Informational messages may be interleaved, but session
             * state must not be treated as authenticated until AA05.
             */
            local_log("iAP2 auth interleaved message 0x%04x", id);
        }

        buf_free(&p);
        if (!ok) return NO;
    }
    return NO;
}
static BOOL send_subscriptions(Control *c) {
    Buffer p; BOOL ok = YES;
    buf_init(&p, 32); param_u16(&p, 0, 500); param_u8(&p, 1, 1);
    ok = ok && control_send_csm(c, 0xae03, &p); buf_free(&p);

    buf_init(&p, 128);
    Buffer g0; buf_init(&g0, 64);
    param_void(&g0,1); param_void(&g0,4); param_void(&g0,6); param_void(&g0,12); param_void(&g0,26);
    param_group(&p, 0, &g0); buf_free(&g0);
    Buffer g1; buf_init(&g1, 48);
    param_void(&g1,0); param_void(&g1,1); param_void(&g1,7);
    param_group(&p, 1, &g1); buf_free(&g1);
    ok = ok && control_send_csm(c, 0x5000, &p); buf_free(&p);

    buf_init(&p, 32); param_u16(&p,0,42); param_void(&p,1); param_void(&p,2);
    ok = ok && control_send_csm(c, 0x5200, &p); buf_free(&p);
    buf_init(&p, 32); param_void(&p,4); param_void(&p,5); param_void(&p,6);
    ok = ok && control_send_csm(c, 0xae00, &p); buf_free(&p);
    buf_init(&p, 32); param_void(&p,0); param_void(&p,4); param_void(&p,5);
    ok = ok && control_send_csm(c, 0x4157, &p); buf_free(&p);
    buf_init(&p, 48);
    param_void(&p,0); param_void(&p,1); param_void(&p,2); param_void(&p,3); param_void(&p,4); param_void(&p,11);
    ok = ok && control_send_csm(c, 0x4154, &p); buf_free(&p);
    return ok;
}
static BOOL send_start_session(Control *c, NSInteger port) {
    Buffer p; buf_init(&p, 256);
    Buffer wired; buf_init(&wired, 32);
    param_string(&wired, 0, "::1");
    param_group(&p, 0, &wired); buf_free(&wired);
    param_u32(&p, 2, (uint32_t)port);
    param_string(&p, 3, IPLAY_DEVICE_ID);
    param_string(&p, 4, IPLAY_PUBLIC_KEY);
    param_string(&p, 5, IPLAY_SOURCE_VERSION);
    BOOL ok = control_send_csm(c, 0x4301, &p);
    buf_free(&p);
    if (ok) local_log("CarPlayStartSession sent endpoint=[::1]:%ld", (long)port);
    return ok;
}

static BOOL run_iap2(int fd, NSString *displayName, NSInteger airPlayPort) {
    int noSigPipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
    struct timeval tv = {.tv_sec = 20, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    Control c = {.fd = fd, .sent = 31, .received = 0, .maxFrame = UINT16_MAX};
    buf_init(&c.csm, 4096);
    BOOL ok = control_sync(&c);
    if (!ok) goto done;

    uint16_t id = 0; Buffer p;
    if (!control_recv_csm(&c, &id, &p)) goto done;
    buf_free(&p);
    if (id != 0x1d00 || !send_identification(&c, displayName)) goto done;

    if (!control_recv_csm(&c, &id, &p)) goto done;
    buf_free(&p);
    if (id != 0x1d02) {
        local_log("identification rejected/unexpected id=0x%04x", id);
        goto done;
    }
    local_log("iAP2 identification accepted; CarKit can now construct the iPlay messaging vehicle");
    local_log("Settings lifecycle: waiting for accessory authentication / trusted-RSD approval");

    PendingControlMessage pending;
    if (!authenticate_or_trusted(&c, &pending)) goto done;

    if (!send_subscriptions(&c)) {
        if (pending.present) buf_free(&pending.params);
        goto done;
    }
    local_log("iAP2 power/subscriptions sent; waiting for CarPlay availability");

    /*
     * A trusted RSD session can deliver 0x4300 immediately after
     * identification. Process it after subscriptions rather than losing it.
     */
    if (pending.present) {
        id = pending.id;
        p = pending.params;
        pending.present = NO;
        if (id == 0x4300) {
            local_log("Settings lifecycle: CarPlay availability received (0x4300); system pairing vehicle is active");
            BOOL sent = send_start_session(&c, airPlayPort);
            buf_free(&p);
            if (!sent) goto done;
        } else if (id == 0xaa04 || id == 0x1d03) {
            buf_free(&p);
            goto done;
        } else {
            local_log("trusted RSD pending message 0x%04x handled after subscriptions", id);
            buf_free(&p);
        }
    }

    while (!atomic_load(&g_local_stop)) {
        if (!control_recv_csm(&c, &id, &p)) break;
        if (id == 0x4300) {
            local_log("Settings lifecycle: CarPlay availability received (0x4300); system pairing vehicle is active");
            BOOL sent = send_start_session(&c, airPlayPort);
            buf_free(&p);
            if (!sent) goto done;
            continue;
        }
        if (id == 0xaa04 || id == 0x1d03) {
            buf_free(&p);
            goto done;
        }
        buf_free(&p);
    }
    ok = !atomic_load(&g_local_stop);

done:
    buf_free(&c.csm);
    return ok;
}

static int make_loopback_listener(uint16_t *portOut) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0 || listen(fd, 1) != 0) {
        close(fd); return -1;
    }
    socklen_t len = sizeof(a);
    if (getsockname(fd, (struct sockaddr *)&a, &len) != 0) {
        close(fd); return -1;
    }
    *portOut = ntohs(a.sin_port);
    return fd;
}
static void rust_log(void *ctx, const char *msg) {
    (void)ctx;
    if (msg) local_log("%s", msg);
}
static void local_worker(NSString *displayName, NSInteger airPlayPort) {
    @autoreleasepool {
        if (!ensure_pairing()) {
            local_log("A->A stopped: pairing is required");
            atomic_store(&g_local_running, false);
            return;
        }
        if (atomic_load(&g_local_stop)) {
            atomic_store(&g_local_running, false);
            return;
        }

        uint16_t proxyPort = 0;
        int listener = make_loopback_listener(&proxyPort);
        if (listener < 0) {
            local_log("could not create CarKit proxy listener: %s", strerror(errno));
            atomic_store(&g_local_running, false);
            return;
        }
        g_listener_fd = listener;

        NSString *path = pairing_path();
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char *error = NULL;
            int32_t rc = al_carkit_proxy_run(path.fileSystemRepresentation, proxyPort,
                                             rust_log, NULL, &error);
            NSString *failure = error ? [NSString stringWithUTF8String:error] : nil;
            local_log("RSD CarKit proxy ended rc=%d error=%s", rc, error ?: "none");
            if (error) al_string_free(error);

            int fd = g_control_fd;
            if (fd >= 0) {
                shutdown(fd, SHUT_RDWR);
            } else {
                /* The proxy failed before attaching to our iAP2 listener.
                 * Closing the listener unblocks accept() so we can invoke the
                 * direct APTransport fallback instead of hanging forever. */
                int listenFd = g_listener_fd;
                if (listenFd >= 0) {
                    shutdown(listenFd, SHUT_RDWR);
                    close(listenFd);
                    g_listener_fd = -1;
                }
                if (!atomic_load(&g_local_stop)) {
                    local_report_failure_once(
                        failure.length ? failure.UTF8String :
                        "LocalDevVPN CarKit transport ended before iAP2 connected");
                }
            }
        });

        struct sockaddr_in peer;
        socklen_t peerLen = sizeof(peer);
        int control = accept(listener, (struct sockaddr *)&peer, &peerLen);
        if (g_listener_fd == listener) {
            close(listener);
            g_listener_fd = -1;
        }
        if (control < 0) {
            local_log("CarKit proxy accept failed: %s", strerror(errno));
            if (!atomic_load(&g_local_stop)) {
                local_report_failure_once("LocalDevVPN CarKit proxy did not attach to iAP2");
            }
            atomic_store(&g_local_running, false);
            return;
        }
        g_control_fd = control;
        local_log("trusted RSD CarKit stream connected through LocalDevVPN");

        BOOL ok = run_iap2(control, displayName, airPlayPort);
        local_log("local wired CarPlay control ended ok=%d", ok ? 1 : 0);
        if (!ok && !atomic_load(&g_local_stop)) {
            local_report_failure_once("LocalDevVPN wired iAP2 negotiation failed");
        }
        shutdown(control, SHUT_RDWR);
        close(control);
        g_control_fd = -1;
        atomic_store(&g_local_running, false);
    }
}

BOOL iPlayStartLocalDevVPNCarPlay(NSString *displayName, NSInteger airPlayPort) {
    bool expected = false;
    if (!atomic_compare_exchange_strong(&g_local_running, &expected, true)) return YES;
    atomic_store(&g_local_stop, false);
    atomic_store(&g_local_failure_reported, false);
    NSString *nameCopy = [displayName.length ? displayName : @"iPlay" copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        local_worker(nameCopy, airPlayPort);
    });
    return YES;
}

void iPlayStopLocalDevVPNCarPlay(void) {
    atomic_store(&g_local_stop, true);
    int fd = g_control_fd;
    if (fd >= 0) shutdown(fd, SHUT_RDWR);
    fd = g_listener_fd;
    if (fd >= 0) shutdown(fd, SHUT_RDWR);
    if (g_pair_service) {
        DNSServiceRefDeallocate(g_pair_service);
        g_pair_service = NULL;
    }
}
