@import Cocoa;
@import ApplicationServices;
@import Carbon;
@import IOKit;
#import <objc/message.h>
#include <dlfcn.h>
#include <sys/file.h>
#include <signal.h>
#include <libproc.h>
#include <stdatomic.h>
#include <math.h>
#include "RDDisplayTopology.h"

static NSString *helperPath(NSString *name){
 return [[NSBundle.mainBundle.executableURL.URLByResolvingSymlinksInPath URLByDeletingLastPathComponent]URLByAppendingPathComponent:name].path;
}

static NSString *statePath, *markerPath;
static int activeLockDescriptor = -1;
static id keyboardClient;
static BOOL finished=NO, powerIssued=NO, externalDisconnected=NO;
static BOOL externalWasPresent=NO;
static dispatch_source_t termSource, intSource, releaseSource;
static EventHotKeyRef restoreHotKey;
static id globalWakeEventMonitor = nil;
static id globalMoveEventMonitor = nil;
static NSPoint blankMouseOrigin;
static BOOL mouseOriginRecorded = NO;
static NSArray *savedBuiltins;
static BOOL systemSleeping=NO, restoring=NO, restoreRequested=NO;
static NSUInteger operationGeneration=0, restoreAttempts=0;
static CGDirectDisplayID blankExternalID=0;
static atomic_bool removalObserved;
static BOOL testing=NO, testLidOpen=YES, testRecoveryFails=NO, testBrightnessWriteFails=NO, testKeyboardWriteFails=NO;
static NSMutableDictionary *testDisplays;
static NSMutableArray *testCommands, *testCallbacks;
static RDTopologyGate topologyGate;

static RDTopology screenTopology(void) {
 if(!testing)return RDReadSystemTopology();
 RDTopology snapshot=RDTopologyCreate(true);
 for(NSNumber *number in testDisplays){
  NSDictionary *row=testDisplays[number];RDDisplay display={0};display.id=number.unsignedIntValue;
  display.vendor=[row[@"vendor"]unsignedIntValue];display.model=[row[@"model"]unsignedIntValue];display.serial=[row[@"serial"]unsignedIntValue];
  display.boundWidth=1920;display.boundHeight=1080;
  if([row[@"builtin"]boolValue])display.flags|=RD_BUILTIN;
  if([row[@"online"]boolValue])display.flags|=RD_ONLINE;
  if([row[@"active"]boolValue])display.flags|=RD_ACTIVE;
  if([row[@"asleep"]boolValue])display.flags|=RD_ASLEEP;
  RDTopologyAdd(&snapshot,display);
 }
 return snapshot;
}
typedef CGError (*DisplayList)(uint32_t,CGDirectDisplayID *,uint32_t *);
typedef int (*GetBrightness)(CGDirectDisplayID,float *);
typedef int (*SetBrightness)(CGDirectDisplayID,float);
static GetBrightness getBrightness;
static SetBrightness setBrightness;
static BOOL panelOnline(CGDirectDisplayID display){return testing?[testDisplays[@(display)][@"online"]boolValue]:CGDisplayIsOnline(display);}
static BOOL panelBuiltin(CGDirectDisplayID display){return testing?[testDisplays[@(display)][@"builtin"]boolValue]:CGDisplayIsBuiltin(display);}
static BOOL panelActive(CGDirectDisplayID display){return testing?[testDisplays[@(display)][@"active"]boolValue]:CGDisplayIsActive(display);}
static BOOL panelAsleep(CGDirectDisplayID display){return testing?[testDisplays[@(display)][@"asleep"]boolValue]:CGDisplayIsAsleep(display);}
static uint32_t panelSerial(CGDirectDisplayID display){return testing?[testDisplays[@(display)][@"serial"]unsignedIntValue]:CGDisplaySerialNumber(display);}
static uint32_t panelVendor(CGDirectDisplayID display){return testing?[testDisplays[@(display)][@"vendor"]unsignedIntValue]:CGDisplayVendorNumber(display);}
static BOOL panelVirtual(CGDirectDisplayID display){
 if(testing)return [testDisplays[@(display)][@"virtual"]boolValue];
 return RDQuerySystemVirtualDisplay(display);
}
static BOOL panelSupportedAOC(CGDirectDisplayID display){
 return !panelBuiltin(display) && !panelVirtual(display) && (panelSerial(display)==1010101 || panelVendor(display)==0x05E3);
}
static BOOL lidOpen(void){
 if(testing)return testLidOpen;
 io_service_t root=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOPMrootDomain"));
 if(!root)return NO;
 CFTypeRef value=IORegistryEntryCreateCFProperty(root,CFSTR("AppleClamshellState"),kCFAllocatorDefault,0);
 IOObjectRelease(root);
 BOOL open=value&&CFGetTypeID(value)==CFBooleanGetTypeID()&&!CFBooleanGetValue(value);
 if(value)CFRelease(value);
 return open;
}
static void later(NSTimeInterval delay,dispatch_block_t block){
 if(testing){[testCallbacks addObject:[block copy]];return;}
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),block);
}
static BOOL acquireExclusiveLock(int descriptor, NSTimeInterval timeoutSeconds){
 NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:fmax(0, timeoutSeconds)];
 while(YES){
  if(flock(descriptor, LOCK_EX | LOCK_NB) == 0) return YES;
  if([[NSDate date] compare:deadline] != NSOrderedAscending) return NO;
  usleep(50000);
 }
}

static NSArray *allDisplays(void){
 if(testing)return testDisplays.allKeys;
 CGDirectDisplayID ids[32];uint32_t count=0;
 void *sky=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY);
 DisplayList list=sky?(DisplayList)dlsym(sky,"CGSGetDisplayList"):NULL;
 CGError result=list?list(32,ids,&count):CGGetOnlineDisplayList(32,ids,&count);
 NSMutableArray *out=[NSMutableArray array];
 if(result==kCGErrorSuccess)for(uint32_t i=0;i<count;i++)[out addObject:@(ids[i])];
 return out;
}
static BOOL externalOnline(void){
 for(NSNumber *n in allDisplays())if(panelSupportedAOC(n.unsignedIntValue)&&panelOnline(n.unsignedIntValue))return YES;
 return NO;
}
static BOOL command(NSString *path,NSArray *arguments){
 if(testing){
  [testCommands addObject:@{@"command":path.lastPathComponent,@"arguments":arguments}];
  if([arguments containsObject:@"recover-builtin"]){
   if(testRecoveryFails)return NO;
   for(NSNumber *number in testDisplays)if(panelBuiltin(number.unsignedIntValue))testDisplays[number][@"online"]=@YES;
  }
  return YES;
 }
 NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:path];task.arguments=arguments;
 task.standardOutput=NSFileHandle.fileHandleWithNullDevice;task.standardError=NSFileHandle.fileHandleWithNullDevice;
 if(![task launchAndReturnError:nil])return NO;[task waitUntilExit];return task.terminationStatus==0;
}
static BOOL activeSession(void){
 NSString *pid=[NSString stringWithContentsOfFile:markerPath encoding:NSUTF8StringEncoding error:nil];
 char path[PROC_PIDPATHINFO_MAXSIZE]={0};
 return pid.intValue>0&&proc_pidpath(pid.intValue,path,sizeof(path))>0&&[[@(path) lastPathComponent]isEqual:@"ScreenBlank"]&&kill(pid.intValue,0)==0;
}
static NSString *orphanRecoverySkip(BOOL active,BOOL hasRecord,BOOL awake,BOOL removed,BOOL external){
 if(active)return @"native-owner-active";
 if(!hasRecord)return @"no-owned-state";
 if(!awake&&!(removed&&!external))return @"screens-asleep-or-unknown";
 return nil;
}
static NSArray *builtinSnapshot(void){
 NSMutableArray *out=[NSMutableArray array];
 for(NSNumber *n in allDisplays()){
  CGDirectDisplayID display=n.unsignedIntValue;if(!panelBuiltin(display))continue;
  float brightness=-1;
  if(getBrightness&&getBrightness(display,&brightness)==0&&isfinite(brightness)&&brightness>=0&&brightness<=1)
   [out addObject:@{@"id":n,@"brightness":@(brightness)}];
  else if(panelOnline(display))return nil;
 }
 return out;
}
static BOOL darkenBuiltins(void){
 if(finished||restoreRequested||systemSleeping||!lidOpen()||(externalWasPresent&&(atomic_load(&removalObserved)||externalDisconnected||!externalOnline())))return NO;
 BOOL ok=YES;
 for(NSNumber *n in allDisplays())if(panelBuiltin(n.unsignedIntValue)&&panelOnline(n.unsignedIntValue)){
  float value=-1;
  if(getBrightness&&getBrightness(n.unsignedIntValue,&value)==0&&value<=0.01)continue;
  ok=(setBrightness&&setBrightness(n.unsignedIntValue,0)==0)&&ok;
 }
 return ok;
}

static void output(NSDictionary *value){
 NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
 puts([[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding].UTF8String);fflush(stdout);
}
static BOOL screensAwake(void){
 CGDirectDisplayID displays[32];uint32_t count=0;
 if(CGGetOnlineDisplayList(32,displays,&count)!=kCGErrorSuccess)return NO;
 for(uint32_t index=0;index<count;index++){
  if(!RDQuerySystemVirtualDisplay(displays[index])&&CGDisplayIsActive(displays[index])&&!CGDisplayIsAsleep(displays[index]))return YES;
 }
 return NO;
}
static NSArray *keyboardSnapshot(void){
 NSMutableArray *saved=[NSMutableArray array];
 if(![keyboardClient respondsToSelector:@selector(copyKeyboardBacklightIDs)])return saved;
 NSArray *ids=((id(*)(id,SEL))objc_msgSend)(keyboardClient,@selector(copyKeyboardBacklightIDs));
 for(NSNumber *number in ids){
  uint64_t identifier=number.unsignedLongLongValue;
  float value=((float(*)(id,SEL,uint64_t))objc_msgSend)(keyboardClient,@selector(brightnessForKeyboard:),identifier);
  if(!isfinite(value)||value<0||value>1)continue;
  BOOL automatic=((BOOL(*)(id,SEL,uint64_t))objc_msgSend)(keyboardClient,@selector(isAutoBrightnessEnabledForKeyboard:),identifier);
  [saved addObject:@{@"id":number,@"brightness":@(value),@"automatic":@(automatic)}];
 }
 return saved;
}
static BOOL setKeyboard(NSDictionary *keyboard,BOOL restore){
 if(testing){[testCommands addObject:@{@"keyboard":keyboard,@"restore":@(restore)}];return !testKeyboardWriteFails;}
 if(!keyboardClient)return NO;
 uint64_t identifier=[keyboard[@"id"]unsignedLongLongValue];
 BOOL automatic=restore&&[keyboard[@"automatic"]boolValue];
 float value=restore?[keyboard[@"brightness"]floatValue]:0;
 BOOL changed=((BOOL(*)(id,SEL,BOOL,uint64_t))objc_msgSend)(keyboardClient,@selector(enableAutoBrightness:forKeyboard:),NO,identifier);
 changed=((BOOL(*)(id,SEL,float,uint64_t))objc_msgSend)(keyboardClient,@selector(setBrightness:forKeyboard:),value,identifier)&&changed;
 if(automatic)changed=((BOOL(*)(id,SEL,BOOL,uint64_t))objc_msgSend)(keyboardClient,@selector(enableAutoBrightness:forKeyboard:),YES,identifier)&&changed;
 return changed;
}
static void tearDownUserWakeMonitors(void){
 if(globalWakeEventMonitor){[NSEvent removeMonitor:globalWakeEventMonitor];globalWakeEventMonitor=nil;}
 if(globalMoveEventMonitor){[NSEvent removeMonitor:globalMoveEventMonitor];globalMoveEventMonitor=nil;}
}
static BOOL restoreState(void){
 NSData *data=[NSData dataWithContentsOfFile:statePath];
 if(!data)return YES;
 NSDictionary *state=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
 if(![state isKindOfClass:NSDictionary.class]||![state[@"keyboards"]isKindOfClass:NSArray.class])return NO;
 BOOL restored=YES;
 if([state[@"armed"]isEqual:@NO]){
  [[NSFileManager defaultManager]removeItemAtPath:statePath error:nil];return YES;
 }
 for(NSDictionary *screen in state[@"builtins"]){
  CGDirectDisplayID display=[screen[@"id"]unsignedIntValue];
  if(!panelBuiltin(display)||!panelOnline(display)){
   display=0;
   for(NSNumber *number in allDisplays())if(panelBuiltin(number.unsignedIntValue)&&panelOnline(number.unsignedIntValue)){display=number.unsignedIntValue;break;}
  }
  if(!display||!panelOnline(display)){restored=NO;continue;}
  float current=-1;
  if(!getBrightness||getBrightness(display,&current)!=0){restored=NO;continue;}
  if(current<=0.01){
   float target=[screen[@"brightness"]floatValue];
   if(externalWasPresent&&(externalDisconnected||atomic_load(&removalObserved)||!externalOnline()))target=fmaxf(target,0.5);
   else if(target<=0.02)target=0.5;
   restored=(setBrightness&&setBrightness(display,target)==0)&&restored;
  }
 }
 for(NSDictionary *keyboard in state[@"keyboards"])restored=setKeyboard(keyboard,YES)&&restored;
 if(!testing && ([state[@"externalWasPresent"]boolValue] || externalWasPresent) && externalOnline()){
  // Best-effort VCP Power On for supported AOC monitor when waking from blanking
  (void)command(helperPath(@"DDCControl"), @[@"set", @"0xD6", @"1"]);
 }
 if(restored)[[NSFileManager defaultManager]removeItemAtPath:statePath error:nil];
 return restored;
}
static void finish(void){
 if(finished||restoring)return;
 restoreRequested=YES;operationGeneration++;
 tearDownUserWakeMonitors();
 if(systemSleeping||!lidOpen())return;
 restoring=YES;
 BOOL recovery=YES;
 if(externalWasPresent&&(atomic_load(&removalObserved)||externalDisconnected||!externalOnline()))recovery=command(helperPath(@"DisplayManager"),savedBuiltins.count?@[@"recover-builtin",@"--enable-only",@"--owned-blank-recovery"]:@[@"recover-builtin",@"--owned-blank-recovery"]);
 BOOL restored=recovery&&restoreState();
 restoring=NO;
 restored=restored&&recovery;
 if(!restored){
  output(@{@"restored":@NO,@"pendingRetry":@YES});
  if(restoreAttempts++<3)later(0.4,^{finish();});
  return;
 }
 finished=YES;
 if(restoreHotKey)UnregisterEventHotKey(restoreHotKey);
 [[NSFileManager defaultManager]removeItemAtPath:markerPath error:nil];
 if(activeLockDescriptor >= 0){flock(activeLockDescriptor, LOCK_UN);}
 output(@{@"restored":@(restored),@"mode":@"hardware-off",@"externalPowerButtonRequired":@(!externalOnline())});
 if(!testing)[NSApp terminate:nil];
}
static void requestExplicitFinish(void){
 restoreAttempts = 0;
 finish();
}
static OSStatus restoreKey(EventHandlerCallRef next,EventRef event,void *context){requestExplicitFinish();return noErr;}

static void installUserWakeMonitors(NSUInteger generation){
 if(testing||finished||restoreRequested||generation!=operationGeneration)return;
 tearDownUserWakeMonitors();
 blankMouseOrigin = [NSEvent mouseLocation];
 mouseOriginRecorded = YES;
 NSEventMask wakeMask = NSEventMaskKeyDown | NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown | NSEventMaskScrollWheel;
 globalWakeEventMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:wakeMask handler:^(NSEvent *event){
  dispatch_async(dispatch_get_main_queue(), ^{ requestExplicitFinish(); });
 }];
 globalMoveEventMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskMouseMoved handler:^(NSEvent *event){
  NSPoint p = [NSEvent mouseLocation];
  if(!mouseOriginRecorded){ blankMouseOrigin = p; mouseOriginRecorded = YES; return; }
  if(hypot(p.x - blankMouseOrigin.x, p.y - blankMouseOrigin.y) >= 36.0){
   dispatch_async(dispatch_get_main_queue(), ^{ requestExplicitFinish(); });
  }
 }];
}

@interface SleepObserver:NSObject
@end
@implementation SleepObserver
-(void)changed:(NSNotification *)notification{
 if([notification.name isEqual:NSWorkspaceScreensDidWakeNotification]&&!systemSleeping&&!restoreRequested&&!RDTopologyShouldProcess(&topologyGate,screenTopology(),RDEventScreenWake,0))return;
 if([notification.name isEqual:NSApplicationDidChangeScreenParametersNotification]&&!RDTopologyShouldProcess(&topologyGate,screenTopology(),RDEventScreenParameters,0))return;
 if(finished)return;
 NSString *name=notification.name;
 if([name isEqual:NSWorkspaceWillSleepNotification]||([name isEqual:NSWorkspaceScreensDidSleepNotification]&&!powerIssued)){
  systemSleeping=YES;operationGeneration++;return;
 }
 BOOL waking=[name isEqual:NSWorkspaceDidWakeNotification]||[name isEqual:NSWorkspaceScreensDidWakeNotification];
 if(waking){systemSleeping=NO;restoreAttempts=0;}
 BOOL online=externalOnline();
 if(externalWasPresent&&(!online||atomic_load(&removalObserved)))externalDisconnected=YES;
 BOOL newlyConnectedExternal = !externalWasPresent && online && powerIssued;
 if(restoreRequested||(externalWasPresent&&externalDisconnected)||newlyConnectedExternal||[name isEqual:NSWorkspaceDidWakeNotification]||(waking&&!online)){
  if(newlyConnectedExternal || (externalWasPresent&&externalDisconnected)) restoreAttempts=0;
  finish();return;
 }
}
@end

static void displayChanged(CGDirectDisplayID display,CGDisplayChangeSummaryFlags flags,void *context){
 if(flags&kCGDisplayBeginConfigurationFlag)return;
 if((flags&kCGDisplayRemoveFlag)&&display==blankExternalID)atomic_store(&removalObserved,true);
 if(!(flags&(kCGDisplayAddFlag|kCGDisplayRemoveFlag|kCGDisplayEnabledFlag|kCGDisplayDisabledFlag)))return;
 SleepObserver *observer=(__bridge SleepObserver *)context;
 dispatch_block_t event=^{
  if(display!=blankExternalID&&!RDTopologyShouldProcess(&topologyGate,screenTopology(),RDEventDisplayCallback,display))return;
  if((flags&kCGDisplayRemoveFlag)&&display==blankExternalID){externalDisconnected=YES;restoreAttempts=0;operationGeneration++;}
  if((flags&kCGDisplayAddFlag)&&!panelBuiltin(display)&&!panelVirtual(display)&&powerIssued){
   restoreAttempts=0;
   finish();
   return;
  }
  [observer changed:nil];
 };
 if(testing)event();else dispatch_async(dispatch_get_main_queue(),event);
}

static void beginBlanking(NSArray *keyboards,NSUInteger generation){
 if(finished||generation!=operationGeneration||systemSleeping||!lidOpen()||(externalWasPresent&&(atomic_load(&removalObserved)||externalDisconnected||!externalOnline()))){finish();return;}
 NSData *data=[NSData dataWithContentsOfFile:statePath];
 NSMutableDictionary *state=[[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil]mutableCopy];
 if(!state){finish();return;}
 state[@"armed"]=@YES;
 if(![[NSJSONSerialization dataWithJSONObject:state options:0 error:nil]writeToFile:statePath atomically:YES]){finish();return;}
 for(NSDictionary *keyboard in keyboards)if(!setKeyboard(keyboard,NO)){finish();return;}
 if(!darkenBuiltins()){finish();return;}
 powerIssued=YES;
 if(externalWasPresent&&(atomic_load(&removalObserved)||externalDisconnected||!externalOnline()||!command(helperPath(@"DDCControl"),@[@"set",@"0xD6",@"5"]))){finish();return;}
 if(!testing){
  later(1.0, ^{ installUserWakeMonitors(generation); });
 }
 output(@{@"started":@YES,@"mode":@"hardware-off",@"externalPowerButtonRequired":@(externalWasPresent)});
}

#include "ScreenBlankRegression.inc"

int main(int argc,char **argv){@autoreleasepool{
 if(argc>1&&!strcmp(argv[1],"--lifecycle-regression"))return runOrphanRegression();
 if(argc>1&&(!strcmp(argv[1],"--safety-regression")||!strcmp(argv[1],"--self-test")))return runSafetyRegression();
 NSString *directory=[NSHomeDirectory()stringByAppendingPathComponent:@"Library/Application Support/DisplayPanel"];
 [[NSFileManager defaultManager]createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
 statePath=[directory stringByAppendingPathComponent:@"screen-sleep-state.json"];
 markerPath=[directory stringByAppendingPathComponent:@"blanking.pid"];
 dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",RTLD_LAZY);
 void *services=dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",RTLD_LAZY);
 getBrightness=services?(GetBrightness)dlsym(services,"DisplayServicesGetBrightness"):NULL;
 setBrightness=services?(SetBrightness)dlsym(services,"DisplayServicesSetBrightness"):NULL;
 keyboardClient=[[NSClassFromString(@"KeyboardBrightnessClient")alloc]init];
 NSString *operation=argc>1?@(argv[1]):@"sleep";
 BOOL orphanOnly=[operation isEqualToString:@"--recover-orphan"];
 BOOL observedRemoval=orphanOnly&&argc>2&&!strcmp(argv[2],"--observed-removal");
 if([operation isEqualToString:@"--status"]){
  output(@{@"awake":@(screensAwake()),@"pendingRestore":@([[NSFileManager defaultManager]fileExistsAtPath:statePath]),@"active":@(activeSession()),@"mode":@"hardware-off",@"externalOnline":@(externalOnline()),@"keyboards":keyboardSnapshot(),@"builtins":builtinSnapshot()?:@[]});return 0;
 }
 if(orphanOnly){
  BOOL builtinDisabled = NO;
  for(NSNumber *n in allDisplays()) if(panelBuiltin(n.unsignedIntValue) && !panelOnline(n.unsignedIntValue)) builtinDisabled = YES;
  BOOL forceUnplugAwake = lidOpen() && builtinDisabled && !externalOnline() && [[NSFileManager defaultManager]fileExistsAtPath:statePath];
  NSString *skip=orphanRecoverySkip(activeSession(),[[NSFileManager defaultManager]fileExistsAtPath:statePath],screensAwake()||forceUnplugAwake,observedRemoval||forceUnplugAwake,externalOnline());
  if(skip){output(@{@"ok":@YES,@"skipped":skip});return [skip isEqual:@"screens-asleep-or-unknown"]?1:0;}
  operation=@"--restore";
 }
 if(([operation isEqualToString:@"--release"]||[operation isEqualToString:@"--restore"])&&activeSession()){
  NSString *pid=[NSString stringWithContentsOfFile:markerPath encoding:NSUTF8StringEncoding error:nil];
  if(kill(pid.intValue,SIGUSR1)!=0)return 1;
  for(int i=0;i<40;i++){if(!activeSession())return 0;usleep(100000);}
  return 1;
 }
 if(![operation isEqualToString:@"sleep"]&&![operation isEqualToString:@"--restore"]&&![operation isEqualToString:@"--release"]){fprintf(stderr,"usage: ScreenBlank [--status|--restore|--release|--self-test]\n");return 2;}
 NSString *lockPath=[directory stringByAppendingPathComponent:@"screen-sleep.lock"];
 int descriptor=open(lockPath.fileSystemRepresentation,O_CREAT|O_RDWR,0600);
 BOOL isRestoreOp = [operation isEqualToString:@"--restore"] || [operation isEqualToString:@"--release"];
 if(descriptor<0 || !acquireExclusiveLock(descriptor, isRestoreOp ? 2.0 : 0.0)){
  if(descriptor>=0)close(descriptor);
  if(orphanOnly && activeSession()){output(@{@"ok":@YES,@"skipped":@"native-owner-active"});return 0;}
  output(@{@"ok":@NO,@"error":@"显示器休眠操作已在运行"});return 1;
 }
 activeLockDescriptor = descriptor;
 if(orphanOnly&&activeSession()){flock(descriptor,LOCK_UN);close(descriptor);output(@{@"ok":@YES,@"skipped":@"native-owner-active"});return 0;}
 if(isRestoreOp){
  if(!lidOpen()){flock(descriptor,LOCK_UN);close(descriptor);output(@{@"restored":@NO,@"deferred":@"lid-closed-or-unknown"});return 1;}
  if(![[NSFileManager defaultManager]fileExistsAtPath:statePath]){
   [[NSFileManager defaultManager]removeItemAtPath:markerPath error:nil];
   flock(descriptor,LOCK_UN);close(descriptor);
   output(@{@"restored":@YES});return 0;
  }
  NSData *saved=[NSData dataWithContentsOfFile:statePath];
  NSDictionary *state=saved?[NSJSONSerialization JSONObjectWithData:saved options:0 error:nil]:nil;
  externalWasPresent=[state[@"externalWasPresent"]boolValue];
  if(externalWasPresent&&!externalOnline()){
   NSMutableArray *arguments=[NSMutableArray arrayWithObject:@"recover-builtin"];
   if([state[@"builtins"]count])[arguments addObject:@"--enable-only"];
   if(observedRemoval || lidOpen())[arguments addObject:@"--owned-blank-recovery"];
   if(!command(helperPath(@"DisplayManager"),arguments)){flock(descriptor,LOCK_UN);close(descriptor);return 1;}
  }
  BOOL restored=restoreState();
  if(restored)[[NSFileManager defaultManager]removeItemAtPath:markerPath error:nil];
  flock(descriptor,LOCK_UN);close(descriptor);
  output(@{@"restored":@(restored)});return restored?0:1;
 }
 if(!lidOpen()||!restoreState()){flock(descriptor,LOCK_UN);close(descriptor);output(@{@"ok":@NO,@"error":@"上次的键盘背光尚未恢复或上盖未打开"});return 1;}
 NSArray *keyboards=keyboardSnapshot();
 savedBuiltins=builtinSnapshot();
 if(!savedBuiltins){flock(descriptor,LOCK_UN);close(descriptor);fprintf(stderr,"无法保存内建屏亮度，未关闭显示器\n");return 1;}
 externalWasPresent=externalOnline();
 for(NSNumber *number in allDisplays())if(panelSupportedAOC(number.unsignedIntValue)&&panelOnline(number.unsignedIntValue))blankExternalID=number.unsignedIntValue;
 if(!lidOpen()||(blankExternalID&&(!panelActive(blankExternalID)||panelAsleep(blankExternalID)))){flock(descriptor,LOCK_UN);close(descriptor);return 1;}
 for(NSNumber *n in allDisplays()){
  CGDirectDisplayID display=n.unsignedIntValue;
  if(CGDisplayIsOnline(display)&&!CGDisplayIsBuiltin(display)&&!panelVirtual(display)&&CGDisplayVendorNumber(display)!=0&&!panelSupportedAOC(display)){
   flock(descriptor,LOCK_UN);close(descriptor);
   fprintf(stderr,"当前外接屏尚不支持硬件关机，未执行\n");return 1;
  }
 }
 NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"keyboards":keyboards,@"builtins":savedBuiltins,@"armed":@NO,@"mode":@"hardware-off",@"externalWasPresent":@(externalWasPresent)} options:0 error:nil];
 NSError *error=nil;
 if(![data writeToFile:statePath options:NSDataWritingAtomic error:&error]){flock(descriptor,LOCK_UN);close(descriptor);fprintf(stderr,"无法保存背光恢复状态\n");return 1;}
 if(![[NSString stringWithFormat:@"%d",getpid()]writeToFile:markerPath atomically:YES encoding:NSUTF8StringEncoding error:&error]){
  [[NSFileManager defaultManager]removeItemAtPath:statePath error:nil];flock(descriptor,LOCK_UN);close(descriptor);return 1;
 }
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
 SleepObserver *observer=[SleepObserver new];
 topologyGate=RDTopologyGateCreate(screenTopology());
 [NSNotificationCenter.defaultCenter addObserver:observer selector:@selector(changed:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
 [NSWorkspace.sharedWorkspace.notificationCenter addObserver:observer selector:@selector(changed:) name:NSWorkspaceScreensDidWakeNotification object:nil];
 [NSWorkspace.sharedWorkspace.notificationCenter addObserver:observer selector:@selector(changed:) name:NSWorkspaceDidWakeNotification object:nil];
 [NSWorkspace.sharedWorkspace.notificationCenter addObserver:observer selector:@selector(changed:) name:NSWorkspaceWillSleepNotification object:nil];
 [NSWorkspace.sharedWorkspace.notificationCenter addObserver:observer selector:@selector(changed:) name:NSWorkspaceScreensDidSleepNotification object:nil];
 CGDisplayRegisterReconfigurationCallback(displayChanged,(__bridge void *)observer);
 EventTypeSpec hotKeyEvent={kEventClassKeyboard,kEventHotKeyPressed};
 InstallApplicationEventHandler(restoreKey,1,&hotKeyEvent,NULL,NULL);
 EventHotKeyID hotKeyID={'DPOF',1};
 if(RegisterEventHotKey(kVK_ANSI_O,cmdKey|optionKey|shiftKey,hotKeyID,GetApplicationEventTarget(),0,&restoreHotKey)!=noErr)
  fprintf(stderr,"恢复快捷键注册失败，可从菜单恢复内建屏和键盘\n");
 signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN);
 termSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
 dispatch_source_set_event_handler(termSource,^{requestExplicitFinish();});dispatch_resume(termSource);
 intSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGINT,0,dispatch_get_main_queue());
 dispatch_source_set_event_handler(intSource,^{requestExplicitFinish();});dispatch_resume(intSource);
 signal(SIGUSR1,SIG_IGN);
 releaseSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGUSR1,0,dispatch_get_main_queue());
 dispatch_source_set_event_handler(releaseSource,^{requestExplicitFinish();});dispatch_resume(releaseSource);
 NSUInteger generation=operationGeneration;
 later(0.7,^{beginBlanking(keyboards,generation);});
 [NSApp run];
 tearDownUserWakeMonitors();
 flock(descriptor,LOCK_UN);close(descriptor);
 return 0;
}}
