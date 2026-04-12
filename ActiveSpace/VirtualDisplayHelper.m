#import "VirtualDisplayHelper.h"
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@implementation VirtualDisplayHelper

static id _virtualDisplay = nil;

+ (NSObject *)create {
    if (_virtualDisplay) return _virtualDisplay;

    Class CGVirtualDisplayMode = NSClassFromString(@"CGVirtualDisplayMode");
    Class CGVirtualDisplayDescriptor = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class CGVirtualDisplay = NSClassFromString(@"CGVirtualDisplay");

    if (!CGVirtualDisplay) {
        NSLog(@"ActiveSpace: CGVirtualDisplay not available");
        return nil;
    }

    // Create mode: 1x1 @ 1Hz — just enough to force UUID-based display identifiers.
    // A tiny display prevents macOS from relocating or resizing user windows onto it.
    SEL modeSel = NSSelectorFromString(@"initWithWidth:height:refreshRate:");
    NSMethodSignature *modeSig = [CGVirtualDisplayMode instanceMethodSignatureForSelector:modeSel];
    NSInvocation *modeInv = [NSInvocation invocationWithMethodSignature:modeSig];
    modeInv.selector = modeSel;
    unsigned int w = 1, h = 1;
    double rate = 1.0;
    [modeInv setArgument:&w atIndex:2];
    [modeInv setArgument:&h atIndex:3];
    [modeInv setArgument:&rate atIndex:4];
    id modeObj = [CGVirtualDisplayMode alloc];
    [modeInv invokeWithTarget:modeObj];
    __unsafe_unretained id mode;
    [modeInv getReturnValue:&mode];

    if (!mode) {
        NSLog(@"ActiveSpace: Failed to create CGVirtualDisplayMode");
        return nil;
    }

    // Create descriptor
    id desc = [[CGVirtualDisplayDescriptor alloc] init];
    [desc setValue:@"ActiveSpace Virtual Display" forKey:@"name"];
    [desc setValue:@(0xACE5) forKey:@"vendorID"];
    [desc setValue:@(0x0001) forKey:@"productID"];
    [desc setValue:@(0x0001) forKey:@"serialNum"];
    [desc setValue:@(1) forKey:@"maxPixelsWide"];
    [desc setValue:@(1) forKey:@"maxPixelsHigh"];
    [desc setValue:[NSValue valueWithSize:NSMakeSize(1, 1)] forKey:@"sizeInMillimeters"];
    [desc setValue:dispatch_get_main_queue() forKey:@"queue"];

    // Create virtual display
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id display = [[CGVirtualDisplay alloc] performSelector:NSSelectorFromString(@"initWithDescriptor:") withObject:desc];
#pragma clang diagnostic pop

    if (display) {
        _virtualDisplay = display;
        NSNumber *displayID = [display valueForKey:@"displayID"];
        NSLog(@"ActiveSpace: Virtual display created (ID %u)", displayID.unsignedIntValue);
        return display;
    }

    NSLog(@"ActiveSpace: Failed to create virtual display");
    return nil;
}

@end
