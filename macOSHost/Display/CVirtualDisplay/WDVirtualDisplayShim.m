#import "WDVirtualDisplayShim.h"

#if TARGET_OS_OSX

#import <objc/runtime.h>

NSErrorDomain const WDVirtualDisplayErrorDomain = @"WDVirtualDisplayErrorDomain";

static NSError *WDError(WDVirtualDisplayError code, NSString *message) {
    return [NSError errorWithDomain:WDVirtualDisplayErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

// Informal declarations of the private selectors we call. Declaring them as
// protocols (instead of casting objc_msgSend) lets ARC see the method families,
// so alloc/init ownership is balanced and releasing our reference really
// deallocates the private object (BUG-004). No class symbol is referenced:
// classes are still looked up by name at runtime.
@protocol WDPrivateDisplayDescriptor <NSObject>
- (void)setName:(NSString *)name;
- (void)setMaxPixelsWide:(unsigned int)value;
- (void)setMaxPixelsHigh:(unsigned int)value;
- (void)setSizeInMillimeters:(CGSize)size;
- (void)setVendorID:(unsigned int)value;
- (void)setProductID:(unsigned int)value;
- (void)setSerialNum:(unsigned int)value;
- (void)setQueue:(dispatch_queue_t)queue;
- (void)setRedPrimary:(CGPoint)point;
- (void)setGreenPrimary:(CGPoint)point;
- (void)setBluePrimary:(CGPoint)point;
- (void)setWhitePoint:(CGPoint)point;
@end

@protocol WDPrivateDisplayMode <NSObject>
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@protocol WDPrivateDisplaySettings <NSObject>
- (void)setHiDPI:(unsigned int)value;
- (void)setModes:(NSArray *)modes;
@end

@protocol WDPrivateDisplay <NSObject>
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
- (CGDirectDisplayID)displayID;
@end

typedef struct {
    const char *className;
    const char *selector;
    const char *encoding; // exact type encoding observed on macOS 27.2, arm64
} WDRequiredMethod;

// Only what the shim calls. A changed encoding means a changed ABI: refuse.
// These are arm64 encodings (BOOL is 'B'); on x86_64 the check fails closed,
// which is intended: the project targets Apple Silicon only.
static const WDRequiredMethod kRequired[] = {
    {"CGVirtualDisplayDescriptor", "init", "@16@0:8"},
    {"CGVirtualDisplayDescriptor", "setName:", "v24@0:8@16"},
    {"CGVirtualDisplayDescriptor", "setMaxPixelsWide:", "v20@0:8I16"},
    {"CGVirtualDisplayDescriptor", "setMaxPixelsHigh:", "v20@0:8I16"},
    {"CGVirtualDisplayDescriptor", "setSizeInMillimeters:", "v32@0:8{CGSize=dd}16"},
    {"CGVirtualDisplayDescriptor", "setVendorID:", "v20@0:8I16"},
    {"CGVirtualDisplayDescriptor", "setProductID:", "v20@0:8I16"},
    {"CGVirtualDisplayDescriptor", "setSerialNum:", "v20@0:8I16"},
    {"CGVirtualDisplayDescriptor", "setQueue:", "v24@0:8@16"},
    {"CGVirtualDisplayMode", "initWithWidth:height:refreshRate:", "@32@0:8I16I20d24"},
    {"CGVirtualDisplaySettings", "init", "@16@0:8"},
    {"CGVirtualDisplaySettings", "setHiDPI:", "v20@0:8I16"},
    {"CGVirtualDisplaySettings", "setModes:", "v24@0:8@16"},
    {"CGVirtualDisplay", "initWithDescriptor:", "@24@0:8@16"},
    {"CGVirtualDisplay", "applySettings:", "B24@0:8@16"},
    {"CGVirtualDisplay", "displayID", "I16@0:8"},
};

NSError *WDVirtualDisplayCheckAvailability(void) {
    for (size_t i = 0; i < sizeof(kRequired) / sizeof(kRequired[0]); i++) {
        const WDRequiredMethod *required = &kRequired[i];
        Class cls = objc_getClass(required->className);
        if (cls == Nil) {
            return WDError(WDVirtualDisplayErrorClassMissing,
                           [NSString stringWithFormat:@"class %s is not present", required->className]);
        }
        Method method = class_getInstanceMethod(cls, sel_registerName(required->selector));
        if (method == NULL) {
            return WDError(WDVirtualDisplayErrorSelectorMissing,
                           [NSString stringWithFormat:@"-[%s %s] is not present", required->className,
                                                      required->selector]);
        }
        const char *encoding = method_getTypeEncoding(method);
        if (encoding == NULL || strcmp(encoding, required->encoding) != 0) {
            return WDError(WDVirtualDisplayErrorABIMismatch,
                           [NSString stringWithFormat:@"-[%s %s] has encoding %s, expected %s",
                                                      required->className, required->selector,
                                                      encoding ?: "(null)", required->encoding]);
        }
    }
    return nil;
}

// Optional selectors (not in kRequired): checked individually; absent or
// changed ABI means "stay sRGB", never "fail".
static BOOL WDHasPrimarySetters(void) {
    Class cls = objc_getClass("CGVirtualDisplayDescriptor");
    if (cls == Nil) return NO;
    const char *names[] = {"setRedPrimary:", "setGreenPrimary:", "setBluePrimary:", "setWhitePoint:"};
    for (size_t i = 0; i < 4; i++) {
        Method m = class_getInstanceMethod(cls, sel_registerName(names[i]));
        const char *enc = m ? method_getTypeEncoding(m) : NULL;
        if (enc == NULL || strcmp(enc, "v32@0:8{CGPoint=dd}16") != 0) return NO;
    }
    return YES;
}

static id<WDPrivateDisplayDescriptor> WDMakeDescriptor(WDVirtualDisplayConfig *config, dispatch_queue_t queue) {
    id<WDPrivateDisplayDescriptor> descriptor = [[objc_getClass("CGVirtualDisplayDescriptor") alloc] init];
    [descriptor setName:config.name];
    uint32_t maxWide = config.pixelsWide, maxHigh = config.pixelsHigh;
    unsigned int factor = config.hiDPI ? 2 : 1;
    for (NSValue *value in config.modeSizes) {
        CGSize size = value.sizeValue;
        maxWide = MAX(maxWide, (uint32_t)size.width * factor);
        maxHigh = MAX(maxHigh, (uint32_t)size.height * factor);
    }
    // Square headroom lets landscape/portrait rotations resize in place without
    // exceeding the immutable descriptor bounds.
    uint32_t maxAxis = MIN(MAX(maxWide, maxHigh), 8192);
    [descriptor setMaxPixelsWide:maxAxis];
    [descriptor setMaxPixelsHigh:maxAxis];
    [descriptor setSizeInMillimeters:config.sizeInMillimeters];
    // Non-zero vendor ID is required since macOS 14 (per Chromium's
    // ui/display/mac/test/virtual_display_util_mac.mm). 0x5744 = "WD".
    [descriptor setVendorID:0x5744];
    [descriptor setProductID:0x0001];
    [descriptor setSerialNum:config.serialNumber == 0 ? 0x0001 : config.serialNumber];
    [descriptor setQueue:queue];
    if (config.wideColor && WDHasPrimarySetters()) {
        // Display P3 (CIE 1931 xy), D65 white point.
        [descriptor setRedPrimary:CGPointMake(0.680, 0.320)];
        [descriptor setGreenPrimary:CGPointMake(0.265, 0.690)];
        [descriptor setBluePrimary:CGPointMake(0.150, 0.060)];
        [descriptor setWhitePoint:CGPointMake(0.3127, 0.3290)];
    }
    return descriptor;
}

static id<WDPrivateDisplaySettings> WDMakeSettings(WDVirtualDisplayConfig *config) {
    unsigned int divisor = config.hiDPI ? 2 : 1;
    NSMutableArray<NSValue *> *sizes = [config.modeSizes mutableCopy] ?: [NSMutableArray array];
    if (sizes.count == 0) {
        [sizes addObject:[NSValue valueWithSize:NSMakeSize(config.pixelsWide / divisor, config.pixelsHigh / divisor)]];
    }
    NSMutableArray *modes = [NSMutableArray array];
    for (NSValue *value in sizes) {
        CGSize size = value.sizeValue;
        id<WDPrivateDisplayMode> mode =
            [(id<WDPrivateDisplayMode>)[objc_getClass("CGVirtualDisplayMode") alloc]
                initWithWidth:(unsigned int)size.width
                       height:(unsigned int)size.height
                  refreshRate:config.refreshRate];
        if (mode == nil) return nil;
        [modes addObject:mode];
    }
    id<WDPrivateDisplaySettings> settings = [[objc_getClass("CGVirtualDisplaySettings") alloc] init];
    [settings setHiDPI:config.hiDPI ? 1 : 0];
    [settings setModes:modes];
    return settings;
}

static BOOL WDConfigIsValid(WDVirtualDisplayConfig *config) {
    // Even dimensions (needed for @2x), sane size, sane refresh.
    BOOL sizeOK = config.pixelsWide >= 640 && config.pixelsHigh >= 480 && config.pixelsWide <= 8192 &&
                  config.pixelsHigh <= 8192 && (config.pixelsWide % 2 == 0) && (config.pixelsHigh % 2 == 0);
    BOOL mmOK = isfinite(config.sizeInMillimeters.width) && isfinite(config.sizeInMillimeters.height) &&
                config.sizeInMillimeters.width > 0 && config.sizeInMillimeters.height > 0;
    BOOL rateOK = isfinite(config.refreshRate) && config.refreshRate >= 24.0 && config.refreshRate <= 120.0;
    BOOL modesOK = config.modeSizes.count <= 8;
    unsigned int factor = config.hiDPI ? 2 : 1;
    for (NSValue *value in config.modeSizes) {
        CGSize size = value.sizeValue;
        if (!(size.width >= 320 && size.height >= 240 && size.width * factor <= 8192 && size.height * factor <= 8192 &&
              size.width == floor(size.width) && size.height == floor(size.height))) modesOK = NO;
    }
    return sizeOK && mmOK && rateOK && modesOK && config.name.length > 0;
}

BOOL WDVirtualDisplayDebugSupportObjectsAreReleased(void) {
    if (WDVirtualDisplayCheckAvailability() != nil) return NO;
    __weak id weakDescriptor = nil;
    __weak id weakSettings = nil;
    @autoreleasepool {
        WDVirtualDisplayConfig *config = [[WDVirtualDisplayConfig alloc] init];
        config.pixelsWide = 1280;
        config.pixelsHigh = 960;
        config.sizeInMillimeters = CGSizeMake(200, 150);
        id descriptor = WDMakeDescriptor(config, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0));
        id settings = WDMakeSettings(config);
        if (descriptor == nil || settings == nil) return NO;
        weakDescriptor = descriptor;
        weakSettings = settings;
    }
    return weakDescriptor == nil && weakSettings == nil;
}

@interface WDVirtualDisplayHandle ()
- (instancetype)initPrivate;
@end

@implementation WDVirtualDisplayConfig
- (instancetype)init {
    if ((self = [super init])) {
        _name = @"WiredDisplay";
        _refreshRate = 60.0;
        _modeSizes = @[];
    }
    return self;
}
@end

@implementation WDVirtualDisplayHandle {
    id<WDPrivateDisplay> _display; // strongly held; releasing it removes the display
    dispatch_queue_t _queue;
}

@synthesize displayID = _displayID;
@synthesize appliedWideColor = _appliedWideColor;

+ (instancetype)createWithConfig:(WDVirtualDisplayConfig *)config error:(NSError **)error {
    NSError *unavailable = WDVirtualDisplayCheckAvailability();
    if (unavailable != nil) {
        if (error) *error = unavailable;
        return nil;
    }
    if (!WDConfigIsValid(config)) {
        if (error) *error = WDError(WDVirtualDisplayErrorInvalidArgument, @"invalid virtual display config");
        return nil;
    }

    WDVirtualDisplayHandle *handle = [[WDVirtualDisplayHandle alloc] initPrivate];
    handle->_queue = dispatch_queue_create("wireddisplay.virtualdisplay", DISPATCH_QUEUE_SERIAL);

    // Every early return below drops the only reference to `display`, which
    // deallocates it and removes the display from WindowServer again.
    @try {
        id<WDPrivateDisplayDescriptor> descriptor = WDMakeDescriptor(config, handle->_queue);
        id<WDPrivateDisplaySettings> settings = WDMakeSettings(config);
        if (descriptor == nil || settings == nil) {
            if (error) *error = WDError(WDVirtualDisplayErrorCreateFailed, @"descriptor or settings init returned nil");
            return nil;
        }
        id<WDPrivateDisplay> display =
            [(id<WDPrivateDisplay>)[objc_getClass("CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (display == nil) {
            if (error) *error = WDError(WDVirtualDisplayErrorCreateFailed, @"initWithDescriptor: returned nil");
            return nil;
        }
        if (![display applySettings:settings]) {
            if (error) *error = WDError(WDVirtualDisplayErrorApplySettingsFailed, @"applySettings: returned NO");
            return nil;
        }
        CGDirectDisplayID displayID = [display displayID];
        if (displayID == kCGNullDirectDisplay) {
            if (error) *error = WDError(WDVirtualDisplayErrorCreateFailed, @"displayID is null");
            return nil;
        }
        handle->_display = display;
        handle->_displayID = displayID;
        handle->_appliedWideColor = config.wideColor && WDHasPrimarySetters();
    } @catch (NSException *exception) {
        // An exception from private code must not unwind into Swift.
        handle->_display = nil;
        if (error) {
            *error = WDError(WDVirtualDisplayErrorCreateFailed,
                             [NSString stringWithFormat:@"exception %@: %@", exception.name, exception.reason]);
        }
        return nil;
    }
    return handle;
}

- (instancetype)initPrivate {
    return [super init];
}

- (CGDirectDisplayID)displayID {
    @synchronized(self) {
        return _displayID;
    }
}

- (BOOL)applyConfig:(WDVirtualDisplayConfig *)config error:(NSError **)error {
    if (!WDConfigIsValid(config)) {
        if (error) *error = WDError(WDVirtualDisplayErrorInvalidArgument, @"invalid virtual display config");
        return NO;
    }
    @synchronized(self) {
        if (_display == nil || _displayID == kCGNullDirectDisplay) {
            if (error) *error = WDError(WDVirtualDisplayErrorApplySettingsFailed, @"virtual display already invalidated");
            return NO;
        }
        @try {
            id<WDPrivateDisplaySettings> settings = WDMakeSettings(config);
            if (settings == nil) {
                if (error) *error = WDError(WDVirtualDisplayErrorApplySettingsFailed, @"settings init returned nil");
                return NO;
            }
            if (![_display applySettings:settings]) {
                if (error) *error = WDError(WDVirtualDisplayErrorApplySettingsFailed, @"applySettings: returned NO");
                return NO;
            }
            return YES;
        } @catch (NSException *exception) {
            if (error) {
                *error = WDError(WDVirtualDisplayErrorApplySettingsFailed,
                                 [NSString stringWithFormat:@"exception %@: %@", exception.name, exception.reason]);
            }
            return NO;
        }
    }
}

- (void)invalidate {
    @synchronized(self) {
        _display = nil;
        _displayID = kCGNullDirectDisplay;
    }
}

@end

#endif // TARGET_OS_OSX (the target is intentionally empty on other platforms)
