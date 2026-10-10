//! The JSON Lines capability used by the journal.
pub const strand = @import("strand");

/// strand's limits for a record or document of at most `bytes`: its defaults,
/// raised where a value that long needs more. The journal bounds its records
/// and documents by their bytes, and a value is never more than its bytes can
/// spell.
pub fn limits(bytes: usize) strand.core.Limits {
    var result: strand.core.Limits = .{};
    result.input_bytes = @max(result.input_bytes, bytes);
    result.output_bytes = @max(result.output_bytes, bytes);
    result.string_bytes = @max(result.string_bytes, bytes);
    result.key_bytes = @max(result.key_bytes, bytes);
    result.items = @max(result.items, bytes);
    result.container_items = @max(result.container_items, bytes);
    // A string held whole, and the work of reading and checking it, are a
    // small multiple of its length.
    result.allocation_bytes = @max(result.allocation_bytes, bytes *| 2);
    result.work = @max(result.work, bytes *| 8);
    return result;
}
