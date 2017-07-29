//
//  TIUrlSession.h
//  Pods
//
//  Created by Admin on 29/07/2017.
//
//

#import <Foundation/Foundation.h>

@interface TIUrlSession : NSObject<NSURLSessionDelegate>

- (void)sendAsynchronousRequest:(NSURLRequest *)request callback:(void (^)(NSError *error,NSURLResponse *response,NSString* data, BOOL success))callback;
- (NSData *)sendSynchronousRequest:(NSURLRequest *)request error:(NSError **)error;
-(void)setCertificates:(NSArray*)datas;
@end
