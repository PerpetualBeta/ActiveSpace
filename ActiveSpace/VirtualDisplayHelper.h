#import <Foundation/Foundation.h>

@interface VirtualDisplayHelper : NSObject
+ (NSObject * _Nullable)create;
+ (void)destroy;
+ (BOOL)isCreated;
/// CFUUID-string identifier of the created virtual display, or nil if not created
/// (or if macOS hasn't assigned a UUID yet — can happen briefly after creation).
+ (NSString * _Nullable)displayUUIDString;
@end
