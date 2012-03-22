//
//  TDRouter_Tests.m
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

#import "TDRouter.h"
#import "TDDatabase.h"
#import "TDBody.h"
#import "TDServer.h"
#import "TDBase64.h"
#import "TDInternal.h"
#import "Test.h"


#if DEBUG
#pragma mark - TESTS


static TDDatabaseManager* createDBManager(void) {
    return [TDDatabaseManager createEmptyAtTemporaryPath: @"TDRouterTest"];
}


static TDResponse* SendRequest(TDDatabaseManager* server, NSString* method, NSString* path,
                               NSDictionary* headers, id bodyObj) {
    NSURL* url = [NSURL URLWithString: [@"touchdb://" stringByAppendingString: path]];
    CAssert(url, @"Invalid URL: <%@>", path);
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL: url];
    request.HTTPMethod = method;
    for (NSString* header in headers)
        [request setValue: [headers objectForKey: header] forHTTPHeaderField: header];
    if (bodyObj) {
        NSError* error = nil;
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject: bodyObj options:0 error:&error];
        CAssertNil(error);
    }
    TDRouter* router = [[[TDRouter alloc] initWithDatabaseManager: server request: request] autorelease];
    CAssert(router!=nil);
    __block TDResponse* response = nil;
    __block NSUInteger dataLength = 0;
    __block BOOL calledOnFinished = NO;
    router.onResponseReady = ^(TDResponse* theResponse) {CAssert(!response); response = theResponse;};
    router.onDataAvailable = ^(NSData* data, BOOL finished) {dataLength += data.length;};
    router.onFinished = ^{CAssert(!calledOnFinished); calledOnFinished = YES;};
    [router start];
    CAssert(response);
    CAssertEq(dataLength, response.body.asJSON.length);
    CAssert(calledOnFinished);
    return response;
}

static id ParseJSONResponse(TDResponse* response) {
    NSData* json = response.body.asJSON;
    NSString* jsonStr = nil;
    id result = nil;
    if (json) {
        jsonStr = [[[NSString alloc] initWithData: json encoding: NSUTF8StringEncoding] autorelease];
        CAssert(jsonStr);
        NSError* error;
        result = [NSJSONSerialization JSONObjectWithData: json options: 0 error: &error];
        CAssert(result, @"Couldn't parse JSON response: %@", error);
    }
    return result;
}

static id SendBody(TDDatabaseManager* server, NSString* method, NSString* path, id bodyObj,
               int expectedStatus, id expectedResult) {
    TDResponse* response = SendRequest(server, method, path, nil, bodyObj);
    id result = ParseJSONResponse(response);
    Log(@"%@ %@ --> %d", method, path, response.status);
    
    CAssertEq(response.status, expectedStatus);

    if (expectedResult)
        CAssertEqual(result, expectedResult);
    return result;
}

static id Send(TDDatabaseManager* server, NSString* method, NSString* path,
               int expectedStatus, id expectedResult) {
    return SendBody(server, method, path, nil, expectedStatus, expectedResult);
}


TestCase(TDRouter_Server) {
    RequireTestCase(TDDatabaseManager);
    TDDatabaseManager* server = createDBManager();
    Send(server, @"GET", @"/", 200, $dict({@"TouchDB", @"Welcome"},
                                          {@"couchdb", @"Welcome"},
                                          {@"version", [TDRouter versionString]}));
    Send(server, @"GET", @"/_all_dbs", 200, $array());
    Send(server, @"GET", @"/non-existent", 404, nil);
    Send(server, @"GET", @"/BadName", 400, nil);
    Send(server, @"PUT", @"/", 400, nil);
    Send(server, @"POST", @"/", 400, nil);
    [server close];
}


TestCase(TDRouter_Databases) {
    RequireTestCase(TDRouter_Server);
    TDDatabaseManager* server = createDBManager();
    Send(server, @"PUT", @"/database", 201, nil);
    
    NSDictionary* dbInfo = Send(server, @"GET", @"/database", 200, nil);
    CAssertEq([[dbInfo objectForKey: @"doc_count"] intValue], 0);
    CAssertEq([[dbInfo objectForKey: @"update_seq"] intValue], 0);
    CAssert([[dbInfo objectForKey: @"disk_size"] intValue] > 8000);
    
    Send(server, @"PUT", @"/database", 412, nil);
    Send(server, @"PUT", @"/database2", 201, nil);
    Send(server, @"GET", @"/_all_dbs", 200, $array(@"database", @"database2"));
    dbInfo = Send(server, @"GET", @"/database2", 200, nil);
    CAssertEqual([dbInfo objectForKey: @"db_name"], @"database2");
    Send(server, @"DELETE", @"/database2", 200, nil);
    Send(server, @"GET", @"/_all_dbs", 200, $array(@"database"));

    Send(server, @"PUT", @"/database%2Fwith%2Fslashes", 201, nil);
    dbInfo = Send(server, @"GET", @"/database%2Fwith%2Fslashes", 200, nil);
    CAssertEqual([dbInfo objectForKey: @"db_name"], @"database/with/slashes");
    [server close];
}


TestCase(TDRouter_Docs) {
    RequireTestCase(TDRouter_Databases);
    // PUT:
    TDDatabaseManager* server = createDBManager();
    Send(server, @"PUT", @"/db", 201, nil);
    NSDictionary* result = SendBody(server, @"PUT", @"/db/doc1", $dict({@"message", @"hello"}), 
                                    201, nil);
    NSString* revID = [result objectForKey: @"rev"];
    CAssert([revID hasPrefix: @"1-"]);

    // PUT to update:
    result = SendBody(server, @"PUT", @"/db/doc1",
                      $dict({@"message", @"goodbye"}, {@"_rev", revID}), 
                      201, nil);
    Log(@"PUT returned %@", result);
    revID = [result objectForKey: @"rev"];
    CAssert([revID hasPrefix: @"2-"]);
    
    Send(server, @"GET", @"/db/doc1", 200,
         $dict({@"_id", @"doc1"}, {@"_rev", revID}, {@"message", @"goodbye"}));
    
    // Add more docs:
    result = SendBody(server, @"PUT", @"/db/doc3", $dict({@"message", @"hello"}), 
                                    201, nil);
    NSString* revID3 = [result objectForKey: @"rev"];
    result = SendBody(server, @"PUT", @"/db/doc2", $dict({@"message", @"hello"}), 
                                    201, nil);
    NSString* revID2 = [result objectForKey: @"rev"];

    // _all_docs:
    result = Send(server, @"GET", @"/db/_all_docs", 200, nil);
    CAssertEqual([result objectForKey: @"total_rows"], $object(3));
    CAssertEqual([result objectForKey: @"offset"], $object(0));
    NSArray* rows = [result objectForKey: @"rows"];
    CAssertEqual(rows, $array($dict({@"id",  @"doc1"}, {@"key", @"doc1"},
                                    {@"value", $dict({@"rev", revID})}),
                              $dict({@"id",  @"doc2"}, {@"key", @"doc2"},
                                    {@"value", $dict({@"rev", revID2})}),
                              $dict({@"id",  @"doc3"}, {@"key", @"doc3"},
                                    {@"value", $dict({@"rev", revID3})})
                              ));

    // DELETE:
    result = Send(server, @"DELETE", $sprintf(@"/db/doc1?rev=%@", revID), 200, nil);
    revID = [result objectForKey: @"rev"];
    CAssert([revID hasPrefix: @"3-"]);

    Send(server, @"GET", @"/db/doc1", 404, nil);
    
    // _changes:
    Send(server, @"GET", @"/db/_changes", 200,
         $dict({@"last_seq", $object(5)},
               {@"results", $array($dict({@"id", @"doc3"},
                                         {@"changes", $array($dict({@"rev", revID3}))},
                                         {@"seq", $object(3)}),
                                   $dict({@"id", @"doc2"},
                                         {@"changes", $array($dict({@"rev", revID2}))},
                                         {@"seq", $object(4)}),
                                   $dict({@"id", @"doc1"},
                                         {@"changes", $array($dict({@"rev", revID}))},
                                         {@"seq", $object(5)},
                                         {@"deleted", $true}))}));
    
    // _changes with ?since:
    Send(server, @"GET", @"/db/_changes?since=4", 200,
         $dict({@"last_seq", $object(5)},
               {@"results", $array($dict({@"id", @"doc1"},
                                         {@"changes", $array($dict({@"rev", revID}))},
                                         {@"seq", $object(5)},
                                         {@"deleted", $true}))}));
    Send(server, @"GET", @"/db/_changes?since=5", 200,
         $dict({@"last_seq", $object(5)},
               {@"results", $array()}));
    [server close];
}


TestCase(TDRouter_LocalDocs) {
    RequireTestCase(TDDatabase_LocalDocs);
    RequireTestCase(TDRouter_Docs);
    // PUT a local doc:
    TDDatabaseManager* server = createDBManager();
    Send(server, @"PUT", @"/db", 201, nil);
    NSDictionary* result = SendBody(server, @"PUT", @"/db/_local/doc1", $dict({@"message", @"hello"}), 
                                    201, nil);
    NSString* revID = [result objectForKey: @"rev"];
    CAssert([revID hasPrefix: @"1-"]);
    
    // GET it:
    Send(server, @"GET", @"/db/_local/doc1", 200,
         $dict({@"_id", @"_local/doc1"},
               {@"_rev", revID},
               {@"message", @"hello"}));

    // Local doc should not appear in _changes feed:
    Send(server, @"GET", @"/db/_changes", 200,
         $dict({@"last_seq", $object(0)},
               {@"results", $array()}));
    [server close];
}


TestCase(TDRouter_AllDocs) {
    // PUT:
    TDDatabaseManager* server = createDBManager();
    Send(server, @"PUT", @"/db", 201, nil);
    
    NSDictionary* result;
    result = SendBody(server, @"PUT", @"/db/doc1", $dict({@"message", @"hello"}), 201, nil);
    NSString* revID = [result objectForKey: @"rev"];
    result = SendBody(server, @"PUT", @"/db/doc3", $dict({@"message", @"bonjour"}), 201, nil);
    NSString* revID3 = [result objectForKey: @"rev"];
    result = SendBody(server, @"PUT", @"/db/doc2", $dict({@"message", @"guten tag"}), 201, nil);
    NSString* revID2 = [result objectForKey: @"rev"];
    
    // _all_docs:
    result = Send(server, @"GET", @"/db/_all_docs", 200, nil);
    CAssertEqual([result objectForKey: @"total_rows"], $object(3));
    CAssertEqual([result objectForKey: @"offset"], $object(0));
    NSArray* rows = [result objectForKey: @"rows"];
    CAssertEqual(rows, $array($dict({@"id",  @"doc1"}, {@"key", @"doc1"},
                                    {@"value", $dict({@"rev", revID})}),
                              $dict({@"id",  @"doc2"}, {@"key", @"doc2"},
                                    {@"value", $dict({@"rev", revID2})}),
                              $dict({@"id",  @"doc3"}, {@"key", @"doc3"},
                                    {@"value", $dict({@"rev", revID3})})
                              ));
    
    // ?include_docs:
    result = Send(server, @"GET", @"/db/_all_docs?include_docs=true", 200, nil);
    CAssertEqual([result objectForKey: @"total_rows"], $object(3));
    CAssertEqual([result objectForKey: @"offset"], $object(0));
    rows = [result objectForKey: @"rows"];
    CAssertEqual(rows, $array($dict({@"id",  @"doc1"}, {@"key", @"doc1"},
                                    {@"value", $dict({@"rev", revID})},
                                    {@"doc", $dict({@"message", @"hello"},
                                                   {@"_id", @"doc1"}, {@"_rev", revID} )}),
                              $dict({@"id",  @"doc2"}, {@"key", @"doc2"},
                                    {@"value", $dict({@"rev", revID2})},
                                    {@"doc", $dict({@"message", @"guten tag"},
                                                   {@"_id", @"doc2"}, {@"_rev", revID2} )}),
                              $dict({@"id",  @"doc3"}, {@"key", @"doc3"},
                                    {@"value", $dict({@"rev", revID3})},
                                    {@"doc", $dict({@"message", @"bonjour"},
                                                   {@"_id", @"doc3"}, {@"_rev", revID3} )})
                              ));
    [server close];
}


TestCase(TDRouter_Views) {
    // PUT:
    TDDatabaseManager* server = createDBManager();
    Send(server, @"PUT", @"/db", 201, nil);
    
    SendBody(server, @"PUT", @"/db/doc1", $dict({@"message", @"hello"}), 201, nil);
    SendBody(server, @"PUT", @"/db/doc3", $dict({@"message", @"bonjour"}), 201, nil);
    SendBody(server, @"PUT", @"/db/doc2", $dict({@"message", @"guten tag"}), 201, nil);
    
    TDDatabase* db = [server databaseNamed: @"db"];
    TDView* view = [db viewNamed: @"design/view"];
    [view setMapBlock: ^(NSDictionary* doc, TDMapEmitBlock emit) {
        if ([doc objectForKey: @"message"])
            emit([doc objectForKey: @"message"], nil);
    } reduceBlock: NULL version: @"1"];

    // Query the view and check the result:
    Send(server, @"GET", @"/db/_design/design/_view/view", 200,
         $dict({@"offset", $object(0)},
               {@"rows", $array($dict({@"id", @"doc3"}, {@"key", @"bonjour"}),
                                $dict({@"id", @"doc2"}, {@"key", @"guten tag"}),
                                $dict({@"id", @"doc1"}, {@"key", @"hello"}) )},
               {@"total_rows", $object(3)}));
    
    // Check the ETag:
    TDResponse* response = SendRequest(server, @"GET", @"/db/_design/design/_view/view", nil, nil);
    NSString* etag = [response.headers objectForKey: @"Etag"];
    CAssertEqual(etag, $sprintf(@"\"%lld\"", view.lastSequenceIndexed));
    
    // Try a conditional GET:
    response = SendRequest(server, @"GET", @"/db/_design/design/_view/view",
                           $dict({@"If-None-Match", etag}), nil);
    CAssertEq(response.status, 304);

    // Update the database:
    SendBody(server, @"PUT", @"/db/doc4", $dict({@"message", @"aloha"}), 201, nil);
    
    // Try a conditional GET:
    response = SendRequest(server, @"GET", @"/db/_design/design/_view/view",
                           $dict({@"If-None-Match", etag}), nil);
    CAssertEq(response.status, 200);
    CAssertEqual([ParseJSONResponse(response) objectForKey: @"total_rows"], $object(4));
    [server close];
}


TestCase(TDRouter_ContinuousChanges) {
    TDDatabaseManager* server = createDBManager();
    Send(server, @"PUT", @"/db", 201, nil);

    SendBody(server, @"PUT", @"/db/doc1", $dict({@"message", @"hello"}), 201, nil);

    __block TDResponse* response = nil;
    __block NSMutableData* body = [NSMutableData data];
    __block BOOL finished = NO;
    
    NSURL* url = [NSURL URLWithString: @"touchdb:///db/_changes?feed=continuous"];
    NSURLRequest* request = [NSURLRequest requestWithURL: url];
    TDRouter* router = [[TDRouter alloc] initWithDatabaseManager: server request: request];
    router.onResponseReady = ^(TDResponse* routerResponse) {
        CAssert(!response);
        response = routerResponse;
    };
    router.onDataAvailable = ^(NSData* content, BOOL finished) {
        [body appendData: content];
    };
    router.onFinished = ^{
        CAssert(!finished);
        finished = YES;
    };
    
    // Start:
    [router start];
    
    // Should initially have a response and one line of output:
    CAssert(response != nil);
    CAssertEq(response.status, 200);
    CAssert(body.length > 0);
    CAssert(!finished);
    [body setLength: 0];
    
    // Now make a change to the database:
    SendBody(server, @"PUT", @"/db/doc2", $dict({@"message", @"hej"}), 201, nil);

    // Should now have received additional output from the router:
    CAssert(body.length > 0);
    CAssert(!finished);
    
    [router stop];
    [router release];
    [server close];
}


TestCase(TDRouter_GetAttachment) {
    TDDatabaseManager* server = createDBManager();
    Send(server, @"PUT", @"/db", 201, nil);

    // Create a document with an attachment:
    NSData* attach1 = [@"This is the body of attach1" dataUsingEncoding: NSUTF8StringEncoding];
    NSString* base64 = [TDBase64 encode: attach1];
    NSData* attach2 = [@"This is the body of path/to/attachment" dataUsingEncoding: NSUTF8StringEncoding];
    NSString* base642 = [TDBase64 encode: attach2];
    NSDictionary* attachmentDict = $dict({@"attach", $dict({@"content_type", @"text/plain"},
                                                           {@"data", base64})},
                                         {@"path/to/attachment",
                                                     $dict({@"content_type", @"text/plain"},
                                                           {@"data", base642})});
    NSDictionary* props = $dict({@"message", @"hello"},
                                {@"_attachments", attachmentDict});

    NSDictionary* result = SendBody(server, @"PUT", @"/db/doc1", props, 201, nil);
    NSString* revID = [result objectForKey: @"rev"];
    
    // Now get the attachment via its URL:
    TDResponse* response = SendRequest(server, @"GET", @"/db/doc1/attach", nil, nil);
    CAssertEq(response.status, 200);
    CAssertEqual(response.body.asJSON, attach1);
    CAssertEqual([response.headers objectForKey: @"Content-Type"], @"text/plain");
    NSString* eTag = [response.headers objectForKey: @"Etag"];
    CAssert(eTag.length > 0);
    
    // Ditto the 2nd attachment, whose name contains "/"s:
    response = SendRequest(server, @"GET", @"/db/doc1/path/to/attachment", nil, nil);
    CAssertEq(response.status, 200);
    CAssertEqual(response.body.asJSON, attach2);
    CAssertEqual([response.headers objectForKey: @"Content-Type"], @"text/plain");
    eTag = [response.headers objectForKey: @"Etag"];
    CAssert(eTag.length > 0);
    
    // A nonexistent attachment should result in a 404:
    response = SendRequest(server, @"GET", @"/db/doc1/bogus", nil, nil);
    CAssertEq(response.status, 404);
    
    response = SendRequest(server, @"GET", @"/db/missingdoc/bogus", nil, nil);
    CAssertEq(response.status, 404);
    
    // Get the document with attachment data:
    response = SendRequest(server, @"GET", @"/db/doc1?attachments=true", nil, nil);
    CAssertEq(response.status, 200);
    CAssertEqual([response.body.properties objectForKey: @"_attachments"],
                 $dict({@"attach", $dict({@"data", [TDBase64 encode: attach1]}, 
                                        {@"content_type", @"text/plain"},
                                        {@"length", $object(attach1.length)},
                                        {@"digest", @"sha1-gOHUOBmIMoDCrMuGyaLWzf1hQTE="},
                                         {@"revpos", $object(1)})},
                       {@"path/to/attachment", $dict({@"data", [TDBase64 encode: attach2]}, 
                                         {@"content_type", @"text/plain"},
                                         {@"length", $object(attach2.length)},
                                         {@"digest", @"sha1-IrXQo0jpePvuKPv5nswnenqsIMc="},
                                         {@"revpos", $object(1)})}));

    // Update the document but not the attachments:
    attachmentDict = $dict({@"attach", $dict({@"content_type", @"text/plain"},
                                             {@"stub", $true})},
                           {@"path/to/attachment",
                               $dict({@"content_type", @"text/plain"},
                                     {@"stub", $true})});
    props = $dict({@"_rev", revID},
                  {@"message", @"aloha"},
                  {@"_attachments", attachmentDict});
    result = SendBody(server, @"PUT", @"/db/doc1", props, 201, nil);
    revID = [result objectForKey: @"rev"];
    
    // Get the doc with attachments modified since rev #1:
    NSString* path = $sprintf(@"/db/doc1?attachments=true&atts_since=[%%22%@%%22]", revID);
    Send(server, @"GET", path, 200, 
         $dict({@"_id", @"doc1"}, {@"_rev", revID}, {@"message", @"aloha"},
               {@"_attachments", $dict({@"attach", $dict({@"stub", $true}, 
                                                         {@"content_type", @"text/plain"},
                                                         {@"length", $object(attach1.length)},
                                                         {@"digest", @"sha1-gOHUOBmIMoDCrMuGyaLWzf1hQTE="},
                                                         {@"revpos", $object(1)})},
                                       {@"path/to/attachment", $dict({@"stub", $true}, 
                                                                     {@"content_type", @"text/plain"},
                                                                     {@"length", $object(attach2.length)},
                                                                     {@"digest", @"sha1-IrXQo0jpePvuKPv5nswnenqsIMc="},
                                                                     {@"revpos", $object(1)})})}));
    [server close];
}


TestCase(TDRouter_OpenRevs) {
    RequireTestCase(TDRouter_Databases);
    // PUT:
    TDDatabaseManager* server = createDBManager();
    Send(server, @"PUT", @"/db", 201, nil);
    NSDictionary* result = SendBody(server, @"PUT", @"/db/doc1", $dict({@"message", @"hello"}), 
                                    201, nil);
    NSString* revID1 = [result objectForKey: @"rev"];
    
    // PUT to update:
    result = SendBody(server, @"PUT", @"/db/doc1",
                      $dict({@"message", @"goodbye"}, {@"_rev", revID1}), 
                      201, nil);
    NSString* revID2 = [result objectForKey: @"rev"];
    
    Send(server, @"GET", @"/db/doc1?open_revs=all", 200,
         $array( $dict({@"ok", $dict({@"_id", @"doc1"},
                                     {@"_rev", revID2},
                                     {@"message", @"goodbye"})}) ));
    Send(server, @"GET", $sprintf(@"/db/doc1?open_revs=[%%22%@%%22,%%22%@%%22]", revID1, revID2), 200,
         $array($dict({@"ok", $dict({@"_id", @"doc1"},
                                    {@"_rev", revID1},
                                    {@"message", @"hello"})}),
                $dict({@"ok", $dict({@"_id", @"doc1"},
                                    {@"_rev", revID2},
                                    {@"message", @"goodbye"})})
                ));
    Send(server, @"GET", $sprintf(@"/db/doc1?open_revs=[%%22%@%%22,%%22%@%%22]", revID1, @"bogus"), 200,
         $array($dict({@"ok", $dict({@"_id", @"doc1"},
                                    {@"_rev", revID1},
                                    {@"message", @"hello"})}),
                $dict({@"missing", @"bogus"})
                ));
    [server close];
}


TestCase(TDRouter_RevsDiff) {
    RequireTestCase(TDRouter_Databases);
    TDDatabaseManager* server = createDBManager();
    Send(server, @"PUT", @"/db", 201, nil);
    NSDictionary* doc1r1 = SendBody(server, @"PUT", @"/db/11111", $dict(), 201,nil);
    NSString* doc1r1ID = [doc1r1 objectForKey: @"rev"];
    NSDictionary* doc2r1 = SendBody(server, @"PUT", @"/db/22222", $dict(), 201,nil);
    NSString* doc2r1ID = [doc2r1 objectForKey: @"rev"];
    NSDictionary* doc3r1 = SendBody(server, @"PUT", @"/db/33333", $dict(), 201,nil);
    NSString* doc3r1ID = [doc3r1 objectForKey: @"rev"];
    
    NSDictionary* doc1r2 = SendBody(server, @"PUT", @"/db/11111", $dict({@"_rev", doc1r1ID}), 201,nil);
    NSString* doc1r2ID = [doc1r2 objectForKey: @"rev"];
    SendBody(server, @"PUT", @"/db/22222", $dict({@"_rev", doc2r1ID}), 201,nil);

    SendBody(server, @"PUT", @"/db/11111", $dict({@"_rev", doc1r2ID}), 201,nil);
    
    SendBody(server, @"POST", @"/db/_revs_diff",
             $dict({@"11111", $array(doc1r2ID, @"3-foo")},
                   {@"22222", $array(doc2r1ID)},
                   {@"33333", $array(@"10-bar")},
                   {@"99999", $array(@"6-six")}),
             200,
             $dict({@"11111", $dict({@"missing", $array(@"3-foo")},
                                    {@"possible_ancestors", $array(doc1r1ID, doc1r2ID)})},
                   {@"33333", $dict({@"missing", $array(@"10-bar")},
                                    {@"possible_ancestors", $array(doc3r1ID)})},
                   {@"99999", $dict({@"missing", $array(@"6-six")})}
                   ));
    [server close];
}


TestCase(TDRouter) {
    RequireTestCase(TDRouter_Server);
    RequireTestCase(TDRouter_Databases);
    RequireTestCase(TDRouter_Docs);
    RequireTestCase(TDRouter_AllDocs);
    RequireTestCase(TDRouter_ContinuousChanges);
    RequireTestCase(TDRouter_GetAttachment);
    RequireTestCase(TDRouter_RevsDiff);
}

#endif
