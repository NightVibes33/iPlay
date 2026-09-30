#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <dns_sd.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <math.h>

static id gSessionRequestClient = nil;
static id gSessionRequestHost = nil;
static NSString *gSessionRequestIdentifier = nil;
static CFTypeRef gLocalCarPlayEndpointManager = NULL;
static void *gAirPlaySenderHandle = NULL;
static void *gAPTransportHandle = NULL;
static id gAPSharedSessionHandler = nil;
static IMP gAPOriginalAddCarPlayHelper = NULL;
static IMP gAPOriginalRegisterMachService = NULL;

extern BOOL iPlayStartLocalDevVPNCarPlay(NSString *displayName, NSInteger airPlayPort);
extern void iPlayStopLocalDevVPNCarPlay(void);

static BOOL iPlayLoadFramework(NSString *path) {
    return dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL) != NULL;
}


/*
 * APTransport keeps its useful APCarSessionRequestHandler as an internal
 * singleton. APBrowserCarSessionCreate registers every CarPlay helper by
 * sending -addCarPlayHelper: to that singleton. Capture the receiver of that
 * message while preserving the original implementation verbatim.
 *
 * This gives A -> A a direct in-process route to
 * -startSessionWithHost:requestIdentifier:completion: and avoids the
 * entitlement-gated com.apple.carkit.sessionRequestHandler XPC service.
 */
static void iPlayCaptureAddCarPlayHelper(id self, SEL _cmd, id helper) {
    gAPSharedSessionHandler = self;
    IMP original = gAPOriginalAddCarPlayHelper;
    if (original) {
        ((void (*)(id, SEL, id))original)(self, _cmd, helper);
    }
}


static void iPlaySuppressSessionRequestMachService(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    /*
     * The direct SideStore A->A path calls the shared handler in-process.
     * Registering Apple's global carkitd Mach service from this app is both
     * unnecessary and potentially rejected/colliding, so intentionally no-op.
     */
    NSLog(@"[iPlay:A->A] Suppressed APTransport carkitd Mach-service registration");
}

static BOOL iPlayInstallAPSessionHandlerCapture(void) {
    Class cls = NSClassFromString(@"APCarSessionRequestHandler");
    if (!cls) return NO;

    SEL sel = NSSelectorFromString(@"addCarPlayHelper:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP current = method_getImplementation(method);
    IMP capture = (IMP)iPlayCaptureAddCarPlayHelper;
    if (current != capture) {
        gAPOriginalAddCarPlayHelper = current;
        method_setImplementation(method, capture);
    }

    SEL registerSel =
        NSSelectorFromString(@"registerSessionRequestHandlerMachService");
    Method registerMethod = class_getInstanceMethod(cls, registerSel);
    if (registerMethod) {
        IMP suppress = (IMP)iPlaySuppressSessionRequestMachService;
        IMP registerCurrent = method_getImplementation(registerMethod);
        if (registerCurrent != suppress) {
            gAPOriginalRegisterMachService = registerCurrent;
            method_setImplementation(registerMethod, suppress);
        }
    }

    return YES;
}

static id iPlayWaitForSharedAPSessionHandler(NSTimeInterval timeout) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + MAX(timeout, 0.0);
    do {
        id handler = gAPSharedSessionHandler;
        if (handler) return handler;
        usleep(20000);
    } while (CFAbsoluteTimeGetCurrent() < deadline);
    return gAPSharedSessionHandler;
}


/*
 * Same-device CarPlay source path.
 *
 * AirPlaySender's APEndpointManagerCarPlayCreate is Apple's own local
 * CarPlay endpoint manager factory. It initializes the CarPlay control
 * server plus USB/Wi-Fi/session browsers. APTransport's session browser
 * in turn creates/registers its CarPlay helper with the shared
 * APCarSessionRequestHandler.
 *
 * This is deliberately the primary A -> A path. CARSessionRequestClient
 * is retained only as a compatibility fallback because its carkitd XPC
 * endpoint is entitlement-gated on stock builds.
 */
static BOOL iPlayStartInProcessCarPlaySourceStack(void) {
    if (gLocalCarPlayEndpointManager) return YES;

    gAPTransportHandle = dlopen(
        "/System/Library/PrivateFrameworks/APTransport.framework/APTransport",
        RTLD_NOW | RTLD_GLOBAL);
    gAirPlaySenderHandle = dlopen(
        "/System/Library/PrivateFrameworks/AirPlaySender.framework/AirPlaySender",
        RTLD_NOW | RTLD_GLOBAL);
    if (!gAPTransportHandle || !gAirPlaySenderHandle) {
        NSLog(@"[iPlay:A->A] APTransport/AirPlaySender unavailable");
        return NO;
    }

    if (!iPlayInstallAPSessionHandlerCapture()) {
        NSLog(@"[iPlay:A->A] Could not install APTransport helper capture");
        return NO;
    }

    typedef int32_t (*APEndpointManagerCarPlayCreateFn)(
        CFAllocatorRef allocator,
        CFDictionaryRef options,
        CFTypeRef *managerOut);

    APEndpointManagerCarPlayCreateFn create =
        (APEndpointManagerCarPlayCreateFn)dlsym(
            gAirPlaySenderHandle, "APEndpointManagerCarPlayCreate");
    if (!create) {
        NSLog(@"[iPlay:A->A] APEndpointManagerCarPlayCreate not exported");
        return NO;
    }

    CFTypeRef manager = NULL;
    int32_t status = create(kCFAllocatorDefault, NULL, &manager);
    if (status != 0 || !manager) {
        NSLog(@"[iPlay:A->A] APEndpointManagerCarPlayCreate failed status=%d manager=%p",
              status, manager);
        if (manager) CFRelease(manager);
        return NO;
    }

    gLocalCarPlayEndpointManager = manager;
    NSLog(@"[iPlay:A->A] Apple CarPlay endpoint manager active: %p", manager);
    return YES;
}

static void iPlayStopInProcessCarPlaySourceStack(void) {
    if (!gLocalCarPlayEndpointManager) return;

    /*
     * Fig endpoint managers are CF/CM base objects. Releasing the retained
     * manager runs the framework's normal invalidation/finalization path.
     */
    CFRelease(gLocalCarPlayEndpointManager);
    gLocalCarPlayEndpointManager = NULL;
    NSLog(@"[iPlay:A->A] Apple CarPlay endpoint manager released");
}


static NSUUID *iPlayStablePairedVehicleIdentifier(void) {
    static NSUUID *identifier = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *stored = [defaults stringForKey:@"iPlayCarPlayVehicleIdentifier"];
        identifier = stored.length ? [[NSUUID alloc] initWithUUIDString:stored] : nil;
        if (!identifier) {
            identifier = [[NSUUID alloc] initWithUUIDString:@"49504C41-592D-4341-5250-4C4159414131"];
            [defaults setObject:identifier.UUIDString forKey:@"iPlayCarPlayVehicleIdentifier"];
        }
    });
    return identifier;
}

static NSString *iPlayStableCarPlayWiFiUUID(void) {
    static NSString *value = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        value = [defaults stringForKey:@"iPlayCarPlayWiFiUUID"];
        if (!value.length) {
            value = @"49504C41-592D-5749-4649-555549444131";
            [defaults setObject:value forKey:@"iPlayCarPlayWiFiUUID"];
        }
    });
    return value;
}


static BOOL iPlayEnsurePairedVehicleRecord(NSString *displayName) {
    if (!iPlayLoadFramework(@"/System/Library/PrivateFrameworks/CarKit.framework/CarKit")) {
        NSLog(@"[iPlay:Settings] CarKit unavailable");
        return NO;
    }

    Class vehicleClass = NSClassFromString(@"CRVehicle");
    Class managerClass = NSClassFromString(@"CRPairedVehicleManager");
    if (!vehicleClass || !managerClass) {
        NSLog(@"[iPlay:Settings] CRVehicle/CRPairedVehicleManager unavailable");
        return NO;
    }

    NSString *name = displayName.length ? displayName : @"iPlay";
    NSUUID *identifier = iPlayStablePairedVehicleIdentifier();
    NSString *wifiUUID = iPlayStableCarPlayWiFiUUID();

    id vehicle = ((id (*)(id, SEL))objc_msgSend)(vehicleClass, @selector(alloc));
    SEL initPair = NSSelectorFromString(@"initWithIdentifier:certificateSerial:");
    if ([vehicle respondsToSelector:initPair]) {
        vehicle = ((id (*)(id, SEL, id, id))objc_msgSend)(vehicle, initPair, identifier, nil);
    } else {
        vehicle = ((id (*)(id, SEL))objc_msgSend)(vehicle, @selector(init));
        SEL setIdentifier = NSSelectorFromString(@"setIdentifier:");
        if ([vehicle respondsToSelector:setIdentifier]) {
            ((void (*)(id, SEL, id))objc_msgSend)(vehicle, setIdentifier, identifier);
        }
    }
    if (!vehicle) return NO;

    struct ObjSetter { const char *name; id value; } objectSetters[] = {
        {"setVehicleName:", name},
        {"setVehicleModelName:", @"iPlay Head Unit"},
        {"setCarplayWiFiUUID:", wifiUUID},
        {"setBluetoothAddress:", @"90:B9:31:AC:86:A0"},
        {"setSupportsStartSessionRequest:", @YES},
        {"setLastConnectedDate:", [NSDate date]},
        {"setSDKVersion:", @"iPlay-SideStore-1"},
    };
    for (size_t i = 0; i < sizeof(objectSetters)/sizeof(objectSetters[0]); i++) {
        SEL sel = NSSelectorFromString([NSString stringWithUTF8String:objectSetters[i].name]);
        if ([vehicle respondsToSelector:sel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(vehicle, sel, objectSetters[i].value);
        }
    }

    SEL setPairing = NSSelectorFromString(@"setPairingStatus:");
    if ([vehicle respondsToSelector:setPairing]) {
        ((void (*)(id, SEL, unsigned long long))objc_msgSend)(vehicle, setPairing, 2ULL);
    }
    SEL setUSB = NSSelectorFromString(@"setSupportsUSBCarPlay:");
    if ([vehicle respondsToSelector:setUSB]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(vehicle, setUSB, YES);
    }
    SEL setWireless = NSSelectorFromString(@"setSupportsWirelessCarPlay:");
    if ([vehicle respondsToSelector:setWireless]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(vehicle, setWireless, YES);
    }
    SEL setBLE = NSSelectorFromString(@"setSupportsBluetoothLE:");
    if ([vehicle respondsToSelector:setBLE]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(vehicle, setBLE, YES);
    }

    id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(alloc));
    manager = ((id (*)(id, SEL))objc_msgSend)(manager, @selector(init));
    if (!manager) return NO;

    SEL save = NSSelectorFromString(@"saveVehicle:");
    id saved = nil;
    if ([manager respondsToSelector:save]) {
        saved = ((id (*)(id, SEL, id))objc_msgSend)(manager, save, vehicle);
    } else {
        SEL saveAsync = NSSelectorFromString(@"saveVehicle:completion:");
        if ([manager respondsToSelector:saveAsync]) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block id result = nil;
            void (^completion)(id, NSError *) = ^(id value, NSError *error) {
                if (error) NSLog(@"[iPlay:Settings] saveVehicle error=%@", error);
                result = value;
                dispatch_semaphore_signal(sem);
            };
            ((void (*)(id, SEL, id, id))objc_msgSend)(manager, saveAsync, vehicle, completion);
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
            saved = result;
        }
    }

    SEL paired = NSSelectorFromString(@"pairedVehicles");
    NSArray *vehicles = [manager respondsToSelector:paired]
        ? ((id (*)(id, SEL))objc_msgSend)(manager, paired) : nil;

    BOOL found = NO;
    for (id item in vehicles ?: @[]) {
        SEL identSel = NSSelectorFromString(@"identifier");
        id itemID = [item respondsToSelector:identSel]
            ? ((id (*)(id, SEL))objc_msgSend)(item, identSel) : nil;
        if ([itemID isEqual:identifier]) {
            found = YES;
            break;
        }
    }

    NSLog(@"[iPlay:Settings] paired vehicle save=%@ visible=%d count=%lu",
          saved ?: vehicle, found ? 1 : 0, (unsigned long)vehicles.count);
    return found || saved != nil;
}

BOOL iPlayProbePrivateBluetooth(void) {
    if (!iPlayLoadFramework(@"/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager")) return NO;
    Class cls = NSClassFromString(@"BluetoothManager");
    SEL sel = NSSelectorFromString(@"sharedInstance");
    if (!cls || ![cls respondsToSelector:sel]) return NO;
    id (*sendId)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return sendId(cls, sel) != nil;
}

BOOL iPlayPreparePrivateBluetooth(void) {
    if (!iPlayProbePrivateBluetooth()) return NO;
    Class cls = NSClassFromString(@"BluetoothManager");
    id (*sendId)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id manager = sendId(cls, NSSelectorFromString(@"sharedInstance"));
    if (!manager) return NO;

    BOOL (*sendBool)(id, SEL, BOOL) = (BOOL (*)(id, SEL, BOOL))objc_msgSend;
    void (*sendVoidBool)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;

    SEL setPowered = NSSelectorFromString(@"setPowered:");
    SEL setEnabled = NSSelectorFromString(@"setEnabled:");
    SEL setConnectable = NSSelectorFromString(@"setConnectable:");
    SEL setDiscoverable = NSSelectorFromString(@"setDiscoverable:");
    SEL setPairing = NSSelectorFromString(@"setDevicePairingEnabled:");

    if ([manager respondsToSelector:setPowered]) sendBool(manager, setPowered, YES);
    if ([manager respondsToSelector:setEnabled]) sendBool(manager, setEnabled, YES);
    if ([manager respondsToSelector:setConnectable]) sendVoidBool(manager, setConnectable, YES);
    if ([manager respondsToSelector:setDiscoverable]) sendVoidBool(manager, setDiscoverable, YES);
    if ([manager respondsToSelector:setPairing]) sendVoidBool(manager, setPairing, YES);
    return YES;
}

static id iPlayCreateSessionHost(NSString *displayName,
                                 NSArray *wiredAddresses,
                                 NSArray *wirelessAddresses,
                                 NSInteger port,
                                 BOOL simulator,
                                 BOOL remoteConnected) {
    if (!iPlayLoadFramework(@"/System/Library/PrivateFrameworks/CarKit.framework/CarKit")) return nil;
    Class hostClass = NSClassFromString(@"CARSessionRequestHost");
    if (!hostClass) return nil;

    NSString *name = displayName.length ? displayName : @"iPlay";
    NSArray *wired = wiredAddresses ?: @[];
    NSArray *wireless = wirelessAddresses ?: @[];

    /*
     * A->A is deliberately a wired CarPlay-simulator session over loopback.
     * Do not populate wireless pairing identity for that path: APTransport
     * treats a non-nil carplayWiFiUUID as a request to enter Wi-Fi
     * connectivity state even when wiredCarPlaySimulator is true.
     */
    BOOL localSimulator = simulator && !remoteConnected;
    NSString *wifiUUID = localSimulator ? nil : iPlayStableCarPlayWiFiUUID();
    NSString *deviceID = @"90:B9:31:AC:86:A0";
    NSString *publicKey = localSimulator ? nil :
        @"1b15f0ad62c894721c4097651801e62845451a183c8df8af7d6b20430823586f";
    NSString *sourceVersion = @"509.0";
    /*
     * Keep a stable pairedVehicleIdentifier even for the local simulator.
     * This is the bridge between an A->A session and the CRVehicle record
     * shown by Settings -> General -> CarPlay. It is not a Wi-Fi identity.
     */
    NSUUID *pairedIdentifier = iPlayStablePairedVehicleIdentifier();

    id host = ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(alloc));

    SEL newest = NSSelectorFromString(@"initWithDisplayName:wiredIPv6Addresses:wirelessIPv6Addresses:port:carplayWiFiUUID:deviceIdentifier:publicKey:sourceVersion:supportsMutualAuthentication:authenticationCertificateSerial:pairedVehicleIdentifier:wiredCarPlaySimulator:remoteDeviceConnected:displayScaleMode:zoomFactor:");
    if ([host respondsToSelector:newest]) {
        typedef id (*Fn)(id, SEL, id, id, id, long long, id, id, id, id, BOOL, id, id, BOOL, BOOL, long long, id);
        return ((Fn)objc_msgSend)(host, newest, name, wired, wireless, (long long)port,
                                 wifiUUID, deviceID, publicKey, sourceVersion, NO, nil,
                                 pairedIdentifier, simulator, remoteConnected, 0, @1.0);
    }

    SEL remote = NSSelectorFromString(@"initWithDisplayName:wiredIPv6Addresses:wirelessIPv6Addresses:port:carplayWiFiUUID:deviceIdentifier:publicKey:sourceVersion:supportsMutualAuthentication:authenticationCertificateSerial:pairedVehicleIdentifier:wiredCarPlaySimulator:remoteDeviceConnected:");
    if ([host respondsToSelector:remote]) {
        typedef id (*Fn)(id, SEL, id, id, id, long long, id, id, id, id, BOOL, id, id, BOOL, BOOL);
        return ((Fn)objc_msgSend)(host, remote, name, wired, wireless, (long long)port,
                                 wifiUUID, deviceID, publicKey, sourceVersion, NO, nil,
                                 pairedIdentifier, simulator, remoteConnected);
    }

    SEL legacy = NSSelectorFromString(@"initWithDisplayName:wiredIPv6Addresses:wirelessIPv6Addresses:port:carplayWiFiUUID:deviceIdentifier:publicKey:sourceVersion:supportsMutualAuthentication:authenticationCertificateSerial:pairedVehicleIdentifier:wiredCarPlaySimulator:");
    if ([host respondsToSelector:legacy]) {
        typedef id (*Fn)(id, SEL, id, id, id, long long, id, id, id, id, BOOL, id, id, BOOL);
        return ((Fn)objc_msgSend)(host, legacy, name, wired, wireless, (long long)port,
                                 wifiUUID, deviceID, publicKey, sourceVersion, NO, nil,
                                 pairedIdentifier, simulator);
    }

    return nil;
}

static BOOL iPlayStartSessionWithHost(id host, BOOL localSimulator) {
    if (!host) return NO;
    if (!iPlayLoadFramework(@"/System/Library/PrivateFrameworks/CarKit.framework/CarKit")) return NO;
    Class clientClass = NSClassFromString(@"CARSessionRequestClient");
    if (!clientClass) return NO;

    id client = ((id (*)(id, SEL))objc_msgSend)(clientClass, @selector(alloc));
    client = ((id (*)(id, SEL))objc_msgSend)(client, @selector(init));
    if (!client) return NO;

    if (localSimulator) {
        SEL withHost = NSSelectorFromString(@"startAdvertisingCarPlayControlForUSBWithHost:");
        SEL plain = NSSelectorFromString(@"startAdvertisingCarPlayControlForUSB");
        if ([client respondsToSelector:withHost]) {
            ((void (*)(id, SEL, id))objc_msgSend)(client, withHost, host);
        } else if ([client respondsToSelector:plain]) {
            ((void (*)(id, SEL))objc_msgSend)(client, plain);
        }
    } else {
        SEL wifiUUIDSel = NSSelectorFromString(@"carplayWiFiUUID");
        id wifiUUID = [host respondsToSelector:wifiUUIDSel]
            ? ((id (*)(id, SEL))objc_msgSend)(host, wifiUUIDSel) : nil;
        SEL withHost = NSSelectorFromString(@"startAdvertisingCarPlayControlForWiFiUUID:host:");
        SEL plain = NSSelectorFromString(@"startAdvertisingCarPlayControlForWiFiUUID:");
        if (wifiUUID && [client respondsToSelector:withHost]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(client, withHost, wifiUUID, host);
        } else if (wifiUUID && [client respondsToSelector:plain]) {
            ((void (*)(id, SEL, id))objc_msgSend)(client, plain, wifiUUID);
        }
    }

    SEL start = NSSelectorFromString(@"startSessionWithHost:requestIdentifier:completion:");
    if (![client respondsToSelector:start]) return NO;

    NSString *requestID = [NSUUID UUID].UUIDString;
    void (^completion)(void) = ^{
        NSLog(@"[iPlay] CarKit accepted session request %@", requestID);
    };
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(client, start, host, requestID, completion);

    gSessionRequestClient = client;
    gSessionRequestHost = host;
    gSessionRequestIdentifier = requestID;
    return YES;
}

BOOL iPlayStartLocalCarPlaySession(NSString *displayName, NSInteger port) {
    /*
     * Do not use CRPairedVehicleManager as the primary persistence path here.
     * Its carkitd XPC service requires com.apple.private.carkit, which a normal
     * SideStore provisioning profile does not carry. The trusted RSD/iAP2
     * accessory session below lets carkitd itself create/save the paired
     * vehicle, which is exactly what Settings -> General -> CarPlay reads.
     */
    NSLog(@"[iPlay:Settings] A->A vehicle persistence delegated to trusted RSD/iAP2 CarKit lifecycle");

    /*
     * Preferred SideStore path: use the same Remote Pairing + LocalDevVPN
     * transport as NFCARD/AirCard. The Rust core opens the trusted RSD
     * com.apple.carkit.service shim and the local controller speaks the wired
     * iAP2 head-unit protocol directly to it.
     */
    if (iPlayStartLocalDevVPNCarPlay(displayName, port)) {
        NSLog(@"[iPlay:A->A] LocalDevVPN/RSD CarKit controller started");
        return YES;
    }

    /*
     * 1. Initialize Apple's own sender stack. APBrowserCarSessionCreate
     *    registers a real CarPlay helper with APTransport's shared handler.
     * 2. Capture that handler in-process.
     * 3. Feed it a wired-simulator host pointed at this app's own dual-stack
     *    AirPlay listener on ::1:7000.
     *
     * No carkitd XPC entitlement is required for this direct method call.
     */
    if (iPlayStartInProcessCarPlaySourceStack()) {
        id handler = iPlayWaitForSharedAPSessionHandler(3.0);
        id host = iPlayCreateSessionHost(
            displayName.length ? displayName : @"iPlay",
            @[@"::1"],
            @[],
            port,
            YES,
            NO);

        SEL start = NSSelectorFromString(
            @"startSessionWithHost:requestIdentifier:completion:");
        if (handler && host && [handler respondsToSelector:start]) {
            NSString *requestID = [NSUUID UUID].UUIDString;
            void (^completion)(BOOL, NSError *) = ^(BOOL accepted, NSError *error) {
                NSLog(@"[iPlay:A->A] APTransport direct StartSession accepted=%d error=%@",
                      accepted ? 1 : 0, error);
            };
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(
                handler, start, host, requestID, completion);

            gSessionRequestHost = host;
            gSessionRequestIdentifier = requestID;
            NSLog(@"[iPlay:A->A] Direct APTransport session submitted handler=%@ host=%@",
                  handler, host);
            return YES;
        }

        NSLog(@"[iPlay:A->A] Sender stack started but shared handler/host unavailable");
    }

    /*
     * Compatibility fallback only. carkitd can reject this route when the
     * SideStore provisioning profile lacks the private sessionRequest
     * entitlement, so successful A -> A must not depend on it.
     */
    id host = iPlayCreateSessionHost(displayName, @[@"::1"], @[], port, YES, NO);
    return iPlayStartSessionWithHost(host, YES);
}

BOOL iPlayStartRemoteCarPlaySession(NSString *displayName, NSString *address, NSInteger port) {
    if (!address.length) return NO;
    id host = iPlayCreateSessionHost(displayName, @[], @[address], port, NO, YES);
    return iPlayStartSessionWithHost(host, NO);
}

typedef struct {
    BOOL found;
    uint32_t interfaceIndex;
    char serviceName[256];
    char regtype[256];
    char domain[256];
} iPlayBrowseContext;

typedef struct {
    BOOL found;
    uint32_t interfaceIndex;
    uint16_t port;
    char hostTarget[1024];
} iPlayResolveContext;

static void DNSSD_API iPlayBrowseCallback(DNSServiceRef sdRef,
                                           DNSServiceFlags flags,
                                           uint32_t interfaceIndex,
                                           DNSServiceErrorType errorCode,
                                           const char *serviceName,
                                           const char *regtype,
                                           const char *replyDomain,
                                           void *context) {
    (void)sdRef;
    if (errorCode != kDNSServiceErr_NoError || !(flags & kDNSServiceFlagsAdd)) return;
    iPlayBrowseContext *ctx = context;
    if (!ctx || ctx->found) return;
    ctx->found = YES;
    ctx->interfaceIndex = interfaceIndex;
    strlcpy(ctx->serviceName, serviceName ?: "", sizeof(ctx->serviceName));
    strlcpy(ctx->regtype, regtype ?: "_iplay-carplay._tcp", sizeof(ctx->regtype));
    strlcpy(ctx->domain, replyDomain ?: "local.", sizeof(ctx->domain));
}

static void DNSSD_API iPlayResolveCallback(DNSServiceRef sdRef,
                                            DNSServiceFlags flags,
                                            uint32_t interfaceIndex,
                                            DNSServiceErrorType errorCode,
                                            const char *fullname,
                                            const char *hosttarget,
                                            uint16_t port,
                                            uint16_t txtLen,
                                            const unsigned char *txtRecord,
                                            void *context) {
    (void)sdRef; (void)flags; (void)fullname; (void)txtLen; (void)txtRecord;
    if (errorCode != kDNSServiceErr_NoError) return;
    iPlayResolveContext *ctx = context;
    if (!ctx || ctx->found) return;
    ctx->found = YES;
    ctx->interfaceIndex = interfaceIndex;
    ctx->port = ntohs(port);
    strlcpy(ctx->hostTarget, hosttarget ?: "", sizeof(ctx->hostTarget));
}

static BOOL iPlayProcessDNSService(DNSServiceRef ref, NSTimeInterval timeout) {
    if (!ref) return NO;
    int fd = DNSServiceRefSockFD(ref);
    if (fd < 0) return NO;
    fd_set readSet;
    FD_ZERO(&readSet);
    FD_SET(fd, &readSet);
    struct timeval tv;
    tv.tv_sec = (int)timeout;
    tv.tv_usec = (int)((timeout - floor(timeout)) * 1000000.0);
    int ready = select(fd + 1, &readSet, NULL, NULL, &tv);
    if (ready <= 0 || !FD_ISSET(fd, &readSet)) return NO;
    return DNSServiceProcessResult(ref) == kDNSServiceErr_NoError;
}

static NSString *iPlayIPv6ForHost(const char *host, uint32_t interfaceIndex) {
    if (!host || !*host) return nil;
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    hints.ai_flags = AI_ADDRCONFIG;

    struct addrinfo *result = NULL;
    if (getaddrinfo(host, NULL, &hints, &result) != 0 || !result) return nil;

    NSString *answer = nil;
    for (struct addrinfo *it = result; it; it = it->ai_next) {
        char text[INET6_ADDRSTRLEN + IF_NAMESIZE + 2] = {0};
        if (it->ai_family == AF_INET6) {
            struct sockaddr_in6 *a6 = (struct sockaddr_in6 *)it->ai_addr;
            char address[INET6_ADDRSTRLEN] = {0};
            if (!inet_ntop(AF_INET6, &a6->sin6_addr, address, sizeof(address))) continue;
            uint32_t scope = a6->sin6_scope_id ?: interfaceIndex;
            if (IN6_IS_ADDR_LINKLOCAL(&a6->sin6_addr) && scope) {
                char ifname[IF_NAMESIZE] = {0};
                if (if_indextoname(scope, ifname)) {
                    snprintf(text, sizeof(text), "%s%%%s", address, ifname);
                } else {
                    snprintf(text, sizeof(text), "%s%%%u", address, scope);
                }
            } else {
                strlcpy(text, address, sizeof(text));
            }
            answer = [NSString stringWithUTF8String:text];
            break;
        }
        if (it->ai_family == AF_INET && !answer) {
            struct sockaddr_in *a4 = (struct sockaddr_in *)it->ai_addr;
            char address[INET_ADDRSTRLEN] = {0};
            if (!inet_ntop(AF_INET, &a4->sin_addr, address, sizeof(address))) continue;
            answer = [NSString stringWithFormat:@"::ffff:%s", address];
        }
    }
    freeaddrinfo(result);
    return answer;
}

NSString *iPlayDiscoverRemoteCarPlayReceiver(NSTimeInterval timeout) {
    if (timeout <= 0) timeout = 5.0;

    iPlayBrowseContext browse = {0};
    DNSServiceRef browseRef = NULL;
    DNSServiceErrorType err = DNSServiceBrowse(&browseRef, 0, 0,
                                               "_iplay-carplay._tcp", "local.",
                                               iPlayBrowseCallback, &browse);
    if (err != kDNSServiceErr_NoError || !browseRef) return nil;

    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    while (!browse.found && CFAbsoluteTimeGetCurrent() < deadline) {
        NSTimeInterval left = deadline - CFAbsoluteTimeGetCurrent();
        if (!iPlayProcessDNSService(browseRef, MIN(left, 0.75))) continue;
    }
    DNSServiceRefDeallocate(browseRef);
    if (!browse.found) return nil;

    iPlayResolveContext resolved = {0};
    DNSServiceRef resolveRef = NULL;
    err = DNSServiceResolve(&resolveRef, 0, browse.interfaceIndex,
                            browse.serviceName, browse.regtype, browse.domain,
                            iPlayResolveCallback, &resolved);
    if (err != kDNSServiceErr_NoError || !resolveRef) return nil;

    deadline = CFAbsoluteTimeGetCurrent() + MAX(1.0, timeout * 0.5);
    while (!resolved.found && CFAbsoluteTimeGetCurrent() < deadline) {
        NSTimeInterval left = deadline - CFAbsoluteTimeGetCurrent();
        if (!iPlayProcessDNSService(resolveRef, MIN(left, 0.75))) continue;
    }
    DNSServiceRefDeallocate(resolveRef);
    if (!resolved.found) return nil;

    return iPlayIPv6ForHost(resolved.hostTarget, resolved.interfaceIndex);
}

void iPlayStopRequestedCarPlaySession(void) {
    iPlayStopLocalDevVPNCarPlay();
    /* Stop the direct APTransport A->A session before releasing its manager. */
    if (gAPSharedSessionHandler && gSessionRequestHost) {
        SEL stopped = NSSelectorFromString(@"stoppedSessionForHostIdentifier:");
        SEL deviceID = NSSelectorFromString(@"deviceIdentifier");
        if ([gAPSharedSessionHandler respondsToSelector:stopped] &&
            [gSessionRequestHost respondsToSelector:deviceID]) {
            id identifier =
                ((id (*)(id, SEL))objc_msgSend)(gSessionRequestHost, deviceID);
            if (identifier) {
                ((void (*)(id, SEL, id))objc_msgSend)(
                    gAPSharedSessionHandler, stopped, identifier);
            }
        }
        SEL cancel = NSSelectorFromString(@"cancelRequests");
        if ([gAPSharedSessionHandler respondsToSelector:cancel]) {
            ((void (*)(id, SEL))objc_msgSend)(gAPSharedSessionHandler, cancel);
        }
    }

    iPlayStopInProcessCarPlaySourceStack();

    if (gSessionRequestClient) {
        SEL cancel = NSSelectorFromString(@"cancelRequests");
        if ([gSessionRequestClient respondsToSelector:cancel]) {
            ((void (*)(id, SEL))objc_msgSend)(gSessionRequestClient, cancel);
        }

        SEL stopped = NSSelectorFromString(@"stoppedSessionForHostIdentifier:");
        SEL paired = NSSelectorFromString(@"pairedVehicleIdentifier");
        if ([gSessionRequestClient respondsToSelector:stopped] &&
            [gSessionRequestHost respondsToSelector:paired]) {
            id identifier = ((id (*)(id, SEL))objc_msgSend)(gSessionRequestHost, paired);
            if (identifier) {
                ((void (*)(id, SEL, id))objc_msgSend)(gSessionRequestClient, stopped, identifier);
            }
        }
    }
    gSessionRequestClient = nil;
    gSessionRequestHost = nil;
    gSessionRequestIdentifier = nil;
}
