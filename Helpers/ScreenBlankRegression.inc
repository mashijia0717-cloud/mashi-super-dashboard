static int runOrphanRegression(void){
 NSArray *cases=@[
  @[@"active-owner-screen-wake",@YES,@YES,@YES,@NO,@YES,@"native-owner-active"],
  @[@"active-owner-unplug",@YES,@YES,@NO,@YES,@NO,@"native-owner-active"],
  @[@"active-owner-during-arm",@YES,@YES,@YES,@NO,@YES,@"native-owner-active"],
  @[@"no-record-no-manufactured-recovery",@NO,@NO,@NO,@NO,@NO,@"no-owned-state"],
  @[@"orphan-normal-sleep",@NO,@YES,@NO,@NO,@NO,@"screens-asleep-or-unknown"],
  @[@"orphan-powered-down-aoc",@NO,@YES,@NO,@YES,@YES,@"screens-asleep-or-unknown"],
  @[@"orphan-awake",@NO,@YES,@YES,@NO,@YES,NSNull.null],
  @[@"orphan-observed-physical-unplug",@NO,@YES,@NO,@YES,@NO,NSNull.null]
 ];
 NSMutableArray *names=[NSMutableArray new];
 for(NSArray *row in cases){
  NSString *skip=orphanRecoverySkip([row[1]boolValue],[row[2]boolValue],[row[3]boolValue],[row[4]boolValue],[row[5]boolValue]);
  if(![(skip?:NSNull.null)isEqual:row[6]]){fprintf(stderr,"FAIL orphan policy: %s\n",[row[0]UTF8String]);return 1;}
  [names addObject:row[0]];
 }
 output(@{@"ok":@YES,@"cases":names,@"realDisplayWrites":@0});return 0;
}
static int fakeGetBrightness(CGDirectDisplayID display,float *value){
 if(!testDisplays[@(display)])return 1;
 *value=[testDisplays[@(display)][@"brightness"]floatValue];return 0;
}
static int fakeSetBrightness(CGDirectDisplayID display,float value){
 [testCommands addObject:@{@"brightness":@(value),@"display":@(display)}];
 if(testBrightnessWriteFails)return 1;
 testDisplays[@(display)][@"brightness"]=@(value);return 0;
}
static void resetScenario(BOOL armed){
 finished=NO;powerIssued=armed;externalDisconnected=NO;externalWasPresent=YES;
 systemSleeping=NO;restoring=NO;restoreRequested=NO;operationGeneration=0;restoreAttempts=0;
 blankExternalID=2;testLidOpen=YES;testRecoveryFails=NO;
 testBrightnessWriteFails=NO;testKeyboardWriteFails=NO;
 atomic_store(&removalObserved,false);
 savedBuiltins=@[@{@"id":@1,@"brightness":@0.6}];
 testDisplays=[@{@1:[@{@"builtin":@YES,@"online":@YES,@"active":@YES,@"brightness":@(armed?0:0.6)}mutableCopy],
                 @2:[@{@"builtin":@NO,@"online":@YES,@"active":@YES,@"serial":@1010101}mutableCopy]}mutableCopy];
 testCommands=[NSMutableArray array];testCallbacks=[NSMutableArray array];
 topologyGate=RDTopologyGateCreate(screenTopology());
 NSDictionary *state=@{@"builtins":@[@{@"id":@1,@"brightness":@0.6}],@"keyboards":@[],@"armed":@(armed)};
 [[NSJSONSerialization dataWithJSONObject:state options:0 error:nil]writeToFile:statePath atomically:YES];
 [@"test-owner" writeToFile:markerPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static BOOL hasDestructiveCommand(void){
 for(NSDictionary *entry in testCommands)if(([entry[@"brightness"]isKindOfClass:NSNumber.class]&&[entry[@"brightness"]floatValue]<=0.01)||[entry[@"command"]isEqual:@"DDCControl"]||[entry[@"restore"]isEqual:@NO])return YES;
 return NO;
}
static void requireSafety(BOOL condition,NSString *name){
 if(!condition){fprintf(stderr,"FAILED: %s\n",name.UTF8String);exit(1);}
}
static int runSafetyRegression(void){
 testing=YES;getBrightness=fakeGetBrightness;setBrightness=fakeSetBrightness;
 NSString *directory=[NSTemporaryDirectory()stringByAppendingPathComponent:[@"ScreenBlank-regression-" stringByAppendingString:NSUUID.UUID.UUIDString]];
 [[NSFileManager defaultManager]createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
 statePath=[directory stringByAppendingPathComponent:@"state.json"];markerPath=[directory stringByAppendingPathComponent:@"owner.pid"];
 SleepObserver *observer=[SleepObserver new];
 NSMutableArray *passed=[NSMutableArray array];
 resetScenario(YES);testDisplays[@2][@"online"]=@NO;[observer changed:nil];
 requireSafety(finished&&!hasDestructiveCommand()&&[testDisplays[@1][@"brightness"]floatValue]>0.01,@"unplug restores before any darkening");[passed addObject:@"unplug-after-blank"];
 resetScenario(NO);testDisplays[@2][@"online"]=@NO;[observer changed:nil];beginBlanking(@[],0);
 requireSafety(finished&&!hasDestructiveCommand(),@"unplug during 700ms delay cancels writes");[passed addObject:@"unplug-before-delay"];
 resetScenario(NO);displayChanged(2,kCGDisplayRemoveFlag,(__bridge void *)observer);beginBlanking(@[],0);
 requireSafety(finished&&!hasDestructiveCommand(),@"remove callback overrides stale online list");[passed addObject:@"stale-topology"];
 resetScenario(YES);[testDisplays removeAllObjects];[observer changed:nil];
 requireSafety(!finished&&[[NSFileManager defaultManager]fileExistsAtPath:statePath]&&!hasDestructiveCommand(),@"empty topology retains restoration ownership");[passed addObject:@"empty-topology"];
 testDisplays[@7]=[@{@"builtin":@YES,@"online":@YES,@"active":@YES,@"brightness":@0}mutableCopy];
 dispatch_block_t retry=testCallbacks.firstObject;[testCallbacks removeObjectAtIndex:0];retry();
 requireSafety(finished&&[testDisplays[@7][@"brightness"]floatValue]>0.01,@"later builtin ID is restored");[passed addObject:@"delayed-builtin-and-new-id"];
 resetScenario(YES);testLidOpen=NO;testDisplays[@2][@"online"]=@NO;[observer changed:nil];
 requireSafety(!finished&&testCommands.count==0,@"closed lid defers restoration");[passed addObject:@"closed-lid"];
 testLidOpen=YES;[observer changed:[NSNotification notificationWithName:NSWorkspaceDidWakeNotification object:nil]];
 requireSafety(finished&&!hasDestructiveCommand(),@"lid-open wake restores");[passed addObject:@"lid-open-wake"];
 resetScenario(YES);[observer changed:[NSNotification notificationWithName:NSWorkspaceWillSleepNotification object:nil]];testDisplays[@2][@"online"]=@NO;[observer changed:nil];
 requireSafety(!finished&&testCommands.count==0,@"real sleep is not woken");[passed addObject:@"system-sleep"];
 [observer changed:[NSNotification notificationWithName:NSWorkspaceDidWakeNotification object:nil]];
 requireSafety(finished&&!hasDestructiveCommand(),@"system wake restores owned state");[passed addObject:@"system-wake"];
 resetScenario(YES);testDisplays[@2][@"online"]=@NO;testRecoveryFails=YES;testDisplays[@1][@"online"]=@NO;[observer changed:nil];
 requireSafety(!finished&&[[NSFileManager defaultManager]fileExistsAtPath:markerPath]&&[[NSFileManager defaultManager]fileExistsAtPath:statePath],@"failed enable keeps state and owner marker");[passed addObject:@"failed-recovery-retains-state"];
 for(int attempt=0;attempt<8&&testCallbacks.count;attempt++){dispatch_block_t callback=testCallbacks.firstObject;[testCallbacks removeObjectAtIndex:0];callback();}
 requireSafety(testCallbacks.count==0&&!finished,@"retry is bounded, no periodic wake");[passed addObject:@"bounded-retry"];
 testRecoveryFails=NO;[observer changed:[NSNotification notificationWithName:NSWorkspaceDidWakeNotification object:nil]];
 requireSafety(finished&&!hasDestructiveCommand(),@"new wake can retry exhausted recovery");[passed addObject:@"retry-after-next-wake"];

 // Regression: explicit hotkey/SIGUSR1 after exhausted retries resets restoreAttempts and completes recovery
 resetScenario(YES);testDisplays[@2][@"online"]=@NO;testRecoveryFails=YES;testDisplays[@1][@"online"]=@NO;[observer changed:nil];
 for(int attempt=0;attempt<8&&testCallbacks.count;attempt++){dispatch_block_t callback=testCallbacks.firstObject;[testCallbacks removeObjectAtIndex:0];callback();}
 requireSafety(!finished,@"exhausted before explicit release");
 testRecoveryFails=NO;requestExplicitFinish();
 requireSafety(finished&&!hasDestructiveCommand(),@"explicit release resets retry counter and restores");[passed addObject:@"explicit-release-after-exhaustion"];

 // Regression: plugging in an external display during builtin-only blanking restores builtin and releases lock
 resetScenario(YES);externalWasPresent=NO;blankExternalID=0;[testDisplays removeObjectForKey:@2];
 testDisplays[@2]=[@{@"builtin":@NO,@"online":@YES,@"active":@YES,@"serial":@1010101}mutableCopy];
 displayChanged(2,kCGDisplayAddFlag,(__bridge void *)observer);
 requireSafety(finished&&[testDisplays[@1][@"brightness"]floatValue]>0.01,@"hotplugging external during builtin blanking restores and exits");[passed addObject:@"hotplug-during-builtin-blank"];
 resetScenario(YES);testDisplays[@1][@"brightness"]=@0.8;testDisplays[@2][@"online"]=@NO;finish();
 requireSafety(finished&&[testDisplays[@1][@"brightness"]floatValue]>0.79,@"user brightness overrides are preserved");[passed addObject:@"user-brightness-preserved"];
 resetScenario(YES);finish();NSUInteger count=testCommands.count;finish();beginBlanking(@[],0);
 requireSafety(testCommands.count==count&&!hasDestructiveCommand(),@"exit is idempotent and cancels delayed work");[passed addObject:@"duplicate-exit-and-late-work"];
 resetScenario(YES);[observer changed:nil];[observer changed:nil];
 requireSafety(testCommands.count==0&&!finished,@"ordinary callbacks never re-darken");[passed addObject:@"no-redarken"];
 resetScenario(NO);systemSleeping=YES;operationGeneration++;beginBlanking(@[],0);
 requireSafety(!hasDestructiveCommand(),@"sleep invalidates pending start");[passed addObject:@"sleep-cancels-delay"];
 resetScenario(YES);[observer changed:[NSNotification notificationWithName:NSWorkspaceScreensDidSleepNotification object:nil]];testDisplays[@2][@"online"]=@NO;[observer changed:nil];
 BOOL hasOwnedRecovery=NO;
 for(NSDictionary *entry in testCommands)if([entry[@"arguments"]containsObject:@"--owned-blank-recovery"])hasOwnedRecovery=YES;
 requireSafety(finished&&hasOwnedRecovery&&!hasDestructiveCommand(),@"owned hardware blank does not suppress unplug recovery");[passed addObject:@"owned-blank-is-not-system-sleep"];
 resetScenario(NO);[observer changed:[NSNotification notificationWithName:NSWorkspaceScreensDidSleepNotification object:nil]];testDisplays[@2][@"online"]=@NO;[observer changed:nil];
 requireSafety(!finished&&testCommands.count==0,@"normal display sleep is not woken");[passed addObject:@"normal-display-sleep"];
 resetScenario(YES);testBrightnessWriteFails=YES;testDisplays[@2][@"online"]=@NO;[observer changed:nil];
 requireSafety(!finished&&[[NSFileManager defaultManager]fileExistsAtPath:statePath],@"failed brightness write retains recovery state");[passed addObject:@"brightness-write-failure"];
 testBrightnessWriteFails=NO;dispatch_block_t brightnessRetry=testCallbacks.firstObject;[testCallbacks removeObjectAtIndex:0];brightnessRetry();
 requireSafety(finished,@"brightness write can be retried");[passed addObject:@"brightness-write-retry"];
 resetScenario(YES);
 NSDictionary *keyboardState=@{@"builtins":savedBuiltins,@"keyboards":@[@{@"id":@99,@"brightness":@0.7,@"automatic":@YES}],@"armed":@YES};
 [[NSJSONSerialization dataWithJSONObject:keyboardState options:0 error:nil]writeToFile:statePath atomically:YES];
 testKeyboardWriteFails=YES;finish();
 requireSafety(!finished&&[[NSFileManager defaultManager]fileExistsAtPath:statePath],@"partial keyboard restore retains ownership");[passed addObject:@"partial-keyboard-restore"];
 testKeyboardWriteFails=NO;dispatch_block_t keyboardRetry=testCallbacks.firstObject;[testCallbacks removeObjectAtIndex:0];keyboardRetry();
 requireSafety(finished,@"partial keyboard restore can be retried");[passed addObject:@"partial-keyboard-retry"];
 [[NSFileManager defaultManager]removeItemAtPath:directory error:nil];
 output(@{@"ok":@YES,@"cases":passed,@"safetyRegressionCases":@(passed.count),@"realDisplayWrites":@0});return 0;
}
