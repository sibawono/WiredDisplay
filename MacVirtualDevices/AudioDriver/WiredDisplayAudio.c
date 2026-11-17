// WiredDisplayAudio: a minimal AudioServerPlugIn (HAL driver) that publishes two
// loopback devices for the WiredDisplay host (docs/DECISIONS.md D-017):
//
//   "iPad Speaker"     apps play into its OUTPUT; the host records its INPUT
//                      (the same audio, looped back) and sends it to the iPad.
//   "iPad Microphone"  the host plays iPad microphone audio into its OUTPUT;
//                      apps record its INPUT.
//
// "iPad Speaker" has a main volume and mute control on its output, so the Mac's
// volume keys and menu-bar slider work; the gain is applied to the samples as
// they are written, so the iPad receives audio at the chosen level.
//
// Runs inside coreaudiod. It opens no files, sockets or Mach services; all it
// does is copy samples through a per-device ring buffer. Fixed format:
// 48 kHz, 2 channels, Float32 interleaved.
//
// The IO path (DoIOOperation) never locks or allocates. Property access is
// read-only except for client bookkeeping.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#pragma mark Constants

#define kSampleRate 48000.0
#define kChannels 2
#define kBytesPerFrame (kChannels * sizeof(Float32))
// Ring holds ~340 ms; also the zero-timestamp period.
#define kRingFrames 16384u
#define kManufacturer CFSTR("WiredDisplay")

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject, // 1
    kObjectID_SpeakerDevice = 2,
    kObjectID_SpeakerInput = 3,
    kObjectID_SpeakerOutput = 4,
    kObjectID_MicDevice = 5,
    kObjectID_MicInput = 6,
    kObjectID_MicOutput = 7,
    kObjectID_SpeakerVolume = 8,
    kObjectID_SpeakerMute = 9,
};

// Speaker volume (scalar 0...1, mapped linearly onto -64...0 dB) and mute.
// Written by property calls, read lock-free by the IO path.
#define kVolumeMinDB (-64.0f)
#define kVolumeMaxDB (0.0f)
static _Atomic float gSpeakerVolume = 1.0f;
static _Atomic UInt32 gSpeakerMute = 0;

static Float32 ScalarToDB(Float32 scalar) {
    if (scalar < 0) scalar = 0;
    if (scalar > 1) scalar = 1;
    return kVolumeMinDB + (kVolumeMaxDB - kVolumeMinDB) * scalar;
}

static Float32 DBToScalar(Float32 db) {
    if (db < kVolumeMinDB) db = kVolumeMinDB;
    if (db > kVolumeMaxDB) db = kVolumeMaxDB;
    return (db - kVolumeMinDB) / (kVolumeMaxDB - kVolumeMinDB);
}

static Float32 SpeakerGain(void) {
    if (atomic_load(&gSpeakerMute)) return 0;
    Float32 scalar = atomic_load(&gSpeakerVolume);
    if (scalar <= 0) return 0;
    return powf(10.0f, ScalarToDB(scalar) / 20.0f);
}

typedef struct {
    AudioObjectID device, inputStream, outputStream;
    CFStringRef name;
    CFStringRef uid;
    // Which direction may become the system default (the other one is the loopback tap).
    Boolean defaultForOutput;
    Boolean defaultForInput;
    // Timing, guarded by `lock` (never touched by DoIOOperation).
    pthread_mutex_t lock;
    UInt32 ioClients;
    UInt64 anchorHostTime;
    UInt64 timestampCount;
    // End (exclusive, in sample time) of what the writer has put in the ring.
    // Readers only copy frames inside [writtenEnd - kRingFrames, writtenEnd);
    // everything else reads as silence. This replaces "zero after read",
    // which gave every reader after the first one silence (BUG-028).
    _Atomic double writtenEnd;
    // Audio ring. Single producer (WriteMix), any number of readers.
    Float32 ring[kRingFrames * kChannels];
} LoopbackDevice;

static LoopbackDevice gDevices[2] = {
    {kObjectID_SpeakerDevice, kObjectID_SpeakerInput, kObjectID_SpeakerOutput, CFSTR("iPad Speaker"),
     CFSTR("dev.wireddisplay.audio.speaker"), true, false, PTHREAD_MUTEX_INITIALIZER, 0, 0, 0, 0.0, {0}},
    {kObjectID_MicDevice, kObjectID_MicInput, kObjectID_MicOutput, CFSTR("iPad Microphone"),
     CFSTR("dev.wireddisplay.audio.microphone"), false, true, PTHREAD_MUTEX_INITIALIZER, 0, 0, 0, 0.0, {0}},
};

static AudioServerPlugInHostRef gHost = NULL;
static Float64 gHostTicksPerFrame = 0;
static _Atomic UInt32 gRefCount = 0;

#pragma mark Lookup helpers

static LoopbackDevice *DeviceForObject(AudioObjectID object) {
    for (int i = 0; i < 2; i++) {
        if (gDevices[i].device == object) return &gDevices[i];
    }
    return NULL;
}

static LoopbackDevice *DeviceForStream(AudioObjectID object, Boolean *isInput) {
    for (int i = 0; i < 2; i++) {
        if (gDevices[i].inputStream == object) { if (isInput) *isInput = true; return &gDevices[i]; }
        if (gDevices[i].outputStream == object) { if (isInput) *isInput = false; return &gDevices[i]; }
    }
    return NULL;
}

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerFrame;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerFrame;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

// Copies `size` bytes of `value` if the caller's buffer is large enough.
#define RETURN_VALUE(TYPE, VALUE)                                           \
    do {                                                                    \
        if (inDataSize < sizeof(TYPE)) return kAudioHardwareBadPropertySizeError; \
        *(TYPE *)outData = (VALUE);                                         \
        *outDataSize = sizeof(TYPE);                                        \
        return kAudioHardwareNoError;                                       \
    } while (0)

static OSStatus ReturnIDs(const AudioObjectID *ids, UInt32 count, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    UInt32 fit = inDataSize / sizeof(AudioObjectID);
    if (fit > count) fit = count;
    memcpy(outData, ids, fit * sizeof(AudioObjectID));
    *outDataSize = fit * sizeof(AudioObjectID);
    return kAudioHardwareNoError;
}

#pragma mark Property tables

static Boolean IsControl(AudioObjectID object) {
    return object == kObjectID_SpeakerVolume || object == kObjectID_SpeakerMute;
}

static Boolean ControlHas(AudioObjectID object, AudioObjectPropertySelector s) {
    switch (s) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyOwnedObjects: case kAudioControlPropertyScope: case kAudioControlPropertyElement:
        return true;
    case kAudioLevelControlPropertyScalarValue: case kAudioLevelControlPropertyDecibelValue:
    case kAudioLevelControlPropertyDecibelRange: case kAudioLevelControlPropertyConvertScalarToDecibels:
    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        return object == kObjectID_SpeakerVolume;
    case kAudioBooleanControlPropertyValue:
        return object == kObjectID_SpeakerMute;
    default:
        return false;
    }
}

static Boolean ControlSettable(AudioObjectID object, AudioObjectPropertySelector s) {
    if (object == kObjectID_SpeakerVolume)
        return s == kAudioLevelControlPropertyScalarValue || s == kAudioLevelControlPropertyDecibelValue;
    if (object == kObjectID_SpeakerMute) return s == kAudioBooleanControlPropertyValue;
    return false;
}

static Boolean PlugInHas(AudioObjectPropertySelector s) {
    switch (s) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
    case kAudioPlugInPropertyResourceBundle:
        return true;
    default:
        return false;
    }
}

static Boolean DeviceHas(AudioObjectPropertySelector s) {
    switch (s) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: case kAudioDevicePropertyLatency:
    case kAudioDevicePropertyStreams: case kAudioObjectPropertyControlList: case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyNominalSampleRate: case kAudioDevicePropertyAvailableNominalSampleRates:
    case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyPreferredChannelsForStereo:
    case kAudioDevicePropertyZeroTimeStampPeriod:
        return true;
    default:
        return false;
    }
}

static Boolean StreamHas(AudioObjectPropertySelector s) {
    switch (s) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyOwnedObjects: case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
        return true;
    default:
        return false;
    }
}

#pragma mark Get property data

static OSStatus GetControlProperty(AudioObjectID object, const AudioObjectPropertyAddress *a, UInt32 inDataSize,
                                   UInt32 *outDataSize, void *outData) {
    Boolean volume = object == kObjectID_SpeakerVolume;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
        RETURN_VALUE(AudioClassID, volume ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
    case kAudioObjectPropertyClass:
        RETURN_VALUE(AudioClassID, volume ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
    case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_SpeakerDevice);
    case kAudioObjectPropertyOwnedObjects:
        *outDataSize = 0;
        return kAudioHardwareNoError;
    case kAudioControlPropertyScope: RETURN_VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
    case kAudioControlPropertyElement: RETURN_VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
    case kAudioLevelControlPropertyScalarValue:
        if (!volume) break;
        RETURN_VALUE(Float32, atomic_load(&gSpeakerVolume));
    case kAudioLevelControlPropertyDecibelValue:
        if (!volume) break;
        RETURN_VALUE(Float32, ScalarToDB(atomic_load(&gSpeakerVolume)));
    case kAudioLevelControlPropertyDecibelRange: {
        if (!volume) break;
        AudioValueRange range = {kVolumeMinDB, kVolumeMaxDB};
        RETURN_VALUE(AudioValueRange, range);
    }
    case kAudioLevelControlPropertyConvertScalarToDecibels:
        // In/out: the caller passes the value in outData.
        if (!volume || inDataSize < sizeof(Float32)) break;
        RETURN_VALUE(Float32, ScalarToDB(*(Float32 *)outData));
    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        if (!volume || inDataSize < sizeof(Float32)) break;
        RETURN_VALUE(Float32, DBToScalar(*(Float32 *)outData));
    case kAudioBooleanControlPropertyValue:
        if (volume) break;
        RETURN_VALUE(UInt32, atomic_load(&gSpeakerMute));
    default:
        break;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus GetPlugInProperty(const AudioObjectPropertyAddress *a, UInt32 qSize, const void *qData,
                                  UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, kManufacturer);
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: {
        AudioObjectID ids[2] = {kObjectID_SpeakerDevice, kObjectID_MicDevice};
        return ReturnIDs(ids, 2, inDataSize, outDataSize, outData);
    }
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        if (qSize < sizeof(CFStringRef) || qData == NULL) return kAudioHardwareBadPropertySizeError;
        CFStringRef uid = *(const CFStringRef *)qData;
        AudioObjectID found = kAudioObjectUnknown;
        for (int i = 0; i < 2; i++) {
            if (uid && CFStringCompare(uid, gDevices[i].uid, 0) == kCFCompareEqualTo) found = gDevices[i].device;
        }
        RETURN_VALUE(AudioObjectID, found);
    }
    case kAudioPlugInPropertyResourceBundle: RETURN_VALUE(CFStringRef, CFSTR(""));
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetDeviceProperty(LoopbackDevice *d, const AudioObjectPropertyAddress *a,
                                  UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    Boolean inputScope = a->mScope == kAudioObjectPropertyScopeInput;
    Boolean outputScope = a->mScope == kAudioObjectPropertyScopeOutput;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_PlugIn);
    case kAudioObjectPropertyName: RETURN_VALUE(CFStringRef, d->name);
    case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, kManufacturer);
    case kAudioDevicePropertyDeviceUID: RETURN_VALUE(CFStringRef, d->uid);
    case kAudioDevicePropertyModelUID: RETURN_VALUE(CFStringRef, CFSTR("dev.wireddisplay.audio.loopback"));
    case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: RETURN_VALUE(AudioObjectID, d->device);
    case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0);
    case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
    case kAudioDevicePropertyDeviceIsRunning: {
        pthread_mutex_lock(&d->lock);
        UInt32 running = d->ioClients > 0;
        pthread_mutex_unlock(&d->lock);
        RETURN_VALUE(UInt32, running);
    }
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: {
        // Only the intended direction may become a default device; the other
        // direction is the host's loopback tap.
        UInt32 can = (outputScope && d->defaultForOutput) || (inputScope && d->defaultForInput);
        if (a->mSelector == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice) can = 0; // never alert sounds
        RETURN_VALUE(UInt32, can);
    }
    case kAudioDevicePropertyLatency: RETURN_VALUE(UInt32, 0);
    case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, 0);
    case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyStreams: {
        AudioObjectID ids[4];
        UInt32 count = 0;
        if (!outputScope) ids[count++] = d->inputStream;
        if (!inputScope) ids[count++] = d->outputStream;
        if (a->mSelector == kAudioObjectPropertyOwnedObjects && !inputScope && d->device == kObjectID_SpeakerDevice) {
            ids[count++] = kObjectID_SpeakerVolume;
            ids[count++] = kObjectID_SpeakerMute;
        }
        return ReturnIDs(ids, count, inDataSize, outDataSize, outData);
    }
    case kAudioObjectPropertyControlList: {
        if (d->device != kObjectID_SpeakerDevice) {
            *outDataSize = 0;
            return kAudioHardwareNoError;
        }
        AudioObjectID ids[2] = {kObjectID_SpeakerVolume, kObjectID_SpeakerMute};
        return ReturnIDs(ids, 2, inDataSize, outDataSize, outData);
    }
    case kAudioDevicePropertyNominalSampleRate: RETURN_VALUE(Float64, kSampleRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange range = {kSampleRate, kSampleRate};
        RETURN_VALUE(AudioValueRange, range);
    }
    case kAudioDevicePropertyIsHidden: RETURN_VALUE(UInt32, 0);
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        ((UInt32 *)outData)[0] = 1;
        ((UInt32 *)outData)[1] = 2;
        *outDataSize = 2 * sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kRingFrames);
    default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetStreamProperty(LoopbackDevice *d, Boolean isInput, const AudioObjectPropertyAddress *a,
                                  UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
    case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, d->device);
    case kAudioObjectPropertyOwnedObjects:
        *outDataSize = 0;
        return kAudioHardwareNoError;
    case kAudioStreamPropertyIsActive: RETURN_VALUE(UInt32, 1);
    case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, isInput ? 1 : 0);
    case kAudioStreamPropertyTerminalType:
        RETURN_VALUE(UInt32, isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
    case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
    case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        RETURN_VALUE(AudioStreamBasicDescription, StreamFormat());
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription ranged;
        ranged.mFormat = StreamFormat();
        ranged.mSampleRateRange.mMinimum = kSampleRate;
        ranged.mSampleRateRange.mMaximum = kSampleRate;
        if (inDataSize < sizeof(ranged)) { *outDataSize = 0; return kAudioHardwareNoError; }
        RETURN_VALUE(AudioStreamRangedDescription, ranged);
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark Driver interface

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG AddRef(void *inDriver);
static ULONG Release(void *inDriver);

static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    gHost = inHost;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 ticksPerSecond = 1e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    gHostTicksPerFrame = ticksPerSecond / kSampleRate;
    return kAudioHardwareNoError;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c,
                             AudioObjectID *outID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID inDeviceObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID inDevice, const AudioServerPlugInClientInfo *c) {
    return DeviceForObject(inDevice) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID inDevice, const AudioServerPlugInClientInfo *c) {
    return DeviceForObject(inDevice) ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

static OSStatus PerformConfigChange(AudioServerPlugInDriverRef d, AudioObjectID inDevice, UInt64 action, void *info) {
    return kAudioHardwareNoError;
}

static OSStatus AbortConfigChange(AudioServerPlugInDriverRef d, AudioObjectID inDevice, UInt64 action, void *info) {
    return kAudioHardwareNoError;
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID inObjectID, pid_t pid,
                           const AudioObjectPropertyAddress *a) {
    if (a == NULL) return false;
    if (inObjectID == kObjectID_PlugIn) return PlugInHas(a->mSelector);
    if (DeviceForObject(inObjectID)) return DeviceHas(a->mSelector);
    if (DeviceForStream(inObjectID, NULL)) return StreamHas(a->mSelector);
    if (IsControl(inObjectID)) return ControlHas(inObjectID, a->mSelector);
    return false;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID inObjectID, pid_t pid,
                                   const AudioObjectPropertyAddress *a, Boolean *outIsSettable) {
    if (a == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    if (!HasProperty(d, inObjectID, pid, a)) return kAudioHardwareUnknownPropertyError;
    *outIsSettable = IsControl(inObjectID) && ControlSettable(inObjectID, a->mSelector); // fixed format
    return kAudioHardwareNoError;
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID inObjectID, pid_t pid,
                                const AudioObjectPropertyAddress *a, UInt32 qSize, const void *qData,
                                UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    if (a == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    if (inObjectID == kObjectID_PlugIn) return GetPlugInProperty(a, qSize, qData, inDataSize, outDataSize, outData);
    LoopbackDevice *device = DeviceForObject(inObjectID);
    if (device) return GetDeviceProperty(device, a, inDataSize, outDataSize, outData);
    Boolean isInput = false;
    device = DeviceForStream(inObjectID, &isInput);
    if (device) return GetStreamProperty(device, isInput, a, inDataSize, outDataSize, outData);
    if (IsControl(inObjectID)) return GetControlProperty(inObjectID, a, inDataSize, outDataSize, outData);
    return kAudioHardwareBadObjectError;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID inObjectID, pid_t pid,
                                    const AudioObjectPropertyAddress *a, UInt32 qSize, const void *qData,
                                    UInt32 *outDataSize) {
    if (a == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    // Ask the getter with a buffer large enough for any property here.
    UInt8 scratch[256];
    UInt32 size = 0;
    OSStatus status = GetPropertyData(d, inObjectID, pid, a, qSize, qData, sizeof(scratch), &size, scratch);
    if (status == kAudioHardwareNoError) *outDataSize = size;
    return status;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID inObjectID, pid_t pid,
                                const AudioObjectPropertyAddress *a, UInt32 qSize, const void *qData,
                                UInt32 inDataSize, const void *inData) {
    if (a == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    if (!IsControl(inObjectID) || !ControlSettable(inObjectID, a->mSelector)) {
        return kAudioHardwareUnsupportedOperationError;
    }
    if (inObjectID == kObjectID_SpeakerVolume) {
        if (inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        Float32 value = *(const Float32 *)inData;
        if (!isfinite(value)) return kAudioHardwareIllegalOperationError;
        Float32 scalar = a->mSelector == kAudioLevelControlPropertyDecibelValue ? DBToScalar(value)
                                                                               : (value < 0 ? 0 : value > 1 ? 1 : value);
        if (scalar != atomic_load(&gSpeakerVolume)) {
            atomic_store(&gSpeakerVolume, scalar);
            AudioObjectPropertyAddress changed[2] = {
                {kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
                {kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            };
            if (gHost) gHost->PropertiesChanged(gHost, kObjectID_SpeakerVolume, 2, changed);
        }
        return kAudioHardwareNoError;
    }
    // Mute
    if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
    UInt32 mute = *(const UInt32 *)inData ? 1 : 0;
    if (mute != atomic_load(&gSpeakerMute)) {
        atomic_store(&gSpeakerMute, mute);
        AudioObjectPropertyAddress changed = {kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal,
                                              kAudioObjectPropertyElementMain};
        if (gHost) gHost->PropertiesChanged(gHost, kObjectID_SpeakerMute, 1, &changed);
    }
    return kAudioHardwareNoError;
}

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID inDevice, UInt32 inClientID) {
    LoopbackDevice *device = DeviceForObject(inDevice);
    if (!device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&device->lock);
    if (device->ioClients == 0) {
        device->anchorHostTime = mach_absolute_time();
        device->timestampCount = 0;
        atomic_store(&device->writtenEnd, 0.0);
        memset(device->ring, 0, sizeof(device->ring));
    }
    device->ioClients++;
    pthread_mutex_unlock(&device->lock);
    return kAudioHardwareNoError;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID inDevice, UInt32 inClientID) {
    LoopbackDevice *device = DeviceForObject(inDevice);
    if (!device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&device->lock);
    if (device->ioClients > 0) device->ioClients--;
    pthread_mutex_unlock(&device->lock);
    return kAudioHardwareNoError;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID inDevice, UInt32 inClientID,
                                 Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    LoopbackDevice *device = DeviceForObject(inDevice);
    if (!device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&device->lock);
    Float64 ticksPerRing = gHostTicksPerFrame * (Float64)kRingFrames;
    UInt64 now = mach_absolute_time();
    UInt64 next = device->anchorHostTime + (UInt64)((Float64)(device->timestampCount + 1) * ticksPerRing);
    if (next <= now) device->timestampCount++;
    *outSampleTime = (Float64)(device->timestampCount * kRingFrames);
    *outHostTime = device->anchorHostTime + (UInt64)((Float64)device->timestampCount * ticksPerRing);
    *outSeed = 1;
    pthread_mutex_unlock(&device->lock);
    return kAudioHardwareNoError;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID inDevice, UInt32 inClientID,
                                  UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    Boolean will = inOperationID == kAudioServerPlugInIOOperationReadInput ||
                   inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = will;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID inDevice, UInt32 inClientID,
                                 UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                 const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    return kAudioHardwareNoError;
}

static inline UInt32 RingIndex(Float64 sampleTime) {
    Float64 wrapped = fmod(sampleTime, (Float64)kRingFrames);
    if (wrapped < 0) wrapped += kRingFrames;
    return (UInt32)wrapped;
}

// Real-time path: no locks, no allocation, bounded copies.
static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID inDevice, AudioObjectID inStream,
                              UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                              const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer,
                              void *ioSecondaryBuffer) {
    LoopbackDevice *device = DeviceForObject(inDevice);
    if (!device || !inIOCycleInfo || !ioMainBuffer || inIOBufferFrameSize > kRingFrames) return kAudioHardwareNoError;
    Float32 *buffer = (Float32 *)ioMainBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && inStream == device->outputStream) {
        if (device->device == kObjectID_SpeakerDevice) {
            // Volume/mute from the Mac's controls, applied in place.
            Float32 gain = SpeakerGain();
            if (gain != 1.0f) {
                UInt32 samples = inIOBufferFrameSize * kChannels;
                for (UInt32 i = 0; i < samples; i++) buffer[i] *= gain;
            }
        }
        Float64 time = floor(inIOCycleInfo->mOutputTime.mSampleTime);
        UInt32 start = RingIndex(time);
        UInt32 first = kRingFrames - start;
        if (first > inIOBufferFrameSize) first = inIOBufferFrameSize;
        memcpy(&device->ring[start * kChannels], buffer, first * kBytesPerFrame);
        memcpy(&device->ring[0], buffer + first * kChannels, (inIOBufferFrameSize - first) * kBytesPerFrame);
        double end = time + inIOBufferFrameSize;
        if (end > atomic_load(&device->writtenEnd)) atomic_store(&device->writtenEnd, end);
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput && inStream == device->inputStream) {
        // Frame-by-frame validity against what was actually written, so a
        // stopped writer reads as silence (not a 340 ms loop of stale audio)
        // and any number of readers see the same audio.
        Float64 time = floor(inIOCycleInfo->mInputTime.mSampleTime);
        double end = atomic_load(&device->writtenEnd);
        double oldest = end - (double)kRingFrames;
        for (UInt32 frame = 0; frame < inIOBufferFrameSize; frame++) {
            double t = time + frame;
            Float32 *out = buffer + frame * kChannels;
            if (t >= oldest && t < end) {
                memcpy(out, &device->ring[RingIndex(t) * kChannels], kBytesPerFrame);
            } else {
                memset(out, 0, kBytesPerFrame);
            }
        }
    }
    return kAudioHardwareNoError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID inDevice, UInt32 inClientID,
                               UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                               const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    return kAudioHardwareNoError;
}

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient,
    RemoveDeviceClient, PerformConfigChange, AbortConfigChange, HasProperty, IsPropertySettable,
    GetPropertyDataSize, GetPropertyData, SetPropertyData, StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation,
    BeginIOOperation, DoIOOperation, EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (outInterface == NULL) return E_POINTER;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (requested && (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID))) {
        atomic_fetch_add(&gRefCount, 1);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    if (requested) CFRelease(requested);
    return result;
}

static ULONG AddRef(void *inDriver) { return atomic_fetch_add(&gRefCount, 1) + 1; }

static ULONG Release(void *inDriver) {
    UInt32 current = atomic_load(&gRefCount);
    if (current == 0) return 0;
    return atomic_fetch_sub(&gRefCount, 1) - 1;
}

// Factory named in Info.plist (CFPlugInFactories).
void *WiredDisplayAudio_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);
void *WiredDisplayAudio_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    atomic_fetch_add(&gRefCount, 1);
    return gDriverRef;
}
