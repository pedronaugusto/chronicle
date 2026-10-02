// Old snapshots return values; the final API returns opaque owner pointers.
// Only ownership spelling changes; each workload makes the same calls.
pub fn ref(value: anytype) Ref(@TypeOf(value)) {
    return if (@typeInfo(@TypeOf(value.*)) == .pointer) value.* else value;
}
fn Ref(comptime T: type) type {
    return if (@typeInfo(@typeInfo(T).pointer.child) == .pointer)
        @typeInfo(T).pointer.child
    else
        T;
}
