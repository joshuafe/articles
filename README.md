# Reminder Board

This repository contains everything needed to run a Siri-triggered reminder capture flow that transcribes your voice with OpenAI and pushes the text to a minimalist web display designed for an always-on iPad.

## Repository layout

```
.
├── ios/ReminderBoard/            # SwiftUI app distributed as a SwiftPM iOS application
├── server/                       # FastAPI backend that stores reminders and serves the board UI
└── README.md                     # This file
```

## iOS app

The iOS target lives under `ios/ReminderBoard` and is defined as a Swift Package Manager iOS application. It uses:

- **Siri shortcuts** via `CaptureReminderIntent` so you can say “Hey Siri, capture reminder in Reminder Board”.
- **AVFoundation** to record raw audio in-app.
- **OpenAI’s transcription endpoint** (`gpt-4o-mini-transcribe`) to convert audio to text.
- **A configurable uploader** that POSTs the text to the backend service.

### Configure secrets

1. Open the package in Xcode (`File` → `Open Package...` and select `ios/ReminderBoard`).
2. Add your OpenAI API key to the generated app target Info.plist by setting `OpenAIAPIKey` to your secret value. When using the SwiftPM app template you can also edit the `infoPlist` dictionary in `Package.swift` to inline the value during development (do **not** commit production keys).
3. Update `ReminderUploader.Configuration.live.baseURL` in `ReminderUploader.swift` so it points at the machine running the FastAPI service (e.g. `http://192.168.1.42:8000`). If you want to require an API key, create a `server/API_KEY.txt` file and add the same value to the app so it can send it as the `X-API-Key` header.

### Running in the simulator/device

Because the project is SPM-based you can build and run from Xcode 15+: open the package and select the `ReminderBoard` scheme. The first run will request microphone permissions. The main screen has a large record button and shows the last reminder pushed to the board.

## Backend service

The backend is a lightweight FastAPI service that stores reminders in a JSON file and serves the minimalist board UI.

### Setup

```bash
cd server
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn server.main:app --host 0.0.0.0 --port 8000 --reload
```

The service writes reminders to `server/data/reminders.json`. To protect the endpoint, optionally place an API key in `server/API_KEY.txt`; the iOS app will include it automatically if you set `ReminderUploader.Configuration.live.apiKey`.

### API surface

- `GET /reminders` returns the stored reminders (newest last).
- `POST /reminders` accepts `{ "text": "Buy milk", "created_at": "2024-05-21T23:45:00Z" }`.
- `GET /` serves the high-contrast wall display.

## Wall display

The `server/static/index.html` page is styled for legibility from a distance: large white text on a black background with subtle timestamps. Point the always-on iPad to the FastAPI server’s root URL (for example `http://192.168.1.42:8000/`). The page automatically refreshes every 30 seconds.

## Siri setup

After installing the iOS app, open Settings → Siri & Search → Shortcuts and add the “Capture reminder” shortcut that the app exposes. You can then trigger it hands-free: *“Hey Siri, capture reminder in Reminder Board”*. The app launches, starts recording, sends audio to OpenAI, and updates the board once the transcription returns.

## Development notes

- The OpenAI request uses multipart/form-data and targets `gpt-4o-mini-transcribe`. You can change the model name in `OpenAITranscriptionService` if you prefer a different transcription model.
- The board retains the most recent 32 reminders; adjust `ReminderStore(max_items=...)` if you need a larger history.
- For local testing without the OpenAI call you can swap in the preview mode by instantiating `ReminderCaptureCoordinator(preview: true)` inside `ReminderBoardApp`.
