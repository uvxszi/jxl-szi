//! This crate provides types related to representation of VarDCT frames, such as
//! [varblock transform types][TransformType], [LF images][LfCoeff],
//! [dequantization matrices][DequantMatrixSet] and [HF coefficients][write_hf_coeff].
//!
//! Actual decoding (dequantization and rendering) of such frames is not done in this crate.
mod dct_select;
mod dequant;
mod error;
mod hf_coeff;
mod hf_metadata;
mod hf_pass;
mod lf;

pub use dct_select::TransformType;
pub use dequant::*;
pub use error::{Error, Result};
pub use hf_coeff::*;
pub use hf_metadata::*;
pub use hf_pass::*;
pub use lf::*;


/// Research census (JXL GPU, X4): what the HF entropy streams use.
#[derive(Debug, Default)]
pub struct ResearchCounts {
    pub hf_passes: u64,
    pub hf_lz77: u64,
    pub hf_prefix: u64,
    pub hf_clusters_max: u64,
    pub custom_orders: u64,
    pub presets_max: u64,
    pub block_clusters_max: u64,
}

pub static RESEARCH: std::sync::Mutex<ResearchCounts> = std::sync::Mutex::new(ResearchCounts {
    hf_passes: 0, hf_lz77: 0, hf_prefix: 0, hf_clusters_max: 0, custom_orders: 0, presets_max: 0, block_clusters_max: 0,
});
