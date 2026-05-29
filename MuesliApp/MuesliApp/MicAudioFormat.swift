import Foundation

/// True when an input node format can carry real audio. A 0 Hz sample rate or
/// 0 channels is the signature of a failed VPIO/device configuration, where the
/// tap would install but never deliver buffers.
func isUsableInputFormat(sampleRate: Double, channelCount: UInt32) -> Bool {
    sampleRate > 0 && channelCount > 0
}
