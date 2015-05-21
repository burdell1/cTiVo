//
//  MTTiVoShow.m
//  cTiVo
//
//  Created by Scott Buchanan on 12/18/12.
//  Copyright (c) 2012 Scott Buchanan. All rights reserved.
//
// Class for handling individual TiVo Shows

#import "MTTiVoShow.h"
#import "MTProgramTableView.h"
#import "MTiTunes.h"
#import "MTTiVoManager.h"
#import "NSString+RFC3339Date.h"
#import "mp4v2.h"
#import "NSString+Helpers.h"
#import "NSNotificationCenter+Threads.h"

@interface MTTiVoShow () {
	
	NSMutableString *elementString;
	NSMutableArray *elementArray;
	NSArray *arrayHolder;
	NSDictionary *parseTermMapping;

}
//rewrite external readonly properties (from detail XML) to allow internal readwrite
@property (atomic, strong, readwrite) NSString
                                *episodeNumber,
                                *movieYear,
                                *originalAirDate,
                                *showTime,
                                *episodeGenre,
                                *tvRating;
@property (strong, nonatomic, readwrite) NSAttributedString
                                *actors,
                                *guestStars,
                                *directors,
                                *producers;

@property (nonatomic, assign) BOOL ignoreSection; //are we skipping this section in XML (esp vActualShowing)

@end

@implementation MTTiVoShow

@synthesize seriesTitle		 = _seriesTitle,
			episodeTitle	 = _episodeTitle,
			episodeID    	 = _episodeID,
			imageString		 = _imageString,
			tempTiVoName     = _tempTiVoName;

__DDLOGHERE__

-(id)init
{
    self = [super init];
    if (self) {
        _showID = 0;
		_gotDetails = NO;
		_gotTVDBDetails = NO;
		elementString = nil;
		self.inProgress = @(NO); //This is the default
		_season = 0;
		_episode = 0;
		_episodeNumber = @"";
        _isQueued = NO;
		_episodeTitle = @"";
		_seriesTitle = @"";
//		_originalAirDate = @"";
		_episodeYear = 0;
        _tvdbArtworkLocation = nil;
		
		self.protectedShow = @(NO); //This is the default
		parseTermMapping = @{
					   @"description" : @"",  //mark to not load these values
					   @"time": @"showTime",  //maybe this one also
					   @"seriesTitle" : @"",
					   @"episodeTitle" : @""
		};
        [self addObserver:self forKeyPath:@"showTime" options:NSKeyValueObservingOptionNew context:showTimeContext];
        [self addObserver:self forKeyPath:@"episodeNumber" options:NSKeyValueObservingOptionNew context:episodeNumberContext];
        [self addObserver:self forKeyPath:@"movieYear" options:NSKeyValueObservingOptionNew context:movieYearContext];
        [self addObserver:self forKeyPath:@"originalAirDate" options:NSKeyValueObservingOptionNew context:originalAirDateContext];
    }
    return self;
}

//Note that getDetails and getTVDB need to be thread-safe. In particular, any setting of values that might be displayed needs to occur on main thread,
//and any access to global data needs to @synchronized
#pragma mark - access theTVDB
//These will be printed out in alpha order...
#define kMTVDBNoEpisode @"Episode Not Found"
#define kMTVDBEpisode @"Episode Found"
#define kMTVDBCached @"Episode Found in Cache"
#define kMTVDBNotSeries @"Movie"
#define kMTVDBNewInfo @"Season/Episode Info Added"
#define kMTVDBWrongInfo @"Season/Episode Info Mismatch"
#define kMTVDBRightInfo @"Season/Episode Info Match"
#define kMTVDBSeriesFoundWithEP @"Series Found EP"
#define kMTVDBSeriesFoundWithSH @"Series Found SH"
#define kMTVDBSeriesFoundWithShort @"Series Found SHShort"
#define kMTVDBSeriesFoundName @"Series Found by Name"
#define kMTVDBNoSeries @"Series Not Found"

-(NSString *) retrieveTVDBIdFromZap2itId: (NSString *) zapItID ofType:(NSString *) type {
	//type is just for debugging
	if (zapItID == nil) return nil;
	DDLogVerbose(@"Trying TVDB: %@==>%@",self.seriesId, zapItID);
	NSString *urlString = [[NSString stringWithFormat:@"http://thetvdb.com/api/GetSeriesByRemoteID.php?zap2it=%@&language=all",zapItID] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
	NSURL *url = [NSURL URLWithString:urlString];
	DDLogVerbose(@"Getting %@ details for %@ using %@",type, self, urlString);
	NSString *TVDBText = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (!TVDBText) return nil;
	NSString *seriesIDTVDB = [self getStringForPattern:@"<seriesid>(\\d*)" fromString:TVDBText];
	if (seriesIDTVDB) {
        [self rememberTVDBSeriesID:seriesIDTVDB];
        DDLogVerbose(@"Got series by %@ for %@ using %@", type, self, zapItID);
        if ([type isEqualToString:kMTVDBSeriesFoundWithEP]) {
            [self incrementStatistic:type];
        } else {
            NSString *longSeriesID = self.seriesId;
            if (self.seriesId.length < 10) {
                longSeriesID = [NSString stringWithFormat:@"SH00%@",[longSeriesID substringFromIndex:2]];
            }
            NSString * epSeriesID = [NSString stringWithFormat:@"EP%@",[longSeriesID substringFromIndex:2]];

            NSString * details = [NSString stringWithFormat:@"Their %@ Zap2It ID should be %@; %@",zapItID, epSeriesID, [self urlForReporting:seriesIDTVDB]];
              [self addValue:details inStatistic:type];
        }
		return seriesIDTVDB;
	} else {
		return nil;
	}
}

-(NSString *) episodeIDForReporting {
	NSString *epID = nil;
	if (self.seriesId.length > 1) {
		epID = [self.seriesId  substringFromIndex:2];
		if (epID.length < 8) {
			epID = [NSString stringWithFormat:@"EP00%@",epID];
		} else {
			epID = [NSString stringWithFormat:@"EP%@",epID];
		}
	}
	return epID;
}

-(NSString *) urlForReporting:(NSString *) tvdbID {
	NSString * showURL = [NSString stringWithFormat:@"http://thetvdb.com/?tab=series&id=%@",tvdbID];
	return showURL;
}

-(NSString *) tvdbURLForSeries {
    NSString * tvdbID = [self checkTVDBSeriesID];
    if (tvdbID) {
        return [self urlForReporting:tvdbID];
    } else {
        return @"";
    }
}

-(NSString *) retrieveTVDBIdFromSeriesName: (NSString *) name  {
	NSString * urlString = [[NSString stringWithFormat:@"http://thetvdb.com/api/GetSeries.php?seriesname=%@&language=all",name] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
	NSURL *url = [NSURL URLWithString:urlString];
	DDLogDetail(@"Getting series for %@ using %@",self,urlString);
	NSString *seriesID = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
	//This can result in multiple series return only 1 of which is correct.  First break up into Series
	NSArray *serieses = [seriesID componentsSeparatedByString:@"<Series>"];
	DDLogVerbose(@"Series for %@: %@",self,serieses);
	for (NSString *series in serieses) {
		NSString *seriesName = [[self getStringForPattern:@"<SeriesName>(.*)<\\/SeriesName>" fromString:series] stringByConvertingHTMLToPlainText];
		if (seriesName && [seriesName caseInsensitiveCompare:name] == NSOrderedSame) {
			NSString * tvdbID= [self getStringForPattern:@"<seriesid>(\\d*)" fromString:series];
			NSString * zap2ID= [self getStringForPattern:@"<zap2it_id>(.*)</zap2it_id>" fromString:series];
			if (tvdbID) {
				NSString * details = [NSString stringWithFormat:@"tvdb has %@ for our %@; %@ ", zap2ID, [self episodeIDForReporting],[self urlForReporting:tvdbID]  ];
				DDLogVerbose(@"Had to search by name %@, %@",self.showTitle, details);
                [self addValue:details inStatistic:kMTVDBSeriesFoundName];
				return tvdbID;
			} else {
				return nil;
			}
		}
	}
	return nil;

}

-(void) incrementStatistic: (NSString *) statistic {
    @synchronized(tiVoManager.theTVDBStatistics) {
        tiVoManager.theTVDBStatistics[statistic] = @([tiVoManager.theTVDBStatistics[statistic] intValue] + 1);
    }
}

-(void) addValue:(NSString *) value inStatistic:(NSString *) statistic  {
    @synchronized(tiVoManager.theTVDBStatistics) {
        NSString * statisticListName = [statistic stringByAppendingString:@" List"];
        NSMutableDictionary * statisticList = tiVoManager.theTVDBStatistics[statisticListName];
        if (!statisticList) {
            statisticList = [NSMutableDictionary dictionary];
            [tiVoManager.theTVDBStatistics setObject:statisticList forKey:statisticListName];
        }
        if (!statisticList[self.showTitle]) {
            [statisticList setValue: value forKey: self.showTitle];
            NSString * statisticCount = [statistic stringByAppendingString:@" Count"];
            tiVoManager.theTVDBStatistics[statisticCount] = @([tiVoManager.theTVDBStatistics[statisticCount] intValue] + 1);
        }
        [statisticList setValue: value forKey: self.showTitle]; //keep latest version in case it changed

    }
}

-(void)  updateSeason: (int) season andEpisode: (int) episode {
    dispatch_sync(dispatch_get_main_queue(), ^{
        self.episodeNumber = [NSString stringWithFormat:@"%d%02d",season, episode];
        self.episode = episode;
        self.season = season;
    });
}

-(void) rememberTVDBSeriesID: (NSString *) seriesID {
    @synchronized (tiVoManager.tvdbSeriesIdMapping) {
        [tiVoManager.tvdbSeriesIdMapping setObject:seriesID forKey:self.seriesTitle];
    }
}
-(NSString *) checkTVDBSeriesID {
    NSString *seriesID = nil;
    @synchronized (tiVoManager.tvdbSeriesIdMapping) {
       seriesID = [tiVoManager.tvdbSeriesIdMapping objectForKey:self.seriesTitle];
    }
    return seriesID;
}

-(void)getTheTVDBDetails
{
    //note all the statistics references are not threadsafe, but failure should not be critical either.
	if (_gotTVDBDetails) {
		return;
	}
    @synchronized (tiVoManager.theTVDBStatistics) {
        if (!tiVoManager.theTVDBStatistics) {
            tiVoManager.theTVDBStatistics = [NSMutableDictionary dictionary];
        }
    }
	if (self.seriesId.length && [self.seriesId startsWith:@"SH"]) { //if we have a series get the other informaiton
        NSString *episodeNum = nil, *seasonNum = nil, *artwork = nil;
        NSDictionary *episodeEntry;
        @synchronized (tiVoManager.tvdbCache) {
             episodeEntry = [tiVoManager.tvdbCache objectForKey:self.episodeID];
        }
        DDLogVerbose(@"%@ %@",episodeEntry? @"Already had": @"Need to get",self.showTitle);
        NSString *seriesIDTVDB = [self checkTVDBSeriesID];
        if (episodeEntry) { // We already have this information
            episodeNum = [episodeEntry objectForKey:@"episode"];
            seasonNum = [episodeEntry objectForKey:@"season"];
            artwork = [episodeEntry objectForKey:@"artwork"];
            if (!seriesIDTVDB) {
                seriesIDTVDB = [episodeEntry objectForKey:@"series"];
                [self rememberTVDBSeriesID:seriesIDTVDB];
            }
			_gotTVDBDetails = YES;
            [self incrementStatistic:kMTVDBCached];
        } else {
            if (!seriesIDTVDB) {
				NSString *longSeriesID = nil;
				NSString *shortSeriesID = nil;
				if (self.seriesId.length < 10) {
                    shortSeriesID = self.seriesId;
                    if (self.seriesId.length > 2) {
                        longSeriesID = [NSString stringWithFormat:@"SH00%@",[self.seriesId substringFromIndex:2]];
                    }
                } else {
                    shortSeriesID = [NSString stringWithFormat:@"SH%@",[self.seriesId substringFromIndex:2]];
                    longSeriesID = self.seriesId;
                }
				NSString * epSeriesID = [NSString stringWithFormat:@"EP%@",[longSeriesID substringFromIndex:2]];

				if (!seriesIDTVDB)  seriesIDTVDB = [self retrieveTVDBIdFromZap2itId:epSeriesID ofType:kMTVDBSeriesFoundWithEP];
				if (!seriesIDTVDB)  seriesIDTVDB = [self retrieveTVDBIdFromZap2itId:longSeriesID ofType:kMTVDBSeriesFoundWithSH];
				if (!seriesIDTVDB)
                    seriesIDTVDB = [self retrieveTVDBIdFromZap2itId:shortSeriesID ofType:kMTVDBSeriesFoundWithShort];
                if (!seriesIDTVDB)  seriesIDTVDB = [self retrieveTVDBIdFromSeriesName:self.seriesTitle];
                //Don't give up yet; look for "Series: subseries" format
                if (!seriesIDTVDB)  {
                    NSArray * splitName = [self.seriesTitle componentsSeparatedByString:@":"];
                    if (splitName.count > 1) {
                        seriesIDTVDB = [self retrieveTVDBIdFromSeriesName:splitName[0]];
                    }
                }
                
				if (seriesIDTVDB) {
					DDLogDetail(@"Got TVDB for %@: %@ ",self, seriesIDTVDB);
	                [self rememberTVDBSeriesID:seriesIDTVDB];
				} else {
                    [self rememberTVDBSeriesID:@""];
					DDLogDetail(@"TheTVDB series not found: %@: %@ ",self.seriesTitle, self.seriesId);
                    [self addValue: epSeriesID   inStatistic: kMTVDBNoSeries];
                    _gotTVDBDetails = YES;
                    return; //really can't get them.
				}

            }
            if (seriesIDTVDB.length) {
				//Now get the details
				NSString *urlString = [[NSString stringWithFormat:@"http://thetvdb.com/api/GetEpisodeByAirDate.php?apikey=%@&seriesid=%@&airdate=%@",kMTTheTVDBAPIKey,seriesIDTVDB,self.originalAirDateNoTime] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
				DDLogDetail(@"Getting TVDB details @ %@",urlString);
				NSURL *url = [NSURL URLWithString:urlString];
				NSString *episodeInfo = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
				if (episodeInfo) {
					episodeNum = [self getStringForPattern:@"<Combined_episodenumber>(\\d*)" fromString:episodeInfo];
					seasonNum = [self getStringForPattern:@"<Combined_season>(\\d*)" fromString:episodeInfo];
					artwork = [self getStringForPattern:@"<filename>(.*)<\\/filename>" fromString:episodeInfo];
					if (!seasonNum) seasonNum = @"";
					if (!episodeNum) episodeNum = @"";
					if (!artwork) artwork = @"";
					if (!seriesIDTVDB) seriesIDTVDB = @"";
                    @synchronized (tiVoManager.tvdbCache) {
                            [tiVoManager.tvdbCache setObject:@{
                             @"season":seasonNum,
                             @"episode":episodeNum,
                             @"artwork":artwork,
                             @"series": seriesIDTVDB,
                             @"date":[NSDate date]
                         } forKey:self.episodeID];
                    }
					_gotTVDBDetails = YES;
				}
            }
       }
        if (episodeNum.length && seasonNum.length && [episodeNum intValue] > 0 && [seasonNum intValue] > 0) {
			//special case due to parsing of tivo's season/episode combined string
            DDLogDetail(@"Got episode %@, season %@ and artwork %@ from %@",episodeNum, seasonNum, artwork, self);
            [self incrementStatistic:kMTVDBEpisode];
			if (self.season > 0 && self.season/10 == [seasonNum intValue]  && [episodeNum intValue] == self.episode) {
				//must have mis-parsed, so let's fix
				NSString * details = [NSString stringWithFormat:@"%@/%@ v our %d/%d aired %@ %@ ",seasonNum, episodeNum, self.season, self.episode, self.originalAirDateNoTime,  [self urlForReporting:seriesIDTVDB]];
				DDLogDetail(@"TVDB says we misparsed for %@: %@", self.showTitle, details );
				self.season = [seasonNum intValue];
			}
			if (self.episode >0 && self.season > 0) {
				//both sources have sea/epi; so compare for report
				if ([episodeNum intValue] != self.episode || [seasonNum intValue] != self.season) {
					NSString * details = [NSString stringWithFormat:@"%@/%@ v our %d/%d; %@ aired %@; %@ ",seasonNum, episodeNum, self.season, self.episode, [self episodeIDForReporting], self.originalAirDateNoTime,  [self urlForReporting:seriesIDTVDB]];
					DDLogDetail(@"TheTVDB has different Sea/Eps info for %@: %@ %@", self.showTitle, details, [[NSUserDefaults standardUserDefaults] boolForKey:kMTTrustTVDB] ? @"updating": @"leaving" );
                    [self addValue: details   inStatistic: kMTVDBWrongInfo];

                    if ([[NSUserDefaults standardUserDefaults] boolForKey:kMTTrustTVDB]) {
                        //user asked us to prefer TVDB
                        [self updateSeason: [seasonNum intValue] andEpisode: [episodeNum intValue]];
                    }
				} else {
                    [self incrementStatistic:kMTVDBRightInfo];
				}
			} else {
                [self updateSeason: [seasonNum intValue] andEpisode: [episodeNum intValue]];
                [self incrementStatistic:kMTVDBNewInfo];
 				DDLogVerbose(@"Adding TVDB season/episode %d/%d to show %@",self.season, self.episode, self.showTitle);
			}
        } else {
            NSString * details = [NSString stringWithFormat:@"%@ aired %@ (our  %d/%d) %@ ",[self episodeIDForReporting ], self.originalAirDateNoTime, self.season, self.episode, [self urlForReporting:seriesIDTVDB] ];
            DDLogDetail(@"No episode info for %@ %@ ",self.showTitle, details);
            [self addValue:details inStatistic:kMTVDBNoEpisode];
    }

        if (artwork.length) self.tvdbArtworkLocation = artwork;

    } else {
        [self incrementStatistic:kMTVDBNotSeries];
        _gotTVDBDetails = YES; //never going to find it
        }
    }

-(void)retrieveTVDBArtworkIntoPath: (NSString *) path
{
	if(_gotTVDBDetails) {
		[self getTheTVDBDetails];
	}
	if (_tvdbArtworkLocation.length == 0 ||
		self.seasonEpisode.length == 0 ) {
		return;
	}
	NSString * extension = [self.tvdbArtworkLocation pathExtension];
	
	NSString * destination = [NSString stringWithFormat:@"%@_%@.%@",path, [self seasonEpisode],extension];
	
	//download only if we don't have it already
	if (![[NSFileManager defaultManager] fileExistsAtPath:destination]) {
		NSString *urlString = [[NSString stringWithFormat:@"http://thetvdb.com/banners/%@",_tvdbArtworkLocation] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
		DDLogDetail(@"downloading artwork at %@",urlString);
		NSURLRequest *theRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:urlString]
												cachePolicy:NSURLRequestUseProtocolCachePolicy
											timeoutInterval:60.0];
		
		// Create the connection with the request and start loading the data.
		NSURLDownload  *theDownload = [[NSURLDownload alloc] initWithRequest:theRequest
																delegate:nil];
		if (theDownload) {
			// Set the destination file.
			[theDownload setDestination:destination allowOverwrite:YES];
		}
	}
}



-(NSString *)getStringForPattern:(NSString *)pattern fromString:(NSString *)string
{
    NSError *error = nil;
    NSString *answer = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:&error];
    if (error) {
        DDLogReport(@"GetStringFormPattern error %@",error.userInfo);
        return nil;
    }
    NSTextCheckingResult *result = [regex firstMatchInString:string options:NSMatchingWithoutAnchoringBounds range:NSMakeRange(0, string.length)];
    if (result && [result numberOfRanges] > 1) {
        NSRange rangeOfanswer = [result rangeAtIndex:1];
        answer = [string substringWithRange:rangeOfanswer];
    }
    return answer;
    
}


#pragma mark - Queue encoding/decoding methods for persistent queue, copy/paste, and drag/drop

- (void) encodeWithCoder:(NSCoder *)encoder {
	//necessary for cut/paste drag/drop. 
	DDLogVerbose(@"encoding %@",self);
	[encoder encodeObject:[NSNumber numberWithInteger: _showID] forKey: kMTQueueID];
	[encoder encodeObject:_showTitle forKey: kMTQueueTitle];
	[encoder encodeObject:self.tiVoName forKey: kMTQueueTivo];
}

-(BOOL) isEqual:(id)object {
	MTTiVoShow * show = (MTTiVoShow *) object;
	return [self.showTitle isEqualToString: show.showTitle] &&
			self. showID == show.showID &&
		   [self.tiVoName isEqualToString: show.tiVoName];
}

-(NSUInteger) hash {
    return [self.showTitle hash] ^
            self.showID ^
             [self.tiVoName hash];
}

-(void) setShowSeriesAndEpisodeFrom:(NSString *) newTitle {
	if (newTitle) {
		self.showTitle = newTitle;

		NSRange pos = [newTitle rangeOfString: @": "];
		//Normally this is built from episode/series; but if we got showtitle from
		//"old" queue, we'd like to temporarily display eps/series
		if (pos.location == NSNotFound) {
			if (_seriesTitle.length == 0) {
				self.seriesTitle = newTitle;
			}
		} else {
			if (_seriesTitle.length == 0) {
				self.seriesTitle = [newTitle substringToIndex:pos.location];
			}
			if (_episodeTitle.length == 0) {
				self.episodeTitle = [newTitle substringFromIndex:pos.location+pos.length];
			}
		}
	}
}


- (id)initWithCoder:(NSCoder *)decoder {
	//keep parallel with updateFromDecodedShow
	if ((self = [self init])) {
		//NSString *title = [decoder decodeObjectForKey:kTitleKey];
		//float rating = [decoder decodeFloatForKey:kRatingKey];
		self.showID   = [[decoder decodeObjectForKey: kMTQueueID] intValue];
		[self setShowSeriesAndEpisodeFrom:[decoder decodeObjectForKey: kMTQueueTitle] ] ;
		NSString * tivoName = [decoder decodeObjectForKey: kMTQueueTivo] ;
		for (MTTiVo * tiVo in [tiVoManager tiVoList]) {
			if ([tiVo.tiVo.name compare: tivoName] == NSOrderedSame) {
				_tiVo = tiVo;
				break;
			}
		}
		if (!_tiVo) {
			self.tempTiVoName = tivoName;
		}
	}
	DDLogDetail(@"initWithCoder for %@",self);
	return self;
}

- (id)pasteboardPropertyListForType:(NSString *)type {
//	NSLog(@"QQQ:pboard Type: %@",type);
	if ([type isEqualToString:kMTTivoShowPasteBoardType]) {
		return  [NSKeyedArchiver archivedDataWithRootObject:self];
    } else if ( [type isEqualToString:(NSString *)kUTTypeFileURL]) {
        NSArray * files = [tiVoManager.showsOnDisk objectForKey:self.showKey];
        if (files.count > 0) {
            NSURL *URL = [NSURL fileURLWithPath:files[0] isDirectory:NO];
            id temp =  [URL pasteboardPropertyListForType:(id)kUTTypeFileURL];
            return temp;
        } else {
           return nil;
        }
    } else if ( [type isEqualToString:NSPasteboardTypeString]) {
        NSString * episodePart = self.seasonEpisode.length >0 ?
                                        [NSString stringWithFormat:@"\t(%@)",self.seasonEpisode] :
                                        @""; //skip empty episode info
        NSString * protected = self.protectedShow.boolValue ? @"-CP":@"";
        return [NSString stringWithFormat:@"%@\t%@%@%@" ,self.showDateString, self.showTitle, protected, episodePart] ;
    } else {
        return nil;
    }
}

-(NSArray *)writableTypesForPasteboard:(NSPasteboard *)pasteboard {
    if ([tiVoManager.showsOnDisk objectForKey:self.showKey]) {
        return @[kMTTivoShowPasteBoardType, (NSString *)kUTTypeFileURL, NSPasteboardTypeString];
    } else {
        return @[kMTTivoShowPasteBoardType, NSPasteboardTypeString];
    }
}

- (NSPasteboardWritingOptions)writingOptionsForType:(NSString *)type pasteboard:(NSPasteboard *)pasteboard {
	return 0;
}

+ (NSArray *)readableTypesForPasteboard:(NSPasteboard *)pasteboard {
	return @[kMTTivoShowPasteBoardType];

}
+ (NSPasteboardReadingOptions)readingOptionsForType:(NSString *)type pasteboard:(NSPasteboard *)pasteboard {
	if ([type compare:kMTTivoShowPasteBoardType] ==NSOrderedSame)
		return NSPasteboardReadingAsKeyedArchive;
	return 0;
}

#pragma mark - GetDetails from Tivo and parse


-(void)getShowDetail
{
    if (_gotDetails) {
        if (!_gotTVDBDetails) {
            [self getTheTVDBDetails];
        }
        return;
    }
    DDLogDetail(@"getting Detail for %@ at %@",self, _detailURL);
    _gotDetails = YES;
    @autoreleasepool {
        //	NSString *detailURLString = [NSString stringWithFormat:@"https://%@/TiVoVideoDetails?id=%d",_tiVo.tiVo.hostName,_showID];
        //	NSLog(@"Show Detail URL %@", detailURLString );
        NSString *detailFilePath = [NSString stringWithFormat:@"%@/%@_%d_Details.xml",kMTTmpDetailsDir,_tiVo.tiVo.name,_showID];
        NSData *xml = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:detailFilePath]) {
            DDLogDetail(@"downloading details from file %@", detailFilePath);
            xml = [NSData dataWithContentsOfFile:detailFilePath];
            NSMutableDictionary *attr = [NSMutableDictionary dictionaryWithDictionary:[[NSFileManager defaultManager] attributesOfItemAtPath:detailFilePath error:nil]];
            [attr setObject:[NSDate date] forKey:NSFileModificationDate];
            [[NSFileManager defaultManager] setAttributes:attr ofItemAtPath:detailFilePath error:nil];
        } else {
            NSURLResponse *detailResponse = nil;
            NSURLRequest *detailRequest = [NSURLRequest requestWithURL:_detailURL];;
            xml = [NSURLConnection sendSynchronousRequest:detailRequest returningResponse:&detailResponse error:nil];
            if (![_inProgress boolValue]) {
                [xml writeToFile:detailFilePath atomically:YES];
            }
        }
        DDLogVerbose(@"Got Details for %@: %@", self, [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding	]);

        NSXMLParser * parser = [[NSXMLParser alloc] initWithData:xml];
        parser.delegate = self;
        self.ignoreSection = NO;
        [parser parse];
        if (!_gotDetails) {
            DDLogMajor(@"GetDetails Fail for %@",_showTitle);
            DDLogMajor(@"Returned XML is %@",	[[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding	]);
        } else {
            DDLogDetail(@"GetDetails parsing Finished");
        }
        DDLogVerbose(@"Show: %@, AirDate: %@",self.showTitle, self.originalAirDateNoTime);
        [self getTheTVDBDetails];
        
        [NSNotificationCenter postNotificationNameOnMainThread:kMTNotificationDetailsLoaded object:self ];
    }
    DDLogDetail(@"Exiting detail for %@ ",self);
    if ([NSOperationQueue currentQueue].operationCount == 1 && self.tiVo.showURLConnection) {
        DDLogReport(@"Got all details for %@",self.tiVo);
    }
}

#pragma  mark - parser methods


-(void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict
{
    if (self.ignoreSection) return;
    
    if ([elementName isEqualToString:@"vActualShowing"]) {
       self.ignoreSection = YES;
       return;
   }

   elementString = [NSMutableString new];
   if (![elementName isEqualToString:@"element"]) {
       elementArray = [NSMutableArray new];
   }
}

-(void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
    if (self.ignoreSection) return;
    [elementString appendString:string];
}

- (void)setValue:(id)value forUndefinedKey:(NSString *)key{
    //nothing to see here; just move along
	DDLogVerbose(@"Unrecognized key %@", key);
}

-(void) endElement:(NSString *)elementName item:(id) item {
	DDLogDetail(@" %@: %@",elementName, item);

}

-(void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
{
    if ([elementName isEqualToString:@"vActualShowing"]) {
        self.ignoreSection = NO;
        return;
    }
    if (self.ignoreSection) return;
    if (parseTermMapping[elementName]) {
		elementName = parseTermMapping[elementName];
	}
	if ([elementName compare:@"element"] == NSOrderedSame) {
        if (elementName.length > 0) {
            [elementArray addObject:elementString];
        }
	} else if (elementName.length != 0) {
		id item;
		if (elementArray.count) {
			item = [NSArray arrayWithArray:elementArray];
		} else {
			item = elementString;
		}
		@try {
             dispatch_sync(dispatch_get_main_queue(), ^{
                [self setValue:item forKeyPath:elementName];
            });
            [self endElement: elementName item: item];
		}
		@catch (NSException *exception) {
		}
		@finally {
		}
	}
}

-(void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError
{
	_gotDetails = NO;
	DDLogMajor(@"Show: %@ Parser Error %@",self.showTitle, parseError);
}

#pragma mark - Custom Getters

-(NSString *)showKey
{
	return [NSString stringWithFormat:@"%@: %@",self.tiVoName,self.idString];
}
												  
-(NSString *) seasonEpisode {
    
    NSString *returnString = @"";
    if (_episode > 0) {
		if (_season > 0) {
			returnString = [NSString stringWithFormat:@"S%0.2dE%0.2d",_season,_episode ];
		} else {
			returnString = [NSString stringWithFormat:@"%d",_episode];
		}
     } else {
        returnString = _episodeNumber;
    }
    return returnString;
}

-(NSString *) seriesFromProgram:(NSString *) name {
    NSArray * nameParts = [name componentsSeparatedByString: @":"];
    if (nameParts.count == 0) return name;
    return [nameParts objectAtIndex:0];
}

-(NSString * ) seriesTitle {
    if (!_seriesTitle) {
        self.seriesTitle = [self seriesFromProgram:_showTitle];
    }
    return _seriesTitle;
}

-(BOOL) isMovie {
	BOOL value =  ([self.episodeID hasPrefix:@"MV"]) ;
	return value;
}

-(NSAttributedString *)attrStringFromDictionaries:(id)nameList
{
    NSMutableString *returnString = [NSMutableString string];
    if ([nameList isKindOfClass:[NSArray class]]) {
        for (NSDictionary *name in nameList) {
            [returnString appendFormat:@"%@\n",[self nameString:name]];
        }
       	if (returnString.length > 0)[returnString deleteCharactersInRange:NSMakeRange(returnString.length-1, 1)];
		
    }
	return [[NSAttributedString alloc] initWithString:returnString attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:11]}];
    
}

-(NSAttributedString *)attribDescription {
	NSAttributedString *attstring = [[NSAttributedString alloc] initWithString:@""];
	if (self.showDescription) {
		attstring = [[NSAttributedString alloc] initWithString:self.showDescription attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:11]}];
	}
	return attstring;
}

-(NSString *)yearString
{
    return [NSString stringWithFormat:@"%d",_episodeYear];
}

-(NSString *)seasonString
{
	NSString *returnString = @"";
	if (_season > 0) {
		returnString = [NSString stringWithFormat:@"%d",_season];
	}
    return returnString;
}


-(MTTiVo *) tiVo {
	if (!_tiVo) {
		for (MTTiVo * possibleTiVo in tiVoManager.tiVoList) {
			if ([possibleTiVo.tiVo.name isEqualToString:self.tempTiVoName]) {
				self.tiVo = possibleTiVo;
				break;
			}
		}
	}
	return _tiVo;
}

-(const MP4Tags * ) metaDataTagsWithImage: (NSImage* ) image andResolution:(HDTypes) hdType {
	//maintain source code parallel with MTiTunes.m>importIntoiTunes
	const MP4Tags *tags = MP4TagsAlloc();
	uint8_t mediaType = 10;
	if (self.isMovie) {
		mediaType = 9;
		MP4TagsSetMediaType(tags, &mediaType);
		MP4TagsSetName(tags,[self.showTitle cStringUsingEncoding:NSUTF8StringEncoding]) ;
	} else {
		mediaType = 10;
		MP4TagsSetMediaType(tags, &mediaType);
		if (self.season > 0 ) {
			uint32_t showSeason =  self.season;
			MP4TagsSetTVSeason(tags, &showSeason);
			MP4TagsSetAlbum(tags,[[NSString stringWithFormat: @"%@, Season %d",self.seriesTitle, self.season] cStringUsingEncoding:NSUTF8StringEncoding]) ;
		} else {
			MP4TagsSetAlbum(tags,[self.seriesTitle cStringUsingEncoding:NSUTF8StringEncoding]) ;
			
		}
		if (self.seriesTitle.length>0) {
			MP4TagsSetTVShow(tags,[self.seriesTitle cStringUsingEncoding:NSUTF8StringEncoding]);
			MP4TagsSetArtist(tags,[self.seriesTitle cStringUsingEncoding:NSUTF8StringEncoding]);
			MP4TagsSetAlbumArtist(tags,[self.seriesTitle cStringUsingEncoding:NSUTF8StringEncoding]);
		}
		if (self.episodeTitle.length==0) {
			NSString * dateString = self.originalAirDateNoTime;
			if (dateString.length == 0) {
				NSDateFormatter *dateFormat = [[NSDateFormatter alloc] init];
				[dateFormat setDateStyle:NSDateFormatterShortStyle];
				[dateFormat setTimeStyle:NSDateFormatterNoStyle];
				dateString =  [dateFormat stringFromDate: self.showDate ];
			}
			MP4TagsSetName(tags,[[NSString stringWithFormat:@"%@ - %@",self.showTitle, dateString] cStringUsingEncoding:NSUTF8StringEncoding]);
		} else {
			MP4TagsSetName(tags,[self.episodeTitle cStringUsingEncoding:NSUTF8StringEncoding]);
		}
		uint32_t episodeNum = (uint32_t) self.episode;
		if (episodeNum == 0) {
			episodeNum = (uint32_t) [self.episodeNumber integerValue];
		}
		if (episodeNum> 0) {
			MP4TagsSetTVEpisode(tags, &episodeNum);
			MP4TagTrack track;
			track.index = (uint16)episodeNum;
			track.total = 0;
			MP4TagsSetTrack(tags, &track);
			
		}
	}
	if (self.episodeID.length >0) {
		MP4TagsSetTVEpisodeID(tags, [self.episodeID cStringUsingEncoding:NSUTF8StringEncoding]);
		if ([[NSUserDefaults standardUserDefaults] boolForKey:kMTiTunesContentIDExperiment ] & (self.episodeID.length >2)) {
			NSRange digitPart = NSMakeRange(2, self.episodeID.length-2);
			NSUInteger bigDigits = [[self.episodeID substringWithRange:digitPart] integerValue];
			uint32 digits = (uint32)(bigDigits & ULONG_MAX); //modulo to wrap around over 4G
			DDLogDetail(@"ContentID: %lu => %u", bigDigits, digits);
			MP4TagsSetContentID(tags, &digits);
		}
	}
	
	if (self.showDescription.length > 0) {
		if (self.showDescription.length < 255) {
			MP4TagsSetDescription(tags,[self.showDescription cStringUsingEncoding:NSUTF8StringEncoding]);
			MP4TagsSetComments(tags,[self.showDescription cStringUsingEncoding:NSUTF8StringEncoding]);			
		} else {
			MP4TagsSetDescription(tags,[[self.showDescription  substringToIndex:255] cStringUsingEncoding:NSUTF8StringEncoding]);
			MP4TagsSetLongDescription(tags,[self.showDescription cStringUsingEncoding:NSUTF8StringEncoding]);
			MP4TagsSetComments(tags,[self.showDescription cStringUsingEncoding:NSUTF8StringEncoding]);
		}
	}
	if (self.seriesTitle.length>0) {
		MP4TagsSetTVShow(tags, [self.seriesTitle cStringUsingEncoding:NSUTF8StringEncoding]);
	}
	//no year equivalent?
	NSString * releaseDate = self.originalAirDate;
	if (releaseDate.length == 0) {
		releaseDate = self.movieYear;
	}
	if (releaseDate.length>0) {
		MP4TagsSetReleaseDate(tags,[releaseDate cStringUsingEncoding:NSUTF8StringEncoding]);
	}
	if (self.stationCallsign) {
		MP4TagsSetTVNetwork(tags, [self.stationCallsign cStringUsingEncoding:NSUTF8StringEncoding]);
	}
	if (self.episodeGenre.length>0) {
		MP4TagsSetGenre(tags,[self.episodeGenre cStringUsingEncoding:NSUTF8StringEncoding]);
	}
	
	if (image) {
		NSData *PNGData  = [NSBitmapImageRep representationOfImageRepsInArray: [image representations]
																	usingType:NSPNGFileType properties:nil];
		MP4TagArtwork artwork;
		
		artwork.data = (void *)[PNGData bytes];
		artwork.size = (uint32_t)[PNGData length];
		artwork.type = MP4_ART_PNG;
		
		MP4TagsAddArtwork(tags, &artwork);
	}
	
	if (hdType != HDTypeNotAvailable ) {
		uint8_t myHDType = (uint8_t) hdType;
		MP4TagsSetHDVideo(tags, &myHDType);
	}
	return tags;
}

-(NSString *)showDateString
{
	static NSDateFormatter *dateFormat;
	if(!dateFormat) {
		dateFormat = [[NSDateFormatter alloc] init] ;
		[dateFormat setDateStyle:NSDateFormatterShortStyle];
		[dateFormat setTimeStyle:NSDateFormatterShortStyle] ;
	}
//	[dateFormat setTimeStyle:NSDateFormatterNoStyle];
	return [dateFormat stringFromDate:_showDate];
}

-(NSString *)showMediumDateString
{
	static NSDateFormatter *dateFormat;
	if(!dateFormat) {
		dateFormat = [[NSDateFormatter alloc] init] ;
		[dateFormat setDateStyle:NSDateFormatterMediumStyle];
		[dateFormat setTimeStyle:NSDateFormatterShortStyle] ;
	}
	//	[dateFormat setTimeStyle:NSDateFormatterNoStyle];
	return [dateFormat stringFromDate:_showDate];
}
												  
-(NSString *)checkString:(BOOL) test {
  return test ? @"✔" : @"";
}
											  
-(NSString*) lengthString {
	NSInteger length = (_showLength+30)/60; //round up to nearest minute;
	return [NSString stringWithFormat:@"%ld:%0.2ld",length/60,length % 60];
}
												  
-(NSString*) isQueuedString {
  return [self checkString: _isQueued];
}
												  
-(NSString*) isHDString {
	return [self checkString:_isHD.boolValue];
}

-(NSString*) imageString {
	if (self.protectedShow.boolValue && !self.inProgress.boolValue) {
		if (self.fileSize > 0) {
			return @"copyright";
		} else {
			//not loaded yet
			return @"status-unknown";
		}
	}
	if (_imageString.length) {
		return _imageString;
	} else {
		return @"recent-recording";
	}
}

-(NSString*) idString {
	return[NSString stringWithFormat:@"%d", _showID ];
}
												  
-(NSString*) sizeString {
  
  if (_fileSize >= 1000000000) {
	  return[NSString stringWithFormat:@"%0.1fGB",_fileSize/(1000000000)];
  } else if (_fileSize > 0) {
	  return[NSString stringWithFormat:@"%ldMB",((NSInteger)_fileSize)/(1000000) ];
  } else {
	  return @"-";
  }
}

-(NSString *) combinedChannelString {
	if (!self.channelString) return @"";
	return  [NSString stringWithFormat:@"%@-%@ %@",
			 self.stationCallsign,
			 self.channelString,
			 self.isHD.boolValue? @"HD": @""];
}

-(NSNumber *) channelNumber {
    NSInteger channel = self.channelString.integerValue;
    if (!channel) return @(NSIntegerMax);
    return @(channel);

}

-(NSString *) tiVoName {
	if (_tiVo) {
		return _tiVo.tiVo.name;
	} else {
		return self.tempTiVoName;
	}
}

-(void) setProgramId:(NSString *)programId {
	if (programId != _programId) {
		_programId = programId;
        _episodeID = nil;
    }
}

-(NSString *) episodeID {
    if (!_episodeID) {
		_episodeID = _programId;
		if (_episodeID.length == 12) {
			_episodeID = [NSString stringWithFormat:@"%@00%@",[_episodeID substringToIndex:2],[_episodeID substringFromIndex:2]];
		}
		if (![_episodeID hasPrefix:@"MV"] && [_episodeID hasSuffix:@"0000"] ) {
                NSDateFormatter *dateFormat = [[NSDateFormatter alloc] init] ;
                [dateFormat setDateStyle:NSDateFormatterShortStyle];
                [dateFormat setTimeStyle:NSDateFormatterNoStyle] ;
			_episodeID = [NSString stringWithFormat: @"%@-%@",_episodeID, [dateFormat stringFromDate: _showDate] ];
		}
	}
    return _episodeID;
}

#pragma mark - Custom Setters; many for parsing

-(NSString *)nameString:(NSDictionary *)nameDictionary
{
    return [NSString stringWithFormat:@"%@ %@",nameDictionary[kMTFirstName] ? nameDictionary[kMTFirstName] : @"" ,nameDictionary[kMTLastName] ? nameDictionary[kMTLastName] : @"" ];
}

-(void)setShowLengthString:(NSString *)showLengthString
{
    if (showLengthString != _showLengthString) {
        _showLengthString = showLengthString;
        _showLength = [_showLengthString longLongValue]/1000;
    }
}
static void * showTimeContext = &showTimeContext;
static void * episodeNumberContext = &episodeNumberContext;
static void * movieYearContext = &movieYearContext;
static void * originalAirDateContext = &originalAirDateContext;

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if (context == showTimeContext) {
        NSDate *newDate =[_showTime dateForRFC3339DateTimeString];
        if (newDate) {
            self.showDate = newDate;
        }

    } else if (context == episodeNumberContext) {
        if (_episodeNumber.length) {
            long l = _episodeNumber.length;
            if (l > 2 && l < 6) {
                //3,4,5 ok: 3 = SEE 4= SSEE 5 = SSEEE
                //4 might be corrected by tvdb to SEEE
                int epDigits = (l > 4) ? 3:2;
                _episode = [[_episodeNumber substringFromIndex:l-epDigits] intValue];
                _season = [[_episodeNumber substringToIndex:l-epDigits] intValue];
            } else {
                _episode = [_episodeNumber intValue];
            }
        }
    } else if (context == movieYearContext) {
        if (self.originalAirDateNoTime.length == 0) {
            _originalAirDateNoTime = self.movieYear;
        }
    } else if (context == originalAirDateContext) {
        if (_originalAirDate.length > 4) {
            _episodeYear = [[_originalAirDate substringToIndex:4] intValue];
        }
        if (_originalAirDate.length >= 10) {
            _originalAirDateNoTime = [_originalAirDate substringToIndex:10];
        } else if (_originalAirDate.length > 0) {
            _originalAirDateNoTime = _originalAirDate;
        } else if (_movieYear.length > 0){
            _originalAirDateNoTime = _movieYear;
        }
    }
}

-(void) setImageString:(NSString *)imageString {
	if (imageString != _imageString) {
		_imageString = imageString;
		_isSuggestion = [@"suggestion-recording" isEqualToString:imageString];
	}
}

-(void)playVideo:(NSString *)path
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];

}

-(void)revealInFinder:(NSArray *)paths
{
   	NSMutableArray * showURLs = [NSMutableArray arrayWithCapacity:paths.count];
	for (NSString *fileName in paths) {
		NSURL * showURL = [NSURL fileURLWithPath:fileName];
		if (showURL) {
			[showURLs addObject:showURL];
		}
	}
	if (showURLs.count > 0) {
		[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:showURLs];
	}
}

-(void)setInProgress:(NSNumber *)inProgress
{
  if (_inProgress != inProgress) {
	  _inProgress = inProgress;
	  if ([_inProgress boolValue]) {
		  self.protectedShow = @(YES);
	  }
  }
}


-(void)setSeriesTitle:(NSString *)seriesTitle
{
	if (_seriesTitle != seriesTitle) {
        _seriesTitle =seriesTitle;
		if (_episodeTitle.length > 0 ) {
			self.showTitle =[NSString stringWithFormat:@"%@: %@",_seriesTitle, _episodeTitle];
		} else {
			self.showTitle =_seriesTitle;
		}
	}
}

-(void)setEpisodeTitle:(NSString *)episodeTitle
{
	if (_episodeTitle != episodeTitle) {
		_episodeTitle = episodeTitle;
		if (_episodeTitle.length > 0 ) {
			self.showTitle =[NSString stringWithFormat:@"%@: %@",_seriesTitle, _episodeTitle];
		} else {
			self.showTitle =_seriesTitle;
		}
	}
}

-(void)setShowDescription:(NSString *)showDescription
{
    NSString * tribuneCopyright = @" Copyright Tribune Media Services, Inc.";
	if (_showDescription == showDescription) {
		return;
	}
    if ([showDescription hasSuffix: tribuneCopyright]){
        _showDescription = [showDescription substringToIndex:showDescription.length -tribuneCopyright.length];
    } else {
        _showDescription = showDescription;

    }
}



-(NSAttributedString *)parseNames:(NSArray *)nameSet
{
    if (!nameSet || ![nameSet respondsToSelector:@selector(count)] || nameSet.count == 0 ) { //|| [nameSet[0] isKindOfClass:[NSString class]]) {
        return [[NSAttributedString alloc] initWithString:@""] ;
    }
    NSRegularExpression *nameParse = [NSRegularExpression regularExpressionWithPattern:@"([^|]*)\\|([^|]*)" options:NSRegularExpressionCaseInsensitive error:nil];
    NSMutableArray *newNames = [NSMutableArray array];
    for (NSString *name in nameSet) {
        NSTextCheckingResult *match = [nameParse firstMatchInString:name options:NSMatchingWithoutAnchoringBounds range:NSMakeRange(0, name.length)];
        NSString *lastName = [name substringWithRange:[match rangeAtIndex:1]];
        NSString *firstName = [name substringWithRange:[match rangeAtIndex:2]];
        [newNames addObject:@{kMTLastName : lastName, kMTFirstName : firstName}];
    }
    return [self attrStringFromDictionaries:newNames];
}

-(void)setVActor:(NSArray *)vActor
{
	if ( ![vActor isKindOfClass:[NSArray class]]) {
		return;
	}
    self.actors = [self parseNames: vActor ]  ;
}

-(void)setVGuestStar:(NSArray *)vGuestStar
{
	if ( ![vGuestStar isKindOfClass:[NSArray class]]) {
		return;
	}
	self.guestStars = [self parseNames: vGuestStar ];
}

-(void)setVDirector:(NSArray *)vDirector
{
	if ( ![vDirector isKindOfClass:[NSArray class]]) {
		return;
	}
	self.directors = [self parseNames: vDirector ];
}

-(void)setVExecProducer:(NSArray *)vExecProducer
{
	if ( ![vExecProducer isKindOfClass:[NSArray class]]) {
		return;
	}
    self.producers  = [self parseNames:vExecProducer];
}


-(void)setVProgramGenre:(NSArray *)vProgramGenre
{
	if (![vProgramGenre isKindOfClass:[NSArray class]] ||
        vProgramGenre.count == 0) {
		return;
	}
    self.episodeGenre = [vProgramGenre[0] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];

}

-(void)setVSeriesGenre:(NSArray *)vSeriesGenre{
    if (![vSeriesGenre isKindOfClass:[NSArray class]] ||
        vSeriesGenre.count == 0) {
        return;
    }
    self.episodeGenre = [vSeriesGenre[0] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
    
}

#pragma mark - Memory Management

-(void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self removeObserver:self forKeyPath:@"showTime"];
    [self removeObserver:self forKeyPath:@"episodeNumber"];
    [self removeObserver:self forKeyPath:@"movieYear"];
    [self removeObserver:self forKeyPath:@"originalAirDate"];
    self.showTitle = nil;
    self.showDescription = nil;
    self.tiVo = nil;
	if (elementString) {
        elementString = nil;
	}
	if (elementArray) {
        elementArray = nil;
	}
}

-(NSString *)description
{
    return [NSString stringWithFormat:@"%@ (%@)%@",_showTitle,self.tiVoName,[_protectedShow boolValue]?@"-Protected":@""];
}


@end

