//
//  Endpointer.swift
//  FrictionlessNotes
//
//  Stop is a physical signal, not a silence guess (DESIGN.md v3.1).
//  Round 1: MockEndpointer driven by the debug bar.
//  Round 3: MotionEndpointer fuses VAD + CMDeviceMotion attitude + proximity/lock —
//  disposal = sustained ≥ ~70° attitude change while VAD-silent; rotation during
//  speech is ignored; silence cap ~3 min.
//

import Foundation

@MainActor
protocol Endpointer: AnyObject {
    var signals: AsyncStream<EndpointSignal> { get }
}

@MainActor
final class MockEndpointer: Endpointer {
    let signals: AsyncStream<EndpointSignal>
    private let cont: AsyncStream<EndpointSignal>.Continuation

    init() {
        (signals, cont) = AsyncStream.makeStream(of: EndpointSignal.self)
    }

    func send(_ signal: EndpointSignal) {
        cont.yield(signal)
    }
}

@MainActor
protocol MacReachability: AnyObject {
    var status: AsyncStream<MacStatus> { get }
    func set(_ status: MacStatus)
}

@MainActor
final class MockMacReachability: MacReachability {
    let status: AsyncStream<MacStatus>
    private let cont: AsyncStream<MacStatus>.Continuation

    init() {
        (status, cont) = AsyncStream.makeStream(of: MacStatus.self)
        cont.yield(.online(lastActiveMinutes: 0))
    }

    func set(_ s: MacStatus) {
        cont.yield(s)
    }
}
