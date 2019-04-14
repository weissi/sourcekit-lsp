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
import SKCore
import SPMUtility
import LanguageServerProtocol
import LanguageServerProtocolJSONRPC
import SourceKit
import Darwin
import Foundation

public struct TestSourceKitServer {
  public enum ConnectionKind {
    case local, jsonrpc
  }

  enum ConnectionImpl {
    case local(
      clientConnection: LocalConnection,
      serverConnection: LocalConnection)
    case jsonrpc(
      clientEnd: CInt,
      serverEnd: CInt,
      clientConnection: JSONRPCConection,
      serverConnection: JSONRPCConection)
  }

  public static let buildSetup: BuildSetup = BuildSetup(configuration: .debug,
                                                        path: nil,
                                                        flags: BuildFlags())

  public let client: TestClient
  let connImpl: ConnectionImpl

  /// The server, if it is in the same process.
  public let server: SourceKitServer?

  public init(connectionKind: ConnectionKind = .local) throws {
     _ = initRequestsOnce

    var socketFDs: [CInt] = [-1, -1]
    let err = socketpair(PF_LOCAL, SOCK_STREAM, 0, &socketFDs)
    guard err == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: .init(errno), userInfo: ["func": "socketpair"])
    }

    switch connectionKind {
      case .local:
        let clientConnection = LocalConnection()
        let serverConnection = LocalConnection()
        client = TestClient(server: serverConnection)
        server = SourceKitServer(client: clientConnection, buildSetup: TestSourceKitServer.buildSetup, onExit: {
          clientConnection.close()
        })

        clientConnection.start(handler: client)
        serverConnection.start(handler: server!)

        connImpl = .local(clientConnection: clientConnection, serverConnection: serverConnection)

      case .jsonrpc:
        let clientConnection = JSONRPCConection(socketFD: socketFDs[0])
        let serverConnection = JSONRPCConection(socketFD: socketFDs[1])

        client = TestClient(server: clientConnection)
        server = SourceKitServer(client: serverConnection, buildSetup: TestSourceKitServer.buildSetup, onExit: {
          serverConnection.close()
        })

        clientConnection.start(receiveHandler: client)
        serverConnection.start(receiveHandler: server!)

        connImpl = .jsonrpc(
          clientEnd: socketFDs[0],
          serverEnd: socketFDs[1],
          clientConnection: clientConnection,
          serverConnection: serverConnection)
    }
  }

  func close() {
    switch connImpl {
      case .local(clientConnection: let cc, serverConnection: let sc):
      cc.close()
      sc.close()

    case .jsonrpc(clientEnd: _, serverEnd: _, clientConnection: let cc, serverConnection: let sc):
      cc.close()
      sc.close()
    }
  }
}
