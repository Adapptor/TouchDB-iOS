//
//  TDMisc.h
//  TouchDB
//
//  Created by Jens Alfke on 1/13/12.
//  Copyright (c) 2012 Couchbase, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "TDRevision.h"

extern NSString* const TDHTTPErrorDomain;

NSString* TDHexString( const uint8_t* bytes, size_t length, bool lowercase);

NSString* TDCreateUUID( void );

NSString* TDHexSHA1Digest( NSData* input );

NSError* TDHTTPError( int status, NSURL* url );

NSComparisonResult TDSequenceCompare( SequenceNumber a, SequenceNumber b);

/** Escapes a document or revision ID for use in a URL.
    This does the usual %-escaping, but makes sure that '/' is escaped in case the ID appears in the path portion of the URL, and that '&' is escaped in case the ID appears in a query value. */
NSString* TDEscapeID( NSString* param );

/** Escapes a string to be used as the value of a query parameter in a URL.
    This does the usual %-escaping, but makes sure that '&' is also escaped. */
NSString* TDEscapeURLParam( NSString* param );

/** Wraps a string in double-quotes and prepends backslashes to any existing double-quote or backslash characters in it. */
NSString* TDQuoteString( NSString* param );

/** Undoes effect of TDQuoteString, i.e. removes backslash escapes and any surrounding double-quotes.
    If the string has no surrounding double-quotes it will be returned as-is. */
NSString* TDUnquoteString( NSString* param );

/** Returns YES if this error appears to be due to the computer being offline or the remote host being unreachable. */
BOOL TDIsOfflineError( NSError* error );
