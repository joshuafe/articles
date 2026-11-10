import CarPlay
import Combine

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var viewModel: CarPlayVoiceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController, to window: CPWindow) {
        self.interfaceController = interfaceController
        let voiceController = CarPlayVoiceController()
        voiceController.delegate = self
        viewModel = voiceController

        interfaceController.setRootTemplate(voiceController.makeTemplate(), animated: true)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnect interfaceController: CPInterfaceController, from window: CPWindow) {
        self.interfaceController = nil
        viewModel = nil
    }
}

extension CarPlaySceneDelegate: CarPlayVoiceControllerDelegate {
    func carPlayVoiceControllerRequestsDismissal(_ controller: CarPlayVoiceController) {
        interfaceController?.popTemplate(animated: true)
    }
}
