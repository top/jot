// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// The coordinator's view of a live session.
///
/// A separate seam from `TranscriptionServicing` on purpose. That protocol's
/// other callers — `RetryQueue` and `RecoveryScanner` — read a CAF off disk long
/// after the session ended, and they are the never-lose-words safety net.
/// Widening it with streaming concepts would drag a socket into the two places
/// whose entire job is to work when everything else has already failed.
///
/// `finish` returns an optional, and that shape is the whole contract: the
/// coordinator does not inspect, score, or repair a live result. It either gets
/// a transcript it may use, or it gets nil and uploads the file exactly as it
/// always has.
public protocol LiveTranscribing: AnyObject, Sendable {
    /// Opens the socket and handshakes. Throwing is normal and cheap — the
    /// caller falls back to batch and the user never learns a socket existed.
    func begin() async throws

    /// Called from the audio write queue for every converted buffer.
    /// **Must not block and must not await** — that queue owns the CAF file
    /// handle and the waiter `stop()` parks on.
    nonisolated func enqueue(_ pcm: Data)

    /// Ends the turn and returns a usable transcript, or nil.
    ///
    /// `framesWritten` is the count the audio engine actually wrote to disk, and
    /// it is the reconciliation input: a stream may only be trusted when the
    /// bytes the socket accepted equal `framesWritten * 2`. Text alone cannot
    /// reveal truncation — a transcript missing its opening seconds reads
    /// perfectly — so the check is arithmetic, not judgement.
    func finish(deadline: TimeInterval, framesWritten: Int64) async -> TranscriptionResult?

    /// Tear down without waiting. Idempotent; called from every path that
    /// abandons a session, including several that run before `begin` finished.
    func abort() async

    /// Speculative text, for display only. Each value replaces the last.
    /// Nothing that arrives here may reach the cursor, History, or `rawTranscript`
    /// — it is a guess the model is still revising.
    var partials: AsyncStream<String> { get }
}
