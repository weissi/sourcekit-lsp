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

import Foundation

import NIO

import LanguageServerProtocol

/// `ContentLengthHeaderFrameEncoder` is responsible for emitting LSP's JSON-RPC wire protocol for one `Message`.
final class ContentLengthHeaderFrameEncoder: ChannelOutboundHandler {
  /// We'll get handed one message through the `Channel` and ...
  typealias OutboundIn = Message
  /// ... will encode it into a `ByteBuffer`.
  typealias OutboundOut = ByteBuffer

  let jsonEncoder = JSONEncoder()
  var scratchBuffer: ByteBuffer!

  func handlerAdded(context: ChannelHandlerContext) {
    self.scratchBuffer = context.channel.allocator.buffer(capacity: 512)
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    let message = self.unwrapOutboundIn(data)
    do {
      // Step 1, encode the message
      let data = try self.jsonEncoder.encode(message)

      // Step 2, reserve enough space in the target buffer
      self.scratchBuffer.reserveCapacity(28 /* Content-Length: ______\r\n\r\n */ + data.count)

      // Clear the target buffer (note, we are re-using it so if we get lucky we don't need to allocate at all.
      self.scratchBuffer.clear()

      // Step 3, write the wire protocol.
      self.scratchBuffer.writeStaticString("Content-Length: ")
      self.scratchBuffer.writeString(String(data.count, radix: 10))
      self.scratchBuffer.writeStaticString("\r\n\r\n")
      self.scratchBuffer.writeBytes(data)

      // Step 4, send it through the `Channel`.
      context.write(self.wrapOutboundOut(self.scratchBuffer), promise: promise)
    } catch {
      // if anything goes wrong, tell the `Channel` and fail the write promise.
      context.fireErrorCaught(error)
      promise?.fail(error)
    }
  }
}

/// `ContentLengthHeaderFrameDecoder`'s only responsibility is to implement LSP's JSON-RPC framing. It does no decoding.
struct ContentLengthHeaderFrameDecoder: ByteToMessageDecoder {
  /// We're emitting one `Data` corresponding exactly to one full payload, no headers etc.
  typealias InboundOut = Data

  /// `ContentLengthHeaderFrameDecoder` is a simple state machine.
  enum State {
    /// either we're waiting for the end of the header block or a new header field, ...
    case waitingForHeaderNameOrHeaderBlockEnd
    /// ... or for a header value, or ...
    case waitingForHeaderValue(name: String)
    /// ... or for the payload of a given size.
    case waitingForPayload(length: Int)
  }

  // We start waiting for a header field (or the end of a header block).
  private var state: State = .waitingForHeaderNameOrHeaderBlockEnd
  private var payloadLength: Int? = nil

  // `decode` will be invoked whenever there is more data available (or if we return `.continue`).
  mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
    switch self.state {
    case .waitingForHeaderNameOrHeaderBlockEnd:
      // Given that we're waiting for the end of a header block or a new header field, it's sensible to
      // check if this might be the end of the block.
      if buffer.readableBytesView.starts(with: "\r\n".utf8) {
        buffer.moveReaderIndex(forwardBy: 2) // skip \r\n\r\n
        if let payloadLength = self.payloadLength {
          if payloadLength == 0 {
            // special case, we're not actually waiting for anything if it's 0 bytes...
            self.state = .waitingForHeaderNameOrHeaderBlockEnd
            self.payloadLength = 0
            context.fireChannelRead(self.wrapInboundOut(Data()))
            return .continue
          }
          // cool, let's just shift to the `.waitingForPayload` state and continue.
          self.state = .waitingForPayload(length: payloadLength)
          self.payloadLength = nil
          return .continue
        } else {
          // this happens if we reached the end of the header block but we haven't seen the Content-Length
          // header, that's an error. It will be sent through the `Channel` and decoder won't be called
          // again.
          throw MessageDecodingError.parseError("missing Content-Length header")
        }
      }

      // Given that this is not the end of a header block, it must be a new header field. A new header field
      // must always have a colon (or we don't have enough data).
      if let colonIndex = buffer.readableBytesView.firstIndex(of: UInt8(ascii: ":")) {
        let headerName = buffer.readString(length: colonIndex - buffer.readableBytesView.startIndex)!
        buffer.moveReaderIndex(forwardBy: 1) // skip the colon
        self.state = .waitingForHeaderValue(name: headerName.trimmed().lowercased())
        return .continue
      }

      return .needMoreData
    case .waitingForHeaderValue(name: let headerName):
      // Cool, we're waiting for a header value (ie. we're after the colon).

      // Let's not bother unless we found the whole thing
      guard let newlineIndex = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) else {
        return .needMoreData
      }

      // Is this a header we actually care about?
      if headerName == "content-length" {
        // Yes, let's parse the int.
        let headerValue = buffer.readString(length: newlineIndex - buffer.readableBytesView.startIndex + 1)!
        if let length = UInt32(headerValue.trimmed()) { // anything more than 4GB or negative doesn't make sense
          self.payloadLength = .init(length)
        } else {
          throw MessageDecodingError.parseError("expected integer value in \(headerValue)")
        }
      } else {
        // Nope, let's just skip over it
        buffer.moveReaderIndex(forwardBy: newlineIndex - buffer.readableBytesView.startIndex + 1)
      }

      // but in any case, we're now waiting for a new header or the end of the header block again.
      self.state = .waitingForHeaderNameOrHeaderBlockEnd
      return .continue
    case .waitingForPayload(length: let length):
      // That's the easiest case, let's just wait until we have enough data.
      if let payload = buffer.readData(length: length) {
        // Cool, we got enough data, let's go back waiting for a new header block.
        self.state = .waitingForHeaderNameOrHeaderBlockEnd
        // And send what we found through the pipeline.
        context.fireChannelRead(self.wrapInboundOut(payload))
        return .continue
      } else {
        return .needMoreData
      }
    }
  }

  /// Invoked when the `Channel` is being brough down.
  mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
    // Last chance to decode anything.
    while try self.decode(context: context, buffer: &buffer) == .continue {}

    if buffer.readableBytes > 0 {
      // Oops, there are leftovers that don't form a full message, we could ignore those but it doesn't hurt to send
      // an error.
      throw ByteToMessageDecoderError.leftoverDataWhenDone(buffer)
    }
    return .needMoreData
  }
}

extension String {
  func trimmed() -> Substring {
    var substring = self[...]
    while substring.first.map({ $0.isNewline || $0.isWhitespace }) ?? false {
      substring = substring.dropFirst()
    }
    while substring.last.map({ $0.isNewline || $0.isWhitespace }) ?? false {
      substring = substring.dropLast()
    }
    return substring
  }
}
