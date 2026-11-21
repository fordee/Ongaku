//
//  TorchCheckpoint.swift
//  OngakuEngine
//

import Accelerate
import Foundation
import OngakuCore

/// Reads a PyTorch checkpoint (`torch.save`'s ZIP of a pickle and its tensors' storage)
/// without Python: just enough of the pickle format to rebuild the dictionaries, numbers,
/// strings and tensors Demucs saves. Tensors come back as Float32.
struct TorchCheckpoint {
  /// A tensor: its shape and its values in row-major order.
  struct Tensor {
    var shape: [Int]
    var values: [Float]

    var count: Int { shape.reduce(1, *) }
  }

  /// A value rebuilt from the pickle.
  indirect enum Value {
    case none
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case bytes(Data)
    case list([Value])
    case tuple([Value])
    case dict([(Value, Value)])
    case tensor(Tensor)
    /// A class or function the pickle names (`module.name`), and what was built from it.
    case global(String)
    case object(String, [Value])
    /// A tensor's storage: which file in the archive, and its element type.
    case storage(key: String, type: String)

    var string: String? { if case .string(let text) = self { text } else { nil } }
    var int: Int? {
      switch self {
      case .int(let value): value
      case .bool(let value): value ? 1 : 0
      default: nil
      }
    }
    var double: Double? {
      switch self {
      case .double(let value): value
      case .int(let value): Double(value)
      case .object("fractions.Fraction", let arguments):
        // Fraction('39/5')
        arguments.first?.string.flatMap { text in
          let parts = text.split(separator: "/").compactMap { Double($0) }
          return parts.count == 2 ? parts[0] / parts[1] : Double(text)
        }
      default: nil
      }
    }

    /// A dictionary's value for a string key.
    subscript(key: String) -> Value? {
      guard case .dict(let pairs) = self else { return nil }
      return pairs.first { $0.0.string == key }?.1
    }
  }

  enum CheckpointError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
      switch self {
      case .unreadable(let detail): "The model file couldn't be read (\(detail))."
      }
    }
  }

  /// The pickled object (for Demucs: a dictionary of `klass`, `args`, `kwargs` and `state`).
  let root: Value

  init(contentsOf url: URL) throws {
    let entries = try ZipArchive.read(Data(contentsOf: url, options: .mappedIfSafe))
    guard let pickle = entries.first(where: { $0.path.hasSuffix("data.pkl") }) else { throw CheckpointError.unreadable("no data.pkl") }
    let prefix = String(pickle.path.dropLast("data.pkl".count))
    let storage = Dictionary(entries.map { ($0.path, $0.data) }, uniquingKeysWith: { first, _ in first })
    var machine = Unpickler(bytes: [UInt8](pickle.data)) { key in storage[prefix + "data/" + key] }
    root = try machine.run()
  }

  /// The model's weights by name ("encoder.0.conv.weight").
  var state: [String: Tensor] {
    guard case .dict(let pairs) = root["state"] ?? .none else { return [:] }
    var result: [String: Tensor] = [:]
    for (key, value) in pairs {
      if let name = key.string, case .tensor(let tensor) = value { result[name] = tensor }
    }
    return result
  }

  /// The model's constructor arguments.
  var kwargs: Value { root["kwargs"] ?? .none }
}

/// The pickle virtual machine, protocol 2 (what torch.save writes), the opcodes it uses.
private struct Unpickler {
  let bytes: [UInt8]
  let storage: (String) -> Data?
  var position = 0
  var stack: [TorchCheckpoint.Value] = []
  var marks: [Int] = []
  var memo: [Int: TorchCheckpoint.Value] = [:]

  init(bytes: [UInt8], storage: @escaping (String) -> Data?) {
    self.bytes = bytes
    self.storage = storage
  }

  mutating func byte() throws -> UInt8 {
    guard position < bytes.count else { throw TorchCheckpoint.CheckpointError.unreadable("truncated pickle") }
    defer { position += 1 }
    return bytes[position]
  }

  mutating func read(_ count: Int) throws -> ArraySlice<UInt8> {
    guard position + count <= bytes.count else { throw TorchCheckpoint.CheckpointError.unreadable("truncated pickle") }
    defer { position += count }
    return bytes[position..<(position + count)]
  }

  mutating func uint(_ count: Int) throws -> Int {
    try read(count).reversed().reduce(0) { $0 << 8 | Int($1) }
  }

  mutating func line() throws -> String {
    var text: [UInt8] = []
    while true {
      let next = try byte()
      if next == 0x0A { break }
      text.append(next)
    }
    return String(decoding: text, as: UTF8.self)
  }

  mutating func popMark() -> [TorchCheckpoint.Value] {
    let mark = marks.popLast() ?? 0
    let items = Array(stack[mark...])
    stack.removeSubrange(mark...)
    return items
  }

  mutating func pop() throws -> TorchCheckpoint.Value {
    guard let value = stack.popLast() else { throw TorchCheckpoint.CheckpointError.unreadable("empty stack") }
    return value
  }

  mutating func run() throws -> TorchCheckpoint.Value {
    while true {
      let opcode = try byte()
      switch opcode {
      case 0x80: _ = try byte()  // PROTO
      case 0x95: _ = try read(8)  // FRAME
      case 0x2E: return try pop()  // STOP
      case 0x28: marks.append(stack.count)  // MARK
      case 0x7D: stack.append(.dict([]))  // EMPTY_DICT
      case 0x5D: stack.append(.list([]))  // EMPTY_LIST
      case 0x29: stack.append(.tuple([]))  // EMPTY_TUPLE
      case 0x4E: stack.append(.none)  // NONE
      case 0x88: stack.append(.bool(true))  // NEWTRUE
      case 0x89: stack.append(.bool(false))  // NEWFALSE
      case 0x4A: stack.append(.int(Int(Int32(truncatingIfNeeded: try uint(4)))))  // BININT
      case 0x4B: stack.append(.int(Int(try byte())))  // BININT1
      case 0x4D: stack.append(.int(try uint(2)))  // BININT2
      case 0x8A:  // LONG1
        let count = Int(try byte())
        let raw = try read(count)
        var value = 0
        for (index, part) in raw.enumerated() { value |= Int(part) << (8 * index) }
        if count > 0, count < 8, raw.last! & 0x80 != 0 { value -= 1 << (8 * count) }
        stack.append(.int(value))
      case 0x47:  // BINFLOAT (big endian)
        let raw = try read(8)
        stack.append(.double(Double(bitPattern: raw.reduce(0) { $0 << 8 | UInt64($1) })))
      case 0x58: stack.append(.string(String(decoding: try read(try uint(4)), as: UTF8.self)))  // BINUNICODE
      case 0x8C: stack.append(.string(String(decoding: try read(Int(try byte())), as: UTF8.self)))  // SHORT_BINUNICODE
      case 0x43: stack.append(.bytes(Data(try read(Int(try byte())))))  // SHORT_BINBYTES
      case 0x42: stack.append(.bytes(Data(try read(try uint(4)))))  // BINBYTES
      case 0x71: memo[Int(try byte())] = stack.last  // BINPUT
      case 0x72: memo[try uint(4)] = stack.last  // LONG_BINPUT
      case 0x94: memo[memo.count] = stack.last  // MEMOIZE
      case 0x68: stack.append(memo[Int(try byte())] ?? .none)  // BINGET
      case 0x6A: stack.append(memo[try uint(4)] ?? .none)  // LONG_BINGET
      case 0x63:  // GLOBAL
        let module = try line(), name = try line()
        stack.append(.global("\(module).\(name)"))
      case 0x93:  // STACK_GLOBAL
        let name = try pop(), module = try pop()
        stack.append(.global("\(module.string ?? "").\(name.string ?? "")"))
      case 0x74: stack.append(.tuple(popMark()))  // TUPLE
      case 0x85: stack.append(.tuple([try pop()]))  // TUPLE1
      case 0x86:  // TUPLE2
        let second = try pop(), first = try pop()
        stack.append(.tuple([first, second]))
      case 0x87:  // TUPLE3
        let third = try pop(), second = try pop(), first = try pop()
        stack.append(.tuple([first, second, third]))
      case 0x61:  // APPEND
        let item = try pop()
        if case .list(var items) = try pop() {
          items.append(item)
          stack.append(.list(items))
        }
      case 0x65:  // APPENDS
        let items = popMark()
        if case .list(let existing) = try pop() { stack.append(.list(existing + items)) }
      case 0x73:  // SETITEM
        let value = try pop(), key = try pop()
        if case .dict(var pairs) = try pop() {
          pairs.append((key, value))
          stack.append(.dict(pairs))
        }
      case 0x75:  // SETITEMS
        let items = popMark()
        if case .dict(var pairs) = try pop() {
          for index in stride(from: 0, to: items.count - 1, by: 2) { pairs.append((items[index], items[index + 1])) }
          stack.append(.dict(pairs))
        }
      case 0x51:  // BINPERSID: ('storage', type, key, location, size)
        let id = try pop()
        guard case .tuple(let parts) = id, parts.count >= 3, case .global(let type) = parts[1], let key = parts[2].string else {
          throw TorchCheckpoint.CheckpointError.unreadable("unknown persistent id")
        }
        stack.append(.storage(key: key, type: type))
      case 0x52:  // REDUCE
        let arguments = try pop(), callable = try pop()
        stack.append(try reduce(callable, arguments))
      case 0x81:  // NEWOBJ
        let arguments = try pop(), cls = try pop()
        stack.append(try reduce(cls, arguments))
      case 0x62:  // BUILD: state for an object; ignored (tensors and dicts are complete)
        _ = try pop()
      default:
        throw TorchCheckpoint.CheckpointError.unreadable("pickle opcode \(String(opcode, radix: 16))")
      }
    }
  }

  func reduce(_ callable: TorchCheckpoint.Value, _ arguments: TorchCheckpoint.Value) throws -> TorchCheckpoint.Value {
    guard case .global(let name) = callable else { return .none }
    let args: [TorchCheckpoint.Value] = if case .tuple(let items) = arguments { items } else { [arguments] }
    switch name {
    case "collections.OrderedDict": return .dict([])
    case "torch._utils._rebuild_tensor_v2":
      // (storage, offset, size, stride, requires_grad, hooks)
      guard args.count >= 4, case .storage(let key, let type) = args[0], let offset = args[1].int,
        case .tuple(let sizeValues) = args[2], case .tuple(let strideValues) = args[3]
      else { throw TorchCheckpoint.CheckpointError.unreadable("tensor") }
      let shape = sizeValues.compactMap(\.int), strides = strideValues.compactMap(\.int)
      guard let data = storage(key) else { throw TorchCheckpoint.CheckpointError.unreadable("missing storage \(key)") }
      let all = Self.floats(data, type: type)
      return .tensor(TorchCheckpoint.Tensor(shape: shape, values: Self.gather(all, offset: offset, shape: shape, strides: strides)))
    default:
      return .object(name, args)
    }
  }

  /// A storage's values as Float32.
  static func floats(_ data: Data, type: String) -> [Float] {
    if type.hasSuffix("HalfStorage") {
      let count = data.count / 2
      var output = [Float](repeating: 0, count: count)
      data.withUnsafeBytes { raw in
        output.withUnsafeMutableBufferPointer { out in
          var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: raw.baseAddress!), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
          var destination = vImage_Buffer(data: out.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
          vImageConvert_Planar16FtoPlanarF(&source, &destination, 0)
        }
      }
      return output
    }
    // FloatStorage.
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }

  /// The values a strided view holds, in row-major order.
  static func gather(_ values: [Float], offset: Int, shape: [Int], strides: [Int]) -> [Float] {
    let count = shape.reduce(1, *)
    // Contiguous (the usual case): a straight copy.
    var expected = 1
    var contiguous = true
    for (size, stride) in zip(shape, strides).reversed() {
      if size > 1, stride != expected { contiguous = false }
      expected *= size
    }
    if contiguous { return Array(values[offset..<(offset + count)]) }
    var output = [Float](repeating: 0, count: count)
    var index = [Int](repeating: 0, count: shape.count)
    for flat in 0..<count {
      var source = offset
      for axis in shape.indices { source += index[axis] * strides[axis] }
      output[flat] = values[source]
      var axis = shape.count - 1
      while axis >= 0 {
        index[axis] += 1
        if index[axis] < shape[axis] { break }
        index[axis] = 0
        axis -= 1
      }
    }
    return output
  }
}
