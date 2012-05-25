//
//  TDConnectionChangeTracker.m
//  TouchDB
//
//  Created by Jens Alfke on 12/1/11.
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.
//
// <http://wiki.apache.org/couchdb/HTTP_database_API#Changes>

#import "TDConnectionChangeTracker.h"
#import "TDMisc.h"
#import "TDStatus.h"


@implementation TDConnectionChangeTracker

- (BOOL) start {
    [super start];
    _inputBuffer = [[NSMutableData alloc] init];
    
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL: self.changesFeedURL];
    request.cachePolicy = NSURLRequestReloadIgnoringCacheData;
    request.timeoutInterval = 6.02e23;
    
    // Add headers.
    [self.requestHeaders enumerateKeysAndObjectsUsingBlock: ^(id key, id value, BOOL *stop) {
        [request setValue: value forHTTPHeaderField: key];
    }];
    
    _connection = [[NSURLConnection connectionWithRequest: request delegate: self] retain];
    LogTo(ChangeTracker, @"%@: Started... <%@>", self, request.URL);
    return YES;
}


- (void) clearConnection {
    [_connection autorelease];
    _connection = nil;
    [_inputBuffer release];
    _inputBuffer = nil;
}


- (void) stopped {
    LogTo(ChangeTracker, @"%@: Stopped", self);
    [self clearConnection];
    [super stopped];
}


- (void) stop {
    if (_connection) {
        [_connection cancel];
        [super stop];
    }
}


- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    TDStatus status = (TDStatus) ((NSHTTPURLResponse*)response).statusCode;
    LogTo(ChangeTracker, @"%@: Got response, status %d", self, status);
    if (TDStatusIsError(status)) {
        Warn(@"%@: Got status %i", self, status);
        self.error = TDStatusToNSError(status, self.changesFeedURL);
        [self stop];
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    LogTo(ChangeTrackerVerbose, @"%@: Got %lu bytes", self, (unsigned long)data.length);
    [_inputBuffer appendData: data];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    LogTo(ChangeTracker, @"%@: Got error %@", self, error);
    self.error = error;
    [self stopped];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    // Now parse the entire response as a JSON document:
    NSData* input = [_inputBuffer retain];
    LogTo(ChangeTracker, @"%@: Got entire body, %u bytes", self, (unsigned)input.length);
    NSInteger numChanges = [self receivedPollResponse: input];
    if (numChanges < 0)
        [self setUpstreamError: @"Unparseable server response"];
    [input release];
    
    [self clearConnection];
    
    // Poll again if there was no error, and either we're in longpoll mode or it looks like we
    // ran out of changes due to a _limit rather than because we hit the end.
    if (numChanges > 0 && (_mode == kLongPoll || numChanges == (NSInteger)_limit))
        [self start];       // Next poll...
    else
        [self stopped];
}

@end
