// rust-crypto/src/lib.rs - Rust crypto implementations for benchmarking
// Using the sha2 crate for SHA256 and SHA512 with hardware acceleration

use sha2::{Digest, Sha256, Sha512};

/// SHA256 using sha2 crate with hardware acceleration
#[no_mangle]
pub extern "C" fn rust_sha256(data: *const u8, len: usize, output: *mut u8) {
    let input = unsafe { std::slice::from_raw_parts(data, len) };

    // Create hasher and process data
    let mut hasher = Sha256::new();
    hasher.update(input);
    let result = hasher.finalize();

    // Copy result to output buffer
    unsafe {
        std::ptr::copy_nonoverlapping(result.as_ptr(), output, 32);
    }
}

/// SHA512 using sha2 crate with hardware acceleration
#[no_mangle]
pub extern "C" fn rust_sha512(data: *const u8, len: usize, output: *mut u8) {
    let input = unsafe { std::slice::from_raw_parts(data, len) };

    // Create hasher and process data
    let mut hasher = Sha512::new();
    hasher.update(input);
    let result = hasher.finalize();

    // Copy result to output buffer
    unsafe {
        std::ptr::copy_nonoverlapping(result.as_ptr(), output, 64);
    }
}
