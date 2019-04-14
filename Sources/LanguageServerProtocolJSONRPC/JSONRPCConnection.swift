//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SKSupport
import LanguageServerProtocol
import Dispatch
import Foundation
import NIO
import NIOExtras
import NIOFoundationCompat

/// `JSONRPCConnectionBridge` parses the incoming messages and bridges into the remaining system
final class JSONRPCConnectionBridge: ChannelDuplexHandler {
  /// The input from the `Channel` is a `Data` that corresponds exactly to one encoded message
  typealias InboundIn = Data
  /// On the outbound side, we receive a tuple of the `Message` to send alongside optionally the expected `ResponseType`
  /// as well as a promise for the result.
  typealias OutboundIn = (Message, (ResponseType.Type, EventLoopPromise<LSPResult<Any>>)?)
  /// We emit `Message`s that will then be encoded by `ContentLengthHeaderFrameEncoder`
  typealias OutboundOut = Message

  struct OutstandingRequest {
    var promise: EventLoopPromise<LSPResult<Any>>
    var responseType: ResponseType.Type
  }

  init(messageHandler: @escaping (Message) -> Void,
       errorHandler: @escaping (Error) -> Void,
       handlerQueue: DispatchQueue) {
    self.messageHandler = messageHandler
    self.handlerQueue = handlerQueue
    self.errorHandler = errorHandler
  }

  let messageHandler: (Message) -> Void
  let errorHandler: (Error) -> Void
  let handlerQueue: DispatchQueue
  let jsonDecoder = JSONDecoder()
  var outstandingRequests: [RequestID: OutstandingRequest] = [:]

  /// Called when we're added to the pipeline. All we have to do is to setup the `JSONEncoder`
  func handlerAdded(context: ChannelHandlerContext) {
    // Setup callback for response type.
    self.jsonDecoder.userInfo[.responseTypeCallbackKey] = { id in
      // this must be from the event loop (called when encoding the messages)
      context.eventLoop.preconditionInEventLoop()
      guard let outstanding = self.outstandingRequests[id] else {
        log("Unknown request for \(id)", level: .error)
        return nil
      }
      return outstanding.responseType
    } as Message.ResponseTypeCallback
  }

  /// Called whenever a encoded message is received through the `ChannelPipeline`. The framing has been taken care of
  /// we just need to decode.
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let data = self.unwrapInboundIn(data)
    do {
      let message = try self.jsonDecoder.decode(Message.self, from: data)
      let response: (value: LSPResult<Any>, requestID: RequestID)?
      switch message {
      case .errorResponse(let error, id: let id):
        response = (.failure(error), id)
      case .response(let value, id: let id):
        response = (.success(value), id)
      default:
        response = nil
      }

      if let response = response, let outstandingMessage = self.outstandingRequests[response.requestID] {
        self.outstandingRequests.removeValue(forKey: response.requestID)
        outstandingMessage.promise.succeed(response.value)
      }

      self.handlerQueue.async {
        self.messageHandler(message)
      }
    } catch {
      self.errorCaught(context: context, error: error)
    }
  }

  /// Called when we receive a write. We mostly forward to the encoder.
  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    let (message, extraInfo) = self.unwrapOutboundIn(data)
    if case .request(_, id: let reqID) = message {
      precondition(self.outstandingRequests[reqID] == nil)
      self.outstandingRequests[reqID] = OutstandingRequest(promise: extraInfo!.1, responseType: extraInfo!.0)
    }
    context.write(self.wrapOutboundOut(message), promise: promise)
  }

  /// Called when the `Channel` becomes inactive (received EOF or closed)
  func channelInactive(context: ChannelHandlerContext) {
    let outstandingRequests = self.outstandingRequests
    self.outstandingRequests.removeAll()
    // fail all outstanding requests
    outstandingRequests.forEach { _, outstandingRequest in
      outstandingRequest.promise.succeed(.failure(ResponseError.cancelled))
    }
  }

  /// This is called whenever there's an error received, anywhere in the pipline. This is pretty much all the error
  /// handling we have to do.
  func errorCaught(context: ChannelHandlerContext, error: Error) {
    // certain errors are special because we can handle them
    if let error = error as? MessageDecodingError {
      switch error.code {
      case .invalidParams, .methodNotFound:
        // these two errors are non-fatal, we don't tell the errorHandler and we don't close the channel.
        switch error.messageKind {
        case .request:
          if let id = error.id {
            // write an error response.
            context.writeAndFlush(self.wrapOutboundOut(Message.errorResponse(ResponseError(error), id: id)),
                                  promise: nil)
          }
        case .response:
          if let id = error.id {
            self.outstandingRequests[id] = nil
          }

        default:
          ()
        }
        return
      default:
        ()
      }
    }
    self.handlerQueue.async {
      // let the error handler know
      self.errorHandler(error)
    }

    // and close the connection. All errors that aren't handled above are fatal, so let's close the connection.
    context.close(promise: nil)
  }

}

/// A connection between a message handler (e.g. language server) in the same process as the connection object and a remote message handler (e.g. language client) that may run in another process using JSON RPC messages sent over a pair of in/out file descriptors.
///
/// For example, inside a language server, the `JSONRPCConnection` takes the language service implemenation as its `receiveHandler` and itself provides the client connection for sending notifications and callbacks.
public final class JSONRPCConection {
  var channel: Channel? = nil
  let socketFD: CInt
  let group: EventLoopGroup

  var receiveHandler: MessageHandler? = nil
  let queue: DispatchQueue = DispatchQueue(label: "jsonrpc-queue", qos: .userInitiated)

  enum State {
    case created, running, closed
  }

  /// Current state of the connection, used to ensure correct usage.
  var state: State

  /// Buffer of received bytes that haven't been parsed.
  var requestBuffer: [UInt8] = []

  private var _nextRequestID: Int = 1000


  var closeHandler: () -> Void

  public init(socketFD: CInt, closeHandler: @escaping () -> Void = {}) {
    self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    self.socketFD = socketFD
    state = .created
    self.closeHandler = closeHandler
  }

  deinit {
    assert(state == .closed)
  }

  /// Start processing `inFD` and send messages to `receiveHandler`.
  ///
  /// - parameter receiveHandler: The message handler to invoke for requests received on the `inFD`.
  public func start(receiveHandler: MessageHandler) {
    precondition(state == .created)
    state = .running
    self.receiveHandler = receiveHandler

    self.channel = try! ClientBootstrap(group: self.group)
      .channelOption(ChannelOptions.allowRemoteHalfClosure, value: false)
      .channelInitializer { channel -> EventLoopFuture<Void> in
        channel.pipeline.addHandlers([ByteToMessageHandler(ContentLengthHeaderFrameDecoder()),
                                      //DebugInboundEventsHandler(),
                                      ContentLengthHeaderFrameEncoder(),
                                      JSONRPCConnectionBridge(messageHandler: self.handle,
                                                              errorHandler: { (error) in
                                                                log("IO error \(type(of: error))", level: .error)
                                      },
                                                              handlerQueue: self.queue)])
      }
      .withConnectedSocket(descriptor: self.socketFD).wait()
  }

  /// Whether we can send messages in the current state.
  ///
  /// - parameter shouldLog: Whether to log an info message if not ready.
  func readyToSend(shouldLog: Bool = true) -> Bool {
    precondition(state != .created, "tried to send message before calling start(messageHandler:)")
    let ready = state == .running
    if shouldLog && !ready {
      log("ignoring message; state = \(state)")
    }
    return ready
  }

  /// Handle a single message by dispatching it to `receiveHandler` or an appropriate reply handler.
  func handle(_ message: Message) {
    switch message {
    case .notification(let notification):
      notification._handle(receiveHandler!, connection: self)
    case .request(let request, id: let id):
      request._handle(receiveHandler!, id: id, connection: self)
    case .response, .errorResponse:
      ()
    }
  }

  func send(messageData: Message, extraInfo: (ResponseType.Type, EventLoopPromise<LSPResult<Any>>)? = nil) {
    if let channel = self.channel {
      channel.writeAndFlush((messageData, extraInfo)).whenFailure { error in
        switch error {
        case ChannelError.ioOnClosedChannel:
          extraInfo?.1.succeed(.failure(ResponseError.cancelled))
        default:
          extraInfo?.1.succeed(.failure(ResponseError.unknown("\(error)")))
        }
      }
    }
  }

  /// Close the connection.
  public func close() {
    guard state == .running else { return }

    log("\(JSONRPCConection.self): closing...")
    state = .closed
    do {
      try self.channel!.close().wait()
    } catch ChannelError.alreadyClosed {
      () // that's okay
    } catch {
      fatalError("could not close channel: \(error)")
    }
    receiveHandler = nil // break retain cycle
    closeHandler()
  }

  /// Request id for the next outgoing request.
  func nextRequestID() -> RequestID {
    _nextRequestID += 1
    return .number(_nextRequestID)
  }

}

extension JSONRPCConection: _IndirectConnection {
  // MARK: Connection interface

  public func send<Notification>(_ notification: Notification) where Notification: NotificationType {
    self.send(messageData: .notification(notification))
  }

  public func send<Request: RequestType>(_ request: Request,
                                         queue: DispatchQueue,
                                         reply: @escaping (LSPResult<Request.Response>) -> Void) -> RequestID {
    let id: RequestID = self.queue.sync {
      self.nextRequestID()
    }
    guard let channel = self.channel else {
      queue.async {
        reply(.failure(.cancelled))
      }
      return id
    }
    let promise = channel.eventLoop.makePromise(of: LSPResult<Any>.self)
    promise.futureResult.recover { error in
      fatalError("error: \(error)")
    }
    .whenSuccess { anyResult in
      queue.async {
        reply(anyResult.map { $0 as! Request.Response })
      }
    }

    self.send(messageData: Message.request(request, id: id), extraInfo: (Request.Response.self, promise))
    return id
  }

  public func sendReply<Response>(_ response: LSPResult<Response>, id: RequestID) where Response: ResponseType {
    switch response {
    case .success(let result):
      self.send(messageData: Message.response(result, id: id))
    case .failure(let error):
      self.send(messageData: Message.errorResponse(error, id: id))
    }
  }
}
