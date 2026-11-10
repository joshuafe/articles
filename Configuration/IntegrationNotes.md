# Integration Notes

This repository includes Swift source files for an iOS + CarPlay application (`VoiceTaskAssistant`) and a macOS companion app (`DeskCompanion`).

To assemble the project in Xcode:

1. Create a new *App* project with SwiftUI lifecycle named **VoiceTaskAssistant**.
2. Add an App Group capability (e.g. `group.com.example.voicetaskassistant`) to both the iOS target and the macOS companion target.
3. Enable the following capabilities for the iOS target:
   - Background Modes: Audio, Voice over IP, Background fetch, Remote notifications.
   - Siri.
   - CarPlay Audio or CarPlay Navigation (for voice-first template usage).
4. Add a CarPlay scene configuration with `CarPlaySceneDelegate` as the scene delegate class.
5. Include a Speech Recognition usage description (`NSSpeechRecognitionUsageDescription`) and Microphone usage description (`NSMicrophoneUsageDescription`) in the iOS Info.plist.
6. Store the OpenAI API key securely (e.g. in the Keychain or encrypted config) and expose it at runtime through the `OpenAIAPIKey` Info.plist entry or another secure mechanism used by `OpenAIConfig`.
7. For the macOS companion app, create a separate target and reuse the `DeskCompanion` sources. Set the app group identifier to match the iOS app so that both apps share the `dailySummary.json` handoff file.
8. Optionally configure background tasks to trigger morning desk sync even when the iOS app is suspended.

The `DailyDeskSyncService` writes the processed structured tasks to a JSON file each morning so that the desktop companion can render the planned day without manual refresh.
