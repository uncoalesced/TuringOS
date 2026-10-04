# Vendored glib 0.18.5 (security patch)

Unmodified crates.io `glib v0.18.5` except for the fix noted below.

## Why this is vendored

`glib` < 0.20.0 has an unsoundness in `VariantStrIter::impl_get`
(RUSTSEC-2024-0429 / GHSA-wrw7-89jp-8q8g, upstream fix gtk-rs/gtk-rs-core#1343):

- `g_variant_get_child` is variadic and takes `p` as a C out-argument.
- The code passed `&p` — a shared reference to a `*mut c_char` — where C
  mutates the pointee in place. The compiler may assume `&p` is never mutated,
  so under optimization the write is dropped and `p` stays `NULL`.
- `std::ffi::CStr::from_ptr(p)` then dereferences `NULL`: undefined behaviour,
  crash on every call.

A version bump is not possible: `tauri` 2.x hard-pins `gtk = "0.18"`, and
`gtk`/`atk`/`cairo-rs` 0.18 require `glib ^0.18`. No fixed `0.18.x` was ever
released, and the glib dependency only exists on Linux/BSD targets.

## The patch

`src/variant_iter.rs`, `VariantStrIter::impl_get`, matching glib 0.20.0:

```diff
-            let p: *mut libc::c_char = std::ptr::null_mut();
+            let mut p: *mut libc::c_char = std::ptr::null_mut();
             let s = b"&s\0";
             ffi::g_variant_get_child(
                 self.variant.to_glib_none().0,
                 i,
                 s as *const u8 as *const _,
-                &p,
+                &mut p,
                 std::ptr::null::<i8>(),
             );
```

## Removal condition

Drop `vendor/glib` and the `[patch.crates-io]` entry in `../Cargo.toml` once
the tauri upgrade pulls `gtk`/`glib` >= 0.20.