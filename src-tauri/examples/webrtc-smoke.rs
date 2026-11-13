use std::cell::Cell;
use std::rc::Rc;

use gtk::prelude::{ContainerExt, GtkWindowExt, WidgetExt};
use webkit2gtk::{glib, LoadEvent, PermissionRequestExt, SettingsExt, WebView, WebViewExt};

const TEST: &str = include_str!("webrtc-smoke.js");

fn main() {
    gtk::init().expect("GTK initialization failed");
    let window = gtk::Window::new(gtk::WindowType::Toplevel);
    window.set_default_size(640, 480);
    let view = WebView::new();
    if let Some(settings) = WebViewExt::settings(&view) {
        settings.set_enable_webrtc(true);
        settings.set_enable_media_stream(true);
        settings.set_enable_media_capabilities(true);
        settings.set_media_playback_requires_user_gesture(false);
        settings.set_enable_write_console_messages_to_stdout(true);
    }
    view.connect_permission_request(|_, request| {
        request.allow();
        true
    });
    window.add(&view);
    window.show_all();
    window.connect_destroy(|_| gtk::main_quit());

    let started = Rc::new(Cell::new(false));
    let started_callback = Rc::clone(&started);
    view.connect_load_changed(move |view, event| {
        if event == LoadEvent::Finished && !started_callback.replace(true) {
            view.evaluate_javascript(TEST, None, None, None::<&gio::Cancellable>, |result| {
                if let Err(error) = result {
                    eprintln!("JavaScript evaluation failed: {error}");
                    std::process::exit(1);
                }
            });
        }
    });
    view.connect_title_notify(|view| {
        let Some(title) = view.title() else { return };
        if title.starts_with("PASS ") || title.starts_with("ERROR ") {
            println!("{title}");
            std::process::exit(if title.starts_with("PASS ") { 0 } else { 1 });
        }
    });
    glib::timeout_add_local(std::time::Duration::from_secs(60), || {
        eprintln!("WebRTC smoke test timed out");
        std::process::exit(1);
    });
    let origin = if std::env::var_os("MSTEAMS_WEBRTC_SYNTHETIC").is_some() {
        "http://localhost/?synthetic"
    } else {
        "http://localhost/"
    };
    view.load_html("<title>WebRTC smoke test</title>", Some(origin));
    gtk::main();
}
