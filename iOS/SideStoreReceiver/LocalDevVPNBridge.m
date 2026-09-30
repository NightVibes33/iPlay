#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dns_sd.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <stdint.h>

typedef void (*ALLogCallback)(void *ctx, const char *msg);
typedef void (*ALPairReadyCb)(void *ctx,
                              const char *service_id,
                              uint16_t port,
                              const char *const *txt_keys,
                              const char *const *txt_vals,
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

extern int32_t al_pairing_run_host(const char *bind_addr,
                                   uint16_t port,
                                   const char *name,
                                   const char *model,
                                   const char *out_path,
                                   const char *host_alt_irk_hex,
                                   ALPairReadyCb ready_cb,
                                   ALPairPinCb pin_cb,
                                   void *ctx,
                                   ALPairResult *out);
extern void al_pairing_result_free(ALPairResult *result);
extern void al_string_free(char *value);
extern int32_t al_iplay_carkit_run(const char *pairing_path,
                                   const char *airplay_ip,
                                   const char *device_identifier,
                                   const char *public_key,
                                   const char *source_version,
                                   ALLogCallback log_cb,
                                   void *ctx,
                                   char **out_error);
extern void al_iplay_carkit_stop(void);

static NSString * const kIPlayPairingFilename = @"iplay_pairing.plist";
static NSString * const kIPlayAltIRKDefaultsKey = @"iPlayRemotePairingHostAltIRK";

@interface IPlayLocalDevContext : NSObject
@property(nonatomic, copy) void (^status)(NSString *);
@property(nonatomic, copy) void (^completion)(BOOL, NSString *);
@property(nonatomic, assign) DNSServiceRef pairingAdvertisement;
@end

@implementation IPlayLocalDevContext
- (void)dealloc {
    if (_pairingAdvertisement) {
        DNSServiceRefDeallocate(_pairingAdvertisement);
        _pairingAdvertisement = NULL;
    }
}
@end

static NSString *iPlayPairingPath(void) {
    NSArray<NSURL *> *urls =
        [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                inDomains:NSUserDomainMask];
    NSURL *documents = urls.firstObject;
    if (!documents) {
        documents = [NSURL fileURLWithPath:NSTemporaryDirectory()
                               isDirectory:YES];
    }
    return [[documents URLByAppendingPathComponent:kIPlayPairingFilename]
            path];
}

BOOL iPlayHasLocalPairingFile(void) {
    NSString *path = iPlayPairingPath();
    NSDictionary *attributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return attributes && [attributes fileSize] > 32;
}

NSString *iPlayLocalPairingPath(void) {
    return iPlayPairingPath();
}

void iPlayOpenLocalDevVPN(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *url = [NSURL URLWithString:@"localdevvpn://"];
        if (url) {
            [[UIApplication sharedApplication] openURL:url
                                               options:@{}
                                     completionHandler:nil];
        }
    });
}

static void iPlayEmitStatus(IPlayLocalDevContext *context, NSString *message) {
    if (!context || !context.status || !message.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        context.status(message);
    });
}

static void DNSSD_API iPlayPairRegistrationCallback(
    DNSServiceRef sdRef,
    DNSServiceFlags flags,
    DNSServiceErrorType errorCode,
    const char *name,
    const char *regtype,
    const char *domain,
    void *contextPointer) {
    (void)sdRef;
    (void)flags;
    IPlayLocalDevContext *context =
        (__bridge IPlayLocalDevContext *)contextPointer;
    if (errorCode == kDNSServiceErr_NoError) {
        iPlayEmitStatus(
            context,
            [NSString stringWithFormat:@"Pairing host ready: %s", name ?: "iPlay"]);
    } else {
        iPlayEmitStatus(
            context,
            [NSString stringWithFormat:@"Pairing Bonjour error: %d",
             (int)errorCode]);
    }
    (void)regtype;
    (void)domain;
}

static void iPlayPairReady(void *opaque,
                           const char *serviceID,
                           uint16_t port,
                           const char *const *txtKeys,
                           const char *const *txtValues,
                           size_t txtCount) {
    IPlayLocalDevContext *context =
        (__bridge IPlayLocalDevContext *)opaque;
    if (!context) return;

    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);
    for (size_t i = 0; i < txtCount; i++) {
        const char *key = txtKeys ? txtKeys[i] : NULL;
        const char *value = txtValues ? txtValues[i] : NULL;
        if (!key || !*key) continue;
        uint8_t valueLength =
            value ? (uint8_t)MIN(strlen(value), (size_t)255) : 0;
        TXTRecordSetValue(&txt, key, valueLength, value);
    }

    DNSServiceRef ref = NULL;
    DNSServiceErrorType error = DNSServiceRegister(
        &ref,
        0,
        0,
        (serviceID && *serviceID) ? serviceID : "iPlay",
        "_remotepairing-pairable-host._tcp",
        NULL,
        NULL,
        htons(port),
        TXTRecordGetLength(&txt),
        TXTRecordGetBytesPtr(&txt),
        iPlayPairRegistrationCallback,
        opaque);
    TXTRecordDeallocate(&txt);

    if (error == kDNSServiceErr_NoError && ref) {
        context.pairingAdvertisement = ref;
        DNSServiceSetDispatchQueue(ref, dispatch_get_main_queue());
        iPlayEmitStatus(
            context,
            @"Pairing is ready. Approve iPlay in Settings → Privacy & Security → Developer Mode.");
    } else {
        if (ref) DNSServiceRefDeallocate(ref);
        iPlayEmitStatus(
            context,
            [NSString stringWithFormat:@"Could not advertise pairing host (%d)",
             (int)error]);
    }
}

static void iPlayPairPin(const char *pin, void *opaque) {
    IPlayLocalDevContext *context =
        (__bridge IPlayLocalDevContext *)opaque;
    NSString *pinString =
        pin ? [NSString stringWithUTF8String:pin] : @"";
    iPlayEmitStatus(
        context,
        pinString.length
            ? [NSString stringWithFormat:@"Pairing PIN: %@ — enter/confirm it on this iPhone.",
               pinString]
            : @"Approve the iPlay pairing request on this iPhone.");
}

void iPlayBeginLocalPairing(void (^status)(NSString *),
                            void (^completion)(BOOL, NSString *)) {
    IPlayLocalDevContext *context = [IPlayLocalDevContext new];
    context.status = status;
    context.completion = completion;
    void *opaque = (__bridge_retained void *)context;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *path = iPlayPairingPath();
            [[NSFileManager defaultManager]
                createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                withIntermediateDirectories:YES
                attributes:nil
                error:nil];

            NSString *altIRK =
                [[NSUserDefaults standardUserDefaults]
                    stringForKey:kIPlayAltIRKDefaultsKey] ?: @"";

            iPlayEmitStatus(
                context,
                @"Starting local Remote Pairing host…");

            ALPairResult result = {0};
            int32_t rc = al_pairing_run_host(
                "0.0.0.0",
                0,
                "iPlay",
                "Mac17,7",
                path.fileSystemRepresentation,
                altIRK.UTF8String,
                iPlayPairReady,
                iPlayPairPin,
                opaque,
                &result);

            if (context.pairingAdvertisement) {
                DNSServiceRefDeallocate(context.pairingAdvertisement);
                context.pairingAdvertisement = NULL;
            }

            NSString *error =
                result.error ? [NSString stringWithUTF8String:result.error] : nil;
            NSString *returnedIRK =
                result.host_alt_irk_hex
                    ? [NSString stringWithUTF8String:result.host_alt_irk_hex]
                    : nil;

            if (rc == 0 && returnedIRK.length) {
                [[NSUserDefaults standardUserDefaults]
                    setObject:returnedIRK
                    forKey:kIPlayAltIRKDefaultsKey];
            }

            BOOL success = (rc == 0 && iPlayHasLocalPairingFile());
            NSString *message = success
                ? @"This iPhone is paired with iPlay."
                : (error.length ? error : @"Remote Pairing did not complete.");

            al_pairing_result_free(&result);

            dispatch_async(dispatch_get_main_queue(), ^{
                if (context.completion) context.completion(success, message);
                CFBridgingRelease(opaque);
            });
        }
    });
}

static void iPlayCarKitLog(void *opaque, const char *message) {
    IPlayLocalDevContext *context =
        (__bridge IPlayLocalDevContext *)opaque;
    if (!context || !message) return;
    NSString *line = [NSString stringWithUTF8String:message];
    if (line.length) iPlayEmitStatus(context, line);
}

void iPlayBeginSameDeviceCarPlay(void (^status)(NSString *),
                                 void (^completion)(BOOL, NSString *)) {
    IPlayLocalDevContext *context = [IPlayLocalDevContext new];
    context.status = status;
    context.completion = completion;
    void *opaque = (__bridge_retained void *)context;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *pairingPath = iPlayPairingPath();
            if (!iPlayHasLocalPairingFile()) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (context.completion) {
                        context.completion(
                            NO,
                            @"Pair this iPhone with iPlay first.");
                    }
                    CFBridgingRelease(opaque);
                });
                return;
            }

            /*
             * The receiver is bound dual-stack on ::/0:7000. For A→A the
             * CarPlay source and receiver share the same network namespace,
             * so ::1 is the lowest-latency deterministic endpoint.
             */
            iPlayEmitStatus(
                context,
                @"Opening LocalDevVPN CarKit service on this iPhone…");

            char *error = NULL;
            int32_t rc = al_iplay_carkit_run(
                pairingPath.fileSystemRepresentation,
                "::1",
                "90:B9:31:AC:86:A0",
                "1b15f0ad62c894721c4097651801e62845451a183c8df8af7d6b20430823586f",
                "509.0",
                iPlayCarKitLog,
                opaque,
                &error);

            NSString *message =
                error ? [NSString stringWithUTF8String:error] : nil;
            if (error) al_string_free(error);

            BOOL success = (rc == 0);
            if (!success && !message.length) {
                message = @"The local CarKit session ended before CarPlay connected.";
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (context.completion) context.completion(success, message ?: @"");
                CFBridgingRelease(opaque);
            });
        }
    });
}

void iPlayStopSameDeviceCarPlay(void) {
    al_iplay_carkit_stop();
}
