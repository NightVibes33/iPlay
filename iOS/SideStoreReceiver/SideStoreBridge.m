#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

BOOL iPlayProbePrivateBluetooth(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
    if (!handle) return NO;
    Class cls = NSClassFromString(@"BluetoothManager");
    SEL sel = NSSelectorFromString(@"sharedInstance");
    if (!cls || ![cls respondsToSelector:sel]) return NO;
    id (*sendId)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return sendId(cls, sel) != nil;
}
