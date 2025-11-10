import CarPlay
import Combine
import Speech

protocol CarPlayVoiceControllerDelegate: AnyObject {
    func carPlayVoiceControllerRequestsDismissal(_ controller: CarPlayVoiceController)
}

final class CarPlayVoiceController: NSObject {
    weak var delegate: CarPlayVoiceControllerDelegate?

    private let speechService: SpeechCaptureServicing
    private let syncCoordinator: SyncCoordinating
    private var cancellables = Set<AnyCancellable>()

    override init() {
        let repository = TaskRepository()
        let deskSyncService = DailyDeskSyncService()
        let syncCoordinator = SyncCoordinator(repository: repository, openAIService: OpenAIService(), deskSyncService: deskSyncService)
        self.speechService = SpeechCaptureService()
        self.syncCoordinator = syncCoordinator
        super.init()
        syncCoordinator.initialize()
        bind()
    }

    func makeTemplate() -> CPTemplate {
        let listeningState = CPVoiceControlState(identifier: "listen", titleVariants: ["Listening"], image: nil, repeats: false)
        let template = CPVoiceControlTemplate(voiceControlStates: [listeningState])
        template.startHandler = { [weak self] _ in
            self?.speechService.startRecording()
        }
        template.stopHandler = { [weak self] _ in
            guard let self else { return }
            self.speechService.stopRecording()
            self.delegate?.carPlayVoiceControllerRequestsDismissal(self)
        }
        return template
    }

    private func bind() {
        speechService.capturedTaskPublisher
            .sink { [weak self] task in
                self?.syncCoordinator.enqueue(task: task)
            }
            .store(in: &cancellables)
    }
}
