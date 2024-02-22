import Foundation

extension Dictionary {
    func compactMapKeys<T>(
        _ transform: ((Key) throws -> T?)
    ) rethrows -> Dictionary<T, Value> {
        return try self.reduce(into: [T: Value](), { (result, x) in
            if let key = try transform(x.key) {
                result[key] = x.value
            }
        })
    }

    func mapKeys<T>(
        _ transform: ((Key) throws -> T)
    ) rethrows -> Dictionary<T, Value> {
        return try self.reduce(into: [T: Value](), { (result, x) in
            result[try transform(x.key)] = x.value
        })
    }
}
