//! Research (JXL GPU, X5): everything a GPU decoder needs for one VarDCT frame, captured while jxl-oxide renders
//! it, plus references to check a GPU port against (HF coefficients before dequant, XYB after the transforms).
//! Off unless `ENABLED` is set; the stager (x5_gpu_dec/stager) takes the dump with `take()` after each render.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};

use jxl_frame::data::{HfGlobal, LfGlobal, LfGroup, TocGroupKind};
use jxl_modular::Sample;
use jxl_vardct::{BlockInfo, TransformType};

use crate::{ImageWithRegion, IndexedFrame};

pub static ENABLED: AtomicBool = AtomicBool::new(false);
/// Stop the VarDCT render right after the capture (no HF decode, no transforms): what the CPU still does when the
/// GPU decodes.
pub static STAGE_ONLY: AtomicBool = AtomicBool::new(false);
/// Capture the references (coefficients, XYB) too; off for staging (they're most of the memory).
pub static WANT_REFS: AtomicBool = AtomicBool::new(true);

thread_local! {
    static DUMP: std::cell::RefCell<Option<GpuDump>> = const { std::cell::RefCell::new(None) };
}

#[derive(Debug, Default)]
pub struct GpuDump {
    /// Colour sample size, and in 8x8 blocks.
    pub width: u32,
    pub height: u32,
    pub w8: u32,
    pub h8: u32,
    pub group_dim: u32,
    pub groups_per_row: u32,
    pub num_groups: u32,
    pub skip_lf_smoothing: bool,
    pub num_passes: u32,
    /// Per pass group: its section bytes and the bit where its HF data starts.
    pub group_bytes: Vec<Vec<u8>>,
    pub group_start_bit: Vec<u32>,

    // HF entropy decoding (pass 0)
    pub num_hf_presets: u32,
    pub cluster_map: Vec<u8>,
    pub configs: Vec<[u32; 4]>,
    pub log_bucket_size: u32,
    pub buckets: Vec<Vec<u64>>,
    pub qf_thresholds: Vec<u32>,
    pub lf_thresholds: [Vec<i32>; 3],
    pub block_ctx_map: Vec<u8>,
    pub num_block_clusters: u32,
    /// 13 order ids x 3 channels (X, Y, B): (x, y) per coefficient in decode order, LLF first.
    pub orders: Vec<Vec<(u16, u16)>>,
    /// Passes after the first: their entropy tables and orders, and every pass's coefficient shift.
    pub extra_passes: Vec<PassTables>,
    pub pass_shift: Vec<u32>,

    // per 8x8 block of the image (w8 x h8)
    /// 0 none, 1 covered by a varblock that starts elsewhere, 2 a varblock's top-left block
    pub block_kind: Vec<u8>,
    pub dct_select: Vec<u8>,
    pub hf_mul: Vec<i32>,
    /// Quantized LF per channel (X, Y, B), for the HF block context; empty without LF thresholds.
    pub lf_quant: [Vec<i32>; 3],

    // dequant, chroma from luma, colour
    pub global_scale: u32,
    pub quant_lf: u32,
    pub x_qm_scale: u32,
    pub b_qm_scale: u32,
    pub quant_bias: [f32; 3],
    pub quant_bias_numerator: f32,
    pub inv_mat: [[f32; 3]; 3],
    pub opsin_bias: [f32; 3],
    pub intensity_target: f32,
    pub base_correlation_x: f32,
    pub base_correlation_b: f32,
    pub colour_factor: u32,
    /// Per used transform type: (type, [X, Y, B] matrix in the varblock's own orientation, row length bw * 8).
    pub matrices: Vec<(u8, [Vec<f32>; 3])>,
    /// Chroma from luma per 64x64 tile (ceil(w8 / 8) x ceil(h8 / 8)).
    pub x_from_y: Vec<i32>,
    pub b_from_y: Vec<i32>,
    /// LF image after LF chroma from luma and adaptive smoothing (w8 x h8 per channel).
    pub lf_xyb: [Vec<f32>; 3],

    // extra channels (alpha): coded as modular data after the HF coefficients of each pass group
    pub num_extra: u32,
    pub extra_bit_depth: Vec<u32>,
    pub alpha_index: Option<u32>,
    pub num_lf_groups: u32,
    pub global_ma: Option<jxl_modular::MaConfig>,
    /// per pass-0 group: the bit where its HF data ends (its modular data starts); set by the caller
    pub hf_end: Vec<u32>,
    /// per pass-0 group: its alpha when that is one value over the whole group (the converter records it), else
    /// u32::MAX; set by the caller
    pub alpha_const: Vec<u32>,

    // references
    /// HF coefficients as decoded (before dequant), (w8 * 8) x (h8 * 8) per channel.
    pub coeff_ref: [Vec<i32>; 3],
    /// XYB after dequant, chroma from luma and the inverse transforms.
    pub xyb_ref: [Vec<f32>; 3],
}

/// The dump of the last frame rendered on this thread.
#[derive(Debug, Default)]
pub struct PassTables {
    pub cluster_map: Vec<u8>,
    pub configs: Vec<[u32; 4]>,
    pub log_bucket_size: u32,
    pub buckets: Vec<Vec<u64>>,
    pub orders: Vec<Vec<(u16, u16)>>,
}

pub fn take() -> Option<GpuDump> {
    DUMP.with(|d| d.borrow_mut().take())
}

pub(crate) fn stage_only() -> bool {
    STAGE_ONLY.load(Ordering::Relaxed)
}

#[inline]
pub(crate) fn enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

fn grid_rows(grid: &jxl_grid::AlignedGrid<f32>, w: usize, h: usize) -> Vec<f32> {
    let mut out = vec![0f32; w * h];
    for y in 0..h.min(grid.height()) {
        let row = grid.get_row(y);
        let n = row.len().min(w);
        out[y * w..][..n].copy_from_slice(&row[..n]);
    }
    out
}

/// Before the pass groups are decoded: tables, block info, LF.
pub(crate) fn capture<S: Sample>(
    frame: &IndexedFrame,
    lf_global: &LfGlobal<S>,
    hf_global: Option<&HfGlobal>,
    lf_groups: &HashMap<u32, LfGroup<S>>,
    lf_xyb: &ImageWithRegion,
) {
    let image_header = frame.image_header();
    let fh = frame.header();
    let Some(hf_global) = hf_global else {
        return;
    };
    let vardct = lf_global.vardct.as_ref().unwrap();
    let mut d = GpuDump {
        width: fh.color_sample_width(),
        height: fh.color_sample_height(),
        ..Default::default()
    };
    d.w8 = d.width.div_ceil(8);
    d.h8 = d.height.div_ceil(8);
    d.group_dim = fh.group_dim();
    d.groups_per_row = fh.groups_per_row();
    d.num_groups = fh.num_groups();
    d.skip_lf_smoothing = fh.flags.skip_adaptive_lf_smoothing();
    d.num_lf_groups = fh.num_lf_groups();
    let ec = &image_header.metadata.ec_info;
    d.num_extra = ec.len() as u32;
    d.extra_bit_depth = ec.iter().map(|e| e.bit_depth.bits_per_sample()).collect();
    d.alpha_index = ec.iter().position(|e| e.is_alpha()).map(|i| i as u32);
    d.global_ma = lf_global.gmodular.ma_config.clone();
    d.num_passes = fh.passes.num_passes;

    for p in 0..d.num_passes {
    for g in 0..d.num_groups {
        if frame.toc().is_single_entry() {
            let bs = frame.pass_group_bitstream(0, 0).unwrap().unwrap();
            d.group_bytes.push(frame.data(TocGroupKind::All).unwrap().to_vec());
            d.group_start_bit.push(bs.bitstream.num_read_bits() as u32);
        } else {
            let bytes = frame
                .data(TocGroupKind::GroupPass { pass_idx: p, group_idx: g })
                .unwrap();
            d.group_bytes.push(bytes.to_vec());
            d.group_start_bit.push(0);
        }
    }
    }
    d.pass_shift = (0..d.num_passes).map(|p| fh.passes.shift.get(p as usize).copied().unwrap_or(0)).collect();
    for hp in hf_global.hf_passes.iter().skip(1) {
        let mut pt = PassTables::default();
        if let Some(t) = hp.research_decoder().research_export() {
            pt.cluster_map = t.clusters;
            pt.configs = t.configs;
            pt.log_bucket_size = t.log_bucket_size;
            pt.buckets = t.buckets;
        }
        for o in 0..13 {
            for c in 0..3 {
                pt.orders.push(if o < 7 { hp.research_order(o, c).to_vec() } else { Vec::new() });
            }
        }
        d.extra_passes.push(pt);
    }

    let hf_pass = &hf_global.hf_passes[0];
    d.num_hf_presets = hf_global.num_hf_presets;
    if let Some(t) = hf_pass.research_decoder().research_export() {
        d.cluster_map = t.clusters;
        d.configs = t.configs;
        d.log_bucket_size = t.log_bucket_size;
        d.buckets = t.buckets;
    }
    let ctx = &vardct.hf_block_ctx;
    d.qf_thresholds = ctx.qf_thresholds.clone();
    d.lf_thresholds = ctx.lf_thresholds.clone();
    d.block_ctx_map = ctx.block_ctx_map.clone();
    d.num_block_clusters = ctx.num_block_clusters;
    for o in 0..13 {
        for c in 0..3 {
            // orders beyond 32x32 are only built on demand; we don't use them
            d.orders
                .push(if o < 7 { hf_pass.research_order(o, c).to_vec() } else { Vec::new() });
        }
    }

    let (w8, h8) = (d.w8 as usize, d.h8 as usize);
    d.block_kind = vec![0; w8 * h8];
    d.dct_select = vec![0; w8 * h8];
    d.hf_mul = vec![0; w8 * h8];
    let want_lf_quant = ctx.lf_thresholds.iter().any(|t| !t.is_empty());
    if want_lf_quant {
        d.lf_quant = std::array::from_fn(|_| vec![0; w8 * h8]);
    }
    let (cw, ch) = (w8.div_ceil(8), h8.div_ceil(8));
    d.x_from_y = vec![0; cw * ch];
    d.b_from_y = vec![0; cw * ch];
    let lf_per_row = fh.lf_groups_per_row() as usize;
    let lf_blocks = (fh.lf_group_dim() / 8) as usize;
    let mut used = [false; 27];
    for (&idx, lf_group) in lf_groups {
        let bx0 = (idx as usize % lf_per_row) * lf_blocks;
        let by0 = (idx as usize / lf_per_row) * lf_blocks;
        let Some(meta) = &lf_group.hf_meta else { continue };
        let bi = &meta.block_info;
        for y in 0..bi.height() {
            for x in 0..bi.width() {
                let i = (by0 + y) * w8 + bx0 + x;
                match bi.get(x, y) {
                    BlockInfo::Data { dct_select, hf_mul } => {
                        d.block_kind[i] = 2;
                        d.dct_select[i] = dct_select as u8;
                        d.hf_mul[i] = hf_mul;
                        used[dct_select as usize] = true;
                    }
                    BlockInfo::Occupied => d.block_kind[i] = 1,
                    _ => {}
                }
            }
        }
        for (src, dst) in [(&meta.x_from_y, &mut d.x_from_y), (&meta.b_from_y, &mut d.b_from_y)] {
            for y in 0..src.height() {
                for x in 0..src.width() {
                    dst[(by0 / 8 + y) * cw + bx0 / 8 + x] = src.get(x, y);
                }
            }
        }
        if let (true, Some(lf_coeff)) = (want_lf_quant, &lf_group.lf_coeff) {
            let chans = lf_coeff.lf_quant.image().unwrap().image_channels();
            for c in 0..3 {
                let g = &chans[[1, 0, 2][c]];
                for y in 0..g.height() {
                    for x in 0..g.width() {
                        d.lf_quant[c][(by0 + y) * w8 + bx0 + x] = g.get(x, y).to_i32();
                    }
                }
            }
        }
    }

    let q = &vardct.quantizer;
    d.global_scale = q.global_scale;
    d.quant_lf = q.quant_lf;
    d.x_qm_scale = fh.x_qm_scale;
    d.b_qm_scale = fh.b_qm_scale;
    let oim = &image_header.metadata.opsin_inverse_matrix;
    d.quant_bias = oim.quant_bias;
    d.quant_bias_numerator = oim.quant_bias_numerator;
    d.inv_mat = oim.inv_mat;
    d.opsin_bias = oim.opsin_bias;
    d.intensity_target = image_header.metadata.tone_mapping.intensity_target;
    let cc = &vardct.lf_chan_corr;
    d.base_correlation_x = cc.base_correlation_x;
    d.base_correlation_b = cc.base_correlation_b;
    d.colour_factor = cc.colour_factor;
    for (t, &u) in used.iter().enumerate() {
        if !u {
            continue;
        }
        let tt = TransformType::try_from(t as u8).unwrap();
        let m = std::array::from_fn(|c| {
            if tt.need_transpose() {
                hf_global.dequant_matrices.get_transposed(c, tt).to_vec()
            } else {
                hf_global.dequant_matrices.get(c, tt).to_vec()
            }
        });
        d.matrices.push((t as u8, m));
    }

    let lf = lf_xyb.as_color_floats();
    d.lf_xyb = std::array::from_fn(|c| grid_rows(lf[c], w8, h8));
    if WANT_REFS.load(Ordering::Relaxed) && !stage_only() {
        d.coeff_ref = std::array::from_fn(|_| vec![0; w8 * 8 * h8 * 8]);
    }
    DUMP.with(|x| *x.borrow_mut() = Some(d));
}

/// One pass group's HF coefficients as decoded (i32 bits in the f32 grid), before dequant.
pub(crate) fn capture_group_coeffs(
    group_idx: u32,
    group_dim: u32,
    groups_per_row: u32,
    grid_xyb: &[jxl_grid::MutableSubgrid<'_, f32>; 3],
) {
    DUMP.with(|g| {
    let mut g = g.borrow_mut();
    let Some(d) = g.as_mut() else { return };
    if d.coeff_ref[0].is_empty() {
        return;
    }
    let left = ((group_idx % groups_per_row) * group_dim) as usize;
    let top = ((group_idx / groups_per_row) * group_dim) as usize;
    let stride = d.w8 as usize * 8;
    for c in 0..3 {
        let grid = &grid_xyb[c];
        for y in 0..grid.height() {
            let row = grid.get_row(y);
            let out = &mut d.coeff_ref[c][(top + y) * stride + left..];
            for (o, v) in out.iter_mut().zip(row) {
                *o = v.to_bits() as i32;
            }
        }
    }
    });
}

/// After dequant, chroma from luma and the inverse transforms.
pub(crate) fn capture_xyb(fb: &ImageWithRegion) {
    DUMP.with(|g| {
        let mut g = g.borrow_mut();
        let Some(d) = g.as_mut() else { return };
        let cf = fb.as_color_floats();
        let (w, h) = (d.w8 as usize * 8, d.h8 as usize * 8);
        d.xyb_ref = std::array::from_fn(|c| grid_rows(cf[c], w, h));
    });
}
