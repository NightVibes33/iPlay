#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

static id gSessionRequestClient = nil;
static id gSessionRequestHost = nil;

static BOOL iPlayLoadFramework(NSString *path) {
    return dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL) != NULL;
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

    id host = ((id (*)(id, SEL))objc_msgSend)(hostClass, @selector(alloc));
    SEL initSel = NSSelectorFromString(@"initWithDisplayName:wiredIPv6Addresses:wirelessIPv6Addresses:port:carplayWiFiUUID:deviceIdentifier:publicKey:sourceVersion:supportsMutualAuthentication:authenticationCertificateSerial:pairedVehicleIdentifier:wiredCarPlaySimulator:remoteDeviceConnected:displayScaleMode:zoomFactor:");
    if (![host respondsToSelector:initSel]) return nil;

    typedef id (*InitHostFn)(id, SEL, id, id, id, long long, id, id, id, id, BOOL, id, id, BOOL, BOOL, long long, id);
    InitHostFn initHost = (InitHostFn)objc_msgSend;
    NSString *wifiUUID = [NSUUID UUID].UUIDString;
    NSString *deviceID = @"90:B9:31:AC:86:A0";
    NSString *publicKey = @"1b15f0ad62c894721c4097651801e62845451a183c8df8af7d6b20430823586f";
    return initHost(host, initSel,
                    displayName ?: @"iPlay",
                    wiredAddresses ?: @[],
                    wirelessAddresses ?: @[],
                    (long long)port,
                    wifiUUID,
                    deviceID,
                    publicKey,
                    @"509.0",
                    NO,
                    nil,
                    [NSUUID UUID],
                    simulator,
                    remoteConnected,
                    0,
                    @1.0);
}

static BOOL iPlayStartSessionWithHost(id host, BOOL localSimulator) {
    if (!host) return NO;
    Class clientClass = NSClassFromString(@"CARSessionRequestClient");
    if (!clientClass) return NO;
    id client = ((id (*)(id, SEL))objc_msgSend)(clientClass, @selector(alloc));
    client = ((id (*)(id, SEL))objc_msgSend)(client, @selector(init));
    if (!client) return NO;

    if (localSimulator) {
        SEL advertise = NSSelectorFromString(@"startAdvertisingCarPlayControlForUSBWithHost:");
        if ([client respondsToSelector:advertise]) {
            ((void (*)(id, SEL, id))objc_msgSend)(client, advertise, host);
        }
    } else {
        SEL wifiUUIDSel = NSSelectorFromString(@"carplayWiFiUUID");
        id wifiUUID = [host respondsToSelector:wifiUUIDSel]
            ? ((id (*)(id, SEL))objc_msgSend)(host, wifiUUIDSel) : nil;
        SEL advertise = NSSelectorFromString(@"startAdvertisingCarPlayControlForWiFiUUID:host:");
        if (wifiUUID && [client respondsToSelector:advertise]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(client, advertise, wifiUUID, host);
        }
    }

    SEL start = NSSelectorFromString(@"startSessionWithHost:requestIdentifier:completion:");
    if (![client respondsToSelector:start]) return NO;
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(
        client, start, host, [NSUUID UUID].UUIDString, nil);

    gSessionRequestClient = client;
    gSessionRequestHost = host;
    return YES;
}

BOOL iPlayStartLocalCarPlaySession(NSString *displayName, NSInteger port) {
    id host = iPlayCreateSessionHost(displayName, @[@"::1"], @[], port, YES, NO);
    return iPlayStartSessionWithHost(host, YES);
}

BOOL iPlayStartRemoteCarPlaySession(NSString *displayName, NSString *address, NSInteger port) {
    if (!address.length) return NO;
    id host = iPlayCreateSessionHost(displayName, @[], @[address], port, NO, YES);
    return iPlayStartSessionWithHost(host, NO);
}

void iPlayStopRequestedCarPlaySession(void) {
    if (gSessionRequestClient) {
        SEL cancel = NSSelectorFromString(@"cancelRequests");
        if ([gSessionRequestClient respondsToSelector:cancel]) {
            ((void (*)(id, SEL))objc_msgSend)(gSessionRequestClient, cancel);
        }
    }
    gSessionRequestClient = nil;
    gSessionRequestHost = nil;
}
