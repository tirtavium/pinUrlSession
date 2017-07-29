//
//  TIUrlSession.m
//  Pods
//
//  Created by Admin on 29/07/2017.
//
//

#import "TIUrlSession.h"

@implementation TIUrlSession{
    CFArrayRef caChainArrayRef;
    BOOL checkHostname;
    NSArray * chains;
}
- (id)init
{
    self = [super init];
    if (self)
    {
        checkHostname = NO;
    }
    return self;
}

-(NSData *)sendSynchronousRequest:(NSURLRequest *)request error:(NSError **)error{
    
    __block NSData *responseData = nil;
    
    
    NSURLSessionConfiguration * sessionConf =[NSURLSessionConfiguration ephemeralSessionConfiguration];
    sessionConf.TLSMaximumSupportedProtocol = kTLSProtocol12;
    sessionConf.TLSMinimumSupportedProtocol = kTLSProtocol1;
    
    sessionConf.URLCache = nil;
    NSURLSession * session = [NSURLSession sessionWithConfiguration:sessionConf
                                                           delegate:self delegateQueue:nil];
    
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    
    NSURLSessionDataTask *postDataTask = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        responseData = data;
        dispatch_group_leave(group);
    }];
    [postDataTask resume];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    
    return responseData;
    
}
- (void)sendAsynchronousRequest:(NSURLRequest *)request callback:(void (^)(NSError *error,NSURLResponse *response,NSString* data, BOOL success))callback
{
    
    NSURLSessionConfiguration * sessionConf =[NSURLSessionConfiguration ephemeralSessionConfiguration];
    sessionConf.URLCache = nil;
    NSURLSession * session = [NSURLSession sessionWithConfiguration:sessionConf
                                                           delegate:self delegateQueue:nil];
    NSURLSessionDataTask *postDataTask = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString* strData = nil;
        strData = [[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding] ;
        
        if (data == nil||data == NULL||!data)
        {
            callback(error,response,strData,NO);
        }else{
            callback(error,response,strData,YES);
        }
        
    }];
    [postDataTask resume];
    
}
-(void)setCertificates:(NSArray*)datas{
    chains = datas;
}

-(void)populateCert{
    if(chains == nil || [chains count] == 0){
        checkHostname = NO;
    }else{
        checkHostname = YES;
        caChainArrayRef = CFBridgingRetain(chains);
    }
}



-(void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler{
    
    [self populateCert];
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust])
    {
        SecTrustRef trust = nil;
        SecTrustResultType result = 0;
        OSStatus err = errSecSuccess;
        NSMutableArray * chain = [NSMutableArray array];
        if (checkHostname) {
            // We use the standard Policy of SSL - which also checks hostnames.
            // -- see SecPolicyCreateSSL() for details.
            //
            trust = challenge.protectionSpace.serverTrust;
            //
#if DEBUG
            NSLog(@"The certificate is expected to match '%@' as the hostname",
                  challenge.protectionSpace.host);
#endif
        } else {
            // Create a new Policy - which goes easy on the hostname.
            //
            
            // Extract the chain of certificates provided by the server.
            //
            CFIndex certificateCount = SecTrustGetCertificateCount(challenge.protectionSpace.serverTrust);
            
            
            for(int i = 0; i < certificateCount; i++) {
                SecCertificateRef certRef = SecTrustGetCertificateAtIndex(challenge.protectionSpace.serverTrust, i);
                [chain addObject:(__bridge id)(certRef)];
                
            }
            
            
            // And create a bland policy which only checks signature paths.
            //
            SecPolicyRef policy = SecPolicyCreateSSL(true, (CFStringRef) challenge.protectionSpace.host);
            
            if (err == errSecSuccess){
                err = SecTrustCreateWithCertificates((__bridge CFArrayRef)(chain),
                                                     policy, &trust);
            }
            if (err != noErr)
            {
                NSLog(@"Error creating trust: %d", (int)err);
                [challenge.sender cancelAuthenticationChallenge: challenge];
                return;
            }
            
            
#if DEBUG
            NSLog(@"The certificate is NOT expected to match the hostname '%@' ",
                  challenge.protectionSpace.host);
#endif
        };
        
        
        
        // Explicity specify the list of certificates we actually trust (i.e. those I have hardcoded
        // in the app - rather than those provided by some randon server on the internet).
        //
        if (err == errSecSuccess)
            err = SecTrustSetAnchorCertificates(trust,caChainArrayRef);
        
        // And only use above - i.e. do not check the system its global keychain or something
        // else the user may have fiddled with.
        //
        if (err == errSecSuccess)
            err = SecTrustSetAnchorCertificatesOnly(trust, YES);
        
        if (err == errSecSuccess)
            err = SecTrustEvaluate(trust, &result);
        
        if(caChainArrayRef!=nil){
            NSLog(@"Local Roots we trust:");
            for(int i = 0; i < CFArrayGetCount(caChainArrayRef); i++) {
                SecCertificateRef certRef = (SecCertificateRef) CFArrayGetValueAtIndex(caChainArrayRef, i);
                CFStringRef str = SecCertificateCopySubjectSummary(certRef);
                NSLog(@"   %02i: %@", 1+i, str);
            }
        }
        
        if(caChainArrayRef == nil){
            NSLog(@"BAD. disable all the cert validation.");
            
            [challenge.sender useCredential:[NSURLCredential credentialForTrust:trust]
                 forAuthenticationChallenge:challenge];
            completionHandler(NSURLSessionAuthChallengeRejectProtectionSpace, nil);
            
            goto done;
        }
        
        if (err == errSecSuccess) {
            switch (result) {
                case kSecTrustResultProceed:{
                    // User gave explicit permission to trust this specific
                    // root at some point (in the past).
                    //
                    NSLog(@"GOOD. kSecTrustResultProceed - the user explicitly trusts this CA");
                    NSURLCredential *credential = [NSURLCredential credentialForTrust:trust];
                    [challenge.sender useCredential:credential
                         forAuthenticationChallenge:challenge];
                    completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
                    goto done;
                }
                    break;
                case kSecTrustResultUnspecified:
                {
                    // The chain is technically valid and matches up to the root
                    // we provided. The user has not had any say in this though,
                    // hence it is not a kSecTrustResultProceed.
                    //
                    NSLog(@"GOOD. kSecTrustResultUnspecified - So things are technically trusted. But the user was not involved." );
                    NSURLCredential *credential = [NSURLCredential credentialForTrust:trust];
                    [challenge.sender useCredential:credential
                         forAuthenticationChallenge:challenge];
                    completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
                    goto done;
                }
                    break;
                case kSecTrustResultInvalid:
                    NSLog(@"FAIL. kSecTrustResultInvalid");
                    break;
                case kSecTrustResultDeny:
                    NSLog(@"FAIL. kSecTrustResultDeny (i.e. user said no explicitly)");
                    break;
                case kSecTrustResultFatalTrustFailure:
                    NSLog(@"FAIL. kSecTrustResultFatalTrustFailure");
                    break;
                case kSecTrustResultOtherError:
                    NSLog(@"FAIL. kSecTrustResultOtherError");
                    break;
                case kSecTrustResultRecoverableTrustFailure:
                {
                    NSLog(@"FAIL. kSecTrustResultRecoverableTrustFailure (i.e. user could say OK, but has not been asked this)");
                    /*  CFDataRef errDataRef= SecTrustCopyExceptions(trust);
                     SecTrustSetExceptions(trust, errDataRef);
                     err = SecTrustEvaluate(trust, &result);
                     NSLog(@"FIXING. kSecTrustResultRecoverableTrustFailure ");
                     [challenge.sender useCredential:[NSURLCredential credentialForTrust:trust]
                     forAuthenticationChallenge:challenge];
                     goto done;
                     */
                }
                    break;
                default:
                    NSAssert(NO,@"Unexpected result: %d", result);
                    break;
            }
            // Reject.
            [challenge.sender cancelAuthenticationChallenge:challenge];
            completionHandler(NSURLSessionAuthChallengeRejectProtectionSpace, nil);
            goto done;
        };
        
        [[challenge sender] cancelAuthenticationChallenge:challenge];
        completionHandler(NSURLSessionAuthChallengeRejectProtectionSpace, nil);
        
    done:
  
        /*    if(caChainArrayRef){
         CFRelease(caChainArrayRef);
         }*/
        
        return;
    }
    // In this example we can cancel at this point - as we only do
    // canAuthenticateAgainstProtectionSpace against ServerTrust.
    //
    // But in other situations a more gentle continue may be appropriate.
    //
    // [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
    
    NSLog(@"Not something we can handle - so we're canceling it.");
    [challenge.sender cancelAuthenticationChallenge:challenge];
    completionHandler(NSURLSessionAuthChallengeRejectProtectionSpace, nil);
}

@end
