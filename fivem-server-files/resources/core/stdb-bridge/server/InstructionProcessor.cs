using CitizenFX.Core;
using SpacetimeDB.Types;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;

namespace StdbBridge
{
    /// <summary>
    /// Owns the ConcurrentQueue of incoming InstructionQueue rows.
    /// Drains them in bounded batches on the main FXServer tick.
    ///
    /// WHY ConcurrentQueue?
    /// SpacetimeDB's OnInsert callback fires on a background WebSocket thread.
    /// FiveM Natives MUST be called from the main server thread.
    /// ConcurrentQueue is the lock-free bridge between these two threads.
    /// </summary>
    public class InstructionProcessor
    {
        // ConcurrentQueue is thread-safe for one-producer / one-consumer patterns.
        // Multiple producers (STDB network thread) ? single consumer (tick thread).
        private readonly ConcurrentQueue<InstructionQueue> _queue
            = new ConcurrentQueue<InstructionQueue>();

        private readonly BaseScript _script;
        private readonly NativeDispatcher _dispatcher;

        // Tracks IDs we've already processed in this session to prevent
        // double-execution if STDB re-delivers (e.g., reconnect snapshot).
        private readonly HashSet<ulong> _processedIds = new HashSet<ulong>();

        public InstructionProcessor(BaseScript script)
        {
            _script = script;
            _dispatcher = new NativeDispatcher(script);
        }

        // ?? PRODUCER: called from STDB network thread ????????????????????????

        /// Enqueue a new instruction row. Called by InstructionQueue.OnInsert.
        public void EnqueueInstruction(EventContext ctx, InstructionQueue row)
        {
            // Pre-filter already-consumed rows (defensive, STDB filter handles most).
            if (row.Consumed) return;

            _queue.Enqueue(row);
        }

        // ?? CONSUMER: called from FXServer main tick thread ??????????????????

        /// Process up to [maxPerTick] instructions per server frame.
        /// Keeps frame time predictable even under instruction bursts.
        public void Drain(int maxPerTick = 20)
        {
            int processed = 0;

            while (processed < maxPerTick && _queue.TryDequeue(out var instruction))
            {
                // Idempotency guard: skip if we've already executed this ID.
                if (_processedIds.Contains(instruction.Id))
                    continue;

                try
                {
                    _dispatcher.Execute(instruction);
                    _processedIds.Add(instruction.Id);
                    processed++;

                    // Mark consumed in STDB so the subscription filter drops it.
                    // This is a lightweight reducer call   no server round-trip bloat.
                    MarkConsumed(instruction.Id);
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"[Processor] Failed instruction {instruction.Id} " +
                                    $"({instruction.NativeKey}): {ex.Message}");
                    // Don't re-queue   log for audit. Could write to an ErrorLog table.
                }
            }

            // Periodic cleanup: trim _processedIds to prevent unbounded growth.
            // In production, use a ring buffer or timestamp-based eviction.
            if (_processedIds.Count > 50_000)
                _processedIds.Clear(); // simple; production should evict oldest
        }

        private static void MarkConsumed(ulong instructionId)
        {
            // Reducer call: mark_instruction_consumed(id)
            // Defined in core/src/instruction.rs (omitted for brevity)
            // Bridge._db.Reducers.MarkInstructionConsumed(instructionId);
        }
    }
}