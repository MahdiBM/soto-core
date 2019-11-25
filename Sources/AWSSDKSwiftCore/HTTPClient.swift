//
//  HTTPClient.swift
//  AWSSDKSwiftCore
//
//  Created by Joseph Mehdi Smith on 4/21/18.
//
// Informed by the Swift NIO
// [`testSimpleGet`](https://github.com/apple/swift-nio/blob/a4318d5e752f0e11638c0271f9c613e177c3bab8/Tests/NIOHTTP1Tests/HTTPServerClientTest.swift#L348)
// and heavily built off Vapor's HTTP client library,
// [`HTTPClient`](https://github.com/vapor/http/blob/2cb664097006e3fda625934079b51c90438947e1/Sources/HTTP/Responder/HTTPClient.swift)

import NIO
import NIOHTTP1
import NIOOpenSSL
import NIOFoundationCompat
import Foundation

private class HTTPClientResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClient.Response

    private enum HTTPClientState {
        /// Waiting to parse the next response.
        case ready
        /// Currently parsing the response's body.
        case parsingBody(HTTPResponseHead, Data?)
    }
    
    private var receiveds: [HTTPClientResponsePart] = []
    private var state: HTTPClientState = .ready
    private var promise: EventLoopPromise<HTTPClient.Response>

    public init(promise: EventLoopPromise<HTTPClient.Response>) {
        self.promise = promise
    }

    func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        promise.fail(error: error)
        ctx.fireErrorCaught(error)
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            switch state {
            case .ready: state = .parsingBody(head, nil)
            case .parsingBody: promise.fail(error: HTTPClient.HTTPError.malformedHead)
            }
        case .body(var body):
            switch state {
            case .ready: promise.fail(error: HTTPClient.HTTPError.malformedBody)
            case .parsingBody(let head, let existingData):
                let data: Data
                if var existing = existingData {
                    existing += body.readData(length: body.readableBytes) ?? Data()
                    data = existing
                } else {
                    data = body.readData(length: body.readableBytes) ?? Data()
                }
                state = .parsingBody(head, data)
            }
        case .end(let tailHeaders):
            assert(tailHeaders == nil, "Unexpected tail headers")
            switch state {
            case .ready: promise.fail(error: HTTPClient.HTTPError.malformedHead)
            case .parsingBody(let head, let data):
                let res = HTTPClient.Response(head: head, body: data ?? Data())
                if ctx.channel.isActive {
                    ctx.fireChannelRead(wrapOutboundOut(res))
                }
                promise.succeed(result: res)
                state = .ready
            }
        }
    }
}

/// HTTP Client class providing API for sending HTTP requests
public final class HTTPClient {
    
    /// Request structure to send
    public struct Request {
        var head: HTTPRequestHead
        var body: Data = Data()
    }
    
    /// Response structure received back
    public struct Response {
        let head: HTTPResponseHead
        let body: Data
        
        public func contentType() -> String? {
            return head.headers.filter { $0.name.lowercased() == "content-type" }.first?.value
        }
    }
    
    /// Errors returned from HTTPClient when parsing responses
    public enum HTTPError: Error {
        case malformedHead, malformedBody, malformedURL
    }
    
    private let hostname: String
    private let headerHostname: String
    private let port: Int
    private let eventGroup: EventLoopGroup

    public init(url: URL,
                eventGroup: EventLoopGroup) throws {
        guard let scheme = url.scheme else {
            throw HTTPClient.HTTPError.malformedURL
        }
        guard let hostname = url.host else {
            throw HTTPClient.HTTPError.malformedURL
        }
        
        self.hostname = hostname
        
        if let port = url.port {
            self.port = port
            self.headerHostname = "\(hostname):\(port)"
        } else {
            let isSecure = (scheme == "https")
            self.port = isSecure ? 443 : 80
            self.headerHostname = hostname
        }

        self.eventGroup = eventGroup
    }

    public init(hostname: String,
                port: Int,
                eventGroup: EventLoopGroup) {
        self.headerHostname = hostname
        self.hostname = String(hostname.split(separator:":")[0])
        self.port = port
        self.eventGroup = eventGroup
    }

    public func connect(_ request: Request) -> EventLoopFuture<Response> {
        var head = request.head
        let body = request.body

        head.headers.replaceOrAdd(name: "Host", value: headerHostname)
        head.headers.replaceOrAdd(name: "User-Agent", value: "AWS SDK Swift Core")
        head.headers.replaceOrAdd(name: "Accept", value: "*/*")
        head.headers.replaceOrAdd(name: "Content-Length", value: body.count.description)

        // TODO implement Keep-alive
        head.headers.replaceOrAdd(name: "Connection", value: "Close")

        var preHandlers = [ChannelHandler]()
        if (port == 443) {
            do {
                let tlsConfiguration = TLSConfiguration.forClient()
                let sslContext = try SSLContext(configuration: tlsConfiguration)
                let tlsHandler = try OpenSSLClientHandler(context: sslContext, serverHostname: hostname)
                preHandlers.append(tlsHandler)
            } catch {
                print("Unable to setup TLS: \(error)")
            }
        }
        let response: EventLoopPromise<Response> = eventGroup.next().newPromise()

        _ = ClientBootstrap(group: eventGroup)
            .connectTimeout(TimeAmount.seconds(5))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelInitializer { channel in
                let accumulation = HTTPClientResponseHandler(promise: response)
                let results = preHandlers.map { channel.pipeline.add(handler: $0) }
                return EventLoopFuture<Void>.andAll(results, eventLoop: channel.eventLoop).then {
                    channel.pipeline.addHTTPClientHandlers().then {
                        channel.pipeline.add(handler: accumulation)
                    }
                }
            }
            .connect(host: hostname, port: port)
            .then { channel -> EventLoopFuture<Void> in
                channel.write(NIOAny(HTTPClientRequestPart.head(head)), promise: nil)
                var buffer = ByteBufferAllocator().buffer(capacity: body.count)
                buffer.write(bytes: body)
                channel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer))), promise: nil)
                return channel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)))
            }
            .whenFailure { error in
                response.fail(error: error)
        }
        return response.futureResult
    }
}
