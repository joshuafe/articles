# Voice Task Assistant

A native iOS and CarPlay experience powered by the OpenAI API for voice-first task capture and daily planning, accompanied by a macOS desk companion.

## Features

- **Instant voice capture** using the iOS Speech framework and AVAudioEngine for zero-delay transcription.
- **Offline-first storage** of captured tasks so nothing is lost when the device is offline.
- **Automated OpenAI processing** that turns captured speech into structured to-dos with subtasks and reminders.
- **CarPlay voice interface** for hands-free task capture while driving.
- **Minimal, single-action UI** optimized for rapid input.
- **Daily desk sync** via an App Group JSON handoff consumed by the macOS companion app.

## Project structure

```
VoiceTaskAssistant/
  VoiceTaskAssistantApp.swift        // iOS SwiftUI entry point
  ContentView.swift                  // Minimal capture UI
  Models/                            // CapturedTask & StructuredTask definitions
  Services/                          // Speech capture, persistence, OpenAI integration, sync orchestration
  ViewModel/                         // TaskCaptureViewModel bridging UI and services
CarPlayExtension/
  CarPlaySceneDelegate.swift         // Scene bridge into CarPlay
  CarPlayVoiceController.swift       // Voice-only CarPlay experience
DeskCompanion/
  DeskCompanionApp.swift             // macOS SwiftUI entry point
  DeskCompanionContentView.swift     // Daily planning UI
  DeskCompanionViewModel.swift       // Reads shared summaries
Configuration/
  OpenAIConfig.swift                 // API configuration helper
  IntegrationNotes.md                // Xcode integration checklist
```

## OpenAI usage

`OpenAIService` posts captured utterances to the `responses` endpoint with the `gpt-4.1-mini` model and expects a JSON payload describing the structured plan. The response is saved to local storage and included in the daily summary exported for the desktop companion.

## Building in Xcode

Use the guidance in `Configuration/IntegrationNotes.md` to wire the targets, entitlements, and Info.plist keys. The project assumes an App Group identifier of `group.com.example.voicetaskassistant`; update the string where necessary to match your team identifier.
