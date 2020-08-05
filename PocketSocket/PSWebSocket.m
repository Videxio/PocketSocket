//  Copyright 2014-Present Zwopple Limited
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

#import "PSWebSocket.h"
#import "PSWebSocketInternal.h"
#import "PSWebSocketDriver.h"
#import "PSWebSocketBuffer.h"
#import <sys/socket.h>
#import <arpa/inet.h>


@interface PSWebSocket() <NSStreamDelegate, PSWebSocketDriverDelegate> {
    PSWebSocketMode _mode;
    NSMutableURLRequest *_request;
    dispatch_queue_t _workQueue;
    PSWebSocketDriver *_driver;
    PSWebSocketBuffer *_inputBuffer;
    PSWebSocketBuffer *_outputBuffer;
    NSInputStream *_inputStream;
    NSOutputStream *_outputStream;
    PSWebSocketReadyState _readyState;
    BOOL _secure;
    BOOL _negotiatedSSL;
    BOOL _opened;
    BOOL _closeWhenFinishedOutput;
    BOOL _sentClose;
    BOOL _failed;
    BOOL _pumpingInput;
    BOOL _pumpingOutput;
    BOOL _inputPaused;
    BOOL _outputPaused;
    NSInteger _closeCode;
    NSString *_closeReason;
    NSMutableArray *_pingHandlers;
}
@end
@implementation PSWebSocket

#pragma mark - Class Methods

+ (BOOL)isWebSocketRequest:(NSURLRequest *)request {
    return [PSWebSocketDriver isWebSocketRequest:request];
}

#pragma mark - Properties

- (PSWebSocketReadyState)readyState {
    __block PSWebSocketReadyState value = 0;
    [self executeWorkAndWait:^{
        value = self->_readyState;
    }];
    return value;
}

- (NSData* )remoteAddress {
    return PSPeerAddressOfInputStream(_inputStream);
}

- (NSString* )remoteHost {
    return PSPeerHostOfInputStream(_inputStream);
}

@synthesize inputPaused = _inputPaused, outputPaused = _outputPaused;

- (BOOL)isInputPaused {
    __block BOOL result;
    [self executeWorkAndWait:^{
        result = self->_inputPaused;
    }];
    return result;
}
- (void)setInputPaused:(BOOL)inputPaused {
    [self executeWorkAndWait:^{
        if (inputPaused != self->_inputPaused) {
            self->_inputPaused = inputPaused;
            if (!inputPaused) {
                [self pumpInput];
            }
        }
    }];
}

- (BOOL)isOutputPaused {
    __block BOOL result;
    [self executeWorkAndWait:^{
        result = self->_outputPaused;
    }];
    return result;
}
- (void)setOutputPaused:(BOOL)outputPaused {
    [self executeWorkAndWait:^{
        if (outputPaused != self->_outputPaused) {
            self->_outputPaused = outputPaused;
            if (!outputPaused) {
                [self pumpOutput];
            }
        }
    }];
}

#pragma mark - Initialization

- (instancetype)initWithMode:(PSWebSocketMode)mode request:(NSURLRequest *)request {
    if((self = [super init])) {
        _mode = mode;
        _request = [request mutableCopy];
        _readyState = PSWebSocketReadyStateConnecting;
        NSString* name = [NSString stringWithFormat: @"PSWebSocket <%@>", request.URL];
        _workQueue = dispatch_queue_create(name.UTF8String, nil);
        if(_mode == PSWebSocketModeClient) {
            _driver = [PSWebSocketDriver clientDriverWithRequest:_request];
        } else {
            _driver = [PSWebSocketDriver serverDriverWithRequest:_request];
        }
        _driver.delegate = self;
        _secure = ([_request.URL.scheme hasPrefix:@"https"] || [_request.URL.scheme hasPrefix:@"wss"]);
        _negotiatedSSL = YES;
        _opened = NO;
        _closeWhenFinishedOutput = NO;
        _sentClose = NO;
        _failed = NO;
        _pumpingInput = NO;
        _pumpingOutput = NO;
        _closeCode = 0;
        _closeReason = nil;
        _pingHandlers = [NSMutableArray array];
        _inputBuffer = [[PSWebSocketBuffer alloc] init];
        _outputBuffer = [[PSWebSocketBuffer alloc] init];
        if(_request.HTTPBody.length > 0) {
            [_inputBuffer appendData:_request.HTTPBody];
            _request.HTTPBody = nil;
        }
    }
    return self;
}

+ (instancetype)clientSocketWithRequest:(NSURLRequest *)request {
    return [[self alloc] initClientSocketWithRequest:request];
}
- (instancetype)initClientSocketWithRequest:(NSURLRequest *)request {
    if((self = [self initWithMode:PSWebSocketModeClient request:request])) {
        NSURL *URL = request.URL;
        NSString *host = URL.host;
        UInt32 port = (UInt32)request.URL.port.integerValue;
        if(port == 0) {
            port = (_secure) ? 443 : 80;
        }
        
        CFReadStreamRef readStream = nil;
        CFWriteStreamRef writeStream = nil;
        CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault,
                                           (__bridge CFStringRef)host,
                                           port,
                                           &readStream,
                                           &writeStream);
        NSAssert(readStream && writeStream, @"Failed to create streams for client socket");

        NSString *networkServiceType = nil;

        switch (request.networkServiceType) {
        case NSURLNetworkServiceTypeDefault:
        case NSURLNetworkServiceTypeCallSignaling:
            break;
        case NSURLNetworkServiceTypeBackground:
            networkServiceType = NSStreamNetworkServiceTypeBackground;
            break;
        case NSURLNetworkServiceTypeVoice:
            networkServiceType = NSStreamNetworkServiceTypeVoice;
            break;
        case NSURLNetworkServiceTypeVideo:
            networkServiceType = NSStreamNetworkServiceTypeVideo;
            break;
        default:
            break;
        }
        
        _inputStream = CFBridgingRelease(readStream);
        _outputStream = CFBridgingRelease(writeStream);
        
        if (networkServiceType != nil) {
            [_inputStream setProperty:networkServiceType forKey:NSStreamNetworkServiceType];
            [_outputStream setProperty:networkServiceType forKey:NSStreamNetworkServiceType];
        }
    }
    return self;
}

+ (instancetype)serverSocketWithRequest:(NSURLRequest *)request inputStream:(NSInputStream *)inputStream outputStream:(NSOutputStream *)outputStream {
    return [[self alloc] initServerWithRequest:request inputStream:inputStream outputStream:outputStream];
}
- (instancetype)initServerWithRequest:(NSURLRequest *)request inputStream:(NSInputStream *)inputStream outputStream:(NSOutputStream *)outputStream {
    if((self = [self initWithMode:PSWebSocketModeServer request:request])) {
        _inputStream = inputStream;
        _outputStream = outputStream;
    }
    return self;
}

#pragma mark - Actions

- (void)open {
    __weak typeof(self) weakSelf = self;
    [self executeWork:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;

        if(strongSelf->_opened || strongSelf->_readyState != PSWebSocketReadyStateConnecting) {
            [NSException raise:@"Invalid State" format:@"You cannot open a PSWebSocket more than once."];
            return;
        }
        
        strongSelf->_opened = YES;
        
        // connect
        [strongSelf connect];
    }];
}
- (void)send:(id)message {
    NSParameterAssert(message);
    __weak typeof(self) weakSelf = self;
    [self executeWork:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;

        if(!strongSelf->_opened || strongSelf->_readyState == PSWebSocketReadyStateConnecting) {
            [NSException raise:@"Invalid State" format:@"You cannot send a PSWebSocket messages before it is finished opening."];
            return;
        }
        
        if([message isKindOfClass:[NSString class]]) {
            [strongSelf->_driver sendText:message];
        } else if([message isKindOfClass:[NSData class]]) {
            [strongSelf->_driver sendBinary:message];
        } else {
            [NSException raise:@"Invalid Message" format:@"Messages must be instances of NSString or NSData"];
        }
    }];
}
- (void)ping:(NSData *)pingData handler:(void (^)(NSData *pongData))handler {
    __weak typeof(self) weakSelf = self;
    [self executeWork:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;

        if(handler) {
            [strongSelf->_pingHandlers addObject:handler];
        }
        [strongSelf->_driver sendPing:pingData];
    }];
}
- (void)close {
    [self closeWithCode:1000 reason:nil];
}
- (void)closeWithCode:(NSInteger)code reason:(NSString *)reason {
    __weak typeof(self) weakSelf = self;
    [self executeWork:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;

        // already closing so lets exit
        if(strongSelf->_readyState >= PSWebSocketReadyStateClosing) {
            return;
        }
        
        BOOL connecting = (strongSelf->_readyState == PSWebSocketReadyStateConnecting);
        strongSelf->_readyState = PSWebSocketReadyStateClosing;
        
        // send close code if we're not connecting
        if(!connecting) {
            strongSelf->_closeCode = code;
            [strongSelf->_driver sendCloseCode:code reason:reason];
        }
        
        // disconnect gracefully
        [strongSelf disconnectGracefully];
        
        // disconnect hard in 30 seconds
        dispatch_after(dispatch_walltime(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakSelf executeWork:^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (strongSelf2 == nil) return;

                if(strongSelf2->_readyState >= PSWebSocketReadyStateClosed) {
                    return;
                }
                [strongSelf2 disconnect];
            }];
        });
    }];
}

#pragma mark - Stream Properties

- (CFTypeRef)copyStreamPropertyForKey:(NSString *)key {
    __block CFTypeRef result;
    [self executeWorkAndWait:^{
        result = CFWriteStreamCopyProperty((__bridge CFWriteStreamRef)self->_outputStream, (__bridge CFStringRef)key);
    }];
    return result;
}
- (void)setStreamProperty:(CFTypeRef)property forKey:(NSString *)key {
    [self executeWorkAndWait:^{
        if(self->_opened || self->_readyState != PSWebSocketReadyStateConnecting) {
            [NSException raise:@"Invalid State" format:@"You cannot set stream properties on a PSWebSocket once it is opened."];
            return;
        }
        CFWriteStreamSetProperty((__bridge CFWriteStreamRef)self->_outputStream, (__bridge CFStringRef)key, (CFTypeRef)property);
    }];
}

#pragma mark - Connection

- (void)connect {
    if(_secure && _mode == PSWebSocketModeClient) {
        
        __block BOOL customTrustEvaluation = NO;
        [self executeDelegateAndWait:^{
            customTrustEvaluation = [self->_delegate respondsToSelector:@selector(webSocket:evaluateServerTrust:)];
        }];
        
        NSMutableDictionary *ssl = [NSMutableDictionary dictionary];
        ssl[(__bridge id)kCFStreamSSLLevel] = (__bridge id)kCFStreamSocketSecurityLevelNegotiatedSSL;
        ssl[(__bridge id)kCFStreamSSLValidatesCertificateChain] = @(!customTrustEvaluation);
        ssl[(__bridge id)kCFStreamSSLIsServer] = @NO;
        
        _negotiatedSSL = !customTrustEvaluation;
        [_inputStream setProperty:ssl forKey:(__bridge id)kCFStreamPropertySSLSettings];
    }

    // delegate
    _inputStream.delegate = self;
    _outputStream.delegate = self;
    
    // driver
    [_driver start];
    
    // schedule streams
    CFReadStreamSetDispatchQueue((__bridge CFReadStreamRef)_inputStream, _workQueue);
    CFWriteStreamSetDispatchQueue((__bridge CFWriteStreamRef)_outputStream, _workQueue);

    // open streams
    if(_inputStream.streamStatus == NSStreamStatusNotOpen) {
        [_inputStream open];
    }
    if(_outputStream.streamStatus == NSStreamStatusNotOpen) {
        [_outputStream open];
    }
    
    // pump
    [self pumpInput];
    [self pumpOutput];
    
    // prepare timeout
    if(_request.timeoutInterval > 0.0) {
        __weak typeof(self)weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_request.timeoutInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf)strongSelf = weakSelf;
            if(strongSelf) {
                [strongSelf executeWork:^{
                    if(strongSelf->_readyState == PSWebSocketReadyStateConnecting) {
                        [strongSelf failWithCode:PSWebSocketErrorCodeTimedOut reason:@"Timed out."];
                    }
                }];
            }
        });
    }
}
- (void)disconnectGracefully {
    _closeWhenFinishedOutput = YES;
    [self pumpOutput];
}
- (void)disconnect {
    _inputStream.delegate = nil;
    _outputStream.delegate = nil;
    
    [_inputStream close];
    [_outputStream close];
    
    _inputStream = nil;
    _outputStream = nil;
}

#pragma mark - SSL

- (void)negotiateSSL:(NSStream *)stream {
    if (_negotiatedSSL) {
        return;
    }
    
    SecTrustRef trust = (__bridge SecTrustRef)[stream propertyForKey:(__bridge id)kCFStreamPropertySSLPeerTrust];
    BOOL accept = [self askDelegateToEvaluateServerTrust:trust];
    if(accept) {
        _negotiatedSSL = YES;
        [self pumpOutput];
        [self pumpInput];
    } else {
        _negotiatedSSL = NO;
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                             code:NSURLErrorServerCertificateUntrusted
                                         userInfo:@{NSURLErrorFailingURLErrorKey: _request.URL}];
        [self failWithError:error];
    }
}

#pragma mark - Pumping

- (void)pumpInput {
    if(_readyState >= PSWebSocketReadyStateClosing ||
       _pumpingInput ||
       _inputPaused ||
       !_inputStream.hasBytesAvailable) {
        return;
    }

    _pumpingInput = YES;
    @autoreleasepool {
        uint8_t chunkBuffer[4096];
        NSInteger readLength = [_inputStream read:chunkBuffer maxLength:sizeof(chunkBuffer)];
        if(readLength > 0) {
            if(!_inputBuffer.hasBytesAvailable) {
                NSUInteger consumedLength = [_driver execute:chunkBuffer maxLength:(NSUInteger)readLength];
                if(consumedLength < readLength) {
                    NSUInteger offset = MAX(0, consumedLength);
                    NSInteger remaining = readLength - (NSInteger)offset;
                    [_inputBuffer appendBytes:chunkBuffer + offset length:(NSUInteger)remaining];
                }
            } else {
                [_inputBuffer appendBytes:chunkBuffer length:(NSUInteger)readLength];
            }
        } else if(readLength < 0) {
            [self failWithError:_inputStream.streamError];
        }

        while(_inputBuffer.hasBytesAvailable) {
            readLength = (NSInteger)[_driver execute:_inputBuffer.mutableBytes maxLength:_inputBuffer.bytesAvailable];
            if(readLength <= 0) {
                break;
            }
            _inputBuffer.offset += readLength;
        }

        [_inputBuffer compact];
        
        if(_readyState == PSWebSocketReadyStateOpen &&
           !_inputStream.hasBytesAvailable &&
           !_inputBuffer.hasBytesAvailable) {
            [self notifyDelegateDidFlushInput];
        }
    }
    _pumpingInput = NO;
}

- (void)pumpOutput {
    if(_pumpingInput ||
       _outputPaused) {
        return;
    }
    
    _pumpingOutput = YES;
    do {
        while(_outputStream.hasSpaceAvailable && _outputBuffer.hasBytesAvailable) {
            NSInteger writeLength = [_outputStream write:_outputBuffer.bytes maxLength:_outputBuffer.bytesAvailable];
            if(writeLength <= -1) {
                _failed = YES;
                [self disconnect];
                NSString *reason = @"Failed to write to output stream";
                NSError *error = [PSWebSocketDriver errorWithCode:PSWebSocketErrorCodeConnectionFailed reason:reason];
                [self notifyDelegateDidFailWithError:error];
                return;
            }
            _outputBuffer.offset += writeLength;
        }
        if(_closeWhenFinishedOutput &&
           !_outputBuffer.hasBytesAvailable &&
           (_inputStream.streamStatus != NSStreamStatusNotOpen &&
            _inputStream.streamStatus != NSStreamStatusClosed) &&
           !_sentClose) {
            _sentClose = YES;
            
            [self disconnect];
            
            if(!_failed) {
                [self notifyDelegateDidCloseWithCode:_closeCode reason:_closeReason wasClean:YES];
            }
        }
        
        [_outputBuffer compact];

        if(_readyState == PSWebSocketReadyStateOpen &&
           _outputStream.hasSpaceAvailable &&
           !_outputBuffer.hasBytesAvailable) {
            [self notifyDelegateDidFlushOutput];
        }
        
    } while (_outputStream.hasSpaceAvailable && _outputBuffer.hasBytesAvailable);
    _pumpingOutput = NO;
}

#pragma mark - Failing

- (void)failWithCode:(NSInteger)code reason:(NSString *)reason {
    [self failWithError:[PSWebSocketDriver errorWithCode:code reason:reason]];
}
- (void)failWithError:(NSError *)error {
    __weak typeof(self) weakSelf = self;
    if(error.code == PSWebSocketStatusCodeProtocolError && [error.domain isEqualToString:PSWebSocketErrorDomain]) {
        [self executeDelegate:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) return;

            strongSelf->_closeCode = error.code;
            strongSelf->_closeReason = error.localizedDescription;
            [strongSelf closeWithCode:strongSelf->_closeCode reason:strongSelf->_closeReason];
            [strongSelf executeWork:^{
                [weakSelf disconnectGracefully];
            }];
        }];
    } else {
        [self executeWork:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) return;

            if(strongSelf->_readyState != PSWebSocketReadyStateClosed) {
                strongSelf->_failed = YES;
                strongSelf->_readyState = PSWebSocketReadyStateClosed;
                [strongSelf notifyDelegateDidFailWithError:error];
                [strongSelf disconnectGracefully];
            }
        }];
    }
}

#pragma mark - PSWebSocketDriverDelegate

- (void)driverDidOpen:(PSWebSocketDriver *)driver {
    if(_readyState != PSWebSocketReadyStateConnecting) {
        [NSException raise:@"Invalid State" format:@"Ready state must be connecting to become open"];
        return;
    }
    _readyState = PSWebSocketReadyStateOpen;
    [self notifyDelegateDidOpen];
    [self pumpInput];
    [self pumpOutput];
}
- (void)driver:(PSWebSocketDriver *)driver didFailWithError:(NSError *)error {
    [self failWithError:error];
}
- (void)driver:(PSWebSocketDriver *)driver didCloseWithCode:(NSInteger)code reason:(NSString *)reason {
    _closeCode = code;
    _closeReason = reason;
    if(_readyState == PSWebSocketReadyStateOpen) {
        [self closeWithCode:1000 reason:nil];
    }
    [self executeWork:^{
        [self disconnectGracefully];
    }];
}
- (void)driver:(PSWebSocketDriver *)driver didReceiveMessage:(id)message {
    [self notifyDelegateDidReceiveMessage:message];
}
- (void)driver:(PSWebSocketDriver *)driver didReceivePing:(NSData *)ping {
    [self executeDelegate:^{
        [self executeWork:^{
            [driver sendPong:ping];
        }];
    }];
}
- (void)driver:(PSWebSocketDriver *)driver didReceivePong:(NSData *)pong {
    void (^handler)(NSData *pong) = [_pingHandlers firstObject];
    if(handler) {
        [self executeDelegate:^{
            handler(pong);
        }];
        [_pingHandlers removeObjectAtIndex:0];
    }
}
- (void)driver:(PSWebSocketDriver *)driver write:(NSData *)data {
    if(_closeWhenFinishedOutput) {
        return;
    }
    [_outputBuffer appendData:data];
    [self pumpOutput];
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
    // This is invoked on the work queue.
    switch(event) {
        case NSStreamEventOpenCompleted: {
            if(_mode != PSWebSocketModeClient) {
                [NSException raise:@"Invalid State" format:@"Server mode should have already opened streams."];
                return;
            }
            if(_readyState >= PSWebSocketReadyStateClosing) {
                return;
            }
            [self pumpOutput];
            [self pumpInput];
            break;
        }
        case NSStreamEventErrorOccurred: {
            [self failWithError:stream.streamError];
            [_inputBuffer reset];
            break;
        }
        case NSStreamEventEndEncountered: {
            [self pumpInput];
            if(stream.streamError) {
                [self failWithError:stream.streamError];
            } else {
                _readyState = PSWebSocketReadyStateClosed;
                if(!_sentClose && !_failed) {
                    _failed = YES;
                    [self disconnect];
                    NSString *reason = [NSString stringWithFormat:@"%@ stream end encountered", (stream == _inputStream) ? @"Input" : @"Output"];
                    NSError *error = [PSWebSocketDriver errorWithCode:PSWebSocketErrorCodeConnectionFailed reason:reason];
                    [self notifyDelegateDidFailWithError:error];
                }
            }
            break;
        }
        case NSStreamEventHasBytesAvailable: {
            if (!_negotiatedSSL) {
                [self negotiateSSL:stream];
            } else {
                [self pumpInput];
            }
            break;
        }
        case NSStreamEventHasSpaceAvailable: {
            if (!_negotiatedSSL) {
                [self negotiateSSL:stream];
            } else {
                [self pumpOutput];
            }
            break;
        }
        default:
            break;
    }
}

#pragma mark - Delegation

- (void)notifyDelegateDidOpen {
    __weak typeof(self) weakSelf = self;
    [self executeDelegate:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;

        [strongSelf->_delegate webSocketDidOpen:strongSelf];
    }];
}
- (void)notifyDelegateDidReceiveMessage:(id)message {
    __weak typeof(self) weakSelf = self;
    [self executeDelegate:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;

        [strongSelf->_delegate webSocket:strongSelf didReceiveMessage:message];
    }];
}
- (void)notifyDelegateDidFailWithError:(NSError *)error {
    __weak typeof(self) weakSelf = self;
    [self executeDelegate:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;

        [strongSelf->_delegate webSocket:strongSelf didFailWithError:error];
    }];
}
- (void)notifyDelegateDidCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    __weak typeof(self) weakSelf = self;
    [self executeDelegate:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;

        [strongSelf->_delegate webSocket:strongSelf didCloseWithCode:code reason:reason wasClean:wasClean];
    }];
}
- (void)notifyDelegateDidFlushInput {
    __weak typeof(self) weakSelf = self;
    [self executeDelegate:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;

        if ([strongSelf->_delegate respondsToSelector:@selector(webSocketDidFlushInput:)]) {
            [strongSelf->_delegate webSocketDidFlushInput:strongSelf];
        }
    }];
}
- (void)notifyDelegateDidFlushOutput {
    __weak typeof(self) weakSelf = self;
    [self executeDelegate:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;

        if ([strongSelf->_delegate respondsToSelector:@selector(webSocketDidFlushOutput:)]) {
            [strongSelf->_delegate webSocketDidFlushOutput:strongSelf];
        }
    }];
}
- (BOOL)askDelegateToEvaluateServerTrust:(SecTrustRef)trust {
    __block BOOL result = NO;
    [self executeDelegateAndWait:^{
        if ([self->_delegate respondsToSelector:@selector(webSocket:evaluateServerTrust:)]) {
            result = [self->_delegate webSocket:self evaluateServerTrust:trust];
        }
    }];
    return result;
}

#pragma mark - Queueing

- (void)executeWork:(void (^)(void))work {
    NSParameterAssert(work);
    dispatch_async(_workQueue, work);
}
- (void)executeWorkAndWait:(void (^)(void))work {
    NSParameterAssert(work);
    dispatch_sync(_workQueue, work);
}
- (void)executeDelegate:(void (^)(void))work {
    NSParameterAssert(work);
    dispatch_async((_delegateQueue) ? _delegateQueue : dispatch_get_main_queue(), work);
}
- (void)executeDelegateAndWait:(void (^)(void))work {
    NSParameterAssert(work);
    dispatch_sync((_delegateQueue) ? _delegateQueue : dispatch_get_main_queue(), work);
}

#pragma mark - Dealloc

- (void)dealloc {
    [self disconnect];
}

@end
