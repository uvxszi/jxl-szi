//! JPEG XL research X5 (library): builds a GPU decode job per .jxl (VarDCT, the fd4 profile): the pass groups' HF bitstreams,
//! the entropy tables, block info, LF image, chroma-from-luma maps and dequant matrices, plus references from
//! jxl-oxide to check a GPU decoder against (HF coefficients, XYB after the transforms, final RGBA8).
//!   stager <out dir> [--no-refs] <file.jxl>...
//!   stager --time <file.jxl>...   (CPU cost of staging only, all files at once on all cores, nothing written)
//!   stager --profile <file.jxl>...   (staging only, one thread: time per jxl-oxide tracing span)
//! Job file: "SZIJ", u32 version, u32 header length, JSON header, then the sections it lists ([byte offset, length]
//! from the file start, 16-byte aligned).


#![recursion_limit = "256"]

pub mod alpha_cpu;
pub mod side;

use jxl_oxide::{JxlImage, JxlThreadPool};
use jxl_render::gpu_dump::{self, GpuDump};
pub use serde_json::{Value, json};

/// stage_bytes decodes the real alpha groups on the CPU (alpha_cpu) instead of leaving them to the GPU kernel.
pub static CPU_ALPHA: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// stage_bytes stages from a file's sziS side box when it has one (side.rs) instead of with jxl-oxide.
pub static USE_SIDE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);

const ORDER_SIZES: [(u32, u32); 7] = [(8, 8), (8, 8), (16, 16), (32, 32), (16, 8), (32, 8), (32, 16)];

pub fn order_id(t: u8) -> u32 {
    match t {
        0 => 0,
        1 | 2 | 3 | 12 | 13 | 14 | 15 | 16 | 17 => 1,
        4 => 2,
        5 => 3,
        6 | 7 => 4,
        8 | 9 => 5,
        10 | 11 => 6,
        _ => 99,
    }
}

/// Varblock size in 8x8 blocks (w, h), as jxl-vardct's dct_select_size.
pub fn block_size(t: u8) -> (u32, u32) {
    match t {
        0..=3 | 12..=17 => (1, 1),
        4 => (2, 2),
        5 => (4, 4),
        6 => (1, 2),
        7 => (2, 1),
        8 => (1, 4),
        9 => (4, 1),
        10 => (2, 4),
        11 => (4, 2),
        _ => (0, 0),
    }
}

pub struct Sections {
    pub data: Vec<(String, Vec<u8>)>,
}

impl Sections {
    pub fn add(&mut self, name: &str, bytes: Vec<u8>) {
        self.data.push((name.to_string(), bytes));
    }

    /// Replaces a section (or adds it).
    pub fn set(&mut self, name: &str, bytes: Vec<u8>) {
        match self.data.iter_mut().find(|(n, _)| n == name) {
            Some(e) => e.1 = bytes,
            None => self.add(name, bytes),
        }
    }
}

// little-endian bytes of 32-bit values, a chunk at a time (collecting byte by byte was a good part of staging)
fn u32s(v: &[u32]) -> Vec<u8> {
    let mut out = vec![0u8; v.len() * 4];
    for (o, x) in out.chunks_exact_mut(4).zip(v) {
        o.copy_from_slice(&x.to_le_bytes());
    }
    out
}
fn i32s(v: &[i32]) -> Vec<u8> {
    let mut out = vec![0u8; v.len() * 4];
    for (o, x) in out.chunks_exact_mut(4).zip(v) {
        o.copy_from_slice(&x.to_le_bytes());
    }
    out
}
fn f32s(v: &[f32]) -> Vec<u8> {
    let mut out = vec![0u8; v.len() * 4];
    for (o, x) in out.chunks_exact_mut(4).zip(v) {
        o.copy_from_slice(&x.to_le_bytes());
    }
    out
}

/// `lean`: only what the GPU loader's kernels read (hf_decode6, vd8 / vdl2 NATURAL, BcStage): no legacy tables or
/// groups, no inverse orders, no two-word block records, no references.
pub fn build(d: &GpuDump, rgba: Vec<u8>, name: &str, refs: bool) -> Result<(Value, Sections), String> {
    build_mode(d, rgba, name, refs, false)
}

pub fn build_mode(d: &GpuDump, rgba: Vec<u8>, name: &str, refs: bool, lean: bool) -> Result<(Value, Sections), String> {
    if d.buckets.is_empty() || d.extra_passes.iter().any(|p| p.buckets.is_empty()) {
        return Err("HF stream uses prefix codes or LZ77".into());
    }
    if d.num_hf_presets != 1 {
        return Err(format!("{} HF presets", d.num_hf_presets));
    }
    let mut s = Sections { data: Vec::new() };
    let (w8, h8) = (d.w8 as usize, d.h8 as usize);

    let _span = tracing::info_span!("pack: bitstreams").entered();
    // bits: each group's section from a word boundary, two zero words after it (little-endian bytes as they are)
    let mut bits: Vec<u8> = Vec::with_capacity(d.group_bytes.iter().map(|b| b.len() + 12).sum());
    let mut section_base: Vec<u32> = Vec::new(); // the word in "bits" where each group's section starts
    let mut groups: Vec<u32> = Vec::new();
    let gd8 = d.group_dim / 8;
    for (g, bytes) in d.group_bytes.iter().enumerate() {
        let start = d.group_start_bit[g];
        let base = (bits.len() / 4) as u32;
        section_base.push(base);
        let word_ofs = base + start / 32;
        bits.extend_from_slice(bytes);
        bits.resize(bits.len().div_ceil(4) * 4 + 8, 0);
        // entries are pass-major: pass p's group g is entry p * num_groups + g
        let gx = (g as u32 % d.num_groups) % d.groups_per_row;
        let gy = (g as u32 % d.num_groups) / d.groups_per_row;
        let bx0 = gx * gd8;
        let by0 = gy * gd8;
        let bw = (d.w8 - bx0).min(gd8);
        let bh = (d.h8 - by0).min(gd8);
        groups.extend([word_ofs, start % 32, bx0, by0, bw, bh, (bytes.len() as u32) * 8, 0]);
    }
    s.add("bits", bits);

    drop(_span);
    let _span = tracing::info_span!("pack: alpha plans").entered();
    // alpha: per pass-0 group, a plan (where its modular data starts, its local tree's leaves, palette) and its
    // entropy tables, for the GPU alpha kernel
    let (apl, atables, alpha_note) = plan_alpha(d, &section_base);
    s.add("apl", u32s(&apl));
    s.add("atables", u32s(&atables));
    if !lean { s.add("groups", u32s(&groups)); }

    drop(_span);
    let _span = tracing::info_span!("pack: entropy tables + orders").entered();
    // tables, in u32 words (the older kernels'; not built when lean)
    let nbc = d.num_block_clusters;
    let mut t: Vec<u32> = Vec::new();
    let (mut t_cmap, mut t_cfg, mut t_bkt, mut t_bctx, mut t_ord) = (0, 0, 0, 0, 0);
    let mut ord_ofs = Vec::new();
    if !lean {
        t_cmap = t.len();
        t.extend(d.cluster_map[..(495 * nbc) as usize].iter().map(|&c| c as u32));
        t_cfg = t.len();
        for c in &d.configs {
            t.extend(c);
        }
        t_bkt = t.len();
        for b in &d.buckets {
            for &w in b {
                t.extend([w as u32, (w >> 32) as u32]);
            }
        }
        t_bctx = t.len();
        t.extend(d.block_ctx_map.iter().map(|&c| c as u32));
        t_ord = t.len();
        for o in 0..7 {
            for c in 0..3 {
                ord_ofs.push((t.len() - t_ord) as u32);
                let ord = &d.orders[o * 3 + c];
                let (ow, oh) = ORDER_SIZES[o];
                if ord.len() != (ow * oh) as usize {
                    return Err(format!("order {o} channel {c}: {} entries", ord.len()));
                }
                t.extend(ord.iter().map(|&(x, y)| x as u32 | (y as u32) << 16));
            }
        }
        s.add("tables", u32s(&t));
    }

    // per pass (for hf_decode6): cluster map, integer configs, alias buckets, coefficient orders
    let mut pt: Vec<u32> = Vec::new();
    let mut passes = Vec::new();
    for p in 0..d.num_passes as usize {
        let (cmap, configs, lbs, buckets, orders) = if p == 0 {
            (&d.cluster_map, &d.configs, d.log_bucket_size, &d.buckets, &d.orders)
        } else {
            let e = &d.extra_passes[p - 1];
            (&e.cluster_map, &e.configs, e.log_bucket_size, &e.buckets, &e.orders)
        };
        let p_cmap = pt.len();
        pt.extend(cmap[..(495 * nbc) as usize].iter().map(|&c| c as u32));
        let p_cfg = pt.len();
        for c in configs {
            pt.extend(c);
        }
        let p_bkt = pt.len();
        for b in buckets {
            for &w in b {
                pt.extend([w as u32, (w >> 32) as u32]);
            }
        }
        let p_ord = pt.len();
        let mut p_ord_ofs = Vec::new();
        for o in 0..7 {
            for c in 0..3 {
                p_ord_ofs.push((pt.len() - p_ord) as u32);
                pt.extend(orders[o * 3 + c].iter().map(|&(x, y)| x as u32 | (y as u32) << 16));
            }
        }
        passes.push(json!({
            "t_cmap": p_cmap, "t_cfg": p_cfg, "t_bkt": p_bkt, "t_ord": p_ord, "ord_ofs": p_ord_ofs,
            "num_clusters": configs.len(), "log_bucket_size": lbs, "shift": d.pass_shift[p],
        }));
    }
    s.add("ptables", u32s(&pt));

    // inverse coefficient orders for the transform pass: per order id 0-6, channel, orientation (1 = transposed,
    // as the varblock types with h >= w use): natural raster position in the varblock -> decode index k
    let mut iord: Vec<u32> = Vec::new();
    let mut iord_ofs = Vec::new();
    for o in 0..if lean { 0 } else { 7 } {
        for c in 0..3 {
            for tr in 0..2 {
                iord_ofs.push(iord.len() as u32);
                let ord = &d.orders[o * 3 + c];
                let (ow, oh) = ORDER_SIZES[o];
                let base = iord.len();
                iord.resize(base + ord.len(), u32::MAX);
                for (k, &(x, y)) in ord.iter().enumerate() {
                    let p = if tr == 1 { x as u32 * oh + y as u32 } else { y as u32 * ow + x as u32 };
                    iord[base + p as usize] = k as u32;
                }
                if iord[base..].contains(&u32::MAX) {
                    return Err(format!("order {o} channel {c} is not a permutation"));
                }
            }
        }
    }
    if !lean { s.add("iorders", u32s(&iord)); }

    drop(_span);
    let _span = tracing::info_span!("pack: blocks + varblock lists").entered();
    // blocks: [transform | kind << 5 | ctxsel << 7 | dx << 16 | dy << 18, hf_mul]; for blocks inside a varblock
    // (kind 1) the transform is the varblock's and dx / dy the offset back to its top-left block
    let lf_idx_mul: usize = d.lf_thresholds.iter().map(|t| t.len() + 1).product();
    let hf_idx_mul = d.qf_thresholds.len() + 1;
    if hf_idx_mul * lf_idx_mul > 1 << 9 {
        return Err(format!("block context selectors {}", hf_idx_mul * lf_idx_mul));
    }
    let mut blocks = vec![0u32; w8 * h8 * 2];
    let mut used = [0u64; 27];
    for i in 0..w8 * h8 {
        let kind = d.block_kind[i] as u32;
        let dct = d.dct_select[i] as u32;
        let mut ctxsel = 0usize;
        if kind == 2 {
            if order_id(dct as u8) > 6 {
                return Err(format!("transform {dct} (larger than 32x32)"));
            }
            used[dct as usize] += 1;
            let mut lf_idx = 0usize;
            if !d.lf_quant[0].is_empty() {
                for c in [0, 2, 1] {
                    lf_idx *= d.lf_thresholds[c].len() + 1;
                    let q = d.lf_quant[c][i];
                    lf_idx += d.lf_thresholds[c].iter().filter(|&&th| q > th).count();
                }
            }
            let qf = d.hf_mul[i];
            let hf_idx = d.qf_thresholds.iter().filter(|&&th| qf > th as i32).count();
            ctxsel = hf_idx * lf_idx_mul + lf_idx;
        }
        blocks[i * 2] |= dct | kind << 5 | (ctxsel as u32) << 7;
        blocks[i * 2 + 1] = d.hf_mul[i] as u32;
    }
    let mut misaligned = 0;
    let mut biglist: Vec<u32> = Vec::new();
    let mut smalllist: Vec<u32> = Vec::new();
    for i in 0..w8 * h8 {
        if d.block_kind[i] != 2 {
            continue;
        }
        let dct = d.dct_select[i] as u32;
        let (vw, vh) = block_size(dct as u8);
        let (bx, by) = ((i % w8) as u32, (i / w8) as u32);
        if bx / 4 != (bx + vw - 1) / 4 || by / 4 != (by + vh - 1) / 4 {
            misaligned += 1;
        }
        if vw * vh > 1 {
            biglist.extend([bx | by << 16, dct]);
        } else {
            smalllist.extend([bx | by << 16, dct]);
        }
        for dy in 0..vh {
            for dx in 0..vw {
                if dx == 0 && dy == 0 {
                    continue;
                }
                let j = ((by + dy) as usize) * w8 + (bx + dx) as usize;
                if j < w8 * h8 && d.block_kind[j] == 1 {
                    blocks[j * 2] = dct | 1 << 5 | dx << 16 | dy << 18;
                    blocks[j * 2 + 1] = d.hf_mul[i] as u32;
                }
            }
        }
    }
    if !lean { s.add("blocks", u32s(&blocks)); }
    s.add("biglist", u32s(&biglist));
    s.add("smalllist", u32s(&smalllist));

    drop(_span);
    let _span = tracing::info_span!("pack: per-group varblocks").entered();
    // per group, its varblocks in decode (raster) order: x | y << 5 (blocks, in the group) | transform << 10 |
    // block context for Y << 15, X << 19, B << 23 | log2 width << 27 | log2 height << 29 (in blocks): all the HF
    // kernel needs per varblock
    let mut blist: Vec<u32> = Vec::new();
    let mut groups2: Vec<u32> = Vec::new();
    for g in 0..d.num_groups as usize {
        let gr = &groups[g * 8..g * 8 + 8];
        let (bx0, by0, bw, bh) = (gr[2] as usize, gr[3] as usize, gr[4] as usize, gr[5] as usize);
        let first = blist.len();
        for by in 0..bh {
            for bx in 0..bw {
                let i = (by0 + by) * w8 + bx0 + bx;
                if d.block_kind[i] != 2 {
                    continue;
                }
                let dct = d.dct_select[i] as u32;
                let ctxsel = blocks[i * 2] >> 7;
                let mut e = bx as u32 | (by as u32) << 5 | dct << 10;
                for ci in 0..3u32 {
                    let idx = ((ci * 13 + order_id(dct as u8)) * (hf_idx_mul * lf_idx_mul) as u32 + ctxsel) as usize;
                    let bc = d.block_ctx_map[idx] as u32;
                    if bc >= 16 {
                        return Err(format!("block context {bc}"));
                    }
                    e |= bc << (15 + ci * 4);
                }
                let (vw, vh) = block_size(dct as u8);
                e |= vw.trailing_zeros() << 27 | vh.trailing_zeros() << 29;
                blist.push(e);
            }
        }
        groups2.extend([gr[0], gr[1], gr[2], gr[3], gr[6], first as u32, (blist.len() - first) as u32, 0]);
    }
    // the other passes' groups: same varblock lists, their own bitstreams; field 7 = pass
    for p in 1..d.num_passes as usize {
        for g in 0..d.num_groups as usize {
            let gr = &groups[(p * d.num_groups as usize + g) * 8..][..8];
            let g0 = &groups2[g * 8..g * 8 + 8];
            let (lo, ln) = (g0[5], g0[6]);
            groups2.extend([gr[0], gr[1], gr[2], gr[3], gr[6], lo, ln, p as u32]);
        }
    }
    s.add("blist", u32s(&blist));
    // HfMul per 8x8 block (what the NATURAL transform kernels read)
    s.add("hfmul", u32s(&blocks.chunks_exact(2).map(|b| b[1]).collect::<Vec<u32>>()));
    s.add("groups2", u32s(&groups2));

    drop(_span);
    let _span = tracing::info_span!("pack: LF, CfL, matrices").entered();
    let mut lf = Vec::new();
    for c in 0..3 {
        lf.extend_from_slice(&d.lf_xyb[c]);
    }
    s.add("lf_xyb", f32s(&lf));
    let mut cfl = d.x_from_y.clone();
    cfl.extend_from_slice(&d.b_from_y);
    s.add("cfl", i32s(&cfl));

    let mut mats: Vec<f32> = Vec::new();
    let mut mat_ofs = serde_json::Map::new();
    for (ty, m) in &d.matrices {
        let (bw, bh) = block_size(*ty);
        let mut ofs = Vec::new();
        for c in 0..3 {
            if m[c].len() != (bw * bh * 64) as usize {
                return Err(format!("matrix {ty}: {} values", m[c].len()));
            }
            ofs.push(mats.len());
            mats.extend_from_slice(&m[c]);
        }
        mat_ofs.insert(ty.to_string(), json!(ofs));
    }
    s.add("mats", f32s(&mats));

    let mut coeff = Vec::new();
    let mut xyb = Vec::new();
    if refs {
        for c in 0..3 {
            coeff.extend_from_slice(&d.coeff_ref[c]);
            xyb.extend_from_slice(&d.xyb_ref[c]);
        }
    }
    if !lean { s.add("coeff_ref", i32s(&coeff)); }
    if !lean { s.add("xyb_ref", f32s(&xyb)); }
    if !lean {
        s.add("rgba_ref", if refs { rgba } else { Vec::new() });
    }

    drop(_span);
    let _span = tracing::info_span!("pack: header").entered();
    let census: serde_json::Map<String, Value> = used
        .iter()
        .enumerate()
        .filter(|(_, n)| **n > 0)
        .map(|(t, n)| (t.to_string(), json!(n)))
        .collect();
    let header = json!({
        "name": name,
        "width": d.width, "height": d.height, "w8": d.w8, "h8": d.h8,
        "group_dim": d.group_dim, "groups_per_row": d.groups_per_row, "num_groups": d.num_groups,
        "skip_lf_smoothing": d.skip_lf_smoothing,
        "nbc": nbc, "num_clusters": d.configs.len(), "log_bucket_size": d.log_bucket_size,
        "hf_idx_mul": hf_idx_mul, "lf_idx_mul": lf_idx_mul,
        "t_cmap": t_cmap, "t_cfg": t_cfg, "t_bkt": t_bkt, "t_bctx": t_bctx, "t_ord": t_ord, "ord_ofs": ord_ofs, "iord_ofs": iord_ofs,
        "num_big": biglist.len() / 2, "num_small": smalllist.len() / 2,
        "num_passes": d.num_passes, "passes": passes,
        "alpha": alpha_note, "alpha_groups": apl.len() / APL_STRIDE,
        "global_scale": d.global_scale, "quant_lf": d.quant_lf,
        "x_qm_scale": d.x_qm_scale, "b_qm_scale": d.b_qm_scale,
        "quant_bias": d.quant_bias, "quant_bias_numerator": d.quant_bias_numerator,
        "inv_mat": d.inv_mat, "opsin_bias": d.opsin_bias, "intensity_target": d.intensity_target,
        "base_correlation_x": d.base_correlation_x, "base_correlation_b": d.base_correlation_b,
        "colour_factor": d.colour_factor,
        "mats": mat_ofs, "transforms": census, "misaligned": misaligned,
    });
    Ok((header, s))
}


impl Sections {
    pub fn get(&self, name: &str) -> &[u8] {
        self.data.iter().find(|(n, _)| n == name).map(|(_, b)| &b[..]).unwrap_or(&[])
    }
}

/// Switches the patched jxl-oxide to staging: dump the GPU inputs, stop before the HF decode, no colour transform,
/// default dequant matrices cached.
pub fn stage_mode() {
    use std::sync::atomic::Ordering::Relaxed;
    gpu_dump::WANT_REFS.store(false, Relaxed);
    gpu_dump::ENABLED.store(true, Relaxed);
    gpu_dump::STAGE_ONLY.store(true, Relaxed);
    jxl_vardct::CACHE_DEFAULT_MATRICES.store(true, Relaxed);
}

/// Stages one file (stage_mode must be on): the job header and sections, no references.
pub fn stage_bytes(bytes: &[u8], name: &str) -> Result<(Value, Sections), String> {
    stage_bytes_with(bytes, name, CPU_ALPHA.load(std::sync::atomic::Ordering::Relaxed))
}

/// stage_bytes with the CPU alpha choice per call (callers staging batches at the same time).
pub fn stage_bytes_with(bytes: &[u8], name: &str, cpu_alpha: bool) -> Result<(Value, Sections), String> {
    let side = if USE_SIDE.load(std::sync::atomic::Ordering::Relaxed) { side::stage_side(bytes, name) } else { None };
    let (h, mut s) = match side {
        Some(r) => r?,
        None => build_mode(&stage_capture(bytes)?, Vec::new(), name, false, true)?,
    };
    if cpu_alpha && h["alpha"].as_str() == Some("ok") {
        let w = |b: &[u8]| -> Vec<u32> { b.chunks_exact(4).map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect() };
        let (plans, adata) = alpha_cpu::decode_all(&w(s.get("bits")), &w(s.get("apl")), &w(s.get("atables")));
        s.set("apl", u32s(&plans));
        s.set("adata", u32s(&adata));
    }
    Ok((h, s))
}

/// jxl-oxide's part of staging (stage_mode must be on): the capture, with an annotated file's sziA box applied.
pub fn stage_capture(bytes: &[u8]) -> Result<GpuDump, String> {
    let image = JxlImage::builder()
        .pool(JxlThreadPool::none())
        .read(std::io::Cursor::new(bytes))
        .map_err(|e| e.to_string())?;
    let _ = image.render_frame(0);
    let mut dump = gpu_dump::take().ok_or("not a VarDCT image")?;
    if let Some((ends, consts)) = read_hf_end_box(bytes) {
        dump.hf_end = ends;
        dump.alpha_const = consts;
    }
    Ok(dump)
}

/// The box an annotated file carries: where each pass group's HF data ends (u32 count, then u32 bits, LE), then
/// optionally each group's constant alpha (u32: the value, or u32::MAX when the group's alpha varies).
pub const HF_END_BOX: &[u8; 4] = b"sziA";

/// Per pass group of an RGBA8 image: its alpha when that is one value over the whole group, else u32::MAX.
pub fn alpha_consts(rgba: &[u8], width: u32, height: u32, group_dim: u32) -> Vec<u32> {
    let gpr = width.div_ceil(group_dim);
    let groups = gpr * height.div_ceil(group_dim);
    (0..groups)
        .map(|g| {
            let (x0, y0) = ((g % gpr) * group_dim, (g / gpr) * group_dim);
            let (x1, y1) = ((x0 + group_dim).min(width), (y0 + group_dim).min(height));
            let first = rgba[((y0 * width + x0) * 4 + 3) as usize];
            let same = (y0..y1).all(|y| (x0..x1).all(|x| rgba[((y * width + x) * 4 + 3) as usize] == first));
            if same { first as u32 } else { u32::MAX }
        })
        .collect()
}

/// The HF end positions and the per-group constant alphas (empty if the box predates them) from an annotated
/// file's `sziA` box, if it's a container that has one.
pub fn read_hf_end_box(bytes: &[u8]) -> Option<(Vec<u32>, Vec<u32>)> {
    if !bytes.starts_with(&[0, 0, 0, 0x0c, b'J', b'X', b'L', b' ']) {
        return None;
    }
    let mut at = 0usize;
    while at + 8 <= bytes.len() {
        let size = u32::from_be_bytes(bytes[at..at + 4].try_into().ok()?) as u64;
        let ty = &bytes[at + 4..at + 8];
        let (hdr, size) = match size {
            1 => (16usize, u64::from_be_bytes(bytes.get(at + 8..at + 16)?.try_into().ok()?)),
            0 => (8, (bytes.len() - at) as u64),
            n => (8, n),
        };
        if ty == HF_END_BOX {
            let data = bytes.get(at + hdr..at + size as usize)?;
            let n = u32::from_le_bytes(data.get(0..4)?.try_into().ok()?) as usize;
            let word = |i: usize| data.get(4 + i * 4..8 + i * 4).map(|b| u32::from_le_bytes(b.try_into().unwrap()));
            let ends = (0..n).map(word).collect::<Option<Vec<u32>>>()?;
            let consts = if data.len() >= 4 + 8 * n { (n..2 * n).map(word).collect::<Option<Vec<u32>>>()? } else { Vec::new() };
            return Some((ends, consts));
        }
        if size < hdr as u64 {
            return None;
        }
        at += size as usize;
    }
    None
}

/// The file with a `sziA` box of `ends` and `consts` (alpha_consts) added (a bare codestream becomes a container:
/// JXL signature, ftyp, jxlc).
pub fn add_hf_end_box(bytes: &[u8], ends: &[u32], consts: &[u32]) -> Vec<u8> {
    let mut data = (ends.len() as u32).to_le_bytes().to_vec();
    for e in ends.iter().chain(consts) {
        data.extend(e.to_le_bytes());
    }
    add_box(bytes, HF_END_BOX, &data)
}

/// The file with a box `ty` of `data` appended (a bare codestream becomes a container first: as_container).
pub fn add_box(bytes: &[u8], ty: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut out = as_container(bytes);
    out.extend(((data.len() + 8) as u32).to_be_bytes());
    out.extend(ty);
    out.extend(data);
    out
}

/// The file as a JPEG XL container (a bare codestream gets the signature, ftyp and a jxlc box around it).
pub fn as_container(bytes: &[u8]) -> Vec<u8> {
    if bytes.starts_with(&[0, 0, 0, 0x0c, b'J', b'X', b'L', b' ']) {
        return bytes.to_vec();
    }
    let mut out = Vec::new();
    let boxed = |ty: &[u8; 4], data: &[u8], out: &mut Vec<u8>| {
        out.extend(((data.len() + 8) as u32).to_be_bytes());
        out.extend(ty);
        out.extend(data);
    };
    out.extend([0, 0, 0, 0x0c, b'J', b'X', b'L', b' ', 0x0d, 0x0a, 0x87, 0x0a]);
    boxed(b"ftyp", b"jxl \0\0\0\0jxl ", &mut out);
    boxed(b"jxlc", bytes, &mut out);
    out
}

/// Words per alpha group plan (see plan_alpha).
pub const APL_STRIDE: usize = 32;

/// The alpha channel's per-group plans: [data bit (absolute in "bits"), kind (0 ANS, 1 prefix, 2 constant: one
/// value over the group, in word 31, nothing to decode), tables offset (in "atables"), clusters, log bucket size,
/// channels, palette colours (0: none), group x0, y0 (pixels), group w, h, pad, then per channel (up to 3): w, h,
/// cluster, predictor, offset, multiplier]. atables per group: per cluster 4 words of integer config, then ANS
/// buckets (2 words an entry, 1 << (12 - log bucket) a cluster) or per cluster a prefix table [toplevel bits,
/// toplevel count, second count, entries...]. The note says what's unsupported; "opaque" when the converter found
/// alpha 255 everywhere (no plans: the image is treated as having no alpha).
fn plan_alpha(d: &GpuDump, section_base: &[u32]) -> (Vec<u32>, Vec<u32>, String) {
    let mut apl = Vec::new();
    let mut at = Vec::new();
    let Some(ai) = d.alpha_index else {
        return (apl, at, "none".into());
    };
    if d.num_extra != 1 || ai != 0 {
        return (Vec::new(), Vec::new(), format!("unsupported: {} extra channels", d.num_extra));
    }
    if d.alpha_const.len() >= d.num_groups as usize && d.alpha_const.iter().all(|&c| c == 255) {
        return (Vec::new(), Vec::new(), "opaque".into());
    }
    if d.hf_end.len() < d.num_groups as usize {
        return (Vec::new(), Vec::new(), "unsupported: no HF end positions".into());
    }
    for g in 0..d.num_groups as usize {
        let gx = g as u32 % d.groups_per_row;
        let gy = g as u32 / d.groups_per_row;
        let (x0, y0) = (gx * d.group_dim, gy * d.group_dim);
        let gw = (d.width - x0).min(d.group_dim);
        let gh = (d.height - y0).min(d.group_dim);
        if let Some(&c) = d.alpha_const.get(g)
            && c != u32::MAX
        {
            let mut rec = vec![0u32; APL_STRIDE];
            rec[1] = 2;
            rec[2] = at.len() as u32;
            rec[7..11].copy_from_slice(&[x0, y0, gw, gh]);
            rec[31] = c;
            apl.extend(rec);
            continue;
        }
        // alpha (shift 0) is modular data in the last pass's group sections (a pass only carries the channels in its
        // shift range, and without downsampling steps only the last pass has one); hf_end is that pass's
        let ap = d.num_passes.max(1) as usize - 1;
        let e = ap * d.num_groups as usize + g;
        let mut bs = jxl_bitstream::Bitstream::new(&d.group_bytes[e]);
        if bs.skip_bits(d.hf_end[g] as usize).is_err() {
            return (Vec::new(), Vec::new(), "unsupported: bad HF end".into());
        }
        let stream = 1 + 3 * d.num_lf_groups + 17 + (ap as u32) * d.num_groups + g as u32;
        let plan = match jxl_modular::research_plan_group(&mut bs, &[(gw, gh)], d.global_ma.as_ref(), stream) {
            Ok(p) => p,
            Err(e) => return (Vec::new(), Vec::new(), format!("unsupported: {e}")),
        };
        if plan.lz77 || plan.other_transforms > 0 || plan.palettes.len() > 1 || plan.channels.len() > 3 {
            return (Vec::new(), Vec::new(), format!("unsupported: lz77 {} transforms {} palettes {} channels {}",
                plan.lz77, plan.other_transforms, plan.palettes.len(), plan.channels.len()));
        }
        if let Some(p) = plan.palettes.first()
            && (p.3 != 0 || p.4 != 0 || p.0 != 0 || p.1 != 1)
        {
            return (Vec::new(), Vec::new(), format!("unsupported: palette {p:?}"));
        }
        let Some(t) = plan.tables else {
            return (Vec::new(), Vec::new(), "unsupported: no tables".into());
        };
        let mut rec = vec![0u32; APL_STRIDE];
        rec[0] = section_base[e] * 32 + plan.data_bit;
        rec[1] = if t.prefix.is_empty() { 0 } else { 1 };
        rec[2] = at.len() as u32;
        rec[3] = t.configs.len() as u32;
        rec[4] = t.log_bucket_size;
        rec[5] = plan.channels.len() as u32;
        rec[6] = plan.palettes.first().map(|p| p.2).unwrap_or(0);
        rec[7] = x0;
        rec[8] = y0;
        rec[9] = gw;
        rec[10] = gh;
        for (i, &(w, h, leaf)) in plan.channels.iter().enumerate() {
            let Some((cluster, pred, offset, mult)) = leaf else {
                return (Vec::new(), Vec::new(), "unsupported: a tree that isn't a single leaf".into());
            };
            if pred != 0 && pred != 5 {
                return (Vec::new(), Vec::new(), format!("unsupported: predictor {pred}"));
            }
            let r = &mut rec[12 + i * 6..12 + i * 6 + 6];
            r.copy_from_slice(&[w, h, cluster, pred, offset as u32, mult]);
        }
        apl.extend(rec);
        for c in &t.configs {
            at.extend(c);
        }
        if t.prefix.is_empty() {
            for b in &t.buckets {
                for &w in b {
                    at.extend([w as u32, (w >> 32) as u32]);
                }
            }
        } else {
            for (bits, top, second) in &t.prefix {
                at.extend([*bits, top.len() as u32, second.len() as u32]);
                at.extend(top);
                at.extend(second);
            }
        }
    }
    (apl, at, "ok".into())
}
