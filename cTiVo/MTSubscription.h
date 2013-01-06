//
//  MTSubscription.h
//  cTiVo
//
//  Created by Hugh Mackworth on 1/4/13.
//  Copyright (c) 2013 Scott Buchanan. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "MTTiVoShow.h"

@interface MTSubscription : NSObject {
    
}


@property (nonatomic, retain) NSString *seriesTitle;
@property (nonatomic, retain) NSDate *lastRecordedTime;

@property (nonatomic, retain) NSNumber *addToiTunes;
@property (nonatomic, retain) NSNumber *simultaneousEncode;
@property (nonatomic, retain) NSDictionary *encodeFormat;

@property (readonly) BOOL canSimulEncode;
@property (readonly) BOOL shouldSimulEncode;
@property (readonly) BOOL canAddToiTunes;
@property (readonly) BOOL shouldAddToiTunes;

@end

@interface NSMutableArray (MTSubscriptionList)

-(void) checkSubscriptionsAll;
-(void) addSubscription:(MTTiVoShow *) tivoShow;
-(void) updateSubscriptionWithDate: (NSNotification *) notification;
-(BOOL) isSubscribed:(MTTiVoShow *) tivoShow;
-(void) saveSubscriptions;
-(void) loadSubscriptions;

@end
