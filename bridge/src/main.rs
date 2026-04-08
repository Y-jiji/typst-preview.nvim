/// Bridge between tinymist preview data plane and SVG output.
/// Accumulates incremental diffs, renders single-page SVG.
/// Reads page numbers from stdin for dynamic page switching.
use std::io::Write;

use clap::Parser;
use futures_util::StreamExt;
use reflexo::vector::{
    incr::IncrDocClient,
    ir::{LayoutRegion, ModuleMetadata, Rect, Scalar},
    stream::BytesModuleStream,
};
use reflexo_vec2svg::IncrSvgDocClient;
use tokio::io::AsyncBufReadExt;
use tokio_tungstenite::{connect_async, tungstenite::Message};

#[derive(Parser)]
struct Args {
    /// Data plane WebSocket URL
    #[arg(long)]
    url: String,
    /// Initial 1-indexed page number
    #[arg(long, default_value_t = 1)]
    page: usize,
    /// Output path (writes on each update)
    #[arg(long)]
    out: String,
}

/// Parse and merge a binary frame into client state.
fn handle(client: &mut IncrDocClient, data: &[u8]) -> bool {
    let comma = match data.iter().position(|&b| b == b',') {
        Some(i) => i,
        None => return false,
    };
    let prefix = match std::str::from_utf8(&data[..comma]) {
        Ok(s) => s,
        Err(_) => return false,
    };
    let payload = &data[comma + 1..];

    match prefix {
        "diff-v1" | "new" => {
            let stream = BytesModuleStream::from_slice(payload);
            let module = stream.checkout_owned();
            for m in &module.metadata {
                if let ModuleMetadata::Layout(regions) = m {
                    for region in regions.iter() {
                        match region {
                            LayoutRegion::ByScalar(r) => {
                                if let Some((_, node)) = r.layouts.first() {
                                    client.set_layout(node.clone());
                                }
                            }
                            LayoutRegion::ByStr(r) => {
                                if let Some((_, node)) = r.layouts.first() {
                                    client.set_layout(node.clone());
                                }
                            }
                        }
                    }
                }
            }
            client.merge_delta(module);
            true
        }
        _ => false,
    }
}

/// Render one page to standalone SVG with correct viewBox.
fn render_page(client: &mut IncrDocClient, page: usize) -> Option<String> {
    let kern = client.kern();
    let pages = kern.pages_meta()?;
    if page == 0 || page > pages.len() {
        return None;
    }

    // Page geometry
    let mut y_off: f32 = 0.0;
    for p in &pages[..page - 1] {
        y_off += p.size.y.0;
    }
    let pg_w = pages[page - 1].size.x.0;
    let pg_h = pages[page - 1].size.y.0;

    // Full document rect so all pages enter the doc_view
    let tot_w: f32 = pages.iter().map(|p| p.size.x.0).fold(0f32, |a, b| a.max(b));
    let tot_h: f32 = pages.iter().map(|p| p.size.y.0).sum();
    let rect = Rect {
        lo: reflexo::vector::ir::Point::new(Scalar(0.0), Scalar(0.0)),
        hi: reflexo::vector::ir::Point::new(Scalar(tot_w), Scalar(tot_h)),
    };

    let mut svg = IncrSvgDocClient::new();
    let raw = svg.render_in_window(client, rect);

    // Patch the <svg> tag: replace viewBox/width/height to show
    // only the target page region.
    let close = raw.find('>')?;
    let tag = &raw[..close];
    let rest = &raw[close..];

    let mut patched = String::with_capacity(raw.len());
    for attr in tag.split_inclusive('"') {
        if attr.contains("viewBox=\"") {
            patched.push_str(&format!(
                "viewBox=\"{y_off:.3} 0 {pg_w:.3} {pg_h:.3}\""
            ));
        } else if attr.contains("width=\"") {
            patched.push_str(&format!("width=\"{pg_w:.3}\""));
        } else if attr.contains("height=\"") {
            patched.push_str(&format!("height=\"{pg_h:.3}\""));
        } else if attr.contains("data-width=\"") {
            patched.push_str(&format!("data-width=\"{pg_w:.3}\""));
        } else if attr.contains("data-height=\"") {
            patched.push_str(&format!("data-height=\"{pg_h:.3}\""));
        } else {
            patched.push_str(attr);
        }
    }
    patched.push_str(rest);

    Some(patched)
}

fn write_svg(path: &str, svg: &str) {
    if let Ok(mut f) = std::fs::File::create(path) {
        let _ = f.write_all(svg.as_bytes());
    }
}

#[tokio::main]
async fn main() {
    let args = Args::parse();

    let (ws, _) = connect_async(&args.url)
        .await
        .expect("failed to connect to data plane");
    eprintln!("tvp-bridge: connected");

    let (_, mut read) = ws.split();
    let mut client = IncrDocClient::default();
    let mut page = args.page;

    let stdin = tokio::io::BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();

    loop {
        tokio::select! {
            msg = read.next() => {
                let Some(msg) = msg else { break };
                let msg = match msg {
                    Ok(m) => m,
                    Err(_) => continue,
                };
                let data = match &msg {
                    Message::Binary(d) => &d[..],
                    _ => continue,
                };
                if !handle(&mut client, data) {
                    continue;
                }
                if let Some(svg) = render_page(&mut client, page) {
                    write_svg(&args.out, &svg);
                }
            }
            line = lines.next_line() => {
                match line {
                    Ok(Some(s)) => {
                        if let Ok(n) = s.trim().parse::<usize>() {
                            page = n;
                            if let Some(svg) = render_page(&mut client, page) {
                                write_svg(&args.out, &svg);
                            }
                        }
                    }
                    _ => break,
                }
            }
        }
    }
}
