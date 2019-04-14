//
//  File.swift
//  LanguageServerProtocolJSONRPC
//
//  Created by Johannes Weiss on 13/04/2019.
//

import Darwin
import Foundation

enum IOState {
    case allDone
    case partiallyDone
}

private func readAll(buffer: UnsafeMutableRawBufferPointer,
                     into: inout [Array<UInt8>],
                     tryWriteToFD: CInt,
                     fd: CInt) throws {
    for _ in 0..<5 {
        let nRead = read(fd, buffer.baseAddress, buffer.count)
        if nRead < 0 {
            if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                return
            } else {
                throw NSError(domain: NSPOSIXErrorDomain, code: .init(errno), userInfo: ["func": "read"])
            }
        }
        var startIndex = 0
        if into.count == 0 && nRead != 0 {
            // let's try to short-circuit
            startIndex = try tryWrite(buffer: UnsafeRawBufferPointer(rebasing: buffer[0 ..< nRead]),
                                      fd: tryWriteToFD)
            if startIndex == nRead {
                continue
            }
        }
        if nRead == 0 {
            return
        } else {
            into.append(Array(UnsafeRawBufferPointer(rebasing: buffer[startIndex ..< nRead])))
            if nRead == buffer.count {
                continue
            } else {
                return
            }
        }
    }
}

private func tryWrite(buffer: UnsafeRawBufferPointer, fd: CInt) throws -> size_t {
    var nWritten = write(fd, buffer.baseAddress, buffer.count)
    if nWritten < 0 {
        if errno == EINTR || errno == EAGAIN {
            nWritten = 0
        } else {
            throw NSError(domain: NSPOSIXErrorDomain, code: .init(errno), userInfo: ["func": "write"])
        }
    }
    return nWritten
}

private func writeAll(buffers: inout [Array<UInt8>], fd: CInt) throws -> IOState {
    for idx in buffers.indices {
        let thing = buffers[idx]
        precondition(thing.count > 0)
        let nWritten = try thing.withUnsafeBytes { try tryWrite(buffer: $0, fd: fd) }
        if nWritten < thing.count {
            if nWritten > 0 {
                buffers[idx] = Array(buffers[idx][nWritten ..< buffers[idx].endIndex])
            }
            buffers.removeFirst(idx)
            return .partiallyDone
        }
    }
    buffers.removeAll(keepingCapacity: true)
    return .allDone
}


func withStdInOutSocketAdapter(inFD: CInt, outFD: CInt, _ body: (CInt) throws -> Void) throws -> Never {
    struct WaitingFor: OptionSet {
        var rawValue: UInt8

        static let readSock = WaitingFor(rawValue: 1 << 0)
        static let writeSock = WaitingFor(rawValue: 1 << 1)
        static let readStdin = WaitingFor(rawValue: 1 << 2)
        static let writeStdout = WaitingFor(rawValue: 1 << 3)
    }

    var socketFDs: [CInt] = [-1, -1]
    let err = socketpair(PF_LOCAL, SOCK_STREAM, 0, &socketFDs)
    guard err == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: .init(errno), userInfo: ["func": "socketpair"])
    }

    precondition(fcntl(inFD, F_SETFL, O_NONBLOCK) == 0)
    precondition(fcntl(outFD, F_SETFL, O_NONBLOCK) == 0)
    precondition(fcntl(socketFDs[0], F_SETFL, O_NONBLOCK) == 0)
    precondition(fcntl(socketFDs[1], F_SETFL, O_NONBLOCK) == 0)

    try body(socketFDs[1])

    var waitingFor: WaitingFor = [.readSock, .readStdin]
    var pollFDs: [pollfd] = []
    var toWriteSock: [Array<UInt8>] = []
    var toWriteStdout: [Array<UInt8>] = []
    let buffer: UnsafeMutableRawBufferPointer = .allocate(byteCount: 16384, alignment: 1)
    pollFDs.reserveCapacity(4)
    while true {
        pollFDs.removeAll(keepingCapacity: true)
        if waitingFor.contains(.readStdin) {
            pollFDs.append(.init(fd: inFD, events: .init(POLLIN), revents: 0))
        }
        if waitingFor.contains(.readSock) || waitingFor.contains(.writeSock) {
            var events = waitingFor.contains(.readSock) ? POLLIN : 0
            events |= waitingFor.contains(.writeSock) ? POLLOUT : 0
            pollFDs.append(.init(fd: socketFDs[0], events: .init(events), revents: 0))
        }
        if waitingFor.contains(.writeStdout) {
            pollFDs.append(.init(fd: outFD, events: .init(POLLOUT), revents: 0))
        }
        precondition(waitingFor != .init(rawValue: 0))
        //print("waiting: \(pollFDs)")
        pollFDs.withUnsafeMutableBufferPointer { ptr in
            let err = poll(ptr.baseAddress, .init(ptr.count), 10000000)
            precondition(err > 0 || (err < 0 && errno == EINTR), "err: \(err), errno: \(errno)")
        }
        //print("got    : \(pollFDs)")
        let socketFD = socketFDs[0]
        for pfd in pollFDs {
            if pfd.revents != 0 {
                if pfd.fd == inFD {
                    try readAll(buffer: buffer, into: &toWriteSock, tryWriteToFD: socketFD, fd: inFD)
                    if toWriteSock.count == 0 {
                        waitingFor.formUnion([.readStdin])
                        waitingFor.subtract(.writeSock)
                    } else {
                        waitingFor.subtract(.readStdin)
                        waitingFor.formUnion([.writeSock])
                    }
                }

                if pfd.fd == outFD {
                    switch try writeAll(buffers: &toWriteStdout, fd: outFD) {
                    case .allDone:
                        precondition(toWriteStdout.count == 0)
                        waitingFor.subtract(.writeStdout)
                        waitingFor.formUnion([.readSock])
                    case .partiallyDone:
                        waitingFor.formUnion([.writeStdout])
                        waitingFor.subtract(.readSock)
                    }
                }

                if pfd.fd == socketFD {
                    if CInt(pfd.revents) & POLLIN != 0 {
                        try readAll(buffer: buffer, into: &toWriteStdout, tryWriteToFD: outFD, fd: socketFD)
                        if toWriteStdout.count == 0 {
                            waitingFor.formUnion([.readSock])
                            waitingFor.subtract(.writeStdout)
                        } else {
                            waitingFor.subtract(.readSock)
                            waitingFor.formUnion([.writeStdout])
                        }
                    }
                    if CInt(pfd.revents) & POLLOUT != 0 {
                        switch try writeAll(buffers: &toWriteSock, fd: socketFD) {
                        case .allDone:
                            precondition(toWriteSock.count == 0)
                            waitingFor.subtract(.writeSock)
                            waitingFor.formUnion([.readStdin])
                        case .partiallyDone:
                            waitingFor.subtract(.readStdin)
                            waitingFor.formUnion([.writeSock])
                        }
                    }
                }
            }
        }
    }
}
