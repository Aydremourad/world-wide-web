#import "YTSABR.h"
#include <stdint.h>
#include <string.h>

static void Var(NSMutableData *out,uint64_t n) {
    while(n>127) { uint8_t byte=(n&127)|128; [out appendBytes:&byte length:1]; n>>=7; }
    uint8_t byte=n; [out appendBytes:&byte length:1];
}
static void Int(NSMutableData *out,unsigned field,uint64_t n) { Var(out,field<<3); Var(out,n); }
static void Bytes(NSMutableData *out,unsigned field,NSData *data) {
    if(!data) return; Var(out,(field<<3)|2); Var(out,[data length]); [out appendData:data];
}
static void Str(NSMutableData *out,unsigned field,NSString *s) { Bytes(out,field,[s dataUsingEncoding:NSUTF8StringEncoding]); }
static BOOL ReadVar(const uint8_t *p,NSUInteger size,NSUInteger *pos,uint64_t *value) {
    uint64_t n=0;
    for(unsigned shift=0;shift<64 && *pos<size;shift+=7) {
        uint8_t byte=p[(*pos)++]; if(shift==63 && byte>1) return NO;
        n|=(uint64_t)(byte&127)<<shift;
        if(!(byte&128)) { *value=n; return YES; }
    }
    return NO;
}
static NSDictionary *Proto(NSData *data) {
    if(![data isKindOfClass:[NSData class]]) return nil;
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    const uint8_t *p=[data bytes]; NSUInteger size=[data length],pos=0;
    while(pos<size) {
        uint64_t tag=0,n=0; if(!ReadVar(p,size,&pos,&tag) || !(tag>>3) || tag>>3>536870911) return nil;
        id value=nil;
        if((tag&7)==0) { if(!ReadVar(p,size,&pos,&n)) return nil; value=[NSNumber numberWithUnsignedLongLong:n]; }
        else if((tag&7)==2) {
            if(!ReadVar(p,size,&pos,&n) || n>size-pos) return nil;
            value=[NSData dataWithBytes:p+pos length:(NSUInteger)n]; pos+=n;
        } else if((tag&7)==1 || (tag&7)==5) {
            NSUInteger count=(tag&7)==1 ? 8 : 4; if(count>size-pos) return nil; pos+=count; continue;
        } else return nil;
        NSNumber *key=[NSNumber numberWithUnsignedInt:(unsigned)(tag>>3)];
        NSMutableArray *values=[result objectForKey:key];
        if(!values) { values=[NSMutableArray array]; [result setObject:values forKey:key]; }
        [values addObject:value];
    }
    return result;
}
static id Field(NSDictionary *p,unsigned field) { NSArray *a=[p objectForKey:[NSNumber numberWithUnsignedInt:field]]; return [a count] ? [a objectAtIndex:0] : nil; }
static long long Number(NSDictionary *p,unsigned f) { id v=Field(p,f); return [v isKindOfClass:[NSNumber class]] ? [v longLongValue] : 0; }
static NSArray *Integers(NSDictionary *p,unsigned f) {
    NSMutableArray *result=[NSMutableArray array];
    for(id value in [p objectForKey:[NSNumber numberWithUnsignedInt:f]]) {
        if([value isKindOfClass:[NSNumber class]]) [result addObject:value];
        else if([value isKindOfClass:[NSData class]]) {
            NSUInteger pos=0; while(pos<[value length]) { uint64_t n=0;
                if(!ReadVar([value bytes],[value length],&pos,&n)) break;
                [result addObject:[NSNumber numberWithUnsignedLongLong:n]];
            }
        }
    }
    return result;
}
static NSString *Text(NSDictionary *p,unsigned f) { id v=Field(p,f); return [v isKindOfClass:[NSData class]] ? [[[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding] autorelease] : nil; }
static NSData *Base64(NSString *s) {
    NSMutableData *out=[NSMutableData data]; unsigned bits=0,buffer=0;
    for(NSUInteger i=0;i<[s length];i++) {
        unichar c=[s characterAtIndex:i]; int n=-1;
        if(c>='A' && c<='Z') n=c-'A'; else if(c>='a' && c<='z') n=c-'a'+26;
        else if(c>='0' && c<='9') n=c-'0'+52; else if(c=='+' || c=='-') n=62; else if(c=='/' || c=='_') n=63;
        else if(c=='=') break; else return nil;
        buffer=(buffer<<6)|n; bits+=6;
        if(bits>=8) { bits-=8; uint8_t byte=(buffer>>bits)&255; [out appendBytes:&byte length:1]; }
    }
    return [out length] ? out : nil;
}
static NSData *FormatID(NSDictionary *format) {
    NSMutableData *data=[NSMutableData data]; Int(data,1,[[format objectForKey:@"itag"] intValue]);
    Int(data,2,(uint64_t)[[format objectForKey:@"lastModified"] longLongValue]); Str(data,3,[format objectForKey:@"xtags"]); return data;
}
static BOOL MediaURL(NSURL *url) {
    return [[url scheme] isEqualToString:@"https"] && [[[url host] lowercaseString] hasSuffix:@".googlevideo.com"];
}
static BOOL UMPInteger(const uint8_t *p,NSUInteger size,NSUInteger *pos,uint32_t *value) {
    if(*pos>=size) return NO; uint8_t first=p[(*pos)++];
    unsigned count=first<128 ? 1 : first<192 ? 2 : first<224 ? 3 : first<240 ? 4 : 5;
    if(count-1>size-*pos) return NO;
    uint32_t n=count==5 ? 0 : first & (255>>(count));
    unsigned shift=count==5 ? 0 : 8-count;
    for(unsigned i=1;i<count;i++) { n|=(uint32_t)p[(*pos)++]<<shift; shift+=8; }
    *value=n; return YES;
}
@interface YTSABRTransfer : NSObject {
@public
    NSMutableData *data; NSURLConnection *connection; NSString *error; BOOL done;
}
@end
@implementation YTSABRTransfer
- (id)init { if((self=[super init])) data=[[NSMutableData alloc] init]; return self; }
- (void)fail:(NSString *)message { if(!error) error=[message copy]; done=YES; [connection cancel]; }
- (void)connection:(NSURLConnection *)sender didReceiveResponse:(NSURLResponse *)r {
    if(![r isKindOfClass:[NSHTTPURLResponse class]]) { [self fail:@"YouTube did not return an HTTP stream."]; return; }
    int code=(int)[(NSHTTPURLResponse *)r statusCode];
    if(code!=200) { [self fail:[NSString stringWithFormat:@"YouTube SABR returned HTTP %d.",code]]; return; }
    NSString *type=[r MIMEType];
    if(![type isEqualToString:@"application/vnd.yt-ump"] && ![type isEqualToString:@"application/octet-stream"])
        [self fail:@"YouTube returned a page instead of SABR media."];
    if([r expectedContentLength]>4*1024*1024) [self fail:@"The SABR response exceeded the memory limit."];
}
- (NSURLRequest *)connection:(NSURLConnection *)sender willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response {
    if(response && !MediaURL([request URL])) { [self fail:@"Unexpected SABR redirect host."]; return nil; } return request;
}
- (void)connection:(NSURLConnection *)sender didReceiveData:(NSData *)bytes {
    if(done) return;
    if([data length]+[bytes length]>4*1024*1024) { [self fail:@"The SABR response exceeded the memory limit."]; return; }
    [data appendData:bytes];
}
- (void)connectionDidFinishLoading:(NSURLConnection *)sender { done=YES; }
- (void)connection:(NSURLConnection *)sender didFailWithError:(NSError *)e { [self fail:@"The direct YouTube SABR request failed."]; }
- (void)dealloc { [connection cancel]; [connection release]; [data release]; [error release]; [super dealloc]; }
@end
static NSData *Fetch(NSURL *url,NSData *body,NSString *ua,NSString **error) {
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12];
    [request setHTTPMethod:@"POST"]; [request setHTTPBody:body];
    [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/vnd.yt-ump" forHTTPHeaderField:@"Accept"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    if(ua) [request setValue:ua forHTTPHeaderField:@"User-Agent"];
    YTSABRTransfer *t=[[YTSABRTransfer alloc] init]; t->connection=[[NSURLConnection alloc] initWithRequest:request delegate:t];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:13];
    while(!t->done && [deadline timeIntervalSinceNow]>0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if(!t->done) [t fail:@"Direct YouTube SABR request timed out."];
    NSData *result=!t->error ? [[t->data copy] autorelease] : nil;
    if(error && t->error) *error=[[t->error copy] autorelease]; [t release]; return result;
}
static NSMutableData *RequestBody(NSDictionary *options,NSData *config,BOOL initialized,long long time,NSData *cookie,NSDictionary *contexts,NSSet *active) {
    NSDictionary *video=[options objectForKey:@"video"],*audio=[options objectForKey:@"audio"];
    NSMutableData *abr=[NSMutableData data],*body=[NSMutableData data],*client=[NSMutableData data],*streamer=[NSMutableData data];
    Int(abr,16,[[video objectForKey:@"height"] intValue]); Int(abr,18,256); Int(abr,19,144);
    Int(abr,21,[[video objectForKey:@"height"] intValue]); Int(abr,22,0); Int(abr,23,2000000);
    Int(abr,26,3); Int(abr,28,time); Int(abr,34,1); Int(abr,40,2); // Video only; retain the already working audio.
    Var(abr,(35<<3)|5); uint8_t rate[4]={0,0,128,63}; [abr appendBytes:rate length:4];
    Bytes(body,1,abr); if(initialized) Bytes(body,2,FormatID(video));
    Bytes(body,5,config); Bytes(body,16,FormatID(audio)); Bytes(body,17,FormatID(video));
    Str(client,1,@"en"); Int(client,16,[[options objectForKey:@"clientNumber"] intValue]);
    Str(client,17,[options objectForKey:@"clientVersion"]); Str(client,18,@"Android"); Str(client,19,@"11");
    Bytes(streamer,1,client); Bytes(streamer,3,cookie);
    for(NSNumber *key in contexts) {
        if([active containsObject:key]) { NSMutableData *ctx=[NSMutableData data]; Int(ctx,1,[key intValue]); Bytes(ctx,2,[contexts objectForKey:key]); Bytes(streamer,5,ctx); }
        else Int(streamer,6,[key intValue]);
    }
    Bytes(body,19,streamer); return body;
}

NSString *YTDownloadSABRVideo(NSDictionary *options,NSString **errorText) {
    NSString *error=nil,*result=nil;
    NSString *vid=[options objectForKey:@"videoID"];
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"];
    if([vid length]!=11 || [vid rangeOfCharacterFromSet:[allowed invertedSet]].location!=NSNotFound) { if(errorText) *errorText=@"Invalid video ID."; return nil; }
    NSURL *url=[options objectForKey:@"url"];
    NSDictionary *video=[options objectForKey:@"video"];
    NSData *config=Base64([options objectForKey:@"config"]);
    long long duration=[[video objectForKey:@"duration"] longLongValue];
    long long declared=[[video objectForKey:@"length"] longLongValue];
    if(!MediaURL(url) || ![config length] || duration<=0 || duration>1200000 || declared<=0 || declared>64*1024*1024 ||
        [[video objectForKey:@"height"] intValue]>144 || [[video objectForKey:@"width"] intValue]>256) {
        if(errorText) *errorText=@"No usable direct 144p SABR video was supplied."; return nil;
    }
    NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:@"YTPhoneVideo"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *name=[NSString stringWithFormat:@"%@-%@-%@",[options objectForKey:@"videoID"],[video objectForKey:@"itag"],[video objectForKey:@"lastModified"]];
    NSString *output=[directory stringByAppendingPathComponent:[name stringByAppendingString:@".mp4"]];
    NSDictionary *attributes=[[NSFileManager defaultManager] attributesOfItemAtPath:output error:NULL];
    if([[attributes objectForKey:NSFileSize] longLongValue]>512) return output;
    NSString *input=[directory stringByAppendingPathComponent:[name stringByAppendingString:@".part"]];
    // Discard older prepared videos before allocating another complete low-res cache.
    for(NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL])
        if([file hasSuffix:@".part"] || [file hasSuffix:@".tmp"] || ([file hasSuffix:@".mp4"] && ![file isEqualToString:[output lastPathComponent]]))
            [[NSFileManager defaultManager] removeItemAtPath:[directory stringByAppendingPathComponent:file] error:NULL];
    if(![[NSFileManager defaultManager] createFileAtPath:input contents:nil attributes:nil]) { if(errorText) *errorText=@"Could not create the phone's video cache."; return nil; }
    NSFileHandle *file=[NSFileHandle fileHandleForWritingAtPath:input];
    BOOL initialized=NO,complete=NO; long long cursor=0,endNum=-1,endTime=duration,lastNum=-1,total=0;
    NSData *cookie=nil; NSMutableDictionary *contexts=[NSMutableDictionary dictionary]; NSMutableSet *active=[NSMutableSet set];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:120]; unsigned redirects=0,stalls=0;
    @try {
        for(unsigned request=0;request<256 && !complete && [deadline timeIntervalSinceNow]>0;request++) {
            NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
            NSString *address=[url absoluteString]; NSString *separator=[address rangeOfString:@"?"].location==NSNotFound ? @"?" : @"&";
            NSURL *requestURL=[NSURL URLWithString:[address stringByAppendingFormat:@"%@rn=%u",separator,request]];
            NSString *failure=nil; NSData *raw=Fetch(requestURL,RequestBody(options,config,initialized,cursor,cookie,contexts,active),[options objectForKey:@"userAgent"],&failure);
            if(!raw) { error=[failure retain]; [pool release]; break; }
            NSMutableDictionary *headers=[NSMutableDictionary dictionary],*payloads=[NSMutableDictionary dictionary];
            NSUInteger pos=0,size=[raw length]; const uint8_t *p=[raw bytes]; long long before=cursor;
            while(pos<size && !error) {
                uint32_t type=0,length=0;
                if(!UMPInteger(p,size,&pos,&type) || !UMPInteger(p,size,&pos,&length) || length>size-pos) { error=[@"YouTube sent an incomplete SABR response." retain]; break; }
                NSData *part=[NSData dataWithBytes:p+pos length:length]; pos+=length;
                if(type==20) {
                    NSDictionary *h=Proto(part); long long id=Number(h,1);
                    if(!h || id>255) { error=[@"Invalid SABR media header." retain]; break; }
                    NSDictionary *fid=Proto(Field(h,13)); long long itag=fid ? Number(fid,1) : Number(h,3);
                    if(itag!=[[video objectForKey:@"itag"] intValue]) continue;
                    long long lmt=fid ? Number(fid,2) : Number(h,4);
                    if(lmt && lmt!=[[video objectForKey:@"lastModified"] longLongValue]) { error=[@"YouTube changed the selected video format." retain]; break; }
                    NSString *vid=Text(h,2); if([vid length] && ![vid isEqualToString:[options objectForKey:@"videoID"]]) { error=[@"YouTube returned a different video." retain]; break; }
                    if(Number(h,7)!=0 || Number(h,14)>4*1024*1024) { error=[@"Unsupported SABR segment encoding or size." retain]; break; }
                    NSNumber *key=[NSNumber numberWithLongLong:id]; [headers setObject:h forKey:key]; [payloads setObject:[NSMutableData data] forKey:key];
                } else if(type==21 || type==22) {
                    if(!length) { error=[@"Invalid empty SABR media part." retain]; break; }
                    uint8_t id=*(const uint8_t *)[part bytes]; NSNumber *key=[NSNumber numberWithInt:id];
                    NSDictionary *h=[headers objectForKey:key]; NSMutableData *bytes=[payloads objectForKey:key]; if(!h) continue;
                    if(type==21) {
                        if([bytes length]+length-1>4*1024*1024) { error=[@"SABR segment exceeded its memory limit." retain]; break; }
                        [bytes appendBytes:(const uint8_t *)[part bytes]+1 length:length-1];
                    } else {
                        long long expected=Number(h,14); if(![bytes length] || (expected && expected!=[bytes length])) { error=[@"SABR video segment was incomplete." retain]; break; }
                        BOOL init=Number(h,8)!=0; long long sequence=Number(h,9),start=Number(h,11),durationMS=Number(h,12);
                        NSDictionary *tr=Proto(Field(h,15)); if(tr && Number(tr,3)>0) { start=Number(tr,1)*1000/Number(tr,3); durationMS=Number(tr,2)*1000/Number(tr,3); }
                        if(init) {
                            if(!initialized) { if([bytes length]<8 || memcmp((const uint8_t *)[bytes bytes]+4,"ftyp",4)) { error=[@"SABR initialization was not an MP4." retain]; break; }
                                [file writeData:bytes]; total+=[bytes length]; initialized=YES; }
                        } else if(sequence>lastNum) {
                            if(!initialized || durationMS<=0 || start>cursor+100 || (lastNum>=0 && (sequence!=lastNum+1 || start<cursor-100))) { error=[@"SABR video segments were not continuous." retain]; break; }
                            if(total+[bytes length]>64*1024*1024) { error=[@"Phone video cache reached its size limit." retain]; break; }
                            [file writeData:bytes]; total+=[bytes length]; lastNum=sequence; cursor=start+durationMS;
                            complete=(endNum>=0 && sequence>=endNum) || cursor>=endTime-2;
                        }
                        [headers removeObjectForKey:key]; [payloads removeObjectForKey:key];
                    }
                } else if(type==42) {
                    NSDictionary *m=Proto(part),*fid=Proto(Field(m,2));
                    if(Number(fid,1)==[[video objectForKey:@"itag"] intValue]) {
                        NSString *vid=Text(m,1); if([vid length] && ![vid isEqualToString:[options objectForKey:@"videoID"]]) { error=[@"SABR metadata described another video." retain]; break; }
                        if(Field(m,4)) endNum=Number(m,4); if(Number(m,3)>0) endTime=Number(m,3);
                    }
                } else if(type==35) {
                    NSDictionary *policy=Proto(part); NSData *next=Field(policy,7);
                    if([next isKindOfClass:[NSData class]]) { [cookie release]; cookie=[next copy]; }
                } else if(type==43) {
                    NSURL *next=[NSURL URLWithString:Text(Proto(part),1)];
                    if(!MediaURL(next) || ++redirects>3) { error=[@"Invalid or repeated SABR redirect." retain]; break; }
                    url=[[next retain] autorelease];
                } else if(type==44 || type==46) { error=[@"YouTube refused this direct SABR stream." retain]; break;
                } else if(type==58 && Number(Proto(part),1)>=3) { error=[@"YouTube requires an additional playback token for this stream." retain]; break;
                } else if(type==57) {
                    NSDictionary *ctx=Proto(part); NSData *value=Field(ctx,3); NSNumber *key=[NSNumber numberWithLongLong:Number(ctx,1)];
                    if([value isKindOfClass:[NSData class]] && !(Number(ctx,5)==2 && [contexts objectForKey:key])) { [contexts setObject:value forKey:key]; if(Number(ctx,4)) [active addObject:key]; }
                } else if(type==59) {
                    NSDictionary *policy=Proto(part);
                    for(NSNumber *n in Integers(policy,1)) if([n isKindOfClass:[NSNumber class]]) [active addObject:n];
                    for(NSNumber *n in Integers(policy,2)) [active removeObject:n];
                    for(NSNumber *n in Integers(policy,3)) { [contexts removeObjectForKey:n]; [active removeObject:n]; }
                }
            }
            if(cursor==before && !error && ++stalls>3) error=[@"YouTube SABR supplied no playable 144p media." retain];
            if(cursor>before) stalls=0;
            // Retain control state across the per-response pool, keeping media memory bounded.
            [url retain]; [pool release]; [url autorelease];
        }
        [file closeFile];
        if(!error && !complete) error=[@"The direct 144p video could not finish downloading in time." retain];
        NSString *temporary=[output stringByAppendingString:@".tmp"];
        if(!error && YTRemuxPhoneVideo([input fileSystemRepresentation],[temporary fileSystemRepresentation])<0) error=[@"The downloaded 144p movie could not be prepared for playback." retain];
        if(!error && ![[NSFileManager defaultManager] moveItemAtPath:temporary toPath:output error:NULL]) error=[@"Could not save the prepared phone video." retain];
        [[NSFileManager defaultManager] removeItemAtPath:temporary error:NULL];
        if(!error) result=output;
    } @catch(NSException *exception) { if(!error) error=[@"Could not write the phone's video cache." retain]; [file closeFile]; }
    [cookie release]; [[NSFileManager defaultManager] removeItemAtPath:input error:NULL];
    if(errorText && error) *errorText=[[error copy] autorelease]; [error release]; return result;
}
