#ifndef AppleRemoteSupport_h
#define AppleRemoteSupport_h

#include <stdbool.h>
#include <stdint.h>

typedef struct {
    int32_t identifier;
    double normalizedX;
    double normalizedY;
    double contactSize;
    bool hasContactSize;
} SAYAppleRemoteTouchContact;

typedef void (*SAYAppleRemoteTouchCallback)(
    const SAYAppleRemoteTouchContact *contacts,
    int32_t contactCount,
    double timestamp,
    void *context
);

typedef struct SAYAppleRemoteTouchSession SAYAppleRemoteTouchSession;

SAYAppleRemoteTouchSession *SAYAppleRemoteTouchSessionCreate(
    SAYAppleRemoteTouchCallback callback,
    void *context
);
bool SAYAppleRemoteTouchSessionStart(SAYAppleRemoteTouchSession *session);
void SAYAppleRemoteTouchSessionStop(SAYAppleRemoteTouchSession *session);
void SAYAppleRemoteTouchSessionDestroy(SAYAppleRemoteTouchSession *session);

#endif
