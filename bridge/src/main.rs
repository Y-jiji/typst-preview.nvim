/// Bridge between tinymist preview data plane and SVG output.
/// Connects to the data plane WebSocket, receives incremental
/// binary diffs, maintains document state, and writes per-page
/// SVG to a file on each update.
use std::io::Write;

use clap::Parser;
use futures_util::StreamExt;
use reflexo::vector::{
    incr::IncrDocClient,
    ir::{LayoutRegion, ModuleMetadata, Rect, Scalar},
    stream::BytesModuleStream,
};
use reflexo_vec2svg::IncrSvgDocClient;
use tokio_tungstenite::{connect_async, tungstenite::Message};

#[derive(Parser)]
struct Args {
    /// Data plane WebSocket URL
    #[arg(long)]
    url: String,
    /// 1-indexed page number to render
    #[arg(long, default_value_t = 1)]
    page: usize,
    /// Output path (writes on each update)
    #[arg(long)]
    out: String,
}

/// Extract layout from delta metadata and set it on the client.
fn apply_layout(client: &mut IncrDocClient, meta: &[ModuleMetadata]) {
    for m in meta {
        if let ModuleMetadata::Layout(regions) = m {
            for region in regions.iter() {
                match region {
                    LayoutRegion::ByScalar(r) => {
                        if let Some((_, node)) = r.layouts.first() {
                            client.set_layout(node.clone());
                            return;
                        }
                    }
                    LayoutRegion::ByStr(r) => {
                        if let Some((_, node)) = r.layouts.first() {
                            client.set_layout(node.clone());
                            return;
                        }
                    }
                }
            }
        }
    }
}

/// Parse a data plane binary frame and merge into client state.
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
            apply_layout(client, &module.metadata);
            client.merge_delta(module);
            true
        }
        _ => false,
    }
}

/// Render a single page to SVG.
fn render_page(
    client: &mut IncrDocClient,
    svg: &mut IncrSvgDocClient,
    page: usize,
) -> Option<String> {
    let kern = client.kern();
    let pages = kern.pages_meta()?;
    if page == 0 || page > pages.len() {
        return None;
    }

    let mut y_lo: f32 = 0.0;
    for p in &pages[..page - 1] {
        y_lo += p.size.y.0;
    }
    let y_hi = y_lo + pages[page - 1].size.y.0;
    let x_hi = pages[page - 1].size.x.0;

    let rect = Rect {
        lo: reflexo::vector::ir::Point::new(Scalar(0.0), Scalar(y_lo)),
        hi: reflexo::vector::ir::Point::new(Scalar(x_hi), Scalar(y_hi)),
    };

    Some(svg.render_in_window(client, rect))
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
    let mut svg = IncrSvgDocClient::new();

    while let Some(msg) = read.next().await {
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

        svg.reset();
        if let Some(svg_str) = render_page(&mut client, &mut svg, args.page) {
            if let Ok(mut f) = std::fs::File::create(&args.out) {
                let _ = f.write_all(svg_str.as_bytes());
            }
        }
    }
}
