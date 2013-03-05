//
//  zkApexClient.m
//  apexCoder
//
//  Created by Simon Fell on 5/29/07.
//  Copyright 2007 Simon Fell. All rights reserved.
//

#import "zkApexClient.h"
#import "ZKEnvelope.h"
#import "zkCompileResult.h"
#import "zkExecuteAnonResult.h"
#import "zkRunTestResult.h"
#import "zkParser.h"

@implementation ZKApexClient

#define APEX_WS_NS   @"http://soap.sforce.com/2006/08/apex"
#define SOAP_ENV_NS  @"http://schemas.xmlsoap.org/soap/envelope/"

@synthesize debugLog;

static NSArray *logLevelNames;

-(NSString *)stringOfLogCategory:(ZKLogCategory)c {
	switch (c) {
	case Category_Db: return @"Db";
	case Category_Workflow: return @"Workflow";
	case Category_Validation: return @"Validation";
	case Category_Callout: return @"Callout";
	case Category_Apex_code: return @"Apex_code";
	case Category_Apex_profiling: return @"Apex_profiling";
	case Category_All: return @"All";
	}
	@throw [NSException exceptionWithName:@"Unexpected log category" reason:[NSString stringWithFormat:@"LogCategory of %d is not valid", c] userInfo:nil];
}

+(NSString *)stringOfLogLevel:(ZKLogCategoryLevel)l {
	switch (l) {
	case Level_Internal: return @"Internal";
	case Level_Finest: return @"Finest";
	case Level_Finer: return @"Finer";
	case Level_Fine: return @"Fine";
	case Level_Debug: return @"Debug";
	case Level_Info: return @"Info";
	case Level_Warn: return @"Warn";
	case Level_Error: return @"Error";
	case Level_None: return @"None";
	}
	@throw [NSException exceptionWithName:@"Unexpected log level" reason:[NSString stringWithFormat:@"LogLevel of %d is not valid", l] userInfo:nil];
}

+(void)initialize {
	NSMutableArray *a = [NSMutableArray array];
	for (int i =0; i < 9; i++) {
		NSDictionary *d = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:i], @"Level", [ZKApexClient stringOfLogLevel:i], @"Name", nil];
		[a addObject:d];
	}
	logLevelNames = [a retain];
}

+ (id) fromClient:(ZKSforceClient *)sf {
	return [[[ZKApexClient alloc] initFromClient:sf] autorelease];
}

- (id) initFromClient:(ZKSforceClient *)sf {
	self = [super init];
	sforce = [sf retain];
	debugLog = NO;
	for (int i = 0; i < ZKLogCategory_Count; i++)
		loggingLevels[i] = Level_None;
	return self;
}

- (void)dealloc {
	[sforce release];
	[lastDebugLog release];
	[super dealloc];
}

-(ZKLogCategoryLevel)debugLevelForCategory:(ZKLogCategory)c {
	return loggingLevels[c];
}

-(void)setDebugLevel:(ZKLogCategoryLevel)lvl forCategory:(ZKLogCategory)c {
	loggingLevels[c] = lvl;
}

+(NSArray *)logLevelNames {
	return logLevelNames;
}

-(NSString *)lastDebugLog {
	return lastDebugLog;
}

-(void)setLastDebugLog:(NSString *)log {
	[lastDebugLog autorelease];
	lastDebugLog = [log retain];
}

- (void)setEndpointUrl {
	[endpointUrl release];
    NSString *sUrl = [sforce serverUrl];
    sUrl = [sUrl stringByReplacingOccurrencesOfString:@"/services/Soap/u/" withString:@"/services/Soap/s/"];
	endpointUrl = [sUrl retain];
}

- (ZKEnvelope *)startEnvelope {
	ZKEnvelope *e = [[[ZKEnvelope alloc] init] autorelease];
	[e start:APEX_WS_NS];
	[e writeSessionHeader:[sforce sessionId]];
	[e writeCallOptionsHeader:[sforce clientId]];
	if ([self debugLog]) {
		[e startElement:@"DebuggingHeader"];
		for (int i =0; i < ZKLogCategory_Count; i++) {
			if (loggingLevels[i] != Level_None) {
				[e startElement:@"categories"];
				[e addElementString:@"category" elemValue:[self stringOfLogCategory:i]];
				[e addElementString:@"level" elemValue:[ZKApexClient stringOfLogLevel:loggingLevels[i]]];
				[e endElement:@"categories"];
			}
		}
		[e endElement:@"DebuggingHeader"];
	}
	[e moveToBody];
	[self setEndpointUrl];
	return e;
}

-(NSString *)getResponseDebugLog:(zkElement *)soapRoot {
	zkElement *headers = [soapRoot childElement:@"Header" ns:SOAP_ENV_NS];
	zkElement *debugInfo = [headers childElement:@"DebuggingInfo" ns:APEX_WS_NS];
	zkElement *debugLogE = [debugInfo childElement:@"debugLog" ns:APEX_WS_NS];
	return [debugLogE stringValue];
}

- (NSArray *)sendAndParseResults:(ZKEnvelope *)requestEnv resultType:(Class)resultClass {
	NSString *soapRequest = [requestEnv end];
//	NSLog(@"request is\r\n%@", soapRequest);
	zkElement *soapRoot = [self sendRequest:soapRequest returnRoot:YES];
	NSString *debugLogStr = [self getResponseDebugLog:soapRoot];
	[self setLastDebugLog:debugLogStr];
	
	zkElement *body = [soapRoot childElement:@"Body" ns:SOAP_ENV_NS];
	zkElement *resRoot = [[body childElements] objectAtIndex:0];
	
	NSArray * results = [resRoot childElements:@"result"];
	NSMutableArray *resArr = [NSMutableArray arrayWithCapacity:[results count]];
	for (zkElement *child in results) {
		NSObject *o = [[resultClass alloc] initWithXmlElement:child];
		[resArr addObject:o];
		[o release];
	}
	return resArr;
}

- (NSArray *)compile:(NSString *)elemName src:(NSArray *)src {
	ZKEnvelope * env = [self startEnvelope];
	[env startElement:elemName];
	[env addElementArray:@"scripts" elemValue:src];
	[env endElement:elemName];
	[env endElement:@"s:Body"];
	return [self sendAndParseResults:env resultType:[ZKCompileResult class]];
}

- (NSArray *)compilePackages:(NSArray *)src {
	return [self compile:@"compilePackages" src:src];
}

- (NSArray *)compileTriggers:(NSArray *)src {
	return [self compile:@"compileTriggers" src:src];
}

- (ZKExecuteAnonymousResult *)executeAnonymous:(NSString *)src {
	ZKEnvelope * env = [self startEnvelope];
	[env startElement:@"executeAnonymous"];
	[env addElement:@"String" elemValue:src];
	[env endElement:@"executeAnonymous"];
	[env endElement:@"s:Body"];
	return [[self sendAndParseResults:env resultType:[ZKExecuteAnonymousResult class]] objectAtIndex:0];
}

- (ZKRunTestResult *)runTests:(BOOL)allTests namespace:(NSString *)ns packages:(NSArray *)pkgs {
	ZKEnvelope *env = [self startEnvelope];
	[env startElement:@"runTests"];
	[env startElement:@"RunTestsRequest"];
	[env addElement:@"allTests" elemValue:allTests ? @"true" : @"false"];
	[env addElement:@"namespace" elemValue:ns];
	[env addElement:@"packages" elemValue:pkgs];
	[env endElement:@"RunTestsRequest"];
	[env endElement:@"runTests"];
	[env endElement:@"s:Body"];
	return [[self sendAndParseResults:env resultType:[ZKRunTestResult class]] objectAtIndex:0];
}

@end
