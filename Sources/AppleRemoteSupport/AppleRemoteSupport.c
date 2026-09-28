#include "AppleRemoteSupport.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hid/IOHIDLib.h>
#include <dlfcn.h>
#include <stdlib.h>

#define SAY_APPLE_REMOTE_MAX_TOUCH_DEVICES 32

typedef const void *MTDeviceRef;

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;
    int32_t state;
    int32_t fingerID;
    int32_t handID;
    MTVector normalizedVector;
    float zTotal;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absoluteVector;
    int32_t field14;
    int32_t field15;
    float zDensity;
} MTTouch;

typedef CFArrayRef (*MTDeviceCreateListFunction)(void);
typedef bool (*MTDeviceIsBuiltInFunction)(MTDeviceRef device);
typedef int32_t (*MTDeviceGetSensorSurfaceDimensionsFunction)(
    MTDeviceRef device,
    int32_t *width,
    int32_t *height
);
typedef io_service_t (*MTDeviceGetServiceFunction)(MTDeviceRef device);
typedef int32_t (*MTDeviceStartFunction)(MTDeviceRef device, int32_t mode);
typedef int32_t (*MTDeviceStopFunction)(MTDeviceRef device);
typedef void (*MTFrameCallback)(
    MTDeviceRef device,
    MTTouch touches[],
    size_t touchCount,
    double timestamp,
    size_t frame,
    void *context
);
typedef void (*MTRegisterCallbackFunction)(
    MTDeviceRef device,
    MTFrameCallback callback,
    void *context
);
typedef void (*MTUnregisterCallbackFunction)(MTDeviceRef device, MTFrameCallback callback);

struct SAYAppleRemoteTouchSession {
    void *framework;
    MTDeviceRef devices[SAY_APPLE_REMOTE_MAX_TOUCH_DEVICES];
    uint64_t sourceIDs[SAY_APPLE_REMOTE_MAX_TOUCH_DEVICES];
    size_t deviceCount;
    SAYAppleRemoteTouchCallback callback;
    void *context;
    MTDeviceCreateListFunction createList;
    MTDeviceIsBuiltInFunction isBuiltIn;
    MTDeviceGetSensorSurfaceDimensionsFunction getDimensions;
    MTDeviceGetServiceFunction getService;
    MTDeviceStartFunction startDevice;
    MTDeviceStopFunction stopDevice;
    MTRegisterCallbackFunction registerCallback;
    MTUnregisterCallbackFunction unregisterCallback;
};

static uint64_t SAYAppleRemoteRegistryUInt64(io_service_t service, CFStringRef key) {
    if (service == IO_OBJECT_NULL) {
        return 0;
    }
    CFTypeRef property = IORegistryEntryCreateCFProperty(
        service,
        key,
        kCFAllocatorDefault,
        0
    );
    if (property == NULL || CFGetTypeID(property) != CFNumberGetTypeID()) {
        if (property != NULL) {
            CFRelease(property);
        }
        return 0;
    }
    uint64_t result = 0;
    CFNumberGetValue((CFNumberRef)property, kCFNumberSInt64Type, &result);
    CFRelease(property);
    return result;
}

static void SAYAppleRemoteTouchFrame(
    MTDeviceRef device,
    MTTouch touches[],
    size_t touchCount,
    double timestamp,
    size_t frame,
    void *context
) {
    (void)frame;
    SAYAppleRemoteTouchSession *session = context;
    if (session == NULL || session->callback == NULL) {
        return;
    }

    SAYAppleRemoteTouchContact contacts[16];
    int32_t count = 0;
    for (size_t index = 0; index < touchCount && count < 16; index++) {
        const MTTouch touch = touches[index];
        if (touch.state != 3 && touch.state != 4) {
            continue;
        }
        contacts[count].identifier = touch.fingerID;
        contacts[count].normalizedX = touch.normalizedVector.position.x;
        contacts[count].normalizedY = touch.normalizedVector.position.y;
        contacts[count].contactSize = touch.zTotal;
        contacts[count].hasContactSize = touch.zTotal > 0;
        count++;
    }
    uint64_t sourceID = 0;
    for (size_t index = 0; index < session->deviceCount; index++) {
        if (session->devices[index] == device) {
            sourceID = session->sourceIDs[index];
            break;
        }
    }
    session->callback(contacts, count, timestamp, sourceID, session->context);
}

static bool SAYAppleRemoteResolveSymbols(SAYAppleRemoteTouchSession *session) {
    session->createList = (MTDeviceCreateListFunction)dlsym(session->framework, "MTDeviceCreateList");
    session->isBuiltIn = (MTDeviceIsBuiltInFunction)dlsym(session->framework, "MTDeviceIsBuiltIn");
    session->getDimensions = (MTDeviceGetSensorSurfaceDimensionsFunction)dlsym(
        session->framework,
        "MTDeviceGetSensorSurfaceDimensions"
    );
    session->getService = (MTDeviceGetServiceFunction)dlsym(
        session->framework,
        "MTDeviceGetService"
    );
    session->startDevice = (MTDeviceStartFunction)dlsym(session->framework, "MTDeviceStart");
    session->stopDevice = (MTDeviceStopFunction)dlsym(session->framework, "MTDeviceStop");
    session->registerCallback = (MTRegisterCallbackFunction)dlsym(
        session->framework,
        "MTRegisterContactFrameCallbackWithRefcon"
    );
    session->unregisterCallback = (MTUnregisterCallbackFunction)dlsym(
        session->framework,
        "MTUnregisterContactFrameCallback"
    );
    return session->createList != NULL
        && session->getService != NULL
        && session->getDimensions != NULL
        && session->startDevice != NULL
        && session->stopDevice != NULL
        && session->registerCallback != NULL
        && session->unregisterCallback != NULL;
}

SAYAppleRemoteTouchSession *SAYAppleRemoteTouchSessionCreate(
    SAYAppleRemoteTouchCallback callback,
    void *context
) {
    SAYAppleRemoteTouchSession *session = calloc(1, sizeof(SAYAppleRemoteTouchSession));
    if (session == NULL) {
        return NULL;
    }
    session->callback = callback;
    session->context = context;
    session->framework = dlopen(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
        RTLD_LOCAL | RTLD_LAZY
    );
    if (session->framework == NULL || !SAYAppleRemoteResolveSymbols(session)) {
        SAYAppleRemoteTouchSessionDestroy(session);
        return NULL;
    }
    return session;
}

bool SAYAppleRemoteTouchSessionStart(SAYAppleRemoteTouchSession *session) {
    if (session == NULL) {
        return false;
    }
    SAYAppleRemoteTouchSessionStop(session);
    CFArrayRef devices = session->createList();
    if (devices == NULL) {
        return false;
    }

    const CFIndex deviceCount = CFArrayGetCount(devices);
    bool startedAny = false;
    for (CFIndex index = 0; index < deviceCount; index++) {
        if (session->deviceCount >= SAY_APPLE_REMOTE_MAX_TOUCH_DEVICES) {
            break;
        }
        MTDeviceRef device = CFArrayGetValueAtIndex(devices, index);
        int32_t width = 0;
        int32_t height = 0;
        if (device == NULL || session->getDimensions(device, &width, &height) != 0) {
            continue;
        }
        const int32_t maximumDimension = width > height ? width : height;
        const bool isBuiltIn = session->isBuiltIn != NULL && session->isBuiltIn(device);
        if (isBuiltIn || maximumDimension <= 0 || maximumDimension >= 6000) {
            continue;
        }
        io_service_t service = session->getService(device);
        const uint64_t sourceID = SAYAppleRemoteRegistryUInt64(
            service,
            CFSTR("LocationID")
        );
        CFRetain(device);
        session->registerCallback(device, SAYAppleRemoteTouchFrame, session);
        const bool started = session->startDevice(device, 0) == 0;
        if (!started) {
            session->unregisterCallback(device, SAYAppleRemoteTouchFrame);
            CFRelease(device);
            continue;
        }
        session->devices[session->deviceCount] = device;
        session->sourceIDs[session->deviceCount] = sourceID;
        session->deviceCount++;
        startedAny = true;
    }
    CFRelease(devices);
    return startedAny;
}

void SAYAppleRemoteTouchSessionStop(SAYAppleRemoteTouchSession *session) {
    if (session == NULL) {
        return;
    }
    for (size_t index = 0; index < session->deviceCount; index++) {
        MTDeviceRef device = session->devices[index];
        if (device == NULL) {
            continue;
        }
        session->unregisterCallback(device, SAYAppleRemoteTouchFrame);
        session->stopDevice(device);
        CFRelease(device);
        session->devices[index] = NULL;
        session->sourceIDs[index] = 0;
    }
    session->deviceCount = 0;
}

uint64_t SAYAppleRemoteTouchSourceIDForHIDDevice(const void *device) {
    if (device == NULL) {
        return 0;
    }
    io_service_t service = IOHIDDeviceGetService((IOHIDDeviceRef)device);
    if (service == IO_OBJECT_NULL) {
        return 0;
    }
    return SAYAppleRemoteRegistryUInt64(service, CFSTR("LocationID"));
}

void SAYAppleRemoteTouchSessionDestroy(SAYAppleRemoteTouchSession *session) {
    if (session == NULL) {
        return;
    }
    SAYAppleRemoteTouchSessionStop(session);
    if (session->framework != NULL) {
        dlclose(session->framework);
    }
    free(session);
}
