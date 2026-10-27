//! Alpha decoded on the CPU from the GPU plans (JXL research X5, F26). The alpha groups' entropy streams are long
//! and serial (one 256x256 group is one ~65 k-sample chain): ~230-490 ns a sample on a GPU thread but ~5 ns on a
//! CPU core, and there are only a few hundred real ones. So the stager can decode them while it stages and hand
//! the GPU finished rows: each real group's plan becomes kind 3 (word 31 = its rows' word offset in the "adata"
//! section, ceil(w / 4) words a row, 4 pixels a word), which the alpha kernel only copies into the plane.
//! Same decode as stager/src/bin/alphacheck.rs (checked against jxl-oxide there).

use rayon::prelude::*;

use crate::APL_STRIDE;

struct Bits<'a> {
    w: &'a [u32],
    pos: u32,
}

impl Bits<'_> {
    #[inline]
    fn peek(&self, n: u32) -> u32 {
        let i = (self.pos >> 5) as usize;
        let s = self.pos & 31;
        let lo = self.w[i] >> s;
        let hi = if s == 0 { 0 } else { self.w[i + 1] << (32 - s) };
        let v = lo | hi;
        if n >= 32 { v } else { v & ((1u32 << n) - 1) }
    }
    #[inline]
    fn read(&mut self, n: u32) -> u32 {
        if n == 0 {
            return 0;
        }
        let v = self.peek(n);
        self.pos += n;
        v
    }
}

/// One group's entropy decoder from the job's tables.
struct Dec<'a> {
    t: &'a [u32],
    base: usize,
    prefix: bool,
    clusters: usize,
    log_bucket: u32,
    state: u32,
    ptab: Vec<usize>,
}

impl Dec<'_> {
    #[inline]
    fn token(&mut self, b: &mut Bits, cl: u32) -> u32 {
        if self.prefix {
            let o = self.ptab[cl as usize];
            let (top_bits, top_n) = (self.t[o], self.t[o + 1] as usize);
            let peeked = b.peek(15);
            let e = self.t[o + 3 + (peeked & ((1 << top_bits) - 1)) as usize];
            if e & 1 != 0 {
                let ofs = (e >> 16) + ((peeked >> top_bits) & ((e >> 8) & 0xff));
                let e2 = self.t[o + 3 + top_n + ofs as usize];
                b.read((e2 >> 8) & 0xff);
                e2 >> 16
            } else {
                b.read((e >> 8) & 0xff);
                e >> 16
            }
        } else {
            let idx = self.state & 0xfff;
            let i = idx >> self.log_bucket;
            let p = idx & ((1 << self.log_bucket) - 1);
            let at = self.base + self.clusters * 4 + ((cl as usize) << (12 - self.log_bucket)) * 2 + i as usize * 2;
            let (lo, hi) = (self.t[at], self.t[at + 1]);
            let map = p >= ((lo >> 8) & 0xff);
            let dist = (lo >> 16) ^ if map { hi >> 16 } else { 0 };
            let offset = p + if map { hi & 0xffff } else { 0 };
            let tok = if map { lo & 0xff } else { i };
            let next = (self.state >> 12) * dist + offset;
            self.state = if next < 0x10000 { (next << 16) | b.read(16) } else { next };
            tok
        }
    }

    #[inline]
    fn varint(&mut self, b: &mut Bits, cl: u32, cfg: [u32; 4]) -> u32 {
        let token = self.token(b, cl);
        let [split_exponent, split, msb, lsb] = cfg;
        if token < split {
            return token;
        }
        let n = (split_exponent - (msb + lsb) + ((token - split) >> (msb + lsb))) & 31;
        let rest = b.read(n);
        let low = token & ((1 << lsb) - 1);
        let top = ((token >> lsb) & ((1 << msb) - 1)) | (1 << msb);
        (((top << n) | rest) << lsb) | low
    }
}

#[inline]
fn unpack(v: u32) -> i32 {
    ((v >> 1) as i32) ^ -((v & 1) as i32)
}

/// Palette inverse for one 8-bit channel, no deltas, Zero delta predictor (what the files use).
fn palette_value(pal: &[i32], index: i32) -> i32 {
    let n = pal.len() as i32;
    if (0..n).contains(&index) {
        pal[index as usize]
    } else if index >= n {
        let i = index - n;
        if i < 64 { (i % 4) * 255 / 4 + 32 } else { ((i - 64) % 5) * 255 / 4 }
    } else {
        const DELTA0: [i32; 72] = [
            0, 4, 11, 0, 0, -10, -18, -27, -18, 0, -32, -37, 0, 24, 50, -45, -24, 0, -34, -24, -45, 64, -32, 0, -32,
            -24, 45, 24, -45, 80, 64, 0, 0, -24, 96, 64, 45, 34, 112, 24, 45, 0, 24, 0, 45, 24, -24, 0, 96, 128, 64,
            144, 96, -36, 45, 45, 0, 0, 0, 45, -128, 24, -45, 64, 64, 96, 45, 24, 64, 128, 0, -24,
        ];
        let i = (-(index + 1) % 143) as usize;
        let v = DELTA0[(i + 1) >> 1];
        if i & 1 == 0 { -v } else { v }
    }
}

/// The ANS path's bit reader: a 64-bit buffer refilled a word at a time.
struct Br<'a> {
    w: &'a [u32],
    next: usize,
    buf: u64,
    n: u32,
}

impl<'a> Br<'a> {
    fn new(w: &'a [u32], pos: u32) -> Self {
        let i = (pos >> 5) as usize;
        Br { w, next: i + 1, buf: (w[i] >> (pos & 31)) as u64, n: 32 - (pos & 31) }
    }
    #[inline]
    fn read(&mut self, k: u32) -> u32 {
        if k == 0 {
            return 0;
        }
        if self.n < k {
            self.buf |= (self.w[self.next] as u64) << self.n;
            self.next += 1;
            self.n += 32;
        }
        let v = (self.buf & ((1u64 << k) - 1)) as u32;
        self.buf >>= k;
        self.n -= k;
        v
    }
}

/// One channel coded with rANS: its cluster's alias table as a slice, hybrid uint config, predictor (0: zero, else
/// gradient), everything for the inner loop in locals.
#[allow(clippy::too_many_arguments)]
fn ans_channel(br: &mut Br, state: &mut u32, tab: &[u32], lb: u32, cfg: [u32; 4], w: usize, h: usize, pred: u32, offset: i32, mult: i32) -> Vec<i32> {
    let mask = (1u32 << lb) - 1;
    let [split_exponent, split, msb, lsb] = cfg;
    let mut st = *state;
    let mut res = |br: &mut Br| -> i32 {
        let idx = st & 0xfff;
        let i = (idx >> lb) as usize;
        let p = idx & mask;
        let (lo, hi) = (tab[2 * i], tab[2 * i + 1]);
        let map = p >= ((lo >> 8) & 0xff);
        let dist = (lo >> 16) ^ if map { hi >> 16 } else { 0 };
        let off = p + if map { hi & 0xffff } else { 0 };
        let tok = if map { lo & 0xff } else { i as u32 };
        let next = (st >> 12) * dist + off;
        st = if next < 0x10000 { (next << 16) | br.read(16) } else { next };
        let u = if tok < split {
            tok
        } else {
            let n = (split_exponent - (msb + lsb) + ((tok - split) >> (msb + lsb))) & 31;
            let rest = br.read(n);
            let low = tok & ((1 << lsb) - 1);
            let top = ((tok >> lsb) & ((1 << msb) - 1)) | (1 << msb);
            (((top << n) | rest) << lsb) | low
        };
        unpack(u).wrapping_mul(mult).wrapping_add(offset)
    };
    let mut v = vec![0i32; w * h];
    if w > 0 && h > 0 {
        if pred == 0 {
            for s in v.iter_mut() {
                *s = res(br);
            }
        } else {
            let mut left = 0i32;
            for s in v[..w].iter_mut() {
                left = left.wrapping_add(res(br));
                *s = left;
            }
            for y in 1..h {
                let (above, rest) = v.split_at_mut(y * w);
                let above = &above[(y - 1) * w..];
                let row = &mut rest[..w];
                let n0 = above[0];
                let mut left = n0.wrapping_add(res(br));
                row[0] = left;
                let mut nw = n0;
                for (s, &n) in row[1..].iter_mut().zip(&above[1..]) {
                    left = grad(left, n, nw).wrapping_add(res(br));
                    *s = left;
                    nw = n;
                }
            }
        }
    }
    *state = st;
    v
}

/// Gradient predictor (clamped W + N - NW).
#[inline]
fn grad(w: i32, n: i32, nw: i32) -> i32 {
    w.wrapping_add(n).wrapping_sub(nw).clamp(w.min(n), w.max(n))
}

/// One channel's samples: the predictor's edge cases taken out of the inner loop (first row: W; first column: N),
/// W and NW kept in registers, the row above as a slice.
#[allow(clippy::too_many_arguments)]
fn decode_channel(d: &mut Dec, b: &mut Bits, w: usize, h: usize, cl: u32, pred: u32, offset: i32, mult: i32, cfg: [u32; 4]) -> Vec<i32> {
    let mut v = vec![0i32; w * h];
    let res = |d: &mut Dec, b: &mut Bits| unpack(d.varint(b, cl, cfg)).wrapping_mul(mult).wrapping_add(offset);
    if w == 0 || h == 0 {
        return v;
    }
    if pred == 0 {
        for s in v.iter_mut() {
            *s = res(d, b);
        }
        return v;
    }
    let mut left = 0i32;
    for s in v[..w].iter_mut() {
        left = left.wrapping_add(res(d, b));
        *s = left;
    }
    for y in 1..h {
        let (above, rest) = v.split_at_mut(y * w);
        let above = &above[(y - 1) * w..];
        let row = &mut rest[..w];
        let n0 = above[0];
        let mut left = n0.wrapping_add(res(d, b));
        row[0] = left;
        let mut nw = n0;
        for (s, &n) in row[1..].iter_mut().zip(&above[1..]) {
            left = grad(left, n, nw).wrapping_add(res(d, b));
            *s = left;
            nw = n;
        }
    }
    v
}

/// Decodes one group (kind 0 / 1 plan) into rows of packed alpha words (ceil(w / 4) a row).
pub fn decode_group(bits: &[u32], rec: &[u32], at: &[u32]) -> Vec<u32> {
    let prefix = rec[1] == 1;
    let clusters = rec[3] as usize;
    let base = rec[2] as usize;
    let nch = rec[5] as usize;
    let ncol = rec[6] as usize;
    let (gw, gh) = (rec[9] as usize, rec[10] as usize);
    let mut pal: Vec<i32> = Vec::new();
    let mut img: Vec<i32> = Vec::new();
    let mut keep = |c: usize, v: Vec<i32>| {
        if ncol > 0 && c == 0 {
            pal = v;
        } else {
            img = v;
        }
    };
    if prefix {
        let mut b = Bits { w: bits, pos: rec[0] };
        let mut d = Dec { t: at, base, prefix, clusters, log_bucket: rec[4], state: 0, ptab: Vec::new() };
        let mut o = base + clusters * 4;
        for _ in 0..clusters {
            d.ptab.push(o);
            o += 3 + at[o + 1] as usize + at[o + 2] as usize;
        }
        for c in 0..nch {
            let r = &rec[12 + c * 6..12 + c * 6 + 6];
            let co = base + r[2] as usize * 4;
            let cfg = [at[co], at[co + 1], at[co + 2], at[co + 3]];
            keep(c, decode_channel(&mut d, &mut b, r[0] as usize, r[1] as usize, r[2], r[3], r[4] as i32, r[5] as i32, cfg));
        }
    } else {
        let mut br = Br::new(bits, rec[0]);
        let mut state = br.read(32);
        let lb = rec[4];
        let tl = 1usize << (12 - lb);
        for c in 0..nch {
            let r = &rec[12 + c * 6..12 + c * 6 + 6];
            let co = base + r[2] as usize * 4;
            let cfg = [at[co], at[co + 1], at[co + 2], at[co + 3]];
            let t0 = base + clusters * 4 + r[2] as usize * tl * 2;
            let v = ans_channel(&mut br, &mut state, &at[t0..t0 + tl * 2], lb, cfg, r[0] as usize, r[1] as usize, r[3], r[4] as i32, r[5] as i32);
            keep(c, v);
        }
    }
    let wpr = gw.div_ceil(4);
    let mut out = vec![0u32; wpr * gh];
    for (orow, irow) in out.chunks_exact_mut(wpr).zip(img.chunks_exact(gw)) {
        for (x, &s) in irow.iter().enumerate() {
            let a = if ncol > 0 { palette_value(&pal, s) } else { s }.clamp(0, 255) as u32;
            orow[x / 4] |= a << ((x & 3) * 8);
        }
    }
    out
}

/// decode_group as first written (the reference the faster one is checked against: alphabench).
pub fn decode_group_ref(bits: &[u32], rec: &[u32], at: &[u32]) -> Vec<u32> {
    let mut b = Bits { w: bits, pos: rec[0] };
    let prefix = rec[1] == 1;
    let clusters = rec[3] as usize;
    let mut d = Dec { t: at, base: rec[2] as usize, prefix, clusters, log_bucket: rec[4], state: 0, ptab: Vec::new() };
    if prefix {
        let mut o = d.base + clusters * 4;
        for _ in 0..clusters {
            d.ptab.push(o);
            o += 3 + at[o + 1] as usize + at[o + 2] as usize;
        }
    } else {
        d.state = b.read(32);
    }
    let nch = rec[5] as usize;
    let ncol = rec[6] as usize;
    let (gw, gh) = (rec[9] as usize, rec[10] as usize);
    let mut pal: Vec<i32> = Vec::new();
    let mut img: Vec<i32> = Vec::new();
    for c in 0..nch {
        let r = &rec[12 + c * 6..12 + c * 6 + 6];
        let (w, hh, cl, pred, offset, mult) = (r[0] as usize, r[1] as usize, r[2], r[3], r[4] as i32, r[5] as i32);
        let co = d.base + cl as usize * 4;
        let cfg = [at[co], at[co + 1], at[co + 2], at[co + 3]];
        let mut v = vec![0i32; w * hh];
        for y in 0..hh {
            for x in 0..w {
                let p = if pred == 0 {
                    0
                } else {
                    let wv = if x > 0 { v[y * w + x - 1] } else if y > 0 { v[(y - 1) * w + x] } else { 0 };
                    let nv = if y > 0 { v[(y - 1) * w + x] } else { wv };
                    let nwv = if x > 0 && y > 0 { v[(y - 1) * w + x - 1] } else { wv };
                    (wv + nv - nwv).clamp(wv.min(nv), wv.max(nv))
                };
                v[y * w + x] = p.wrapping_add(unpack(d.varint(&mut b, cl, cfg)).wrapping_mul(mult).wrapping_add(offset));
            }
        }
        if ncol > 0 && c == 0 {
            pal = v;
        } else {
            img = v;
        }
    }
    let wpr = gw.div_ceil(4);
    let mut out = vec![0u32; wpr * gh];
    for y in 0..gh {
        for x in 0..gw {
            let s = img[y * gw + x];
            let a = if ncol > 0 { palette_value(&pal, s) } else { s }.clamp(0, 255) as u32;
            out[y * wpr + x / 4] |= a << ((x & 3) * 8);
        }
    }
    out
}

/// Decodes every real alpha group of an image (plans `apl`, tables `at`, the image's `bits`) on the CPU, groups in
/// parallel; returns the plans with those groups turned into kind 3 and the rows ("adata").
pub fn decode_all(bits: &[u32], apl: &[u32], at: &[u32]) -> (Vec<u32>, Vec<u32>) {
    let mut padded = bits.to_vec();
    padded.extend([0; 4]);
    let rows: Vec<Option<Vec<u32>>> = apl
        .par_chunks(APL_STRIDE)
        .map(|rec| if rec[1] <= 1 { Some(decode_group(&padded, rec, at)) } else { None })
        .collect();
    let mut plans = apl.to_vec();
    let mut adata = Vec::new();
    for (rec, r) in plans.chunks_exact_mut(APL_STRIDE).zip(rows) {
        if let Some(r) = r {
            rec[1] = 3;
            rec[31] = adata.len() as u32;
            adata.extend(r);
        }
    }
    (plans, adata)
}
