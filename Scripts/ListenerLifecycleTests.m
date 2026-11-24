#define RD_LISTENER_TESTING 1
#import "display-wake-listener.m"
static int failures=0,checks=0;
static void expect(BOOL value,const char *name){ checks++; if(!value){failures++;fprintf(stderr,"FAIL: %s\n",name);} }
static RDTopology physical(void){ RDTopology t=RDTopologyCreate(true);RDDisplay d={0}; d.id=2;d.serial=1010101;d.boundWidth=1920;d.boundHeight=1080;d.flags=RD_ONLINE|RD_ACTIVE; RDTopologyAdd(&t,d);return t; }
int main(){ @autoreleasepool {
 NSMutableArray *commands=[NSMutableArray new],*completions=[NSMutableArray new];
 DisplayWakeListener *l=[[DisplayWakeListener alloc]initWithTopologyProvider:^{return physical();} commandRunner:^(NSString *p,NSArray *a,void(^done)(int)){[commands addObject:@{@"path":p,@"args":a}];[completions addObject:[done copy]];}];
 l.synchronousTesting=YES;
 [l sleep:nil]; [l requestCheck];
 expect(commands.count==0,"sleep cancels and rejects layout work");
 l.sleeping=NO; [commands removeAllObjects];[completions removeAllObjects];l.running=NO;
 [l wake:[NSNotification notificationWithName:NSWorkspaceScreensDidWakeNotification object:nil]];
 expect(commands.count==1 && [commands[0][@"args"]isEqual:@[@"--recover-orphan"]],"screen wake preserves native active blank owner");
 if(completions.count){void(^done)(int)=completions[0];done(0);}
 expect(commands.count==2 && [commands.lastObject[@"path"]hasSuffix:@"cindy-fix-main-display.sh"],"wake restores orphan then reconciles serially");
 [l sleep:nil];
 if(completions.count>1){void(^done)(int)=completions[1];done(1);}
 expect(!l.pending && !l.rerun,"old failed completion after sleep cannot queue retries");
 // Fake scheduled blocks exercise the real debounce and stale-callback path.
 NSMutableArray *queue=[NSMutableArray new],*syncLog=[NSMutableArray new];
 __block RDTopology current=physical();
 __block BOOL failCommand=NO,failLayout=NO;
 DisplayWakeListener *q=[[DisplayWakeListener alloc]initWithTopologyProvider:^{return current;} commandRunner:^(NSString *p,NSArray *a,void(^done)(int)){[syncLog addObject:@{@"path":p,@"args":a}];done((failCommand||(failLayout&&[p hasSuffix:@"cindy-fix-main-display.sh"]))?1:0);}];
 q.scheduler=^(NSTimeInterval delay,dispatch_block_t work){[queue addObject:[work copy]];};
 [q startAdoptingExisting:YES];expect(queue.count==0,"adopt existing never touches display");
 [q startAdoptingExisting:NO];
 for(int i=0;i<100;i++)[q requestCheck];
 expect(queue.count==1,"startup and 100 callbacks coalesce without postponement");
 [q sleep:nil];
 dispatch_block_t old=queue[0];[queue removeAllObjects];old();
 expect(syncLog.count==0,"queued pre-sleep callback is inert");
 [q wake:nil];
 dispatch_block_t fresh=queue[0];[queue removeAllObjects];fresh();
 expect(syncLog.count==2,"wake restores orphan and reconciles exactly once");
 expect([syncLog[0][@"args"]isEqual:@[@"--recover-orphan"]],"automatic wake never signals active native owner");
 [syncLog removeAllObjects];failCommand=YES;[q requestCheck];
 for(int i=0;i<10&&queue.count;i++){dispatch_block_t work=queue[0];[queue removeObjectAtIndex:0];work();}
 expect(syncLog.count==4&&queue.count==0,"failed native recovery stops after four attempts");
 expect(!q.running&&!q.pending,"exhausted failure releases coordinator for later events");
 failCommand=NO;[syncLog removeAllObjects];[q wake:nil];
 fresh=queue[0];[queue removeAllObjects];fresh();
 expect(syncLog.count==2,"new wake retries after prior exhaustion");
 [syncLog removeAllObjects];failLayout=YES;[q requestCheck];
 for(int i=0;i<10&&queue.count;i++){dispatch_block_t work=queue[0];[queue removeObjectAtIndex:0];work();}
 expect(syncLog.count==8&&queue.count==0,"layout lock failure also uses only four serialized attempts");
 failLayout=NO;[syncLog removeAllObjects];[q requestCheck];
 fresh=queue[0];[queue removeAllObjects];fresh();
 expect(syncLog.count==2,"layout can recover when a later event finds native lock released");
 [syncLog removeAllObjects];
 current=RDTopologyCreate(true);
 [q handleDisplayChange:2 flags:kCGDisplayRemoveFlag];
 RDDisplay concurrentPhone={0};concurrentPhone.id=30;concurrentPhone.vendor=0x5244;concurrentPhone.model=0x4150;concurrentPhone.flags=RD_ONLINE|RD_ACTIVE;RDTopologyAdd(&current,concurrentPhone);
 [q handleDisplayChange:30 flags:kCGDisplayAddFlag];
 expect(q.removedExternal==2,"virtual add cannot erase a queued physical unplug identity");
 fresh=queue[0];[queue removeAllObjects];fresh();
 expect([syncLog[0][@"args"]containsObject:@"--observed-removal"],"real unplug reaches orphan recovery even through empty topology");
 expect([syncLog[1][@"args"]isEqual:@[@"--observed-removal",@"2"]],"real unplug identity reaches native layout recovery");
 [syncLog removeAllObjects];
 RDDisplay phone={0};phone.id=30;phone.vendor=0x5244;phone.model=0x4150;phone.flags=RD_ONLINE|RD_ACTIVE;/* virtual ID 30 is already online from the concurrent add above */
 [q handleDisplayChange:30 flags:kCGDisplayAddFlag];
 expect(queue.count==0,"virtual-only add does not trigger display control");
 [q sleep:nil];expect(q.removedExternal==2,"sleep preserves physical unplug evidence for the next genuine wake");[q handleDisplayChange:2 flags:kCGDisplayRemoveFlag];
 expect(queue.count==0,"physical removal during full system sleep cannot queue wake");

 // Regression 1: Sole external unplug triggers NSWorkspaceScreensDidSleepNotification while builtin is disabled with lid open.
 // Recovery MUST break through screen-sleep deadlock instead of waiting forever for an impossible ScreensDidWake.
 __block RDTopology unplugTopo = physical();
 __block BOOL deadlocked = NO;
 [syncLog removeAllObjects]; [queue removeAllObjects];
 DisplayWakeListener *u = [[DisplayWakeListener alloc] initWithTopologyProvider:^{ return unplugTopo; } commandRunner:^(NSString *p, NSArray *a, void (^done)(int)) {
  [syncLog addObject:@{@"path": p, @"args": a}]; done(0);
 }];
 u.scheduler = ^(NSTimeInterval delay, dispatch_block_t work) { [queue addObject:[work copy]]; };
 u.ownedDeadlockProvider = ^{ return deadlocked; };
 // Simulate multi-step callback where DisabledFlag arrives after display already vanished from online list, before RemoveFlag:
 unplugTopo = RDTopologyCreate(true);
 deadlocked = YES;
 [u handleDisplayChange:2 flags:kCGDisplayDisabledFlag];
 [u handleDisplayChange:2 flags:kCGDisplayRemoveFlag];
 expect(u.removedExternal == 2, "known external tracking survives earlier callback that already refreshed previous topology");
 // Immediately followed by ScreensDidSleep (NOT WillSleep):
 [u sleep:[NSNotification notificationWithName:NSWorkspaceScreensDidSleepNotification object:nil]];
 expect(!u.sleeping && queue.count == 1, "screen-sleep notification during open-lid headless unplug does not cancel builtin recovery");
 if (queue.count) { dispatch_block_t work = queue[0]; [queue removeAllObjects]; work(); }
 expect(syncLog.count == 2 && [syncLog[1][@"args"] isEqual:@[@"--observed-removal", @"2"]], "headless unplug executes orphan + layout recovery with observed removal ID");

 // Regression 2: Ferry virtual display ("mstr" = 0x6d737472) is marked RD_VIRTUAL and never counted as usable physical external.
 RDTopology ferryOnly = RDTopologyCreate(true);
 RDDisplay ferry = {0}; ferry.id = 34; ferry.serial = 0x6d737472u; ferry.boundWidth = 1210; ferry.boundHeight = 834; ferry.flags = RD_ONLINE | RD_ACTIVE;
 RDTopologyAdd(&ferryOnly, ferry);
 expect(RDUsableExternalCount(&ferryOnly) == 0, "Ferry virtual display never counts as a usable physical external display");

 RDTopology asleep=physical();asleep.physical[0].flags|=RD_ASLEEP;
 DisplayWakeListener *boot=[[DisplayWakeListener alloc]initWithTopologyProvider:^{return asleep;} commandRunner:^(NSString *p,NSArray *a,void(^done)(int)){expect(NO,"sleeping startup must emit zero commands");}];
 [boot startAdoptingExisting:NO];expect(boot.sleeping&&!boot.pending,"startup adopts an already-sleeping display without waking it");
 printf("{\"checks\":%d,\"failures\":%d,\"physicalWrites\":0}\n",checks,failures);return failures?1:0;
} }
