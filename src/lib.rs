//! BodySlider native side: rewrites USkeletalMesh::RefBasesInvMatrix in memory.
//! Scaling a bone's inverse bind matrix about its bind-pose pivot == reshaping the mesh in bind space,
//! and the renderer reads these matrices every frame, so changes show up live.
//! The Lua mod writes `cmd.txt` (full state); a worker thread here applies it whenever it changes.
//! Line format: `<mesh_addr_hex> <num_bones> <pivot_bone> <scale> <bone> <bone> ...`
//!   scale `s`        : uniform, about the pivot bone's bind origin (volume sliders)
//!   scale `sx,sy,sz` : along the pivot bone's own axes, about its origin (thickness, nipple length, ...)
//! Lines stack: a bone listed twice gets both scales (e.g. breast size + nipple length).
// ponytail: file polling (100ms) instead of an IPC channel; no Windows crates, raw kernel32 FFI.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

type Mat = [f32; 16]; // FMatrix, row-major, row-vector convention (translation in row 3)

#[repr(C)]
struct MemInfo {
    base: usize, alloc_base: usize, alloc_protect: u32, partition: u16,
    size: usize, state: u32, protect: u32, typ: u32,
}

extern "system" {
    fn VirtualQuery(addr: usize, info: *mut MemInfo, len: usize) -> usize;
    fn GetModuleFileNameW(module: usize, buf: *mut u16, size: u32) -> u32;
    fn GetModuleHandleExW(flags: u32, name: *const u16, module: *mut usize) -> i32;
}

static mut MODULE: usize = 0;

fn readable(addr: usize, len: usize) -> bool {
    if addr < 0x10000 { return false; }
    let mut p = addr;
    while p < addr + len {
        let mut mi: MemInfo = unsafe { std::mem::zeroed() };
        if unsafe { VirtualQuery(p, &mut mi, std::mem::size_of::<MemInfo>()) } == 0 { return false; }
        const MEM_COMMIT: u32 = 0x1000;
        const RW_MASK: u32 = 0x04 | 0x40 | 0x08 | 0x80; // RW, ERW, WC, EWC
        if mi.state != MEM_COMMIT || mi.protect & RW_MASK == 0 || mi.protect & 0x100 != 0 { return false; }
        p = mi.base + mi.size;
    }
    true
}

fn looks_like_inv_array(ptr: usize, n: usize) -> bool {
    if !readable(ptr, n * 64) { return false; }
    let m = unsafe { std::slice::from_raw_parts(ptr as *const Mat, n) };
    m.iter().all(|x| x[3].abs() < 1e-3 && x[7].abs() < 1e-3 && x[11].abs() < 1e-3 && (x[15] - 1.0).abs() < 1e-3)
}

/// Find the TArray<FMatrix> RefBasesInvMatrix inside the USkeletalMesh object by shape.
fn find_inv_array(mesh: usize, n: usize) -> Option<usize> {
    if !readable(mesh, 0x1000) { return None; }
    (0x28..0x1000).step_by(8).find_map(|off| unsafe {
        let ptr = *((mesh + off) as *const usize);
        let num = *((mesh + off + 8) as *const i32);
        let max = *((mesh + off + 12) as *const i32);
        (num as usize == n && max >= num && looks_like_inv_array(ptr, n)).then_some(ptr)
    })
}

fn inv3(m: &Mat) -> [[f32; 3]; 3] {
    let r = [[m[0], m[1], m[2]], [m[4], m[5], m[6]], [m[8], m[9], m[10]]];
    let det = r[0][0] * (r[1][1] * r[2][2] - r[1][2] * r[2][1]) - r[0][1] * (r[1][0] * r[2][2] - r[1][2] * r[2][0])
        + r[0][2] * (r[1][0] * r[2][1] - r[1][1] * r[2][0]);
    [
        [(r[1][1] * r[2][2] - r[1][2] * r[2][1]) / det, (r[0][2] * r[2][1] - r[0][1] * r[2][2]) / det, (r[0][1] * r[1][2] - r[0][2] * r[1][1]) / det],
        [(r[1][2] * r[2][0] - r[1][0] * r[2][2]) / det, (r[0][0] * r[2][2] - r[0][2] * r[2][0]) / det, (r[0][2] * r[1][0] - r[0][0] * r[1][2]) / det],
        [(r[1][0] * r[2][1] - r[1][1] * r[2][0]) / det, (r[0][1] * r[2][0] - r[0][0] * r[2][1]) / det, (r[0][0] * r[1][1] - r[0][1] * r[1][0]) / det],
    ]
}

fn mul(a: &Mat, b: &Mat) -> Mat {
    let mut o = [0.0; 16];
    for r in 0..4 { for c in 0..4 { o[r * 4 + c] = (0..4).map(|k| a[r * 4 + k] * b[k * 4 + c]).sum(); } }
    o
}

/// Sc = P * D * P^-1 (P = the pivot bone's inverse bind matrix): scales by d along that bone's own axes, about its origin.
fn axis_scaler(p: &Mat, d: [f32; 3]) -> Mat {
    let mut pd = *p;
    for r in 0..4 { for c in 0..3 { pd[r * 4 + c] *= d[c]; } }
    let ri = inv3(p);
    let mut pinv = [0.0f32; 16];
    for r in 0..3 { for c in 0..3 { pinv[r * 4 + c] = ri[r][c]; } }
    for c in 0..3 { pinv[12 + c] = -(p[12] * ri[0][c] + p[13] * ri[1][c] + p[14] * ri[2][c]); }
    pinv[15] = 1.0;
    mul(&pd, &pinv)
}

/// Bind-pose component-space origin of the bone whose inverse bind matrix is `m`.
fn pivot_of(m: &Mat) -> [f32; 3] {
    // m = inverse(Ref); Ref origin p satisfies p*R + t = 0  ->  p = -t * R^-1
    let inv = inv3(m);
    let t = [m[12], m[13], m[14]];
    let mut p = [0.0; 3];
    for c in 0..3 { p[c] = -(t[0] * inv[0][c] + t[1] * inv[1][c] + t[2] * inv[2][c]); }
    p
}

/// M' = Sc * M where Sc scales by `s` about pivot `p` (row-vector convention).
fn scaled(m: &Mat, p: [f32; 3], s: f32) -> Mat {
    let mut o = *m;
    for c in 0..4 {
        for r in 0..3 { o[r * 4 + c] = s * m[r * 4 + c]; }
        o[12 + c] = (1.0 - s) * (p[0] * m[c] + p[1] * m[4 + c] + p[2] * m[8 + c]) + m[12 + c];
    }
    o
}

// Only meshes listed in the current cmd.txt are live (Lua lists every live heroine mesh, scale 1.0 included).
// Never write to anything else: an unloaded mesh's matrix array is freed memory the engine reuses
// (writing "restores" there corrupted a pak decompression buffer -> LowLevelFatalError).
#[derive(Default)]
struct State {
    originals: HashMap<(usize, usize), Mat>, // (array ptr, bone) -> original matrix
    written: HashMap<(usize, usize), Mat>,   // what we last wrote there
}

impl State {
    fn apply(&mut self, text: &str) {
        let mut want: HashMap<(usize, usize), Mat> = HashMap::new();
        for line in text.lines() {
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() < 5 { continue; }
            let (Ok(mesh), Ok(n), Ok(pivot)) = (
                usize::from_str_radix(f[0].trim_start_matches("0x"), 16), f[1].parse::<usize>(), f[2].parse::<usize>()) else { continue };
            let s: Vec<f32> = f[3].split(',').filter_map(|x| x.parse().ok()).collect();
            if !(s.len() == 1 || s.len() == 3) || s.iter().any(|v| !(0.2..=6.0).contains(v)) || pivot >= n { continue; }
            // ponytail: re-find every apply (only runs when cmd.txt changes); a cached ptr can go stale
            let Some(arr) = find_inv_array(mesh, n) else { continue };
            let mats = unsafe { std::slice::from_raw_parts(arr as *const Mat, n) };
            let po = self.original(arr, pivot, &mats[pivot]);
            let (p, axes) = (pivot_of(&po), (s.len() == 3).then(|| axis_scaler(&po, [s[0], s[1], s[2]])));
            for b in f[4..].iter().filter_map(|x| x.parse::<usize>().ok()).filter(|&b| b < n) {
                let o = self.original(arr, b, &mats[b]);
                let cur = *want.get(&(arr, b)).unwrap_or(&o);  // stack on earlier lines for this bone
                want.insert((arr, b), match &axes { Some(sc) => mul(sc, &cur), None => scaled(&cur, p, s[0]) });
            }
        }
        // keep history of meshes that left the list (an asset can come back still scaled), but never write to them
        for (k, m) in want { unsafe { write(k, &m) }; self.written.insert(k, m); }
    }

    /// Original matrix of (arr, b). If memory no longer holds what we wrote, the array was replaced: recapture.
    fn original(&mut self, arr: usize, b: usize, cur: &Mat) -> Mat {
        let ours = self.written.get(&(arr, b)).map_or(false, |w| w == cur);
        if !ours || !self.originals.contains_key(&(arr, b)) { self.originals.insert((arr, b), *cur); }
        self.originals[&(arr, b)]
    }
}

unsafe fn write((arr, b): (usize, usize), m: &Mat) {
    let dst = (arr + b * 64) as *mut Mat;
    if readable(dst as usize, 64) { std::ptr::write_volatile(dst, *m); }
}

fn cmd_path() -> PathBuf {
    let mut buf = [0u16; 1024];
    let n = unsafe { GetModuleFileNameW(MODULE, buf.as_mut_ptr(), buf.len() as u32) } as usize;
    PathBuf::from(String::from_utf16_lossy(&buf[..n])).with_file_name("cmd.txt")
}

fn worker() {
    let path = cmd_path();
    let mut last: Option<SystemTime> = None;
    let mut st = State::default();
    loop {
        if let Ok(t) = std::fs::metadata(&path).and_then(|m| m.modified()) {
            if Some(t) != last {
                last = Some(t);
                if let Ok(text) = std::fs::read_to_string(&path) { st.apply(&text); }
            }
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[no_mangle]
pub extern "system" fn DllMain(module: usize, reason: u32, _: usize) -> i32 {
    if reason == 1 {
        unsafe { MODULE = module };
        // Pin: UE4SS hot reload closes the Lua state, which FreeLibrary's us while the worker runs -> crash.
        const PIN: u32 = 0x1; const FROM_ADDRESS: u32 = 0x4;
        let mut h = 0usize;
        unsafe { GetModuleHandleExW(PIN | FROM_ADDRESS, DllMain as *const u16, &mut h) };
        std::thread::spawn(worker); // starts after loader lock is released
    }
    1
}

#[cfg(test)]
mod tests {
    use super::*;
    // Ref bone at (10,20,30) rotated 90deg about Z, uniform scale 1. Its inverse bind matrix:
    fn inv_ref() -> Mat {
        // Ref (row-vector): R = [[0,1,0],[-1,0,0],[0,0,1]], t = (10,20,30). inverse: R^T, -t*R^T
        let rt = [[0.0, -1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0f32]];
        let t = [10.0, 20.0, 30.0f32];
        let mut m = [0.0f32; 16];
        for r in 0..3 { for c in 0..3 { m[r * 4 + c] = rt[r][c]; } }
        for c in 0..3 { m[12 + c] = -(t[0] * rt[0][c] + t[1] * rt[1][c] + t[2] * rt[2][c]); }
        m[15] = 1.0;
        m
    }
    fn xf(v: [f32; 3], m: &Mat) -> [f32; 3] {
        let mut o = [0.0; 3];
        for c in 0..3 { o[c] = v[0] * m[c] + v[1] * m[4 + c] + v[2] * m[8 + c] + m[12 + c]; }
        o
    }
    #[test]
    fn pivot_and_scale() {
        let m = inv_ref();
        let p = pivot_of(&m);
        assert!((p[0] - 10.0).abs() < 1e-4 && (p[1] - 20.0).abs() < 1e-4 && (p[2] - 30.0).abs() < 1e-4, "{p:?}");
        // a bind-pose vertex 2 units from the pivot must land 2*s units away after scaling
        let v = [12.0, 20.0, 30.0];
        let s = 1.5;
        let a = xf(v, &m);
        let b = xf(v, &scaled(&m, p, s));
        let len = |q: [f32; 3]| (q[0] * q[0] + q[1] * q[1] + q[2] * q[2]).sqrt();
        assert!((len(a) - 2.0).abs() < 1e-4 && (len(b) - 3.0).abs() < 1e-4, "{a:?} {b:?}");
        // pivot itself never moves
        assert!(len(xf(p, &scaled(&m, p, s))) < 1e-4);
    }
    #[test]
    fn axis_scale() {
        // the bone's local X axis points along model +Y here (R row 0 = (0,1,0)), local Y along model -X
        let m = inv_ref();
        let sc = axis_scaler(&m, [2.0, 1.0, 1.0]);
        let len = |q: [f32; 3]| (q[0] * q[0] + q[1] * q[1] + q[2] * q[2]).sqrt();
        let along_x = xf([10.0, 22.0, 30.0], &mul(&sc, &m));  // 2 units along local X -> 4
        let along_y = xf([8.0, 20.0, 30.0], &mul(&sc, &m));   // 2 units along local Y -> stays 2
        assert!((len(along_x) - 4.0).abs() < 1e-4 && (len(along_y) - 2.0).abs() < 1e-4, "{along_x:?} {along_y:?}");
        // uniform axis scale == the old pivot scale
        let (a, b) = (mul(&axis_scaler(&m, [1.5; 3]), &m), scaled(&m, pivot_of(&m), 1.5));
        assert!(a.iter().zip(b.iter()).all(|(x, y)| (x - y).abs() < 1e-4));
    }
}
