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

@testable import LanguageServerProtocolJSONRPC
import LanguageServerProtocol
import XCTest

import NIO

final class MessageFrameEncodingTests: XCTestCase {
    private var channel: EmbeddedChannel! // not a real network connection

    override func setUp() {
        self.channel = EmbeddedChannel()

        // let's add the framing handler to the pipeline as that's what we're testing here.
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(ContentLengthHeaderFrameEncoder()).wait())
        // let's also add the decoder so we can round-trip
        XCTAssertNoThrow(try self.channel.pipeline.addHandler(ByteToMessageHandler(ContentLengthHeaderFrameDecoder())).wait())
        // this pretends to connect the channel to this IP address.
        XCTAssertNoThrow(self.channel.connect(to: try .init(ipAddress: "1.2.3.4", port: 5678)))
    }

    override func tearDown() {
        if self.channel.isActive {
            // this makes sure that the channel is clean (no errors, no left-overs in the channel, etc)
            XCTAssertNoThrow(XCTAssertTrue(try self.channel.finish().isClean))
        }
        self.channel = nil
    }

    func testBasicMessage() {
        let r = InitializeRequest(
            processId: nil,
            rootPath: nil,
            rootURL: nil,
            initializationOptions: nil,
            capabilities: ClientCapabilities(workspace: nil, textDocument: nil),
            trace: .off,
            workspaceFolders: nil)
        XCTAssertNoThrow(try self.channel.writeOutbound(Message.request(r, id: .number(1231231231))))
        XCTAssertNoThrow(try {
            if let encoded = try self.channel.readOutbound(as: ByteBuffer.self) {
                XCTAssertTrue(encoded.readableBytesView.starts(with: "Content-Length: ".utf8))
                // round trip it back
                try self.channel.writeInbound(encoded)
            } else {
                XCTFail("no message was encoded")
            }
        }())
        XCTAssertNotNil(XCTAssertTrue(try (self.channel.readInbound(as: Data.self)?.starts(with: "{".utf8))!))
    }
}
