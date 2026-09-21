import AVFoundation
import CoreAudio
import Foundation
import BindersKit

enum SystemAudioError: LocalizedError {
    case tapFailed(OSStatus)
    case formatUnavailable
    case aggregateFailed(OSStatus)
    case startFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapFailed(let status):
            "Couldn't capture meeting audio (\(status)). Allow Binders in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .formatUnavailable: "Couldn't read the system audio format"
        case .aggregateFailed(let status): "Couldn't set up system audio capture (\(status))"
        case .startFailed(let status): "Couldn't start system audio capture (\(status))"
        }
    }
}

/// Captures what other apps play (remote meeting participants) as 16 kHz mono through a Core Audio process tap.
/// Needs macOS 14.2+ and the "System Audio Recording" permission; nothing joins the call.
final class SystemAudioCapture: @unchecked Sendable {
    /// Called on a private queue with each converted chunk.
    var onSamples: (([Float]) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let queue = DispatchQueue(label: "io.binders.mac.system-audio", qos: .userInitiated)
    private var formatListener: AudioObjectPropertyListenerBlock?

    var isRunning: Bool { procID != nil }

    func start() throws {
        stop()
        // Leave the app's own sounds out of the recording.
        let excluded = AudioProcesses.processObject(for: ProcessInfo.processInfo.processIdentifier).map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "Binders meeting capture"

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else { throw SystemAudioError.tapFailed(status) }
        tapID = tap

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &streamDescription)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &streamDescription),
              let converter = AVAudioConverter(from: format, to: outputFormat) else {
            stop()
            throw SystemAudioError.formatUnavailable
        }
        converter.downmix = true
        inputFormat = format
        self.converter = converter
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refreshFormat() }
        if AudioObjectAddPropertyListenerBlock(tap, &formatAddress, queue, listener) == noErr {
            formatListener = listener
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Binders Meeting Capture",
            kAudioAggregateDeviceUIDKey: "io.binders.mac.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice)
        guard status == noErr else {
            stop()
            throw SystemAudioError.aggregateFailed(status)
        }
        aggregateID = aggregateDevice

        var newProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateDevice, queue) { [weak self] _, inputData, _, _, _ in
            self?.process(inputData)
        }
        guard status == noErr, let newProcID else {
            stop()
            throw SystemAudioError.startFailed(status)
        }
        procID = newProcID
        status = AudioDeviceStart(aggregateDevice, newProcID)
        guard status == noErr else {
            stop()
            throw SystemAudioError.startFailed(status)
        }
    }

    func stop() {
        if let formatListener, tapID != kAudioObjectUnknown {
            var address = Self.formatAddress
            AudioObjectRemovePropertyListenerBlock(tapID, &address, queue, formatListener)
        }
        formatListener = nil
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        converter = nil
        inputFormat = nil
    }

    private static let formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                                  mElement: kAudioObjectPropertyElementMain)

    /// Runs on `queue`, like the IO block, so the converter is never swapped mid-conversion.
    private func refreshFormat() {
        guard tapID != kAudioObjectUnknown else { return }
        var address = Self.formatAddress
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description) == noErr,
              let format = AVAudioFormat(streamDescription: &description), format != inputFormat,
              let converter = AVAudioConverter(from: format, to: outputFormat) else { return }
        converter.downmix = true
        Log.meeting.info("System audio format changed to \(format.sampleRate) Hz")
        inputFormat = format
        self.converter = converter
    }

    private func process(_ inputData: UnsafePointer<AudioBufferList>) {
        guard let converter, let inputFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: inputData, deallocator: nil),
              buffer.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { return }
        onSamples?(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
    }
}

/// Core Audio's view of which processes use audio devices.
enum AudioProcesses {
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size),
                                                &pid, &size, &objectID)
        return status == noErr && objectID != kAudioObjectUnknown ? objectID : nil
    }

    /// True when some app is playing through the default output device.
    static func isOutputPlaying() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// Bundle identifiers of processes currently recording from any input device.
    static func bundleIDsCapturingInput() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return objects.compactMap { object in
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr, running != 0 else { return nil }

            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid == ownPID { return nil }

            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr, let bundle else { return nil }
            return bundle.takeRetainedValue() as String
        }
    }
}
