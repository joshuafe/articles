//
//  CarPlaySceneDelegate.swift
//  FrictionlessNotes
//
//  CarPlay scene: a capture button for the car. It shares the live CaptureStore
//  with the phone app, so a thought spoken at the wheel flows through the same
//  brain (Stage-1 ANE guess + Gemma) and lands in the same ledger.
//
//  CarPlay is gated by an Apple-granted entitlement and only activates when
//  connected to CarPlay or the CarPlay Simulator — the scene stays inert during
//  a normal phone launch, so this is safe to ship before the entitlement lands.
//

import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private let controller = CarPlayController()

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        controller.connect(interfaceController)
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        controller.disconnect()
    }
}

/// Builds the CarPlay UI: a list of recent captures plus a mic button that
/// records a new thought into the shared CaptureStore.
@MainActor
final class CarPlayController {

    private let store = CaptureStore.shared
    private weak var interfaceController: CPInterfaceController?
    private let listTemplate = CPListTemplate(title: "Frictionless", sections: [])
    private var capturing = false

    func connect(_ ic: CPInterfaceController) {
        interfaceController = ic
        updateCaptureButton()
        refreshList()
        ic.setRootTemplate(listTemplate, animated: false, completion: nil)
        observeCaptures()
    }

    func disconnect() { interfaceController = nil }

    // MARK: Capture button — tap to start, tap to stop

    private func updateCaptureButton() {
        let symbol = capturing ? "stop.circle.fill" : "mic.fill"
        let button = CPBarButton(image: UIImage(systemName: symbol) ?? UIImage()) { [weak self] _ in
            self?.toggleCapture()
        }
        listTemplate.trailingNavigationBarButtons = [button]
    }

    private func toggleCapture() {
        capturing.toggle()
        updateCaptureButton()
        if capturing {
            Task { await store.carPlayBeginCapture() }
        } else {
            Task {
                await store.carPlayEndCapture()
                refreshList()
            }
        }
    }

    // MARK: Recent-captures list

    private func refreshList() {
        let rows = store.captures.prefix(10).map { capture -> CPListItem in
            let category = capture.category ?? capture.provisionalCategory
            let item = CPListItem(text: capture.ledgerLine,
                                  detailText: category?.rawValue ?? capture.status.label)
            item.handler = { _, completion in completion() }
            return item
        }
        listTemplate.updateSections([CPListSection(items: Array(rows))])
    }

    /// Keep the car's list in step with the ledger as captures file.
    private func observeCaptures() {
        withObservationTracking {
            _ = store.captures
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshList()
                self.observeCaptures()   // re-arm for the next change
            }
        }
    }
}
