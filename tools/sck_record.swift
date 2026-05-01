// sck_record.swift
// Capture a region of the screen + system audio to an MP4 using ScreenCaptureKit.
// Usage: sck_record <out.mp4> <duration_seconds> [<x> <y> <w> <h>]
// Coordinates are in points, top-left origin; omit rect args to capture the whole main display.

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreGraphics

@available(macOS 13.0, *)
final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput
    var sessionStarted = false
    let lock = NSLock()
    var stopped = false

    init(writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput) {
        self.writer = writer
        self.videoInput = video
        self.audioInput = audio
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first else {
            // Audio buffers won't carry SCK frame attachments, so don't gate on this for audio.
            if type == .audio { appendAudio(sampleBuffer) }
            return
        }

        if type == .screen {
            if let statusRaw = attachments[.status] as? Int,
               let status = SCFrameStatus(rawValue: statusRaw) {
                guard status == .complete else { return }
            }
            appendVideo(sampleBuffer)
        } else if type == .audio {
            appendAudio(sampleBuffer)
        }
    }

    private func startSessionIfNeeded(_ pts: CMTime) {
        lock.lock(); defer { lock.unlock() }
        if !sessionStarted {
            writer.startWriting()
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
    }

    private func appendVideo(_ buf: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(buf)
        startSessionIfNeeded(pts)
        if videoInput.isReadyForMoreMediaData {
            videoInput.append(buf)
        }
    }

    private func appendAudio(_ buf: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(buf)
        startSessionIfNeeded(pts)
        if audioInput.isReadyForMoreMediaData {
            audioInput.append(buf)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("stream stopped with error: \(error)\n".utf8))
    }
}

@available(macOS 13.0, *)
func run() async throws {
    // Force CoreGraphics/WindowServer initialization before SCK touches it.
    _ = CGMainDisplayID()

    let args = CommandLine.arguments
    // usage:
    //   sck_record <out.mp4> <seconds> <x> <y> <w> <h>          // explicit rect
    //   sck_record <out.mp4> <seconds> --app <substring>        // find window whose owner app name contains substring
    //   sck_record --list                                        // list windows
    if args.count == 2 && args[1] == "--list" {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        for w in content.windows {
            let app = w.owningApplication?.applicationName ?? "?"
            let title = w.title ?? ""
            print("pid=\(w.owningApplication?.processID ?? 0) windowID=\(w.windowID) app=\"\(app)\" title=\"\(title)\" frame=\(w.frame)")
        }
        return
    }
    guard args.count >= 3 else {
        FileHandle.standardError.write(Data("usage: \(args[0]) <out.mp4> <seconds> [<x> <y> <w> <h> | --app <name>]\n".utf8))
        exit(2)
    }
    let outPath = args[1]
    let seconds = Double(args[2]) ?? 0
    var rect: CGRect? = nil
    var targetWindow: SCWindow? = nil
    var hideTarget = false
    var argv = Array(args.dropFirst(3))
    if let idx = argv.firstIndex(of: "--hide") {
        hideTarget = true
        argv.remove(at: idx)
    }
    if argv.count == 4 {
        let x = Double(argv[0])!, y = Double(argv[1])!, w = Double(argv[2])!, h = Double(argv[3])!
        rect = CGRect(x: x, y: y, width: w, height: h)
    } else if argv.count == 2 && argv[0] == "--app" {
        let needle = argv[1].lowercased()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { w in
            let appName = w.owningApplication?.applicationName.lowercased() ?? ""
            let bundleID = w.owningApplication?.bundleIdentifier.lowercased() ?? ""
            let title = w.title?.lowercased() ?? ""
            // Window must contain visible content (some helper windows are zero-size).
            return (appName.contains(needle) || bundleID.contains(needle) || title.contains(needle))
                && w.frame.width > 50 && w.frame.height > 50
        }.sorted(by: { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height })
        guard let w = candidates.first else {
            FileHandle.standardError.write(Data("no window matching \"\(needle)\"\n".utf8))
            exit(1)
        }
        targetWindow = w
        rect = w.frame
        FileHandle.standardError.write(Data("matched: app=\"\(w.owningApplication?.applicationName ?? "?")\" title=\"\(w.title ?? "")\" frame=\(w.frame)\n".utf8))
    }

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else {
        FileHandle.standardError.write(Data("no displays\n".utf8))
        exit(1)
    }

    // Use a window-only filter when targeting a specific window so the surrounding desktop is excluded.
    // Audio still captures system-wide.
    let filter: SCContentFilter
    if let w = targetWindow {
        filter = SCContentFilter(desktopIndependentWindow: w)
    } else {
        filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    }

    let config = SCStreamConfiguration()
    let scale: CGFloat = 2.0  // assume 2x retina; output is pixels
    if targetWindow != nil, let r = rect {
        // Window filter already crops to the window. Just match output dimensions.
        config.width = Int((r.width * scale).rounded())
        config.height = Int((r.height * scale).rounded())
    } else if let r = rect {
        config.sourceRect = r
        config.width = Int((r.width * scale).rounded())
        config.height = Int((r.height * scale).rounded())
    } else {
        config.width = display.width * 2
        config.height = display.height * 2
    }
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30 fps
    config.queueDepth = 8
    config.showsCursor = false
    config.capturesAudio = true
    config.sampleRate = 48000
    config.channelCount = 2
    config.pixelFormat = kCVPixelFormatType_32BGRA

    // Writer.
    let url = URL(fileURLWithPath: outPath)
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: config.width,
        AVVideoHeightKey: config.height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 6_000_000,
            AVVideoMaxKeyFrameIntervalKey: 60,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
    ]
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput.expectsMediaDataInRealTime = true
    if writer.canAdd(videoInput) { writer.add(videoInput) }

    let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 192_000,
    ]
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    audioInput.expectsMediaDataInRealTime = true
    if writer.canAdd(audioInput) { writer.add(audioInput) }

    let output = StreamOutput(writer: writer, video: videoInput, audio: audioInput)
    let stream = SCStream(filter: filter, configuration: config, delegate: output)
    try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sck.video"))
    try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sck.audio"))

    print("starting capture: \(config.width)x\(config.height) @ 30fps for \(seconds)s -> \(outPath)")
    try await stream.startCapture()

    if hideTarget, let w = targetWindow, let pid = w.owningApplication?.processID {
        // Hide the source app via AppleScript so we don't pull in AppKit (which interferes with CG init).
        try await Task.sleep(nanoseconds: 500_000_000)
        let script = "tell application \"System Events\" to set visible of (first process whose unix id is \(pid)) to false"
        let p = Process()
        p.launchPath = "/usr/bin/osascript"
        p.arguments = ["-e", script]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        FileHandle.standardError.write(Data("hide pid=\(pid) status=\(p.terminationStatus)\n".utf8))
    }

    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

    try await stream.stopCapture()

    videoInput.markAsFinished()
    audioInput.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed {
        FileHandle.standardError.write(Data("writer failed: \(String(describing: writer.error))\n".utf8))
        exit(1)
    }
    print("done")
}

if #available(macOS 13.0, *) {
    let task = Task { try await run() }
    // Block main thread until task completes.
    let semaphore = DispatchSemaphore(value: 0)
    Task { _ = await task.result; semaphore.signal() }
    semaphore.wait()
} else {
    FileHandle.standardError.write(Data("requires macOS 13+\n".utf8))
    exit(1)
}
