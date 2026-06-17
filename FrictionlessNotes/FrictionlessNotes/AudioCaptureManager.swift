//
//  AudioCaptureManager.swift
//  FrictionlessNotes
//
//  Created by Joshua Fein on 12/29/25.
//

import Foundation
import AVFoundation
import Combine
#if os(iOS)
import UIKit
#endif

/// Manages audio recording using AVFoundation
/// Supports background recording, Bluetooth microphones, and file protection
@MainActor
class AudioCaptureManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    /// Indicates whether recording is currently in progress
    @Published var isRecording = false
    
    /// Current recording duration in seconds
    @Published var recordingDuration: TimeInterval = 0
    
    /// Error message if recording fails
    @Published var errorMessage: String?
    
    /// Current microphone permission status
    @Published var microphonePermissionStatus: AVAudioSession.RecordPermission = .undetermined
    
    // MARK: - Private Properties
    private var audioRecorder: AVAudioRecorder?
    private var audioSession: AVAudioSession = AVAudioSession.sharedInstance()
    private var recordingTimer: Timer?
    private var currentRecordingURL: URL?
    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif
    
    // MARK: - Initialization
    override init() {
        super.init()
        microphonePermissionStatus = audioSession.recordPermission
        setupAudioSession()
    }
    
    // MARK: - Permission Handling
    /// Requests microphone permission from the user
    /// AVAudioSession.requestRecordPermission: System API to request microphone access
    /// This shows the iOS permission dialog to the user
    func requestMicrophonePermission() async {
        await audioSession.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.microphonePermissionStatus = self.audioSession.recordPermission
                if !granted {
                    self.errorMessage = "Microphone permission denied. Please enable it in Settings."
                }
            }
        }
    }
    
    /// Checks if microphone permission has been granted
    var hasMicrophonePermission: Bool {
        return audioSession.recordPermission == .granted
    }
    
    // MARK: - Audio Session Setup
    /// Configures the audio session for recording
    /// Uses AVAudioSessionCategoryRecord to enable recording
    /// Sets options to allow Bluetooth and mix with other audio
    private func setupAudioSession() {
        do {
            // AVAudioSession.Category.record: Category for recording audio
            // This category routes audio to the app and silences playback audio
            // This category allows recording even when the app is in the background
            let category = AVAudioSession.Category.record
            
            // AVAudioSession.CategoryOptions:
            // .allowBluetooth: Allows Bluetooth headsets/HFP (Hands-Free Profile) devices to be used as input
            //   This is important for Bluetooth microphones and headsets
            // .defaultToSpeaker: Routes audio to speaker by default when no headphones connected
            //   Note: This option is primarily for playback; for recording, .allowBluetooth is the key option
            let options: AVAudioSession.CategoryOptions = [.allowBluetooth, .defaultToSpeaker]
            
            // AVAudioSession.Mode.default: Standard recording mode
            // The mode affects how the system routes and processes audio
            try audioSession.setCategory(category, mode: .default, options: options)
            
            // Activate the audio session
            // setActive(true): Activates the audio session with the current category and options
            // This must be called before recording can start
            // The session remains active even when the app goes to background (with proper Info.plist setup)
            try audioSession.setActive(true)
        } catch {
            errorMessage = "Failed to setup audio session: \(error.localizedDescription)"
            print("Audio session setup error: \(error)")
        }
    }
    
    // MARK: - Recording Control
    /// Starts audio recording
    /// Creates a file in the Documents directory with file protection
    /// Checks for microphone permission before starting
    func startRecording() async throws {
        // Check microphone permission first
        if !hasMicrophonePermission {
            await requestMicrophonePermission()
            if !hasMicrophonePermission {
                throw AudioCaptureError.microphonePermissionDenied
            }
        }
        
        // Ensure audio session is properly configured
        setupAudioSession()
        
        // Stop any existing recording first
        if isRecording {
            stopRecording()
        }
        
        // Get the Documents directory URL
        // FileManager.default.urls returns an array of URLs for the specified directory
        // .userDomainMask means the user's home directory
        // .documentDirectory is the app's Documents folder (persistent, backed up, user-accessible)
        guard let documentsDirectory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw AudioCaptureError.documentsDirectoryNotFound
        }
        
        // Create a unique filename with timestamp
        let fileName = "recording_\(Date().timeIntervalSince1970).m4a"
        let fileURL = documentsDirectory.appendingPathComponent(fileName)
        currentRecordingURL = fileURL
        
        // Audio settings for recording
        // These settings configure the quality and format of the recorded audio
        let settings: [String: Any] = [
            // AVFormatIDKey: Audio format identifier
            // kAudioFormatMPEG4AAC: Uses AAC (Advanced Audio Coding) format, wrapped in MPEG-4 container (.m4a)
            // AAC provides excellent quality-to-file-size ratio
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            
            // AVSampleRateKey: Number of samples per second
            // 44100.0 Hz is CD quality (standard for high-quality audio)
            AVSampleRateKey: 44100.0,
            
            // AVNumberOfChannelsKey: Number of audio channels
            // 2 = Stereo (left and right channels)
            AVNumberOfChannelsKey: 2,
            
            // AVEncoderAudioQualityKey: Encoding quality level
            // AVAudioQuality.high: High quality encoding (balance between quality and file size)
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        // Create the AVAudioRecorder
        // AVAudioRecorder: Apple's class for recording audio to a file
        // It handles the low-level audio capture and encoding
        audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder?.delegate = self
        
        // Apply file protection BEFORE recording starts
        // FileProtectionType.complete: Strongest file protection available
        // - File is encrypted with a key derived from the user's passcode
        // - File is accessible only when the device is unlocked
        // - Provides data-at-rest encryption for sensitive audio recordings
        // - Files remain encrypted even if device is lost/stolen (until passcode is known)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: fileURL.path
            )
        } catch {
            print("Warning: Failed to set file protection: \(error)")
            // Continue recording even if file protection fails (but log the issue)
        }
        
        // Prepare to record
        // prepareToRecord(): Pre-allocates audio buffers and prepares the file for writing
        // Returns false if preparation fails (e.g., invalid settings, insufficient permissions)
        guard audioRecorder?.prepareToRecord() == true else {
            throw AudioCaptureError.recorderPreparationFailed
        }
        
        // Start recording
        // record(): Begins recording audio to the file
        // Returns false if recording cannot start (e.g., audio session not active)
        // Recording continues even when app goes to background (with proper Info.plist setup)
        guard audioRecorder?.record() == true else {
            throw AudioCaptureError.recordingStartFailed
        }
        
        isRecording = true
        recordingDuration = 0
        errorMessage = nil
        
        // Start a background task to keep the app running in background (iOS only)
        // UIBackgroundTaskIdentifier: Allows app to continue executing for a short time in background
        // This helps ensure recording continues smoothly when app transitions to background
        #if os(iOS)
        beginBackgroundTask()
        #endif
        
        // Start timer to track recording duration
        // Timer updates the UI with current recording time
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let recorder = self.audioRecorder else { return }
                self.recordingDuration = recorder.currentTime
            }
        }
    }
    
    #if os(iOS)
    /// Begins a background task to keep the app running during background recording
    /// UIApplication.shared.beginBackgroundTask: Requests extra execution time when app goes to background
    /// This is a safety mechanism; audio recording with proper Info.plist setup should work without it,
    /// but it helps ensure smooth transitions
    private func beginBackgroundTask() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            // This closure is called when the system is about to terminate the background task
            // We should end the task cleanly
            Task { @MainActor [weak self] in
                self?.endBackgroundTask()
            }
        }
    }
    
    /// Ends the background task
    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    #endif
    
    /// Stops audio recording
    func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false
        #if os(iOS)
        endBackgroundTask()
        #endif
    }
    
    /// Returns the URL of the current or last recording
    var currentRecordingFileURL: URL? {
        return currentRecordingURL
    }
    
    deinit {
        // deinit is nonisolated — do the minimal cleanup directly rather than
        // calling the MainActor-isolated stopRecording().
        audioRecorder?.stop()
        recordingTimer?.invalidate()
    }
}

// MARK: - AVAudioRecorderDelegate
extension AudioCaptureManager: AVAudioRecorderDelegate {
    /// Called when recording finishes successfully
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !flag {
                errorMessage = "Recording finished with errors"
            }
            isRecording = false
            recordingTimer?.invalidate()
            recordingTimer = nil
        }
    }
    
    /// Called when recording encounters an error
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            errorMessage = "Recording error: \(error?.localizedDescription ?? "Unknown error")"
            isRecording = false
            recordingTimer?.invalidate()
            recordingTimer = nil
        }
    }
}

// MARK: - Custom Errors
enum AudioCaptureError: LocalizedError {
    case documentsDirectoryNotFound
    case recorderPreparationFailed
    case recordingStartFailed
    case microphonePermissionDenied
    
    var errorDescription: String? {
        switch self {
        case .documentsDirectoryNotFound:
            return "Could not find Documents directory"
        case .recorderPreparationFailed:
            return "Failed to prepare audio recorder"
        case .recordingStartFailed:
            return "Failed to start audio recording"
        case .microphonePermissionDenied:
            return "Microphone permission is required to record audio"
        }
    }
}

