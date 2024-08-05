//! Some metaprogramming magic to simplify operating on interface
//! types.
//!
//! An _interface_ `INTERFACE` is a parametric type like this:
//! ```
//! const INTERFACE = struct {
//!     object: *anyopaque,
//!     vt: *const Vt,
//!
//!     pub const Vt = struct {
//!         METHOD1: *const fn (*anyopaque, PARAMS1) RET1,
//!         METHOD2: *const fn (*anyopaque, PARAMS2) RET2,
//!         ...
//!     };
//!
//!     pub fn from(X: anytype) INTERFACE {
//!         return @import("Interface.zig").cast(INTERFACE, X);
//!     }
//!
//!     pub fn METHOD1(self: INTERFACE, PARAMS1) RET1 {
//!         return self.vt.METHOD1(self.object, PARAMS1);
//!     }
//!
//!     pub fn METHOD2(self: INTERFACE, PARAMS2) RET2 {
//!         return self.vt.METHOD2(self.object, PARAMS2);
//!     }
//!     ...
//! }
//! ```
//! where all upper-case words refer to template parameters.
//!
//! Then, you could cast any object carrying the same methods to the
//! interface like this:
//! ```
//! const interfaceObject = INTERFACE.cast(myObject);
//! ```

const Type = @import("std").builtin.Type;

// Ensure type-safety of performing a `@ptrCast` operation on the
// given method. The `method` argument is used as a comptime template
// to construct an analogous method type on `T`.
fn methodTypeCheck(method: Type.StructField, comptime T: type) void {
    const method_ptr_info = @typeInfo(method.type);
    comptime var method_info = @typeInfo(method_ptr_info.Pointer.child);
    const orig_params = method_info.Fn.params;
    comptime var params: [orig_params.len]Type.Fn.Param = undefined;
    inline for (orig_params, 0..) |param, j| {
        params[j] = param;
    }
    params[0].type = *T;
    method_info.Fn.params = &params;
    _ = @as(@Type(method_info), @field(T, method.name));
}

// Construct a struct type that holds a virtual table for `T`.
fn VtWrapperStruct(Vtab: type, comptime T: type) type {
    comptime var vtab: Vtab = undefined;
    inline for (@typeInfo(Vtab).Struct.fields) |method| {
        methodTypeCheck(method, T);
        @field(vtab, method.name) = @ptrCast(&@field(T, method.name));
    }
    return struct {
        const vt = vtab;
    };
}

/// Cast `object` to the given interface type.
pub fn cast(InterfaceType: type, object: anytype) InterfaceType {
    return .{
        .object = @ptrCast(object),
        .vt = &VtWrapperStruct(InterfaceType.Vt, @TypeOf(object.*)).vt,
    };
}
