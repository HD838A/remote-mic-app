#include "AppleRemoteSupport.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdlib.h>

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
    MTDeviceRef device;
    SAYAppleRemoteTouchCallback callback;
    void *context;
    MTDeviceCreateListFunction createList;
    MTDeviceIsBuiltInFunction isBuiltIn;
    MTDeviceGetSensorSurfaceDimensionsFunction getDimensions;
    MTDeviceStartFunction startDevice;
    MTDeviceStopFunction stopDevice;
    MTRegisterCallbackFunction registerCallback;
    MTUnregisterCallbackFunction unregisterCallback;
};

static void SAYAppleRemoteTouchFrame(
    MTDeviceRef device,
    MTTouch touches[],
    size_t touchCount,
    double timestamp,
    size_t frame,
    void *context
) {
    (void)device;
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
    session->callback(contacts, count, timestamp, session->context);
}

static bool SAYAppleRemoteResolveSymbols(SAYAppleRemoteTouchSession *session) {
    session->createList = (MTDeviceCreateListFunction)dlsym(session->framework, "MTDeviceCreateList");
    session->isBuiltIn = (MTDeviceIsBuiltInFunction)dlsym(session->framework, "MTDeviceIsBuiltIn");
    session->getDimensions = (MTDeviceGetSensorSurfaceDimensionsFunction)dlsym(
        session->framework,
        "MTDeviceGetSensorSurfaceDimensions"
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
    for (CFIndex index = 0; index < deviceCount; index++) {
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
        session->device = device;
        CFRetain(device);
        session->registerCallback(device, SAYAppleRemoteTouchFrame, session);
        const bool started = session->startDevice(device, 0) == 0;
        if (!started) {
            session->unregisterCallback(device, SAYAppleRemoteTouchFrame);
            CFRelease(device);
            session->device = NULL;
        }
        CFRelease(devices);
        return started;
    }
    CFRelease(devices);
    return false;
}

void SAYAppleRemoteTouchSessionStop(SAYAppleRemoteTouchSession *session) {
    if (session == NULL || session->device == NULL) {
        return;
    }
    session->unregisterCallback(session->device, SAYAppleRemoteTouchFrame);
    session->stopDevice(session->device);
    CFRelease(session->device);
    session->device = NULL;
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
