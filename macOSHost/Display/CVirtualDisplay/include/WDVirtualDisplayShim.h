#ifndef WD_VIRTUAL_DISPLAY_SHIM_H
#define WD_VIRTUAL_DISPLAY_SHIM_H

#import <TargetConditionals.h>

#if TARGET_OS_OSX

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// The ONLY place in the project that touches the undocumented CGVirtualDisplay
/// classes of CoreGraphics. Nothing here links against a private symbol: every
/// class is looked up with objc_getClass and every selector's type encoding is
/// compared with the recorded arm64 ABI before it is used. If anything is
/// missing or has a different ABI, creation fails closed with an NSError.
///
/// Selector set and type encodings were read from the live runtime on macOS
/// 27.2 with class_copyMethodList (see docs/FEASIBILITY.md E-02).
/// Not App Store compatible. May break on any macOS update.

extern NSErrorDomain const WDVirtualDisplayErrorDomain;

typedef NS_ERROR_ENUM(WDVirtualDisplayErrorDomain, WDVirtualDisplayError) {
    WDVirtualDisplayErrorClassMissing = 1,
    WDVirtualDisplayErrorSelectorMissing = 2,
    WDVirtualDisplayErrorABIMismatch = 3,
    WDVirtualDisplayErrorInvalidArgument = 4,
    WDVirtualDisplayErrorCreateFailed = 5,
    WDVirtualDisplayErrorApplySettingsFailed = 6,
};

/// Test hook with no WindowServer side effect: builds and drops the private
/// descriptor/mode/settings objects and reports whether they were deallocated
/// (ownership regression check for BUG-004). Creates no display.
BOOL WDVirtualDisplayDebugSupportObjectsAreReleased(void);

/// Returns nil if the private API surface is fully present with the expected
/// ABI, otherwise an error naming the first missing class/selector. Has no side
/// effects: it creates no display.
NSError *_Nullable WDVirtualDisplayCheckAvailability(void);

@interface WDVirtualDisplayConfig : NSObject
@property (nonatomic, copy) NSString *name;
/// Framebuffer size in pixels.
@property (nonatomic) uint32_t pixelsWide;
@property (nonatomic) uint32_t pixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
/// YES: advertise a @2x mode (points = pixels / 2).
@property (nonatomic) BOOL hiDPI;
/// Optional modes as logical sizes (points when hiDPI), each an NSValue of
/// CGSize with even integer sides; the FIRST one is the default mode. Empty:
/// one mode, pixels / (hiDPI ? 2 : 1). The framebuffer limit grows to fit the
/// largest mode; capture scales it to the panel size.
@property (nonatomic, copy) NSArray<NSValue *> *modeSizes;
@property (nonatomic) double refreshRate;
/// YES: advertise Display P3 primaries (D65 white) so macOS renders wide-gamut
/// colour to this display. Applied only if the private setters exist with the
/// expected ABI; otherwise the display stays sRGB (never fails creation).
@property (nonatomic) BOOL wideColor;
/// Display serial number; one per iPad so macOS keeps each one's arrangement
/// and mode apart (D-041). 1 = the original single-iPad identity.
@property (nonatomic) uint32_t serialNumber;
@end

/// Owns one virtual display. The display exists while this object is alive and
/// is removed from WindowServer when it is deallocated or the process exits.
@interface WDVirtualDisplayHandle : NSObject
/// kCGNullDirectDisplay after invalidate. Safe to read from any thread.
@property (readonly) CGDirectDisplayID displayID;
/// Whether the Display P3 primaries were actually applied at creation.
@property (nonatomic, readonly) BOOL appliedWideColor;
+ (nullable instancetype)createWithConfig:(WDVirtualDisplayConfig *)config
                                    error:(NSError *_Nullable *_Nullable)error;
- (instancetype)init NS_UNAVAILABLE;
/// Updates modes and HiDPI settings in place without destroying the display,
/// preserving window placement across rotations.
- (BOOL)applyConfig:(WDVirtualDisplayConfig *)config
              error:(NSError *_Nullable *_Nullable)error;
/// Releases the underlying private object now, which removes the display.
/// Idempotent and thread-safe.
- (void)invalidate;
@end

NS_ASSUME_NONNULL_END

#endif // TARGET_OS_OSX

#endif
