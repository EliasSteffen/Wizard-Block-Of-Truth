import Foundation

public enum FrameCodecError: Error, Equatable {
  case frameTooLarge(Int)
  case invalidLengthPrefix
  case payloadEncodingFailed
  case payloadDecodingFailed
}

public enum FrameCodec {
  public static let maxFrameSize = 1_048_576

  public static func encode(_ envelope: WireEnvelope) throws -> Data {
    let encoder = JSONEncoder()
    let payload = try encoder.encode(envelope)
    if payload.count > maxFrameSize {
      throw FrameCodecError.frameTooLarge(payload.count)
    }
    var frame = Data()
    var length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(payload)
    return frame
  }

  public static func decode(_ payload: Data) throws -> WireEnvelope {
    let decoder = JSONDecoder()
    do {
      return try decoder.decode(WireEnvelope.self, from: payload)
    } catch {
      throw FrameCodecError.payloadDecodingFailed
    }
  }
}

public struct FrameDecoder {
  public private(set) var buffer: Data = Data()
  public let maxFrameSize: Int

  public init(maxFrameSize: Int = FrameCodec.maxFrameSize) {
    self.maxFrameSize = maxFrameSize
  }

  public mutating func append(_ data: Data) {
    buffer.append(data)
  }

  public mutating func nextEnvelope() throws -> WireEnvelope? {
    let headerSize = MemoryLayout<UInt32>.size
    guard buffer.count >= headerSize else { return nil }

    let length: UInt32 = buffer.withUnsafeBytes { raw in
      raw.load(fromByteOffset: 0, as: UInt32.self).bigEndian
    }
    if length == 0 {
      throw FrameCodecError.invalidLengthPrefix
    }

    let payloadSize = Int(length)
    if payloadSize > maxFrameSize {
      throw FrameCodecError.frameTooLarge(payloadSize)
    }
    guard buffer.count >= headerSize + payloadSize else { return nil }

    let payloadRange = headerSize..<(headerSize + payloadSize)
    let payload = buffer.subdata(in: payloadRange)
    buffer.removeSubrange(0..<(headerSize + payloadSize))
    return try FrameCodec.decode(payload)
  }
}
