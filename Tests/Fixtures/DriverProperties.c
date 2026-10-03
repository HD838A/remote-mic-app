#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void fail(void) { fputs("driver property verification failed\n", stderr); exit(1); }
static void string_property(AudioServerPlugInDriverRef driver, AudioObjectID object, AudioObjectPropertySelector selector, const char *expected) {
    AudioObjectPropertyAddress address = { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef result = NULL; UInt32 size = sizeof(result); char text[256];
    if ((*driver)->GetPropertyData(driver, object, 0, &address, 0, NULL, size, &size, &result) || !result || !CFStringGetCString(result, text, sizeof(text), kCFStringEncodingUTF8) || strcmp(text, expected)) fail();
    printf("property=%u value=%s\n", selector, text); CFRelease(result);
}
static void number_property(AudioServerPlugInDriverRef driver, AudioObjectID object, AudioObjectPropertySelector selector, UInt32 expected) {
    AudioObjectPropertyAddress address = { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 result=0, size=sizeof(result);
    if ((*driver)->GetPropertyData(driver, object, 0, &address, 0, NULL, size, &size, &result) || result != expected) fail();
    printf("property=%u value=%u\n", selector, result);
}
int main(int argc, char **argv) {
    if (argc != 3) fail();
    void *library = dlopen(argv[1], RTLD_NOW|RTLD_LOCAL); if (!library) fail();
    void *(*factory)(CFAllocatorRef, CFUUIDRef) = dlsym(library, "BlackHole_Create"); if (!factory) fail();
    AudioServerPlugInDriverRef driver = factory(NULL, kAudioServerPlugInTypeUUID); if (!driver) fail();
    string_property(driver, 3, kAudioObjectPropertyName, argv[2]);
    string_property(driver, 3, kAudioDevicePropertyDeviceUID, "MiRemoteV2ch_UID");
    string_property(driver, 3, kAudioDevicePropertyModelUID, "MiRemoteV2ch_ModelUID");
    string_property(driver, 12, kAudioDevicePropertyDeviceUID, "MiRemoteV2ch_2_UID");
    string_property(driver, 2, kAudioBoxPropertyBoxUID, "MiRemoteV2ch_UID");
    number_property(driver, 3, kAudioDevicePropertyIsHidden, 0);
    number_property(driver, 12, kAudioDevicePropertyIsHidden, 1);
    number_property(driver, 3, kAudioDevicePropertyTransportType, kAudioDeviceTransportTypeUSB);
    // The hidden mirror and public device endpoint count must stay identical.
    AudioObjectPropertyAddress address = { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size=0;
    if ((*driver)->GetPropertyDataSize(driver, kAudioObjectPlugInObject, 0, &address, 0, NULL, &size) || size != 2*sizeof(AudioObjectID)) fail();
    printf("device_count=2 public_count=1\n");
    return 0;
}
