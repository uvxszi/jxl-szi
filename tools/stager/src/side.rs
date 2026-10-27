//! GPU-ready side data in the file (JXL research X5, F29). Staging a file with jxl-oxide (headers, histograms, the
//! modular LF and block-info streams) is most of the CPU cost of loading; its result is small once compressed (the
//! lean job's sections other than the bitstreams: ~115 MB raw, ~25 MB deflated for the 221 textures). So the
//! converter can store it in a `sziS` box after the codestream, and loading becomes: inflate the box, copy each
//! pass group's bytes out of the codestream where the box says they are. The file stays a valid JPEG XL (other
//! decoders skip unknown boxes) and keeps decoding without the box.
//! Box payload: u32 JSON length, JSON { header, sections: [[name, bytes]...], groups: [[file offset, bytes]...] },
//! then one deflate stream of the sections, concatenated in that order.

use crate::{Sections, Value, json};

pub const SIDE_BOX: &[u8; 4] = b"sziS";
/// The same payload with the sections as one zlib stream (JXL_SZI_SIDE=z): what Godot's own decompress reads (jxl-szi).
pub const SIDE_BOX_ZLIB: &[u8; 4] = b"sziZ";

/// The payload of a box `ty` in a JPEG XL container, if there is one.
pub fn find_box<'a>(bytes: &'a [u8], ty: &[u8; 4]) -> Option<&'a [u8]> {
    if !bytes.starts_with(&[0, 0, 0, 0x0c, b'J', b'X', b'L', b' ']) {
        return None;
    }
    let mut at = 0usize;
    while at + 8 <= bytes.len() {
        let size = u32::from_be_bytes(bytes[at..at + 4].try_into().ok()?) as u64;
        let (hdr, size) = match size {
            1 => (16usize, u64::from_be_bytes(bytes.get(at + 8..at + 16)?.try_into().ok()?)),
            0 => (8, (bytes.len() - at) as u64),
            n => (8, n),
        };
        if &bytes[at + 4..at + 8] == ty {
            return bytes.get(at + hdr..at + size as usize);
        }
        if size < hdr as u64 {
            return None;
        }
        at += size as usize;
    }
    None
}

/// The "bits" section from the pass groups' byte ranges in `file`, laid out as build_mode does (each from a word
/// boundary, two zero words after it).
fn bits_from(file: &[u8], groups: &[(usize, usize)]) -> Option<Vec<u8>> {
    let mut bits = Vec::with_capacity(groups.iter().map(|g| g.1 + 12).sum());
    for &(o, n) in groups {
        bits.extend_from_slice(file.get(o..o + n)?);
        bits.resize(bits.len().div_ceil(4) * 4 + 8, 0);
    }
    Some(bits)
}

/// The side box's payload for an annotated file: `h`, `s` are its staged lean job, `group_bytes` the pass groups'
/// bytes (as the dump captured them), found again in `file` to record where they are. `zlib`: the sections as a
/// zlib stream (the sziZ box) instead of raw deflate (sziS).
pub fn side_box(file: &[u8], group_bytes: &[Vec<u8>], h: &Value, s: &Sections, zlib: bool) -> Result<Vec<u8>, String> {
    let mut groups = Vec::with_capacity(group_bytes.len());
    let mut from = 0usize;
    for (g, b) in group_bytes.iter().enumerate() {
        // the next group normally follows the last one; search the whole file only if it doesn't
        let find = |start: usize| -> Option<usize> {
            if b.is_empty() {
                return Some(start);
            }
            file.get(start..)?.windows(b.len()).position(|w| w == &b[..]).map(|p| p + start)
        };
        let at = find(from).or_else(|| find(0)).ok_or(format!("pass group {g}'s bytes are not in the file"))?;
        groups.push((at, b.len()));
        from = at + b.len();
    }
    if bits_from(file, &groups).as_deref() != Some(s.get("bits")) {
        return Err("bitstreams don't rebuild from the file".into());
    }
    let mut blob = Vec::new();
    let mut names = Vec::new();
    for (n, d) in &s.data {
        if n == "bits" {
            continue;
        }
        names.push(json!([n, d.len()]));
        blob.extend_from_slice(d);
    }
    let meta = serde_json::to_vec(&json!({
        "header": h, "sections": names, "groups": groups.iter().map(|g| json!([g.0, g.1])).collect::<Vec<_>>(),
    }))
    .map_err(|e| e.to_string())?;
    let mut out = (meta.len() as u32).to_le_bytes().to_vec();
    out.extend(meta);
    if zlib {
        out.extend(miniz_oxide::deflate::compress_to_vec_zlib(&blob, 9));
    } else {
        out.extend(miniz_oxide::deflate::compress_to_vec(&blob, 6));
    }
    Ok(out)
}

/// An image's (width, height, has alpha) from its side box header, or else its codestream headers; the GPU
/// buffers a batch needs follow from these (the loader allocates them before staging: measure in the extension).
pub fn image_size(file: &[u8]) -> Option<(u32, u32, bool)> {
    if let Some(data) = find_box(file, SIDE_BOX) {
        let ml = u32::from_le_bytes(data.get(0..4)?.try_into().ok()?) as usize;
        let meta: Value = serde_json::from_slice(data.get(4..4 + ml)?).ok()?;
        let h = &meta["header"];
        return Some((h["width"].as_u64()? as u32, h["height"].as_u64()? as u32, h["alpha"].as_str() == Some("ok")));
    }
    let image = jxl_oxide::JxlImage::builder().read(std::io::Cursor::new(file)).ok()?;
    let ih = image.image_header();
    let alpha = ih.metadata.ec_info.iter().any(|e| e.is_alpha());
    Some((image.width(), image.height(), alpha))
}

/// Stages a file from its side box (no jxl-oxide): None when it has none.
pub fn stage_side(file: &[u8], name: &str) -> Option<Result<(Value, Sections), String>> {
    let data = find_box(file, SIDE_BOX)?;
    Some((|| {
        let ml = u32::from_le_bytes(data.get(0..4).ok_or("short side box")?.try_into().unwrap()) as usize;
        let meta: Value = serde_json::from_slice(data.get(4..4 + ml).ok_or("short side box")?).map_err(|e| e.to_string())?;
        // zune-inflate: ~2x miniz_oxide's speed for the same stream (written by miniz_oxide)
        let blob = zune_inflate::DeflateDecoder::new(&data[4 + ml..]).decode_deflate().map_err(|e| format!("side box: {e:?}"))?;
        let groups: Vec<(usize, usize)> = meta["groups"]
            .as_array()
            .ok_or("side box: no groups")?
            .iter()
            .map(|g| (g[0].as_u64().unwrap_or(0) as usize, g[1].as_u64().unwrap_or(0) as usize))
            .collect();
        let mut s = Sections { data: Vec::new() };
        s.add("bits", bits_from(file, &groups).ok_or("side box: a pass group outside the file")?);
        let mut at = 0usize;
        for e in meta["sections"].as_array().ok_or("side box: no sections")? {
            let (n, len) = (e[0].as_str().unwrap_or(""), e[1].as_u64().unwrap_or(0) as usize);
            s.add(n, blob.get(at..at + len).ok_or("side box: short data")?.to_vec());
            at += len;
        }
        let mut h = meta["header"].clone();
        h["name"] = json!(name);
        Ok((h, s))
    })())
}
