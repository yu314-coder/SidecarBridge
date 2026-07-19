import Foundation

struct FileTransferSnapshot: Equatable {
    enum Direction: Equatable {
        case sending
        case receiving
    }

    let direction: Direction
    let fileName: String
    let completedBytes: Int64
    let totalBytes: Int64
    let message: String

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }
}

@MainActor
final class FileTransferEngine {
    static let maximumFileSize: Int64 = 512 * 1024 * 1024
    static let chunkSize = 128 * 1024

    var sendPacket: ((FileTransferPacket) -> Void)?
    var onSnapshot: ((FileTransferSnapshot?) -> Void)?
    var onReceived: ((URL) -> Void)?
    var onError: ((String) -> Void)?

    private struct OutgoingTransfer {
        let id: UUID
        let name: String
        let size: Int64
        let sourceURL: URL
        let handle: FileHandle
        let hasSecurityScope: Bool
        var offset: Int64
    }

    private struct IncomingTransfer {
        let id: UUID
        let name: String
        let size: Int64
        let destinationURL: URL
        let handle: FileHandle
        var offset: Int64
    }

    private let receiveDirectory: () throws -> URL
    private var outgoing: OutgoingTransfer?
    private var incoming: IncomingTransfer?
    private var timeoutTask: Task<Void, Never>?

    init(receiveDirectory: @escaping () throws -> URL) {
        self.receiveDirectory = receiveDirectory
    }

    var isBusy: Bool { outgoing != nil || incoming != nil }

    func sendFile(at url: URL) {
        guard !isBusy else {
            onError?("Another file transfer is already active.")
            return
        }

        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw TransferError.notAFile }
            let size = Int64(values.fileSize ?? 0)
            guard size <= Self.maximumFileSize else { throw TransferError.tooLarge }
            let name = Self.safeFileName(url.lastPathComponent)
            let handle = try FileHandle(forReadingFrom: url)
            let id = UUID()
            outgoing = OutgoingTransfer(
                id: id,
                name: name,
                size: size,
                sourceURL: url,
                handle: handle,
                hasSecurityScope: scoped,
                offset: 0
            )
            armTimeout(for: id)
            publish(direction: .sending, name: name, completed: 0, total: size, message: "Waiting for receiver…")
            sendPacket?(FileTransferPacket(
                kind: .begin,
                transferID: id,
                name: name,
                totalSize: size,
                offset: 0,
                payload: nil,
                message: nil
            ))
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            fail(error.localizedDescription)
        }
    }

    func handle(_ packet: FileTransferPacket) {
        do {
            switch packet.kind {
            case .begin:
                try beginReceiving(packet)
            case .chunk:
                try receiveChunk(packet)
            case .acknowledgement:
                try handleAcknowledgement(packet)
            case .complete:
                try handleCompletion(packet)
            case .cancel:
                handleCancellation(packet)
            }
        } catch {
            sendPacket?(FileTransferPacket(
                kind: .cancel,
                transferID: packet.transferID,
                name: packet.name,
                totalSize: nil,
                offset: nil,
                payload: nil,
                message: error.localizedDescription
            ))
            fail(error.localizedDescription)
        }
    }

    func cancelAll(reason: String = "Transfer canceled.") {
        if let outgoing {
            sendPacket?(FileTransferPacket(
                kind: .cancel,
                transferID: outgoing.id,
                name: outgoing.name,
                totalSize: nil,
                offset: outgoing.offset,
                payload: nil,
                message: reason
            ))
        }
        closeTransfers()
        onSnapshot?(nil)
    }

    private func beginReceiving(_ packet: FileTransferPacket) throws {
        guard !isBusy else { throw TransferError.busy }
        guard let rawName = packet.name, let size = packet.totalSize, size >= 0 else {
            throw TransferError.invalidPacket
        }
        guard size <= Self.maximumFileSize else { throw TransferError.tooLarge }

        let name = Self.safeFileName(rawName)
        let directory = try receiveDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = Self.uniqueURL(for: name, in: directory)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw TransferError.cannotCreateFile
        }
        let handle = try FileHandle(forWritingTo: destination)
        incoming = IncomingTransfer(
            id: packet.transferID,
            name: name,
            size: size,
            destinationURL: destination,
            handle: handle,
            offset: 0
        )
        armTimeout(for: packet.transferID)
        publish(direction: .receiving, name: name, completed: 0, total: size, message: "Receiving securely…")
        acknowledge(packet.transferID, offset: 0)
    }

    private func receiveChunk(_ packet: FileTransferPacket) throws {
        guard var transfer = incoming, transfer.id == packet.transferID,
              let payload = packet.payload, let offset = packet.offset,
              offset == transfer.offset,
              payload.count <= Self.chunkSize,
              transfer.offset + Int64(payload.count) <= transfer.size else {
            throw TransferError.invalidPacket
        }
        try transfer.handle.write(contentsOf: payload)
        transfer.offset += Int64(payload.count)
        incoming = transfer
        armTimeout(for: transfer.id)
        publish(
            direction: .receiving,
            name: transfer.name,
            completed: transfer.offset,
            total: transfer.size,
            message: "Receiving securely…"
        )
        acknowledge(transfer.id, offset: transfer.offset)
    }

    private func handleAcknowledgement(_ packet: FileTransferPacket) throws {
        guard var transfer = outgoing, transfer.id == packet.transferID,
              let acknowledgedOffset = packet.offset,
              acknowledgedOffset == transfer.offset else { return }
        armTimeout(for: transfer.id)

        if transfer.offset >= transfer.size {
            try transfer.handle.close()
            outgoing = transfer
            publish(
                direction: .sending,
                name: transfer.name,
                completed: transfer.size,
                total: transfer.size,
                message: "Verifying on receiver…"
            )
            sendPacket?(FileTransferPacket(
                kind: .complete,
                transferID: transfer.id,
                name: transfer.name,
                totalSize: transfer.size,
                offset: transfer.size,
                payload: nil,
                message: nil
            ))
            return
        }

        let data = try transfer.handle.read(upToCount: Self.chunkSize) ?? Data()
        guard !data.isEmpty else { throw TransferError.unexpectedEnd }
        let chunkOffset = transfer.offset
        transfer.offset += Int64(data.count)
        outgoing = transfer
        publish(
            direction: .sending,
            name: transfer.name,
            completed: transfer.offset,
            total: transfer.size,
            message: "Sending securely…"
        )
        sendPacket?(FileTransferPacket(
            kind: .chunk,
            transferID: transfer.id,
            name: nil,
            totalSize: nil,
            offset: chunkOffset,
            payload: data,
            message: nil
        ))
    }

    private func handleCompletion(_ packet: FileTransferPacket) throws {
        if let transfer = incoming, transfer.id == packet.transferID {
            guard transfer.offset == transfer.size else { throw TransferError.unexpectedEnd }
            try transfer.handle.close()
            incoming = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            publish(
                direction: .receiving,
                name: transfer.name,
                completed: transfer.size,
                total: transfer.size,
                message: "Received"
            )
            onReceived?(transfer.destinationURL)
            sendPacket?(FileTransferPacket(
                kind: .complete,
                transferID: transfer.id,
                name: transfer.name,
                totalSize: transfer.size,
                offset: transfer.size,
                payload: nil,
                message: "saved"
            ))
            return
        }

        if let transfer = outgoing, transfer.id == packet.transferID {
            finishOutgoing(transfer)
        }
    }

    private func handleCancellation(_ packet: FileTransferPacket) {
        if outgoing?.id == packet.transferID || incoming?.id == packet.transferID {
            closeTransfers()
            fail(packet.message ?? "The other device canceled the transfer.")
        }
    }

    private func finishOutgoing(_ transfer: OutgoingTransfer) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if transfer.hasSecurityScope { transfer.sourceURL.stopAccessingSecurityScopedResource() }
        outgoing = nil
        publish(
            direction: .sending,
            name: transfer.name,
            completed: transfer.size,
            total: transfer.size,
            message: "Sent"
        )
    }

    private func acknowledge(_ id: UUID, offset: Int64) {
        sendPacket?(FileTransferPacket(
            kind: .acknowledgement,
            transferID: id,
            name: nil,
            totalSize: nil,
            offset: offset,
            payload: nil,
            message: nil
        ))
    }

    private func publish(
        direction: FileTransferSnapshot.Direction,
        name: String,
        completed: Int64,
        total: Int64,
        message: String
    ) {
        onSnapshot?(FileTransferSnapshot(
            direction: direction,
            fileName: name,
            completedBytes: completed,
            totalBytes: total,
            message: message
        ))
    }

    private func fail(_ message: String) {
        closeTransfers()
        onSnapshot?(nil)
        onError?(message)
    }

    private func closeTransfers() {
        timeoutTask?.cancel()
        timeoutTask = nil
        if let outgoing {
            try? outgoing.handle.close()
            if outgoing.hasSecurityScope { outgoing.sourceURL.stopAccessingSecurityScopedResource() }
        }
        if let incoming {
            try? incoming.handle.close()
            try? FileManager.default.removeItem(at: incoming.destinationURL)
        }
        outgoing = nil
        incoming = nil
    }

    private func armTimeout(for transferID: UUID) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            let isCurrent = self.outgoing?.id == transferID || self.incoming?.id == transferID
            guard isCurrent else { return }
            self.cancelAll(reason: "File transfer timed out; try again.")
            self.onError?("File transfer timed out; try again.")
        }
    }

    private static func safeFileName(_ rawName: String) -> String {
        let fallback = "Transferred File"
        let leaf = URL(fileURLWithPath: rawName).lastPathComponent
        let filtered = leaf.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != ":"
        }
        let value = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : String(value.prefix(180))
    }

    private static func uniqueURL(for name: String, in directory: URL) -> URL {
        let initial = directory.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: initial.path) else { return initial }
        let source = URL(fileURLWithPath: name)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for index in 2...999 {
            let candidateName = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    enum TransferError: LocalizedError {
        case busy
        case notAFile
        case tooLarge
        case invalidPacket
        case cannotCreateFile
        case unexpectedEnd

        var errorDescription: String? {
            switch self {
            case .busy: return "Another incoming file transfer is active."
            case .notAFile: return "Choose a regular file."
            case .tooLarge: return "Files larger than 512 MB are not supported."
            case .invalidPacket: return "The file transfer data was invalid."
            case .cannotCreateFile: return "The received file could not be created."
            case .unexpectedEnd: return "The source file ended before the transfer completed."
            }
        }
    }
}
