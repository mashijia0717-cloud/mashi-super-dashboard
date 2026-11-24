import pathlib
import subprocess
import sys
import tempfile

baseline = pathlib.Path(sys.argv[1]).read_text()
start = baseline.index("static NSArray *allDisplays(void){")
end = baseline.index("static BOOL externalOnline(void){", start)
baseline = baseline[:start] + "static NSArray *allDisplays(void){ return @[@1]; }\n" + baseline[end:]
baseline = baseline.replace("int main(int argc,char **argv)", "int unusedLegacyMain(int argc,char **argv)")
baseline = baseline.replace("CGDisplayIsBuiltin(", "fakeBuiltin(")
baseline = baseline.replace("CGDisplayIsOnline(", "fakeOnline(")
baseline = baseline.replace("CGDisplaySerialNumber(", "fakeSerial(")
baseline = baseline.replace("[NSApp terminate:nil];", "abort();")
baseline = baseline.replace("if(![task launchAndReturnError:nil])return NO;", "abort(); if(![task launchAndReturnError:nil])return NO;")
prefix = r'''
@import Cocoa;
@import ApplicationServices;
static int zeroWrites;
static int fakeBuiltin(CGDirectDisplayID display){ return display==1; }
static int fakeOnline(CGDirectDisplayID display){ return display==1; }
static uint32_t fakeSerial(CGDirectDisplayID display){ return 0; }
static int fakeGet(CGDirectDisplayID display,float *value){ *value=0.6; return 0; }
static int fakeSet(CGDirectDisplayID display,float value){ if(value==0)zeroWrites++; return 0; }
'''
suffix = r'''
int main(void){ @autoreleasepool {
 getBrightness=fakeGet;setBrightness=fakeSet;
 powerIssued=YES;externalWasPresent=YES;
 SleepObserver *observer=[SleepObserver new];
 [observer changed:nil];
 if(zeroWrites!=1||finished||!externalDisconnected)return 1;
 puts("{\"baselineBugReproduced\":true,\"scenario\":\"external-removed-after-blank\",\"recordedZeroWrites\":1,\"restorationStarted\":false,\"realDisplayWrites\":0}");
 return 0;
}}
'''
with tempfile.TemporaryDirectory(prefix="legacy-screenblank-recorder-") as directory:
    source = pathlib.Path(directory) / "recorder.m"
    binary = pathlib.Path(directory) / "recorder"
    source.write_text(prefix + baseline + suffix)
    subprocess.run(["xcrun", "clang", "-w", "-fmodules", "-fobjc-arc", str(source),
                    "-framework", "Cocoa", "-framework", "ApplicationServices", "-framework", "Carbon", "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
