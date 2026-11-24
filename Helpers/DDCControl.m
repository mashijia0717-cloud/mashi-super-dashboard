@import Foundation;
@import IOKit;
@import ApplicationServices;
#include "ioregistry.h"
#include "i2c.h"
static DDCTransport transport;
static NSDictionary *failure(NSString *s) { return @{@"ok":@NO,@"error":s}; }
static void emit(id obj) { NSData *d=[NSJSONSerialization dataWithJSONObject:obj options:0 error:nil]; puts([[NSString alloc]initWithData:d encoding:NSUTF8StringEncoding].UTF8String); }
static NSData *exchange(UInt8 *payload,int length) {
 UInt8 packet[16]={}; memcpy(packet,payload,length); UInt8 sum=0x6e^0x51;
 for(int i=0;i<length;i++) sum^=packet[i]; packet[length]=sum;
 if(IOAVServiceWriteI2C(transport.service,transport.chipAddress,0x51,packet,length+1))return nil;
 usleep(80000); UInt8 reply[64]={};
 if(IOAVServiceReadI2C(transport.service,transport.chipAddress,0x51,reply,64))return nil;
 int n=reply[1]&127; if(reply[0]!=0x6e || n+3>64)return nil;
 sum=0x50; for(int i=0;i<n+3;i++)sum^=reply[i]; if(sum)return nil;
 return [NSData dataWithBytes:reply length:n+3];
}
static NSDictionary *readVCP(int code) {
 for(int attempt=0;attempt<3;attempt++) {
  UInt8 req[]={0x82,0x01,(UInt8)code}; NSData *data=exchange(req,3);
  if(data.length>=11){const UInt8 *r=data.bytes;if(r[2]==2 && r[4]==code){
   if(r[3])return failure(@"显示器报告不支持此项目");
   return @{@"ok":@YES,@"current":@((r[8]<<8)|r[9]),@"max":@((r[6]<<8)|r[7])};
  }}
  usleep(50000);
 }
 return failure(@"未获得有效且校验通过的显示器响应");
}
static NSString *capabilities(void) {
 NSMutableData *out=[NSMutableData data];
 for(int i=0;i<64;i++){
  unsigned offset=(unsigned)out.length; UInt8 req[]={0x83,0xf3,(offset>>8)&255,offset&255};
  NSData *d=exchange(req,4);if(d.length<6)return nil;const UInt8 *r=d.bytes;
  if(r[2]!=0xe3 || (unsigned)((r[3]<<8)|r[4])!=offset)return nil;
  int count=(r[1]&127)-3;if(count<=0)break;
  const UInt8 *zero=memchr(r+5,0,count); if(zero){[out appendBytes:r+5 length:zero-(r+5)];break;}
  [out appendBytes:r+5 length:count];
 }
 return [[NSString alloc]initWithData:out encoding:NSASCIIStringEncoding];
}
static BOOL allowed(int code,int val){
 if(val<0 || val>65535)return NO;
 switch(code){
  case 0x10:case 0x12:case 0x16:case 0x18:case 0x1a:case 0x62:return val<=100;
  case 0x14:return [@[@1,@5,@6,@8,@11] containsObject:@(val)];
  case 0x60:return [@[@15,@17,@18] containsObject:@(val)];
  case 0x86:return [@[@1,@2,@5,@11,@12,@15,@16,@17] containsObject:@(val)];
  case 0x8d:case 0xca:return val==1||val==2;
  case 0xcc:return [@[@1,@2,@3,@4,@5,@6,@7,@8,@9,@10,@11,@13,@18,@20,@22,@30] containsObject:@(val)];
  case 0xdc:return [@[@0,@11,@12,@13,@14,@15,@16] containsObject:@(val)];
  case 0xd6:return val==1||val==4||val==5;
  case 4:case 5:case 8:return val==1;
  default:return NO;
 }
}
int main(int argc,char **argv){@autoreleasepool{
 if(argc<2){emit(failure(@"缺少操作参数"));return 1;}
 DisplayInfos ds[MAX_DISPLAYS]={};int count=getOnlineDisplayInfos(ds);DisplayInfos *target=NULL;
 for(int i=0;i<count;i++) {
  if(!CGDisplayIsBuiltin(ds[i].id) && ([ds[i].productName containsString:@"AG275UXM"] || ds[i].serial == 1010101 || CGDisplayVendorNumber(ds[i].id) == 0x05E3)) {
   target=&ds[i]; break;
  }
 }
 BOOL isPowerOnRequest = argc==4 && !strcmp(argv[1],"set") && (int)strtol(argv[2],NULL,0)==0xd6 && (int)strtol(argv[3],NULL,0)==1;
 if(!target || (!isPowerOnRequest && CGDisplayIsAsleep(target->id))){emit(failure(@"目标显示器未连接或正在休眠"));return 1;}
 transport=getDisplayDDCTransport(target);if(!transport.service){emit(failure(@"DDC 接口不可用"));return 1;}
 if(!strcmp(argv[1],"caps")){NSString *s=capabilities();emit(s?@{@"ok":@YES,@"capabilities":s}:failure(@"能力清单读取失败"));return s?0:1;}
 if(!strcmp(argv[1],"status") || !strcmp(argv[1],"panel-status")){
  NSMutableDictionary *result=[NSMutableDictionary dictionary];
  NSArray *codes=!strcmp(argv[1],"panel-status") ? @[@0x12,@0x62,@0x16,@0x18,@0x1a,@0x60] : @[@0x10,@0x12,@0x14,@0x16,@0x18,@0x1a,@0x60,@0x62,@0x8d,@0x86,@0xca,@0xcc,@0xd6,@0xdc,@0xdf,@0xac,@0xae,@0xc0,@0xc6,@0xc8,@0xc9,@0xb6];
  for(NSNumber *code in codes)
   result[[NSString stringWithFormat:@"%02X",code.intValue]]=readVCP(code.intValue);
  emit(@{@"ok":@YES,@"values":result});return 0;
 }
 if(argc<3){emit(failure(@"缺少功能编号"));return 1;}
 int code=(int)strtol(argv[2],NULL,0);
 if(!strcmp(argv[1],"get")){NSDictionary *r=readVCP(code);emit(r);return [r[@"ok"]boolValue]?0:1;}
 if(!strcmp(argv[1],"set") && argc==4){
  int val=(int)strtol(argv[3],NULL,0);if(!allowed(code,val)){emit(failure(@"该功能或数值未经允许，未发送"));return 1;}
  UInt8 req[]={0x84,3,code,(val>>8)&255,val&255,0};UInt8 sum=0x6e^0x51;
  for(int i=0;i<5;i++)sum^=req[i];req[5]=sum;
  IOReturn e=IOAVServiceWriteI2C(transport.service,transport.chipAddress,0x51,req,6);
  if(e){emit(failure([NSString stringWithFormat:@"DDC 写入失败：0x%x",e]));return 1;}
  usleep(180000);
  BOOL disruptive=code==0x60||code==0xd6||code==4||code==5||code==8;
  NSDictionary *r=disruptive?failure(@"此操作可能改变连接或多项设置，不做即时读回"):readVCP(code);
  BOOL verified=!disruptive && [r[@"ok"]boolValue] && abs([r[@"current"]intValue]-val)<=1;
  if(!disruptive && !verified){
   usleep(140000);
   r=readVCP(code);
   verified=[r[@"ok"]boolValue] && abs([r[@"current"]intValue]-val)<=1;
  }
  emit(@{@"ok":@YES,@"sent":@YES,@"verified":@(verified),@"readback":r});return 0;
 }
 emit(failure(@"不支持的操作"));return 1;
}}
