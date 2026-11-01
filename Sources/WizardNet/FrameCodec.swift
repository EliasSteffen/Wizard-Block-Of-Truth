import Foundation

public enum FrameCodecError: Error, Equatable {
  case frameTooLarge(Int)
  case invalidLengthPrefix
  case payloadEncodingFailed
  case payloadDecodingFailed
}

/// Framing: 4-byte big-endian payload length, then the JSON-encoded `WireEnvelope`.
public enum FrameCodec {
  public static let headerSize = 4
  public static let maxFrameSize = 1_048_576

  public static func encode(_ envelope: WireEnvelope) throws -> Data {
    let payload: Data
    do {
      payload = try JSONEncoder().encode(envelope)
    } catch {
      throw FrameCodecError.payloadEncodingFailed
    }
    if payload.count > maxFrameSize {
      throw FrameCodecError.frameTooLarge(payload.count)
    }
    return frame(payload: payload)
  }

  /// Prefixes `payload` with its big-endian length (no size check; callers validate).
  public static func frame(payload: Data) -> Data {
    let length = UInt32(truncatingIfNeeded: payload.count)
    var frame = Data(capacity: headerSize + payload.count)
    frame.append(UInt8(truncatingIfNeeded: length >> 24))
    frame.append(UInt8(truncatingIfNeeded: length >> 16))
    frame.append(UInt8(truncatingIfNeeded: length >> 8))
    frame.append(UInt8(truncatingIfNeeded: length))
    frame.append(payload)
    return frame
  }

  public static func decode(_ payload: Data) throws -> WireEnvelope {
    do {
      return try JSONDecoder().decode(WireEnvelope.self, from: payload)
    } catch {
      throw FrameCodecError.payloadDecodingFailed
    }
  }
}

/// Reassembles frames from arbitrarily chunked stream data.
public struct FrameDecoder: Sendable {
  public private(set) var buffer: Data = Data()
  public let maxFrameSize: Int

  public init(maxFrameSize: Int = FrameCodec.maxFrameSize) {
    self.maxFrameSize = maxFrameSize
  }

  public mutating func append(_ data: Data) {
    buffer.append(data)
  }

  /// Next complete envelope, or `nil` while the frame is still incomplete.
  /// Throws on a zero/oversized length prefix or an undecodable payload (the stream is then unusable).
  public mutating func nextEnvelope() throws -> WireEnvelope? {
    guard let payload = try nextPayload() else { return nil }
    return try FrameCodec.decode(payload)
  }

  /// Next complete raw payload (without the length prefix), or `nil` while incomplete.
  public mutating func nextPayload() throws -> Data? {
    let headerSize = FrameCodec.headerSize
    guard buffer.count >= headerSize else { return nil }

    // Assemble the length byte by byte: no (possibly unaligned) `UInt32` load and no assumption
    // that `buffer.startIndex == 0`.
    let start = buffer.startIndex
    var length: UInt32 = 0
    for offset in 0..<headerSize {
      length = (length << 8) | UInt32(buffer[start + offset])
    }
    if length == 0 {
      throw FrameCodecError.invalidLengthPrefix
    }

    let payloadSize = Int(length)
    if payloadSize > maxFrameSize {
      throw FrameCodecError.frameTooLarge(payloadSize)
    }
    guard buffer.count >= headerSize + payloadSize else { return nil }

    let payloadStart = start + headerSize
    let payloadEnd = payloadStart + payloadSize
    let payload = buffer.subdata(in: payloadStart..<payloadEnd)
    buffer = buffer.subdata(in: payloadEnd..<buffer.endIndex)
    return payload
  }
}
