//! Unofficial Microsoft Teams desktop client built with Tauri.
//!
//! The whole application is a thin native shell around the Teams web client
//! (https://teams.microsoft.com). It loads Teams inside the system WebView and
//! adds the few behaviours that make the web app feel like a desktop app:
//!
//! * external links open in the user's default browser instead of hijacking the
//!   application window,
//! * in-app authentication popups (login.microsoftonline.com, ...) are opened in
//!   their own window so the OAuth flow completes inside the app,
//! * camera / microphone / notification permissions are granted automatically so
//!   calls and notifications work,
//! * the WebView data directory is persisted so the user stays signed in,
//! * Teams' web notifications are bridged to native desktop notifications and
//!   drive a red unread-count badge on the system tray icon,
//! * closing the window hides the app to the tray instead of quitting.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};

use tauri::{
    image::Image,
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    webview::{NewWindowResponse, PermissionKind, PermissionResponse},
    AppHandle, Manager, Runtime, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder,
};
use tauri_plugin_notification::NotificationExt;

/// Entry point of the Teams web client.
const TEAMS_URL: &str = "https://teams.microsoft.com/v2/";

/// Domains that are allowed to load inside the application WebView. Anything
/// host that matches one of these suffixes (or is an exact match) stays in the
/// app; every other link is handed over to the system browser.
///
/// Keep this list as small as possible: it is the only thing preventing a
/// malicious link from being loaded inside the privileged application context.
const TRUSTED_HOSTS: &[&str] = &[
    "teams.microsoft.com",
    "msteams.microsoft.com",
    "teams.live.com",
    "microsoft.com",
    "microsoftonline.com",
    "live.com",
    "office.com",
    "office.net",
    "office365.com",
    "sharepoint.com",
    "sharepointonline.com",
    "cloud.microsoft",
    "windows.net",
    "msauth.net",
    "msftauth.net",
    "msauthimages.net",
    "msftauthimages.net",
    "skype.com",
    "lync.com",
    "aka.ms",
    "azure.com",
    "azure.net",
    "trafficmanager.net",
];

/// Counter used to give every popup window a unique label.
static WINDOW_SEQ: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Copy)]
enum WindowKind {
    Main,
    Popup,
}

/// Returns `true` when `url` may be loaded inside the application without
/// exposing the user to content that does not belong to Teams/Microsoft.
fn is_trusted(url: &Url) -> bool {
    match url.scheme() {
        // Internal schemes used by Tauri as well as ephemeral web content.
        "tauri" | "asset" | "ipc" | "about" | "data" | "blob" => return true,
        "http" | "https" => {}
        _ => return false,
    }

    let Some(host) = url.host_str() else {
        return false;
    };

    let host = host.to_ascii_lowercase();
    TRUSTED_HOSTS.iter().any(|suffix| {
        host == *suffix || host.ends_with(&format!(".{suffix}"))
    })
}

/// Opens a URL in the user's default browser.
fn open_external<R: Runtime>(app: &AppHandle<R>, url: &Url) {
    use tauri_plugin_opener::OpenerExt;
    let _ = app.opener().open_url(url.as_str(), None::<&str>);
}

/// Camera, microphone and notifications must be granted for Teams calls and
/// notifications to work. Everything else keeps the browser default.
fn permission_response(kind: PermissionKind) -> PermissionResponse {
    match kind {
        PermissionKind::Camera
        | PermissionKind::Microphone
        | PermissionKind::Notifications
        | PermissionKind::DisplayCapture
        | PermissionKind::MediaKeySystemAccess
        | PermissionKind::PointerLock
        | PermissionKind::Autoplay => PermissionResponse::Allow,
        _ => PermissionResponse::Default,
    }
}

/// Builds a WebView window that loads `url` and shares the common Teams
/// behaviours (external link handling, popup handling and permissions).
fn create_window<R: Runtime>(
    app: &AppHandle<R>,
    label: &str,
    url: Url,
    kind: WindowKind,
    data_dir: PathBuf,
) -> tauri::Result<WebviewWindow<R>> {
    let nav_app = app.clone();
    let popup_app = app.clone();
    let popup_dir = data_dir.clone();

    let builder = WebviewWindowBuilder::new(app, label, WebviewUrl::External(url))
        .title("Microsoft Teams")
        .data_directory(data_dir)
        .min_inner_size(400.0, 300.0)
        .initialization_script(INJECT_JS)
        // Keep Teams/Microsoft navigation in-app, send the rest to the browser.
        .on_navigation(move |url| {
            if is_trusted(url) {
                true
            } else {
                open_external(&nav_app, url);
                false
            }
        })
        // `window.open` / target="_blank": complete OAuth popups in-app, open
        // ordinary web links in the system browser.
        .on_new_window(move |url, _features| {
            if is_trusted(&url) {
                let label = format!("auth-{}", WINDOW_SEQ.fetch_add(1, Ordering::Relaxed));
                match create_window(&popup_app, &label, url, WindowKind::Popup, popup_dir.clone()) {
                    Ok(window) => NewWindowResponse::Create { window },
                    Err(_) => NewWindowResponse::Deny,
                }
            } else {
                open_external(&popup_app, &url);
                NewWindowResponse::Deny
            }
        })
        .on_permission_request(|_webview, kind| permission_response(kind));

    match kind {
        WindowKind::Main => builder.inner_size(1280.0, 820.0).center().build(),
        WindowKind::Popup => builder.inner_size(520.0, 720.0).center().build(),
    }
}

/// JavaScript injected into every Teams window before the page scripts run.
///
/// It bridges the two signals Teams gives us about unread activity to the Rust
/// side: (1) the amount of web notifications fired (`new Notification(...)`),
/// which is the most reliable in-app signal, and (2) the unread counter Teams
/// puts in `document.title` (e.g. `(3) Microsoft Teams...`). Whichever is
/// higher wins, and the counter resets when the user looks at the window.
const INJECT_JS: &str = r#"
(function () {
  if (window.__msteamsHooked) return;
  window.__msteamsHooked = true;

  var sessionCount = 0;
  var titleCount = 0;
  var last = -1;

  function current() { return Math.max(sessionCount, titleCount); }

  function report() {
    var c = current();
    if (c === last) return;
    last = c;
    try {
      window.__TAURI_INTERNALS__.invoke("set_unread_count", { count: c });
    } catch (e) {}
  }

  function notify(title, body) {
    try {
      window.__TAURI_INTERNALS__.invoke("show_notification", {
        title: String(title == null ? "Microsoft Teams" : title),
        body: String(body == null ? "" : body)
      });
    } catch (e) {}
  }

  try {
    function TmsNotification(title, options) {
      options = options || {};
      sessionCount += 1;
      report();
      notify(title, options.body);
      this.title = title;
      this.body = options.body || "";
      this.onclick = null;
      this.close = function () {};
      this.addEventListener = function () {};
      this.removeEventListener = function () {};
      this.dispatchEvent = function () { return true; };
    }
    TmsNotification.permission = "granted";
    TmsNotification.requestPermission = function (cb) {
      if (typeof cb === "function") cb("granted");
      return Promise.resolve("granted");
    };
    window.Notification = TmsNotification;
  } catch (e) {}

  function scanTitle() {
    var m = /^\(\s*(\d+)\s*\)/.exec(document.title || "");
    var n = m ? parseInt(m[1], 10) : 0;
    if (n !== titleCount) { titleCount = n; report(); }
  }

  try {
    var head = document.head || document.documentElement;
    new MutationObserver(scanTitle).observe(head, {
      subtree: true, childList: true, characterData: true
    });
  } catch (e) {}

  window.addEventListener("focus", function () { sessionCount = 0; report(); });
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) { sessionCount = 0; report(); }
  });
  setInterval(scanTitle, 3000);
  setTimeout(scanTitle, 1500);
})();
"#;

/// Shared unread-message count driving the tray badge.
struct Unread(AtomicU32);

/// Minimal 3x5 bitmap glyphs for `0`-`9` and `+` (row-major, MSB = left).
const GLYPHS: [[u8; 5]; 11] = [
    [0b111, 0b101, 0b101, 0b101, 0b111], // 0
    [0b010, 0b110, 0b010, 0b010, 0b111], // 1
    [0b111, 0b001, 0b111, 0b100, 0b111], // 2
    [0b111, 0b001, 0b111, 0b001, 0b111], // 3
    [0b101, 0b101, 0b111, 0b001, 0b001], // 4
    [0b111, 0b100, 0b111, 0b001, 0b111], // 5
    [0b111, 0b100, 0b111, 0b101, 0b111], // 6
    [0b111, 0b001, 0b001, 0b001, 0b001], // 7
    [0b111, 0b101, 0b111, 0b101, 0b111], // 8
    [0b111, 0b101, 0b111, 0b001, 0b111], // 9
    [0b000, 0b010, 0b111, 0b010, 0b000], // +
];

fn glyph(c: u8) -> Option<&'static [u8; 5]> {
    match c {
        b'0'..=b'9' => Some(&GLYPHS[(c - b'0') as usize]),
        b'+' => Some(&GLYPHS[10]),
        _ => None,
    }
}

#[inline]
fn put_pixel(buf: &mut [u8], w: usize, h: usize, x: i32, y: i32, px: [u8; 4]) {
    if x < 0 || y < 0 || x as usize >= w || y as usize >= h {
        return;
    }
    let i = (y as usize * w + x as usize) * 4;
    buf[i..i + 4].copy_from_slice(&px);
}

/// Composites a red circle with a white count onto a copy of the base icon.
fn render_badge(base: &Image<'_>, count: u32) -> Image<'static> {
    let w = base.width() as usize;
    let h = base.height() as usize;
    let mut buf = base.rgba().to_vec();

    if count > 0 {
        let label = if count > 99 {
            "99+".to_string()
        } else {
            count.to_string()
        };

        let r = (w as i32 / 4).max(5);
        let cx = w as i32 - r - 1;
        let cy = r + 1;
        for y in (cy - r)..=(cy + r) {
            for x in (cx - r)..=(cx + r) {
                let (dx, dy) = (x - cx, y - cy);
                if dx * dx + dy * dy <= r * r {
                    put_pixel(&mut buf, w, h, x, y, [214, 40, 40, 255]);
                }
            }
        }

        let chars: Vec<u8> = label.into_bytes();
        let n = chars.len() as i32;
        let (gw, gh, sp) = (3, 5, 1);
        let text_w = n * gw + (n - 1) * sp;
        let max_dim = (2 * r - 4).max(1);
        let scale = (max_dim / text_w.max(1)).min(max_dim / gh).max(1);
        let start_x = cx - text_w * scale / 2;
        let start_y = cy - gh * scale / 2;

        for (i, ch) in chars.iter().enumerate() {
            let Some(g) = glyph(*ch) else { continue };
            let gx = start_x + i as i32 * (gw + sp) * scale;
            for (row, bits) in g.iter().enumerate() {
                for col in 0..gw {
                    if (bits >> (gw - 1 - col)) & 1 == 0 {
                        continue;
                    }
                    for sy in 0..scale {
                        for sx in 0..scale {
                            put_pixel(
                                &mut buf,
                                w,
                                h,
                                gx + col * scale + sx,
                                start_y + row as i32 * scale + sy,
                                [255, 255, 255, 255],
                            );
                        }
                    }
                }
            }
        }
    }

    Image::new_owned(buf, w as u32, h as u32)
}

/// Re-renders the tray icon and tooltip for the given unread count.
fn update_tray<R: Runtime>(app: &AppHandle<R>, count: u32) {
    let Some(tray) = app.tray_by_id("main") else {
        return;
    };
    if let Some(base) = app.default_window_icon() {
        let _ = tray.set_icon(Some(render_badge(base, count)));
    }
    let tip = if count == 0 {
        "Microsoft Teams".to_string()
    } else {
        format!("Microsoft Teams — {count} unread")
    };
    let _ = tray.set_tooltip(Some(tip));
}

fn show_main<R: Runtime>(app: &AppHandle<R>) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

/// Called from the injected script whenever the unread count changes.
#[tauri::command]
fn set_unread_count(app: AppHandle, unread: tauri::State<'_, Unread>, count: u32) {
    unread.0.store(count, Ordering::Relaxed);
    update_tray(&app, count);
}

/// Called from the injected script to show a native notification for a web
/// notification fired by Teams.
#[tauri::command]
fn show_notification(app: AppHandle, title: String, body: String) {
    let _ = app
        .notification()
        .builder()
        .title(title)
        .body(body)
        .show();
}

/// Application entry point shared by the desktop binary and (potentially)
/// mobile targets.
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_notification::init())
        .invoke_handler(tauri::generate_handler![set_unread_count, show_notification])
        .setup(|app| {
            let data_dir = app.path().app_data_dir()?;
            std::fs::create_dir_all(&data_dir).ok();

            app.manage(Unread(AtomicU32::new(0)));

            // System tray: click to restore the window, right-click for the menu.
            let show_i = MenuItem::with_id(app, "show", "Show Microsoft Teams", true, None::<&str>)?;
            let hide_i = MenuItem::with_id(app, "hide", "Hide to tray", true, None::<&str>)?;
            let separator = PredefinedMenuItem::separator(app)?;
            let quit_i = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show_i, &hide_i, &separator, &quit_i])?;

            let mut tray = TrayIconBuilder::with_id("main")
                .menu(&menu)
                .show_menu_on_left_click(true)
                .tooltip("Microsoft Teams")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => show_main(app),
                    "hide" => {
                        if let Some(window) = app.get_webview_window("main") {
                            let _ = window.hide();
                        }
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        show_main(tray.app_handle());
                    }
                });
            if let Some(icon) = app.default_window_icon().cloned() {
                tray = tray.icon(icon);
            }
            tray.build(app)?;

            let url = Url::parse(TEAMS_URL).expect("TEAMS_URL is a valid URL");
            create_window(app.handle(), "main", url, WindowKind::Main, data_dir)?;

            Ok(())
        })
        // Closing the main window hides the app to the tray; quit from the menu.
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running the Microsoft Teams desktop application");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blank(size: u32) -> Image<'static> {
        Image::new_owned(vec![0u8; (size * size * 4) as usize], size, size)
    }

    #[test]
    fn zero_count_leaves_icon_untouched() {
        let base = Image::new_owned(vec![1, 2, 3, 255].repeat(16 * 16), 16, 16);
        let out = render_badge(&base, 0);
        assert_eq!(out.rgba(), base.rgba());
    }

    #[test]
    fn nonzero_count_draws_red_badge_with_white_text() {
        let out = render_badge(&blank(32), 3);
        let rgba = out.rgba();
        let red = rgba
            .chunks_exact(4)
            .any(|p| p[0] > 150 && p[1] < 100 && p[2] < 100);
        let white = rgba
            .chunks_exact(4)
            .any(|p| p[0] > 200 && p[1] > 200 && p[2] > 200);
        assert!(red, "expected a red badge");
        assert!(white, "expected white count text");
    }
}
