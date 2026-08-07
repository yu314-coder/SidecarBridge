import Foundation

struct RemoteTextDelta: Equatable {
    let deleteCount: Int
    let insertedText: String

    var isEmpty: Bool {
        deleteCount == 0 && insertedText.isEmpty
    }

    static func between(_ oldText: String, and newText: String) -> RemoteTextDelta {
        let oldCharacters = Array(oldText)
        let newCharacters = Array(newText)
        let sharedLimit = min(oldCharacters.count, newCharacters.count)

        var prefixCount = 0
        while prefixCount < sharedLimit,
              oldCharacters[prefixCount] == newCharacters[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < oldCharacters.count - prefixCount,
              suffixCount < newCharacters.count - prefixCount,
              oldCharacters[oldCharacters.count - suffixCount - 1]
                == newCharacters[newCharacters.count - suffixCount - 1] {
            suffixCount += 1
        }

        let deleted = oldCharacters.count - prefixCount - suffixCount
        let insertedEnd = newCharacters.count - suffixCount
        let inserted = String(newCharacters[prefixCount..<insertedEnd])
        return RemoteTextDelta(deleteCount: deleted, insertedText: inserted)
    }
}
