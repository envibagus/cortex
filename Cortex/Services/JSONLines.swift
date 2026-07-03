import Foundation

// MARK: - JSONLines
//
// Streaming reader for newline-delimited files (the Claude Code JSONL transcripts).
// Reads through a FileHandle in fixed-size chunks and hands each non-empty line to
// the caller as Data, so a multi-megabyte transcript is never resident in memory
// all at once. Callers decode each line independently; a malformed line is theirs
// to skip, exactly as with a whole-file read + split.

enum JSONLines {
    /// Read chunk size. 1 MiB keeps the syscall count low while bounding the
    /// transient buffer a read can hold.
    private static let chunkSize = 1 << 20

    /// Calls `body` once per newline-delimited, non-empty line, in file order.
    /// The Data passed to `body` is a slice of the read buffer and is only valid
    /// for the duration of the call - decode it, do not store it.
    /// `body` returns `false` to stop reading early.
    /// Returns `false` when the file could not be opened for reading.
    @discardableResult
    static func forEachLine(in url: URL, _ body: (Data) -> Bool) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        // A line fragment that spans a chunk boundary, carried into the next read.
        var carry = Data()
        while true {
            let chunk = autoreleasepool { try? handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }

            var buffer: Data
            if carry.isEmpty {
                buffer = chunk
            } else {
                buffer = carry
                buffer.append(chunk)
                carry = Data()
            }

            var start = buffer.startIndex
            while let nl = buffer[start...].firstIndex(of: 0x0A) {
                if nl > start {
                    if !body(buffer[start..<nl]) { return true }
                }
                start = buffer.index(after: nl)
            }
            // Rebase the fragment into fresh storage so the chunk buffer is freed.
            carry = start < buffer.endIndex ? Data(buffer[start...]) : Data()
        }
        // Final line without a trailing newline.
        if !carry.isEmpty { _ = body(carry) }
        return true
    }
}
