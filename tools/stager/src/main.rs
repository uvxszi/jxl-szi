//! JPEG XL research X5: writes a GPU decode job per .jxl (see the library: lib.rs)
//!   stager <out dir> [--no-refs] <file.jxl>...
//!   stager --time <file.jxl>...   (CPU cost of staging only, all files at once on all cores, nothing written)
//!   stager --profile <file.jxl>...   (staging only, one thread: time per jxl-oxide tracing span)
//! Job file: "SZIJ", u32 version, u32 header length, JSON header, then the sections it lists ([byte offset, length]
//! from the file start, 16-byte aligned).

use std::io::Write;

use jxl_oxide::{JxlImage, JxlThreadPool};
use jxl_render::gpu_dump;
use stager::{Sections, Value, build, json};

fn write_job(path: &std::path::Path, mut header: Value, s: Sections) -> std::io::Result<()> {
    // section offsets depend on the header length; two rounds settle it
    let mut base = 0usize;
    for _ in 0..3 {
        let mut ofs = base;
        let mut table = serde_json::Map::new();
        for (name, bytes) in &s.data {
            table.insert(name.clone(), json!([ofs, bytes.len()]));
            ofs = (ofs + bytes.len()).div_ceil(16) * 16;
        }
        header["sections"] = Value::Object(table);
        let h = serde_json::to_vec(&header).unwrap();
        let need = (12 + h.len()).div_ceil(16) * 16;
        if need == base {
            break;
        }
        base = need;
    }
    let h = serde_json::to_vec(&header).unwrap();
    let mut f = std::io::BufWriter::new(std::fs::File::create(path)?);
    f.write_all(b"SZIJ")?;
    f.write_all(&1u32.to_le_bytes())?;
    f.write_all(&(h.len() as u32).to_le_bytes())?;
    f.write_all(&h)?;
    let mut pos = 12 + h.len();
    for (_, bytes) in &s.data {
        let aligned = pos.div_ceil(16) * 16;
        f.write_all(&vec![0u8; aligned - pos])?;
        f.write_all(bytes)?;
        pos = aligned + bytes.len();
    }
    Ok(())
}

/// Stage one file in memory (stage-only render: no HF decode or transforms on the CPU); returns the job size.
fn stage(bytes: &[u8]) -> usize {
    match stager::stage_bytes(bytes, "") {
        Ok((_, s)) => s.data.iter().map(|(_, b)| b.len()).sum(),
        Err(_) => 0,
    }
}

mod spans {
    use std::collections::HashMap;
    use std::sync::Mutex;
    use std::time::{Duration, Instant};
    use tracing::Subscriber;
    use tracing::span::{Attributes, Id};
    use tracing_subscriber::layer::{Context, Layer};
    use tracing_subscriber::registry::LookupSpan;

    struct Timing(Instant);

    #[derive(Default)]
    pub struct Sums(pub Mutex<HashMap<&'static str, (Duration, u64)>>);

    pub struct SpanTimer(pub &'static Sums);

    /// Trace events counted by their message (which decode paths run).
    pub static EVENTS: Mutex<Option<HashMap<String, u64>>> = Mutex::new(None);

    struct Msg(String);

    impl tracing::field::Visit for Msg {
        fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
            if field.name() == "message" {
                self.0 = format!("{value:?}");
            }
        }
    }

    impl<S: Subscriber + for<'a> LookupSpan<'a>> Layer<S> for SpanTimer {
        fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
            let mut m = Msg(String::new());
            event.record(&mut m);
            if m.0.is_empty() {
                m.0 = format!("{}:{}", event.metadata().file().unwrap_or("?"), event.metadata().line().unwrap_or(0));
            }
            let mut g = EVENTS.lock().unwrap();
            *g.get_or_insert_with(HashMap::new).entry(m.0).or_default() += 1;
        }
        fn on_new_span(&self, _attrs: &Attributes<'_>, _id: &Id, _ctx: Context<'_, S>) {}
        fn on_enter(&self, id: &Id, ctx: Context<'_, S>) {
            if let Some(span) = ctx.span(id) {
                span.extensions_mut().replace(Timing(Instant::now()));
            }
        }
        fn on_exit(&self, id: &Id, ctx: Context<'_, S>) {
            if let Some(span) = ctx.span(id)
                && let Some(t) = span.extensions_mut().remove::<Timing>()
            {
                let mut m = self.0.0.lock().unwrap();
                let e = m.entry(span.metadata().name()).or_default();
                e.0 += t.0.elapsed();
                e.1 += 1;
            }
        }
    }
}

fn profile_mode(files: &[String]) {
    use tracing_subscriber::prelude::*;
    let sums: &'static spans::Sums = Box::leak(Box::new(spans::Sums::default()));
    tracing_subscriber::registry()
        .with(spans::SpanTimer(sums).with_filter(tracing_subscriber::filter::LevelFilter::TRACE))
        .init();
    gpu_dump::ENABLED.store(true, std::sync::atomic::Ordering::Relaxed);
    // FULL=1: a whole decode (pass groups, alpha), to see every path
    gpu_dump::STAGE_ONLY.store(std::env::var("FULL").is_err(), std::sync::atomic::Ordering::Relaxed);
    jxl_vardct::CACHE_DEFAULT_MATRICES.store(std::env::var("NO_CACHE").is_err(), std::sync::atomic::Ordering::Relaxed);
    let blobs: Vec<Vec<u8>> = files.iter().map(|p| std::fs::read(p).unwrap()).collect();
    let t = std::time::Instant::now();
    let (mut t_render, mut t_build) = (0.0, 0.0);
    for b in &blobs {
        let t0 = std::time::Instant::now();
        let image = JxlImage::builder().pool(JxlThreadPool::none()).read(std::io::Cursor::new(&b[..])).unwrap();
        let _ = image.render_frame(0);
        let mut dump = gpu_dump::take().unwrap();
        let t1 = std::time::Instant::now();
        // as stage_bytes does: the annotated file's box, lean jobs
        if let Some((ends, consts)) = stager::read_hf_end_box(b) {
            dump.hf_end = ends;
            dump.alpha_const = consts;
        }
        let _ = stager::build_mode(&dump, Vec::new(), "", false, true);
        t_render += (t1 - t0).as_secs_f64();
        t_build += t1.elapsed().as_secs_f64();
    }
    let total = t.elapsed().as_secs_f64();
    println!("parse + render to the capture (jxl-oxide + capture): {t_render:.3} s, build (job packing): {t_build:.3} s");
    let mut v: Vec<_> = sums.0.lock().unwrap().iter().map(|(k, v)| (*k, v.0.as_secs_f64(), v.1)).collect();
    v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    println!("staging {} files on one thread: {:.3} s", blobs.len(), total);
    for (name, s, n) in v.iter().take(25) {
        println!("  {:<40} {:>8.3} s {:>6.1}% {:>8} calls", name, s, s / total * 100.0, n);
    }
    if let Some(m) = jxl_modular::RESEARCH.lock().unwrap().as_ref() {
        let mut m: Vec<_> = m.iter().collect();
        m.sort_by(|a, b| b.1.cmp(a.1));
        println!("modular streams:");
        for (k, n) in m.iter().take(40) {
            println!("  {n:>7}  {}", k.chars().take(150).collect::<String>());
        }
    }
    if let Some(ev) = spans::EVENTS.lock().unwrap().as_ref() {
        let mut ev: Vec<_> = ev.iter().collect();
        ev.sort_by(|a, b| b.1.cmp(a.1));
        println!("trace events:");
        for (m, n) in ev.iter().take(30) {
            println!("  {n:>8}  {}", m.chars().take(110).collect::<String>());
        }
    }
}

fn time_mode(files: &[String]) {
    use rayon::prelude::*;
    gpu_dump::ENABLED.store(true, std::sync::atomic::Ordering::Relaxed);
    gpu_dump::STAGE_ONLY.store(true, std::sync::atomic::Ordering::Relaxed);
    jxl_vardct::CACHE_DEFAULT_MATRICES.store(std::env::var("NO_CACHE").is_err(), std::sync::atomic::Ordering::Relaxed);
    let blobs: Vec<Vec<u8>> = files.iter().map(|p| std::fs::read(p).unwrap()).collect();
    let t = std::time::Instant::now();
    let one: Vec<f64> = blobs
        .iter()
        .map(|b| {
            let t0 = std::time::Instant::now();
            stage(b);
            t0.elapsed().as_secs_f64()
        })
        .collect();
    let serial = t.elapsed().as_secs_f64();
    for run in 0..3 {
        let t = std::time::Instant::now();
        let bytes: usize = blobs.par_iter().map(|b| stage(b)).sum();
        println!(
            "run {run}: {} files staged in {:.3} s on {} threads ({:.0} MB of GPU input); one thread: {:.3} s (slowest file {:.1} ms)",
            blobs.len(),
            t.elapsed().as_secs_f64(),
            rayon::current_num_threads(),
            bytes as f64 / 1e6,
            serial,
            one.iter().cloned().fold(0.0, f64::max) * 1000.0
        );
    }
}

/// The converter's extra step: decode each file once, record where every pass group's HF data ends and which
/// groups have a single alpha value (and which), and write a copy with that in a `sziA` box (only files with alpha
/// need it). JXL_SZI_SIDE=1: also the GPU-ready side data (the staged job) in a `sziS` box, for every file (side.rs); JXL_SZI_SIDE=z:
/// the same as zlib in a `sziZ` box (what the jxl-szi Godot addon reads).
fn annotate(out: &str, files: &[String]) {
    use std::sync::atomic::Ordering::Relaxed;
    std::fs::create_dir_all(out).unwrap();
    gpu_dump::ENABLED.store(true, Relaxed);
    gpu_dump::WANT_REFS.store(false, Relaxed);
    let mode = std::env::var("JXL_SZI_SIDE").unwrap_or_default();
    let side = mode == "1" || mode == "z";
    let zlib = mode == "z";
    let (mut raw, mut boxed_side) = (0usize, 0usize);
    for p in files {
        let path = std::path::Path::new(p);
        let bytes = std::fs::read(path).unwrap();
        gpu_dump::STAGE_ONLY.store(false, Relaxed);
        let image = JxlImage::builder().pool(JxlThreadPool::none()).read(std::io::Cursor::new(&bytes[..])).unwrap();
        let render = image.render_frame(0).unwrap();
        let dump = gpu_dump::take();
        let ends = jxl_frame::HF_END.lock().unwrap().take();
        let dst = std::path::Path::new(out).join(path.file_name().unwrap());
        let mut file = match (dump, ends) {
            (Some(d), Some(m)) if d.alpha_index.is_some() => {
                // the last pass's HF ends: its group sections carry the alpha (plan_alpha)
                let lp = d.num_passes.max(1) - 1;
                let e: Vec<u32> = (0..d.num_groups).map(|g| m.get(&(lp, g)).copied().unwrap_or(0)).collect();
                let rgba = rgba8(&render);
                let c = stager::alpha_consts(&rgba, d.width, d.height, d.group_dim);
                println!("{}: alpha, {} group ends boxed, {} constant groups", path.display(), e.len(),
                    c.iter().filter(|&&v| v != u32::MAX).count());
                stager::add_hf_end_box(&bytes, &e, &c)
            }
            _ => bytes.clone(),
        };
        if side {
            // stage the annotated file as the loader would and store the result next to the codestream (a container
            // first, so the pass groups' offsets don't move when the box is added)
            file = stager::as_container(&file);
            gpu_dump::STAGE_ONLY.store(true, Relaxed);
            let r = stager::stage_capture(&file).and_then(|d| {
                let (h, s) = stager::build_mode(&d, Vec::new(), "", false, true)?;
                raw += s.data.iter().filter(|(n, _)| n != "bits").map(|(_, b)| b.len()).sum::<usize>();
                stager::side::side_box(&file, &d.group_bytes, &h, &s, zlib)
            });
            match r {
                Ok(b) => {
                    boxed_side += b.len();
                    file = stager::add_box(&file, if zlib { stager::side::SIDE_BOX_ZLIB } else { stager::side::SIDE_BOX }, &b);
                }
                Err(e) => println!("{}: no side data: {e}", path.display()),
            }
        }
        std::fs::write(&dst, &file).unwrap();
    }
    if side {
        println!("side data: {:.1} MB staged, {:.1} MB in the boxes", raw as f64 / 1e6, boxed_side as f64 / 1e6);
    }
}

/// Stages each file from its sziS side box and again with jxl-oxide, and compares every section and the header;
/// then times both ways for all files on all cores.
fn side_check(files: &[String]) {
    use rayon::prelude::*;
    use std::sync::atomic::Ordering::Relaxed;
    stager::stage_mode();
    let blobs: Vec<Vec<u8>> = files.iter().map(|p| std::fs::read(p).unwrap()).collect();
    let (mut same, mut differ, mut no_box) = (0, 0, 0);
    for (p, b) in files.iter().zip(&blobs) {
        if stager::side::find_box(b, stager::side::SIDE_BOX).is_none() {
            no_box += 1;
            continue;
        }
        stager::USE_SIDE.store(true, Relaxed);
        let a = stager::stage_bytes(b, "x");
        stager::USE_SIDE.store(false, Relaxed);
        let o = stager::stage_bytes(b, "x");
        match (a, o) {
            (Ok((ha, sa)), Ok((ho, so))) => {
                // header floats are f32 values: a JSON round trip may change the f64's last digit, not the f32
                fn f32ed(v: &Value) -> Value {
                    match v {
                        Value::Number(n) if n.is_f64() => json!(n.as_f64().unwrap() as f32),
                        Value::Array(a) => Value::Array(a.iter().map(f32ed).collect()),
                        Value::Object(m) => Value::Object(m.iter().map(|(k, x)| (k.clone(), f32ed(x))).collect()),
                        x => x.clone(),
                    }
                }
                let (ha, ho) = (f32ed(&ha), f32ed(&ho));
                let mut bad: Vec<String> = Vec::new();
                if ha != ho {
                    let keys: Vec<String> = ho
                        .as_object()
                        .map(|m| m.iter().filter(|(k, v)| ha.get(k.as_str()) != Some(v)).map(|(k, v)| format!("{k}: {v} vs {}", ha[k.as_str()])).collect())
                        .unwrap_or_default();
                    bad.push(format!("header {keys:?}"));
                }
                for (n, d) in &so.data {
                    if sa.get(n) != &d[..] {
                        bad.push(n.clone());
                    }
                }
                if sa.data.len() != so.data.len() {
                    bad.push(format!("{} vs {} sections", sa.data.len(), so.data.len()));
                }
                if bad.is_empty() {
                    same += 1;
                } else {
                    differ += 1;
                    println!("{p}: differs in {bad:?}");
                }
            }
            (a, o) => {
                differ += 1;
                println!("{p}: side {:?} / jxl-oxide {:?}", a.err(), o.err());
            }
        }
    }
    println!("{same} files stage the same from the side box, {differ} differ, {no_box} have no box");
    for use_side in [true, false] {
        stager::USE_SIDE.store(use_side, Relaxed);
        let mut best = f64::MAX;
        for _ in 0..3 {
            let t = std::time::Instant::now();
            let n: usize = blobs.par_iter().map(|b| stager::stage_bytes(b, "x").map(|r| r.1.data.len()).unwrap_or(0)).sum();
            std::hint::black_box(n);
            best = best.min(t.elapsed().as_secs_f64());
        }
        let t = std::time::Instant::now();
        for b in &blobs {
            std::hint::black_box(stager::stage_bytes(b, "x").ok());
        }
        println!("staging {} files {}: {:.1} ms on {} threads, {:.1} ms on one", blobs.len(),
            if use_side { "from the side boxes" } else { "with jxl-oxide" }, best * 1000.0, rayon::current_num_threads(),
            t.elapsed().as_secs_f64() * 1000.0);
    }
    stager::USE_SIDE.store(true, Relaxed);
}

/// A render as RGBA8 (grey replicated; alpha 255 when there is none).
fn rgba8(render: &jxl_oxide::Render) -> Vec<u8> {
    let fb = render.image_all_channels();
    let (w, h, ch) = (fb.width(), fb.height(), fb.channels());
    let mut rgba = vec![255u8; w * h * 4];
    for (i, px) in fb.buf().chunks_exact(ch).enumerate() {
        for c in 0..ch.min(4) {
            rgba[i * 4 + c] = (px[c] * 255.0 + 0.5).clamp(0.0, 255.0) as u8;
        }
        if ch == 1 {
            rgba[i * 4 + 1] = rgba[i * 4];
            rgba[i * 4 + 2] = rgba[i * 4];
        }
    }
    rgba
}

fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    if args[0] == "--time" {
        time_mode(&args[1..]);
        return;
    }
    if args[0] == "--annotate" {
        annotate(&args[1], &args[2..]);
        return;
    }
    if args[0] == "--sidecheck" {
        side_check(&args[1..]);
        return;
    }
    if args[0] == "--profile" {
        profile_mode(&args[1..]);
        return;
    }
    // --no-refs: leave out the reference sections (coefficients, XYB, RGBA), which are most of a job's size
    let refs = !args.iter().any(|a| a == "--no-refs");
    args.retain(|a| a != "--no-refs");
    let out = std::path::PathBuf::from(&args[0]);
    std::fs::create_dir_all(&out).unwrap();
    gpu_dump::ENABLED.store(true, std::sync::atomic::Ordering::Relaxed);
    for p in &args[1..] {
        let path = std::path::Path::new(p);
        let name = path.file_stem().unwrap().to_string_lossy().to_string();
        let bytes = std::fs::read(path).unwrap();
        let boxed = stager::read_hf_end_box(&bytes);
        let t0 = std::time::Instant::now();
        let image = JxlImage::builder()
            .pool(JxlThreadPool::none())
            .read(std::io::Cursor::new(bytes))
            .unwrap();
        let render = image.render_frame(0).unwrap();
        let rgba = rgba8(&render);
        let Some(mut dump) = gpu_dump::take() else {
            println!("{name}: no VarDCT dump");
            continue;
        };
        if let Some(m) = jxl_frame::HF_END.lock().unwrap().take() {
            let lp = dump.num_passes.max(1) - 1; // the alpha's pass (plan_alpha)
            dump.hf_end = (0..dump.num_groups).map(|g| m.get(&(lp, g)).copied().unwrap_or(0)).collect();
        }
        // an annotated file's constant alpha groups (what staging in the game would see)
        if let Some((_, consts)) = boxed {
            dump.alpha_const = consts;
        }
        match build(&dump, rgba, &name, refs) {
            Ok((header, s)) => {
                let transforms = header["transforms"].clone();
                let misaligned = header["misaligned"].clone();
                let alpha = header["alpha"].clone();
                write_job(&out.join(format!("{name}.job")), header, s).unwrap();
                println!("{name}: {}x{}, {} groups, {:.0} ms, misaligned {misaligned}, alpha {alpha}, transforms {transforms}", dump.width, dump.height, dump.num_groups,
                    t0.elapsed().as_secs_f64() * 1000.0);
            }
            Err(e) => println!("{name}: skipped ({e})"),
        }
    }
}
