#import <Foundation/Foundation.h>
#import <CoreGraphics/CGDirectDisplay.h>

@interface VirtualDisplayHelper : NSObject
+ (NSObject * _Nullable)create;
+ (void)destroy;
+ (BOOL)isCreated;
/// CFUUID-string identifier of the created virtual display, or nil if not created
/// (or if macOS hasn't assigned a UUID yet — can happen briefly after creation).
+ (NSString * _Nullable)displayUUIDString;
/// CGDirectDisplayID of the created virtual display, or 0 if not created.
/// Unlike displayUUIDString, this is captured synchronously at create time
/// and is immediately available — use it for race-free display identification.
+ (CGDirectDisplayID)displayID;
/// Width / height of the most-recently-created virtual display (whatever was
/// passed at create-time, after defaults clamping). 0 / 0 if not created.
+ (unsigned int)currentWidth;
+ (unsigned int)currentHeight;
@end
